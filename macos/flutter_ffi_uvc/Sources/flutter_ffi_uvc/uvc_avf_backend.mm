// AVFoundation implementation of the flutter_ffi_uvc C ABI.
//
// The libuvc backend (src/backend_libuvc/flutter_ffi_uvc.c) and the Windows
// backend (windows/uvc_mf_backend.cpp) implement the same exported functions.
// This file must stay byte-compatible with them at the contract level: same
// symbol names, same JSON shapes for modes / controls / stream stats, same
// error-code conventions (libuvc-style negative codes). The Dart layer
// treats every backend identically.
//
// Streaming goes through AVFoundation and the system UVC driver. Controls go
// to the device as UVC class requests over IOKit (uvc_usb_controls.cpp).

#import "uvc_avf_backend.h"

#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "../../../../src/common/uvc_guard.h"
#include "../../../../src/common/uvc_requests_internal.h"
#include "../../../../src/include/flutter_ffi_uvc.h"
#include "uvc_usb_controls.h"

namespace {
struct Session;
}

// Sample buffer delegate bound to one session through a weak_ptr, so after
// uvc_session_destroy the lock() fails and the callback returns early.
@interface UvcFrameDelegate
    : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithSession:(std::weak_ptr<Session>)session
                     generation:(uint64_t)generation;
@end

namespace {

// libuvc uvc_frame_format values, mirrored so mode "format" ints round-trip
// through Dart identically on every platform.
constexpr int kFormatYuyv = 3;
constexpr int kFormatUyvy = 4;
constexpr int kFormatMjpeg = 7;
constexpr int kFormatNv12 = 17;

// libuvc uvc_error_t codes used by this backend.
constexpr int kErrorIo = -1;            // UVC_ERROR_IO
constexpr int kErrorInvalidParam = -2;  // UVC_ERROR_INVALID_PARAM
constexpr int kErrorAccess = -3;        // UVC_ERROR_ACCESS
constexpr int kErrorNoDevice = -4;      // UVC_ERROR_NO_DEVICE
constexpr int kErrorBusy = -6;          // UVC_ERROR_BUSY
constexpr int kErrorNotSupported = -12; // UVC_ERROR_NOT_SUPPORTED
constexpr int kErrorInvalidMode = -51;  // UVC_ERROR_INVALID_MODE

// 'usb ', the AVCaptureDevice.transportType of a USB camera.
constexpr int32_t kTransportTypeUsb = 0x75736220;

struct ModeInfo {
  int format = 0;
  const char* format_name = "UNKNOWN";
  int width = 0;
  int height = 0;
  int fps = 0;
  AVCaptureDeviceFormat* native = nil;
  CMTime frame_duration = kCMTimeInvalid;
};

struct StreamStats {
  uint64_t input_frame_count = 0;
  uint64_t delivered_frame_count = 0;
  uint64_t decode_success_count = 0;
  uint64_t decode_failure_count = 0;
  uint64_t undersized_frame_count = 0;
  uint64_t buffer_allocation_failure_count = 0;
  uint64_t conversion_failure_count = 0;
  int64_t start_ns = 0;
  int64_t first_frame_ns = 0;
  int64_t last_delivered_ns = 0;
  double max_gap_ms = 0.0;
  double gap_sum_ms = 0.0;
  // Ring buffer of delivered-frame gaps for the p95 estimate.
  static constexpr size_t kGapCapacity = 512;
  double gaps_ms[kGapCapacity] = {};
  size_t gap_count = 0;
  size_t gap_next = 0;
};

// Process-wide state shared by every session. ProcessState::mutex is a leaf
// lock, held only around the device id table.
struct ProcessState {
  std::mutex mutex;
  // Stable process-lifetime device ids keyed by AVCaptureDevice.uniqueID.
  std::map<std::string, int> id_by_unique_id;
  int next_device_id = 1;

  std::atomic<int> log_level{1};
};

ProcessState process;

// Live session wrappers for uvc_session_acquire/release, compared by address
// so a freed pointer is never dereferenced. registry.mutex is a leaf lock
// and is never held while taking any other lock or calling into a session.
struct RegistryEntry {
  uint64_t id = 0;  // never reused within the process
  int pins = 0;
  bool destroying = false;
};

struct SessionRegistry {
  std::mutex mutex;
  std::condition_variable unpinned;  // signalled when an entry's pins hit 0
  std::map<const uvc_session*, RegistryEntry> live;
  uint64_t next_id = 1;
};

SessionRegistry registry;

// One camera session. Everything a Dart UvcCamera instance touches lives
// here.
//
// Lock order, outer to inner:
//   lifecycle_mutex -> mutex -> rec_mutex -> error_mutex
//   lifecycle_mutex -> ctrl_mutex -> error_mutex
// The sample buffer delegate takes mutex and rec_mutex but never
// lifecycle_mutex, so a lifecycle call may wait for the frame queue to drain
// while holding it. Never wait for the frame queue with mutex or rec_mutex
// held. Never invoke a listener with a session lock held.
struct Session {
  // Serializes open, start, stop, and close, and guards the capture
  // objects below.
  std::mutex lifecycle_mutex;
  AVCaptureSession* capture = nil;
  AVCaptureVideoDataOutput* output = nil;
  UvcFrameDelegate* delegate = nil;
  id runtime_error_observer = nil;
  id disconnect_observer = nil;
  // Serial queue the sample buffer delegate runs on.
  dispatch_queue_t frame_queue = nil;

  // Guards everything below up to the listeners.
  std::mutex mutex;

  // Open device. unique_id stays set while a device is open.
  std::string unique_id;
  AVCaptureDevice* device = nil;
  std::vector<ModeInfo> modes;

  // Preview.
  std::atomic<bool> previewing{false};
  // Bumped on every start and stop so a late frame of the previous stream
  // is ignored.
  uint64_t generation = 0;
  std::vector<uint8_t> rgba;
  // Capture buffer of the frame in rgba, rendered by the Flutter texture
  // without a copy when no transform is set.
  CVPixelBufferRef latest_buffer = nullptr;
  int frame_w = 0;
  int frame_h = 0;
  std::atomic<int64_t> sequence{0};
  StreamStats stats;

  // Transform applied to the Flutter texture only.
  int rotation = 0;
  int flip_h = 0;
  int flip_v = 0;

  // Guarded by listener_mutex, which is held while a listener runs so
  // clearing a slot returns only after a call in progress has finished.
  // Leaf lock. A listener must not call back into the ABI.
  std::mutex listener_mutex;
  uvc_frame_listener_t frame_listener = nullptr;
  void* frame_listener_data = nullptr;
  uvc_error_listener_t error_listener = nullptr;
  void* error_listener_data = nullptr;

  // Guarded by error_mutex.
  std::mutex error_mutex;
  char last_error[512] = {0};
  // Stream errors reported to the error listener since creation.
  std::atomic<int64_t> error_count{0};
  // Copy handed to uvc_last_error callers. Written only by uvc_last_error.
  char last_error_snapshot[512] = {0};

  // UVC controls over IOKit. Null when the USB device cannot be reached,
  // with the reason in usb_error. Guarded by ctrl_mutex.
  std::mutex ctrl_mutex;
  std::unique_ptr<uvc_mac::UsbControlDevice> usb;
  std::string usb_error;

  // MP4 recording. rec_mutex serializes appends against the finish.
  std::mutex rec_mutex;
  std::atomic<bool> recording{false};
  AVAssetWriter* writer = nil;
  AVAssetWriterInput* writer_input = nil;
  AVAssetWriterInputPixelBufferAdaptor* writer_adaptor = nil;
  int rec_src_w = 0, rec_src_h = 0;  // expected preview frame dimensions
  int rec_w = 0, rec_h = 0;          // post-transform (encoded) dimensions
  int rec_rotation = 0, rec_flip_h = 0, rec_flip_v = 0;
  int64_t rec_start_ns = 0;
  int64_t rec_last_us = -1;
  // Atomics: bumped under rec_mutex when writing but also under mutex in
  // the frame callback's dimension-mismatch path.
  std::atomic<uint64_t> rec_frames_written{0};
  std::atomic<uint64_t> rec_frames_dropped{0};
  // Set by the first failed append, which is the only one reported. The
  // recording stays active until it is stopped, and the stop then fails.
  // Guarded by rec_mutex.
  bool rec_failed = false;

  Session() {
    frame_queue = dispatch_queue_create("com.cornpip.flutter_ffi_uvc.frames",
                                        DISPATCH_QUEUE_SERIAL);
  }
  ~Session() {
    if (latest_buffer != nullptr) {
      CVPixelBufferRelease(latest_buffer);
      latest_buffer = nullptr;
    }
  }
  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;
};

}  // namespace

// Opaque handle handed to Dart. The shared_ptr lets a late AVFoundation
// callback keep the Session alive after uvc_session_finalize freed this
// wrapper.
struct uvc_session {
  std::shared_ptr<Session> impl;
};

namespace {

std::shared_ptr<Session> Impl(uvc_session_t* session) {
  return session != nullptr ? session->impl : nullptr;
}

int64_t NowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

double NsToMs(int64_t ns) { return static_cast<double>(ns) / 1000000.0; }

std::string Utf8(NSString* string) {
  const char* utf8 = string != nil ? string.UTF8String : nullptr;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

void SetErrorMessage(Session& s, const char* fmt, ...) {
  std::lock_guard<std::mutex> lock(s.error_mutex);
  va_list args;
  va_start(args, fmt);
  vsnprintf(s.last_error, sizeof(s.last_error), fmt, args);
  va_end(args);
}

// Sets last_error and pushes the message to the Dart stream-error listener.
void ReportError(Session& s, const char* fmt, ...) {
  char message[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(message, sizeof(message), fmt, args);
  va_end(args);
  {
    std::lock_guard<std::mutex> lock(s.error_mutex);
    strlcpy(s.last_error, message, sizeof(s.last_error));
  }
  s.error_count.fetch_add(1);
  std::lock_guard<std::mutex> lock(s.listener_mutex);
  if (s.error_listener != nullptr) {
    s.error_listener(s.error_listener_data, message);
  }
}

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

int AssignId(const std::string& unique_id) {
  std::lock_guard<std::mutex> lock(process.mutex);
  auto it = process.id_by_unique_id.find(unique_id);
  if (it != process.id_by_unique_id.end()) return it->second;
  const int id = process.next_device_id++;
  process.id_by_unique_id[unique_id] = id;
  return id;
}

// Parses the decimal number that follows needle, 0 when absent.
int ParseDecimalAfter(NSString* haystack, NSString* needle) {
  if (haystack == nil) return 0;
  const NSRange range = [haystack rangeOfString:needle];
  if (range.location == NSNotFound) return 0;
  return [[haystack substringFromIndex:NSMaxRange(range)] intValue];
}

// The uniqueID of a UVC camera is "0x" + location id + vendor id + product
// id in hex, the last two padded to four digits.
uvc_mac::UsbIds UsbIdsForDevice(AVCaptureDevice* device) {
  uvc_mac::UsbIds ids;
  ids.vendor_id =
      static_cast<uint16_t>(ParseDecimalAfter(device.modelID, @"VendorID_"));
  ids.product_id =
      static_cast<uint16_t>(ParseDecimalAfter(device.modelID, @"ProductID_"));
  NSString* unique = device.uniqueID.lowercaseString;
  if ([unique hasPrefix:@"0x"] && unique.length > 10 && unique.length <= 18) {
    unsigned long long value = 0;
    NSScanner* scanner =
        [NSScanner scannerWithString:[unique substringFromIndex:2]];
    if ([scanner scanHexLongLong:&value] && scanner.isAtEnd) {
      const uint16_t pid = static_cast<uint16_t>(value & 0xffff);
      const uint16_t vid = static_cast<uint16_t>((value >> 16) & 0xffff);
      if (ids.vendor_id == 0 && ids.product_id == 0) {
        ids.vendor_id = vid;
        ids.product_id = pid;
      }
      // The location only counts when the rest of the id agrees with the
      // model id, which shows the id has the expected layout.
      if (vid == ids.vendor_id && pid == ids.product_id) {
        ids.location = static_cast<uint32_t>(value >> 32);
        ids.has_location = true;
      }
    }
  }
  return ids;
}

// The device type of an external camera, which was renamed in macOS 14.
AVCaptureDeviceType ExternalType() {
  if (@available(macOS 14.0, *)) {
    return AVCaptureDeviceTypeExternal;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return AVCaptureDeviceTypeExternalUnknown;
#pragma clang diagnostic pop
}

bool IsExternalType(AVCaptureDeviceType type) {
  return type != nil && [type isEqualToString:ExternalType()];
}


bool SubtypeToFormat(FourCharCode subtype, int* format, const char** name) {
  switch (subtype) {
    case kCVPixelFormatType_422YpCbCr8_yuvs:
      *format = kFormatYuyv;
      *name = "YUYV";
      return true;
    case kCVPixelFormatType_422YpCbCr8:
      *format = kFormatUyvy;
      *name = "UYVY";
      return true;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      *format = kFormatNv12;
      *name = "NV12";
      return true;
    case kCMVideoCodecType_JPEG:
    case kCMVideoCodecType_JPEG_OpenDML:
      *format = kFormatMjpeg;
      *name = "MJPEG";
      return true;
    default:
      // H.264 lands here on purpose: an inter-frame codec breaks this
      // package's per-frame validation model. See doc/macos-backend.md.
      return false;
  }
}

// Caller holds s.mutex.
void EnumerateModesLocked(Session& s) {
  s.modes.clear();
  if (s.device == nil) return;
  for (AVCaptureDeviceFormat* format in s.device.formats) {
    const CMFormatDescriptionRef description = format.formatDescription;
    if (CMFormatDescriptionGetMediaType(description) != kCMMediaType_Video) {
      continue;
    }
    ModeInfo mode;
    if (!SubtypeToFormat(CMFormatDescriptionGetMediaSubType(description),
                         &mode.format, &mode.format_name)) {
      continue;
    }
    const CMVideoDimensions size =
        CMVideoFormatDescriptionGetDimensions(description);
    if (size.width <= 0 || size.height <= 0) continue;
    mode.width = size.width;
    mode.height = size.height;
    mode.native = format;
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
      mode.fps = static_cast<int>(range.maxFrameRate + 0.5);
      mode.frame_duration = range.minFrameDuration;
      if (mode.fps <= 0) continue;
      const bool listed = std::any_of(
          s.modes.begin(), s.modes.end(), [&mode](const ModeInfo& other) {
            return other.format == mode.format && other.width == mode.width &&
                   other.height == mode.height && other.fps == mode.fps;
          });
      if (!listed) s.modes.push_back(mode);
    }
  }
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

// Copies 4-byte pixels from src into dst applying rotation (0/90/180/270
// clockwise) and flips, swapping the first and third channel when swap_rb
// is set. dst_w/dst_h are the post-rotation dimensions.
void TransformPixels(const uint8_t* src, size_t src_stride, int src_w,
                     int src_h, int rotation, int flip_h, int flip_v,
                     uint8_t* dst, size_t dst_stride, int dst_w, int dst_h,
                     bool swap_rb) {
  for (int y = 0; y < dst_h; ++y) {
    uint8_t* out = dst + static_cast<size_t>(y) * dst_stride;
    for (int x = 0; x < dst_w; ++x) {
      const int ox = flip_h != 0 ? dst_w - 1 - x : x;
      const int oy = flip_v != 0 ? dst_h - 1 - y : y;
      int sx, sy;
      switch (rotation) {
        case 90:
          sx = oy;
          sy = src_h - 1 - ox;
          break;
        case 180:
          sx = src_w - 1 - ox;
          sy = src_h - 1 - oy;
          break;
        case 270:
          sx = src_w - 1 - oy;
          sy = ox;
          break;
        default:
          sx = ox;
          sy = oy;
          break;
      }
      const uint8_t* in = src + static_cast<size_t>(sy) * src_stride +
                          static_cast<size_t>(sx) * 4;
      if (swap_rb) {
        out[0] = in[2];
        out[1] = in[1];
        out[2] = in[0];
        out[3] = in[3];
      } else {
        memcpy(out, in, 4);
      }
      out += 4;
    }
  }
}

// A BGRA buffer a Flutter texture can render and an asset writer can encode.
CVPixelBufferRef CreateBgraBuffer(int width, int height) {
  NSDictionary* attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef buffer = nullptr;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                          kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)attributes,
                          &buffer) != kCVReturnSuccess) {
    return nullptr;
  }
  return buffer;
}

// Caller holds s.mutex.
void RecordDeliveredLocked(Session& s) {
  const int64_t now = NowNs();
  StreamStats& st = s.stats;
  st.delivered_frame_count += 1;
  st.decode_success_count += 1;
  if (st.first_frame_ns == 0) st.first_frame_ns = now;
  if (st.last_delivered_ns != 0) {
    const double gap_ms = NsToMs(now - st.last_delivered_ns);
    st.gap_sum_ms += gap_ms;
    if (gap_ms > st.max_gap_ms) st.max_gap_ms = gap_ms;
    st.gaps_ms[st.gap_next] = gap_ms;
    st.gap_next = (st.gap_next + 1) % StreamStats::kGapCapacity;
    if (st.gap_count < StreamStats::kGapCapacity) st.gap_count += 1;
  }
  st.last_delivered_ns = now;
}

// Converts one BGRA capture buffer into the session's RGBA buffer. Returns
// true when a frame was delivered. Caller holds s.mutex.
bool ConvertFrameLocked(Session& s, CVPixelBufferRef pixels) {
  if (CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA ||
      CVPixelBufferIsPlanar(pixels)) {
    s.stats.conversion_failure_count += 1;
    return false;
  }
  if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) !=
      kCVReturnSuccess) {
    s.stats.conversion_failure_count += 1;
    return false;
  }
  bool delivered = false;
  const size_t w = CVPixelBufferGetWidth(pixels);
  const size_t h = CVPixelBufferGetHeight(pixels);
  const size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  void* base = CVPixelBufferGetBaseAddress(pixels);
  if (base == nullptr || w == 0 || h == 0 || w > INT32_MAX / 4 ||
      h > INT32_MAX / 4 || stride < w * 4) {
    s.stats.undersized_frame_count += 1;
    s.stats.decode_failure_count += 1;
  } else {
    const size_t out_bytes = w * h * 4;
    try {
      if (s.rgba.size() != out_bytes) s.rgba.resize(out_bytes);
    } catch (...) {
      s.rgba.clear();
    }
    if (s.rgba.size() != out_bytes) {
      s.stats.buffer_allocation_failure_count += 1;
    } else {
      vImage_Buffer src = {base, h, w, stride};
      vImage_Buffer dst = {s.rgba.data(), h, w, w * 4};
      const uint8_t bgra_to_rgba[4] = {2, 1, 0, 3};
      if (vImagePermuteChannels_ARGB8888(&src, &dst, bgra_to_rgba,
                                         kvImageNoFlags) != kvImageNoError) {
        s.stats.conversion_failure_count += 1;
      } else {
        // Opaque alpha, as the other backends deliver it.
        vImageOverwriteChannelsWithScalar_ARGB8888(255, &dst, &dst, 0x1,
                                                   kvImageNoFlags);
        s.frame_w = static_cast<int>(w);
        s.frame_h = static_cast<int>(h);
        s.sequence.fetch_add(1);
        RecordDeliveredLocked(s);
        delivered = true;
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  return delivered;
}

// ---------------------------------------------------------------------------
// MP4 recording (AVAssetWriter)
// ---------------------------------------------------------------------------

// Appends one frame to the asset writer. Called from the frame queue
// without s.mutex held.
void WriteRecordingFrame(Session& s, CVPixelBufferRef pixels, int64_t now_ns) {
  NSString* failure = nil;
  {
    std::lock_guard<std::mutex> lock(s.rec_mutex);
    if (!s.recording.load() || s.writer_input == nil ||
        s.writer_adaptor == nil) {
      return;
    }
    if (s.rec_failed || !s.writer_input.readyForMoreMediaData) {
      s.rec_frames_dropped += 1;
      return;
    }

    CVPixelBufferRef frame = nullptr;
    if (s.rec_rotation == 0 && s.rec_flip_h == 0 && s.rec_flip_v == 0) {
      frame = CVPixelBufferRetain(pixels);
    } else {
      frame = CreateBgraBuffer(s.rec_w, s.rec_h);
      if (frame != nullptr) {
        const bool locked =
            CVPixelBufferLockBaseAddress(
                pixels, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess;
        if (locked && CVPixelBufferLockBaseAddress(frame, 0) ==
                          kCVReturnSuccess) {
          TransformPixels(
              static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixels)),
              CVPixelBufferGetBytesPerRow(pixels), s.rec_src_w, s.rec_src_h,
              s.rec_rotation, s.rec_flip_h, s.rec_flip_v,
              static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(frame)),
              CVPixelBufferGetBytesPerRow(frame), s.rec_w, s.rec_h, false);
          CVPixelBufferUnlockBaseAddress(frame, 0);
        } else {
          CVPixelBufferRelease(frame);
          frame = nullptr;
        }
        if (locked) {
          CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        }
      }
    }
    if (frame == nullptr) {
      s.rec_frames_dropped += 1;
      return;
    }

    int64_t us = (now_ns - s.rec_start_ns) / 1000;
    if (us <= s.rec_last_us) us = s.rec_last_us + 1;
    BOOL appended = NO;
    @try {
      appended = [s.writer_adaptor
             appendPixelBuffer:frame
          withPresentationTime:CMTimeMake(us, 1000000)];
    } @catch (NSException* exception) {
      failure = exception.reason ?: @"exception";
    }
    CVPixelBufferRelease(frame);
    if (appended) {
      s.rec_last_us = us;
      s.rec_frames_written += 1;
      return;
    }
    s.rec_frames_dropped += 1;
    s.rec_failed = true;
    if (failure == nil) {
      failure = s.writer.error.localizedDescription ?: @"unknown error";
    }
  }
  ReportError(s, "Recording append failed: %s", failure.UTF8String);
}

// Stops accepting frames, then finishes the MP4 outside rec_mutex so an
// append in progress can return first.
int StopRecordingInternal(Session& s) {
  AVAssetWriter* writer = nil;
  AVAssetWriterInput* input = nil;
  uint64_t written = 0;
  bool failed = false;
  {
    std::lock_guard<std::mutex> lock(s.rec_mutex);
    if (!s.recording.exchange(false)) return 0;
    failed = s.rec_failed;
    writer = s.writer;
    input = s.writer_input;
    s.writer = nil;
    s.writer_input = nil;
    s.writer_adaptor = nil;
    written = s.rec_frames_written.load();
  }
  if (writer == nil) return 0;
  if (failed || writer.status == AVAssetWriterStatusFailed) {
    SetErrorMessage(s, "Recording failed: %s",
                    writer.error.localizedDescription.UTF8String ?: "unknown");
    [writer cancelWriting];
    return kErrorIo;
  }
  if (written == 0) {
    [writer cancelWriting];
    SetErrorMessage(s, "Recording produced no encoded frames");
    return kErrorIo;
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  @try {
    [input markAsFinished];
    [writer finishWritingWithCompletionHandler:^{
      dispatch_semaphore_signal(done);
    }];
  } @catch (NSException* exception) {
    SetErrorMessage(s, "Failed to finalize recording: %s",
                    exception.reason.UTF8String);
    return kErrorIo;
  }
  if (dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
    SetErrorMessage(s, "Timed out finalizing the recording");
    return kErrorIo;
  }
  if (writer.status != AVAssetWriterStatusCompleted) {
    SetErrorMessage(s, "Failed to finalize recording: %s",
                    writer.error.localizedDescription.UTF8String);
    return kErrorIo;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// Runs on the session's frame queue.
void OnFrame(Session& s, uint64_t generation, CMSampleBufferRef sample) {
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
  bool delivered = false;
  bool record_frame = false;
  int64_t sequence = 0;
  CVPixelBufferRef previous = nullptr;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.previewing.load() || s.generation != generation) return;
    s.stats.input_frame_count += 1;
    if (pixels == nullptr) {
      s.stats.decode_failure_count += 1;
    } else {
      delivered = ConvertFrameLocked(s, pixels);
    }
    if (delivered) {
      sequence = s.sequence.load();
      previous = s.latest_buffer;
      s.latest_buffer = CVPixelBufferRetain(pixels);
      {
        // A delivered frame clears the last error, as on the libuvc backend.
        std::lock_guard<std::mutex> error_lock(s.error_mutex);
        s.last_error[0] = '\0';
      }
      if (s.recording.load()) {
        if (s.frame_w == s.rec_src_w && s.frame_h == s.rec_src_h) {
          record_frame = true;
        } else {
          s.rec_frames_dropped += 1;
        }
      }
    }
  }
  if (previous != nullptr) CVPixelBufferRelease(previous);
  if (!delivered) return;
  {
    std::lock_guard<std::mutex> lock(s.listener_mutex);
    if (s.frame_listener != nullptr) {
      s.frame_listener(s.frame_listener_data, sequence);
    }
  }
  if (record_frame) WriteRecordingFrame(s, pixels, NowNs());
}

// Stops the stream and waits for a frame callback in progress. Caller holds
// s.lifecycle_mutex and neither s.mutex nor s.rec_mutex.
void StopPreviewLocked(Session& s) {
  StopRecordingInternal(s);
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    s.previewing.store(false);
    s.generation += 1;
  }
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  if (s.runtime_error_observer != nil) {
    [center removeObserver:s.runtime_error_observer];
    s.runtime_error_observer = nil;
  }
  if (s.disconnect_observer != nil) {
    [center removeObserver:s.disconnect_observer];
    s.disconnect_observer = nil;
  }
  if (s.capture != nil) {
    @try {
      [s.capture stopRunning];
      [s.output setSampleBufferDelegate:nil queue:nil];
    } @catch (NSException* exception) {
    }
    // A callback that was already queued sees the bumped generation.
    dispatch_sync(s.frame_queue, ^{
                  });
  }
  s.capture = nil;
  s.output = nil;
  s.delegate = nil;
}

// Caller holds s.lifecycle_mutex with the preview stopped.
void CloseDeviceLocked(Session& s) {
  CVPixelBufferRef latest = nullptr;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    s.unique_id.clear();
    s.device = nil;
    s.modes.clear();
    s.frame_w = 0;
    s.frame_h = 0;
    s.sequence.store(0);
    s.rgba.clear();
    latest = s.latest_buffer;
    s.latest_buffer = nullptr;
  }
  if (latest != nullptr) CVPixelBufferRelease(latest);
  std::lock_guard<std::mutex> lock(s.ctrl_mutex);
  s.usb.reset();
  s.usb_error.clear();
}

bool AppendJson(char* buffer, size_t capacity, size_t* offset, const char* fmt,
                ...) {
  if (*offset >= capacity) return false;
  va_list args;
  va_start(args, fmt);
  const int written =
      vsnprintf(buffer + *offset, capacity - *offset, fmt, args);
  va_end(args);
  if (written < 0 || static_cast<size_t>(written) >= capacity - *offset) {
    return false;
  }
  *offset += static_cast<size_t>(written);
  return true;
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

struct CtrlInfo {
  int id;
  const char* name;
  const char* label;
  const char* ui_type;
  // true = Camera Terminal, false = Processing Unit
  bool is_ct;
  // UVC control selector. BmControlsBit gives its bmControls bit.
  uint8_t selector;
  // Payload size in bytes.
  uint8_t length;
  bool is_signed;
};

// Names / labels / uiTypes mirror the libuvc backend's k_ctrl_table so the
// Dart-visible control metadata matches across platforms.
const CtrlInfo kCtrlTable[] = {
    {UVC_CTRL_ID_BRIGHTNESS, "brightness", "Brightness", "slider", false, 0x02,
     2, true},
    {UVC_CTRL_ID_CONTRAST, "contrast", "Contrast", "slider", false, 0x03, 2,
     false},
    {UVC_CTRL_ID_HUE, "hue", "Hue", "slider", false, 0x06, 2, true},
    {UVC_CTRL_ID_SATURATION, "saturation", "Saturation", "slider", false, 0x07,
     2, false},
    {UVC_CTRL_ID_SHARPNESS, "sharpness", "Sharpness", "slider", false, 0x08, 2,
     false},
    {UVC_CTRL_ID_GAMMA, "gamma", "Gamma", "slider", false, 0x09, 2, false},
    {UVC_CTRL_ID_GAIN, "gain", "Gain", "slider", false, 0x04, 2, false},
    {UVC_CTRL_ID_BACKLIGHT_COMPENSATION, "backlight_compensation",
     "Backlight Compensation", "slider", false, 0x01, 2, false},
    {UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE, "white_balance_temperature",
     "White Balance Temperature", "slider", false, 0x0a, 2, false},
    {UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO, "white_balance_temp_auto",
     "Auto White Balance", "bool", false, 0x0b, 1, false},
    {UVC_CTRL_ID_POWER_LINE_FREQUENCY, "power_line_frequency",
     "Power Line Frequency", "enum", false, 0x05, 1, false},
    {UVC_CTRL_ID_CONTRAST_AUTO, "contrast_auto", "Auto Contrast", "bool",
     false, 0x13, 1, false},
    {UVC_CTRL_ID_HUE_AUTO, "hue_auto", "Auto Hue", "bool", false, 0x10, 1,
     false},
    {UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO, "white_balance_component_auto",
     "Auto White Balance Component", "bool", false, 0x0d, 1, false},
    {UVC_CTRL_ID_DIGITAL_MULTIPLIER, "digital_multiplier",
     "Digital Multiplier", "slider", false, 0x0e, 2, false},
    {UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT, "digital_multiplier_limit",
     "Digital Multiplier Limit", "slider", false, 0x0f, 2, false},
    {UVC_CTRL_ID_ANALOG_VIDEO_STANDARD, "analog_video_standard",
     "Analog Video Standard", "enum", false, 0x11, 1, false},
    {UVC_CTRL_ID_ANALOG_LOCK_STATUS, "analog_lock_status",
     "Analog Lock Status", "enum", false, 0x12, 1, false},
    {UVC_CTRL_ID_SCANNING_MODE, "scanning_mode", "Scanning Mode", "bool", true,
     0x01, 1, false},
    {UVC_CTRL_ID_AE_MODE, "ae_mode", "Exposure Mode", "enum", true, 0x02, 1,
     false},
    {UVC_CTRL_ID_AE_PRIORITY, "ae_priority", "AE Priority", "bool", true, 0x03,
     1, false},
    {UVC_CTRL_ID_EXPOSURE_ABS, "exposure_abs", "Exposure Time", "slider", true,
     0x04, 4, false},
    {UVC_CTRL_ID_EXPOSURE_REL, "exposure_rel", "Exposure Step", "slider", true,
     0x05, 1, true},
    {UVC_CTRL_ID_FOCUS_ABS, "focus_abs", "Focus", "slider", true, 0x06, 2,
     false},
    {UVC_CTRL_ID_FOCUS_AUTO, "focus_auto", "Auto Focus", "bool", true, 0x08, 1,
     false},
    {UVC_CTRL_ID_IRIS_ABS, "iris_abs", "Iris", "slider", true, 0x09, 2, false},
    {UVC_CTRL_ID_IRIS_REL, "iris_rel", "Iris Step", "slider", true, 0x0a, 1,
     false},
    {UVC_CTRL_ID_ZOOM_ABS, "zoom_abs", "Zoom", "slider", true, 0x0b, 2, false},
    {UVC_CTRL_ID_ROLL_ABS, "roll_abs", "Roll", "slider", true, 0x0f, 2, true},
    {UVC_CTRL_ID_PRIVACY, "privacy", "Privacy", "bool", true, 0x11, 1, false},
    {UVC_CTRL_ID_FOCUS_SIMPLE, "focus_simple", "Simple Focus", "enum", true,
     0x12, 1, false},
};

// Compound control selectors.
constexpr uint8_t kPuWhiteBalanceComponent = 0x0c;
constexpr uint8_t kCtFocusRelative = 0x07;
constexpr uint8_t kCtZoomRelative = 0x0c;
constexpr uint8_t kCtPanTiltAbsolute = 0x0d;
constexpr uint8_t kCtPanTiltRelative = 0x0e;
constexpr uint8_t kCtRollRelative = 0x10;
constexpr uint8_t kCtDigitalWindow = 0x13;
constexpr uint8_t kCtRegionOfInterest = 0x14;

const CtrlInfo* FindCtrl(int ctrl_id) {
  for (const CtrlInfo& info : kCtrlTable) {
    if (info.id == ctrl_id) return &info;
  }
  return nullptr;
}

// Bit of a control in the descriptor bmControls of its unit, which the UVC
// specification orders differently from the selectors. -1 when unknown.
int BmControlsBit(bool is_ct, uint8_t selector) {
  // Indexed by selector.
  static const int8_t kCameraTerminal[] = {-1, 0,  1,  2,  3,  4,  5,
                                           6,  17, 7,  8,  9,  10, 11,
                                           12, 13, 14, 18, 19, 20, 21};
  static const int8_t kProcessingUnit[] = {-1, 8,  0,  1,  9,  10, 2,
                                           3,  4,  5,  6,  12, 7,  13,
                                           14, 15, 11, 16, 17, 18};
  if (is_ct) {
    return selector < sizeof(kCameraTerminal) ? kCameraTerminal[selector] : -1;
  }
  return selector < sizeof(kProcessingUnit) ? kProcessingUnit[selector] : -1;
}

bool Advertised(const uvc_mac::UsbControlDevice& usb, const CtrlInfo& info) {
  const uint64_t bitmap = info.is_ct ? usb.camera_terminal_controls()
                                     : usb.processing_unit_controls();
  const int bit = BmControlsBit(info.is_ct, info.selector);
  return bit >= 0 && (bitmap & (1ULL << bit)) != 0;
}

uint16_t ReadU16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

uint32_t ReadU32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

void WriteU16(uint8_t* p, uint16_t value) {
  p[0] = static_cast<uint8_t>(value & 0xff);
  p[1] = static_cast<uint8_t>(value >> 8);
}

void WriteU32(uint8_t* p, uint32_t value) {
  p[0] = static_cast<uint8_t>(value & 0xff);
  p[1] = static_cast<uint8_t>((value >> 8) & 0xff);
  p[2] = static_cast<uint8_t>((value >> 16) & 0xff);
  p[3] = static_cast<uint8_t>(value >> 24);
}

// Reads one value of a table control. Caller holds s.ctrl_mutex.
bool CtrlReadLocked(Session& s, const CtrlInfo& info, uint8_t request,
                    int32_t* out) {
  if (!s.usb) return false;
  uint8_t data[4] = {0, 0, 0, 0};
  if (s.usb->Request(info.is_ct, info.selector, request, data, info.length) !=
      0) {
    return false;
  }
  switch (info.length) {
    case 1:
      *out = info.is_signed ? static_cast<int8_t>(data[0]) : data[0];
      return true;
    case 2:
      *out = info.is_signed ? static_cast<int16_t>(ReadU16(data))
                            : ReadU16(data);
      return true;
    default:
      *out = static_cast<int32_t>(ReadU32(data));
      return true;
  }
}

// Takes ctrl_mutex and reads the current value of a compound control.
// Returns false, with nothing written, when the control cannot be read.
bool CompoundGet(uvc_session_t* session, bool is_ct, uint8_t selector,
                 uint8_t* data, uint16_t length) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return false;
  std::lock_guard<std::mutex> lock(s->ctrl_mutex);
  if (!s->usb) return false;
  return s->usb->Request(is_ct, selector, uvc_mac::kUvcGetCur, data, length) ==
         0;
}

int CompoundSet(uvc_session_t* session, bool is_ct, uint8_t selector,
                uint8_t* data, uint16_t length) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  bool open = false;
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    open = !s->unique_id.empty();
  }
  std::lock_guard<std::mutex> lock(s->ctrl_mutex);
  if (!s->usb) {
    if (!open) {
      SetErrorMessage(*s, "Camera is not open");
      return kErrorNoDevice;
    }
    SetErrorMessage(*s, "%s", s->usb_error.c_str());
    return kErrorNotSupported;
  }
  return s->usb->Request(is_ct, selector, uvc_mac::kUvcSetCur, data, length);
}

int WriteJson(uint8_t* buffer, int buffer_length, const char* fmt, ...) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  va_list args;
  va_start(args, fmt);
  const int written = vsnprintf(reinterpret_cast<char*>(buffer),
                                static_cast<size_t>(buffer_length), fmt, args);
  va_end(args);
  if (written < 0 || written >= buffer_length) return 0;
  return written;
}

}  // namespace

@implementation UvcFrameDelegate {
  std::weak_ptr<Session> _session;
  uint64_t _generation;
}

- (instancetype)initWithSession:(std::weak_ptr<Session>)session
                     generation:(uint64_t)generation {
  self = [super init];
  if (self != nil) {
    _session = std::move(session);
    _generation = generation;
  }
  return self;
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
  std::shared_ptr<Session> owner = _session.lock();
  if (!owner) return;
  // Nothing may unwind into AVFoundation.
  try {
    OnFrame(*owner, _generation, sampleBuffer);
  } catch (...) {
  }
}

@end

// ---------------------------------------------------------------------------
// Internal plugin-facing API
// ---------------------------------------------------------------------------

namespace uvc_mac {

AVCaptureDeviceDiscoverySession* CreateDiscoverySession() {
  return [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[
        ExternalType(), AVCaptureDeviceTypeBuiltInWideAngleCamera
      ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
}

bool IsListedDevice(AVCaptureDevice* device) {
  if (device == nil || ![device hasMediaType:AVMediaTypeVideo]) return false;
  if ([device.deviceType
          isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
    // A Continuity Camera reports the built-in type unless the app opts in
    // to its own type.
    if (@available(macOS 13.0, *)) {
      return !device.isContinuityCamera;
    }
    return true;
  }
  if (!IsExternalType(device.deviceType)) return false;
  if (device.transportType != kTransportTypeUsb) return false;
  const UsbIds ids = UsbIdsForDevice(device);
  return ids.vendor_id != 0 || ids.product_id != 0;
}

DeviceInfo InfoForDevice(AVCaptureDevice* device) {
  DeviceInfo info;
  if (device == nil) return info;
  const UsbIds ids = UsbIdsForDevice(device);
  info.unique_id = Utf8(device.uniqueID);
  info.name = Utf8(device.localizedName);
  info.manufacturer = Utf8(device.manufacturer);
  info.vendor_id = ids.vendor_id;
  info.product_id = ids.product_id;
  info.device_id = AssignId(info.unique_id);
  return info;
}

std::vector<DeviceInfo> ListDevices() {
  std::vector<DeviceInfo> result;
  @autoreleasepool {
    for (AVCaptureDevice* device in CreateDiscoverySession().devices) {
      if (!IsListedDevice(device)) continue;
      result.push_back(InfoForDevice(device));
    }
  }
  return result;
}

bool DeviceExists(int device_id) {
  for (const DeviceInfo& info : ListDevices()) {
    if (info.device_id == device_id) return true;
  }
  return false;
}

CVPixelBufferRef CopyPreviewPixelBuffer(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return nullptr;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->latest_buffer == nullptr || s->sequence.load() <= 0) return nullptr;
  if (s->rotation == 0 && s->flip_h == 0 && s->flip_v == 0) {
    return CVPixelBufferRetain(s->latest_buffer);
  }
  const int src_w = s->frame_w;
  const int src_h = s->frame_h;
  if (src_w <= 0 || src_h <= 0 ||
      s->rgba.size() < static_cast<size_t>(src_w) * src_h * 4) {
    return nullptr;
  }
  const bool swap = s->rotation == 90 || s->rotation == 270;
  const int dst_w = swap ? src_h : src_w;
  const int dst_h = swap ? src_w : src_h;
  CVPixelBufferRef out = CreateBgraBuffer(dst_w, dst_h);
  if (out == nullptr) return nullptr;
  if (CVPixelBufferLockBaseAddress(out, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(out);
    return nullptr;
  }
  TransformPixels(s->rgba.data(), static_cast<size_t>(src_w) * 4, src_w, src_h,
                  s->rotation, s->flip_h, s->flip_v,
                  static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(out)),
                  CVPixelBufferGetBytesPerRow(out), dst_w, dst_h, true);
  CVPixelBufferUnlockBaseAddress(out, 0);
  return out;
}

}  // namespace uvc_mac

// ---------------------------------------------------------------------------
// Exported C ABI (see src/include/flutter_ffi_uvc.h)
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT uvc_session_t* uvc_session_create(void) {
  uvc_session* session = nullptr;
  try {
    session = new uvc_session();
    session->impl = std::make_shared<Session>();
    std::lock_guard<std::mutex> lock(registry.mutex);
    RegistryEntry entry;
    entry.id = registry.next_id++;
    registry.live[session] = entry;
  } catch (...) {
    delete session;
    return nullptr;
  }
  return session;
}

FFI_PLUGIN_EXPORT uint64_t uvc_session_id(uvc_session_t* session) try {
  if (session == nullptr) return 0;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  return it == registry.live.end() ? 0 : it->second.id;
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT uvc_session_t* uvc_session_acquire_id(uint64_t id) try {
  if (id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(registry.mutex);
  for (auto& entry : registry.live) {
    if (entry.second.id != id || entry.second.destroying) continue;
    entry.second.pins += 1;
    return const_cast<uvc_session_t*>(entry.first);
  }
  return nullptr;
} catch (...) {
  return nullptr;
}

FFI_PLUGIN_EXPORT int uvc_session_acquire(uvc_session_t* session) try {
  if (session == nullptr) return 0;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  if (it == registry.live.end() || it->second.destroying) return 0;
  it->second.pins += 1;
  return 1;
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT void uvc_session_release(uvc_session_t* session) try {
  if (session == nullptr) return;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  if (it == registry.live.end() || it->second.pins <= 0) return;
  it->second.pins -= 1;
  if (it->second.pins == 0) registry.unpinned.notify_all();
} catch (...) {
}

FFI_PLUGIN_EXPORT void uvc_session_destroy(uvc_session_t* session) {
  uvc_requests_destroy(session, 0);
}

void uvc_session_finalize(uvc_session_t* session) try {
  if (session == nullptr) return;
  // Closing first leaves the session locks free while the retire below
  // waits for pins a plugin still holds.
  {
    std::shared_ptr<Session> s = Impl(session);
    if (s) {
      @autoreleasepool {
        std::lock_guard<std::mutex> lock(s->lifecycle_mutex);
        StopPreviewLocked(*s);
        CloseDeviceLocked(*s);
      }
    }
  }
  // Refuse new pins, wait for existing ones, then unlink. Only after this
  // point is it safe to delete the wrapper.
  {
    std::unique_lock<std::mutex> lock(registry.mutex);
    auto it = registry.live.find(session);
    if (it == registry.live.end() || it->second.destroying) return;
    it->second.destroying = true;
    registry.unpinned.wait(lock, [&] { return it->second.pins == 0; });
    registry.live.erase(it);
  }
  std::shared_ptr<Session> s = Impl(session);
  if (s) {
    std::lock_guard<std::mutex> lock(s->listener_mutex);
    s->frame_listener = nullptr;
    s->frame_listener_data = nullptr;
    s->error_listener = nullptr;
    s->error_listener_data = nullptr;
  }
  delete session;
  // A callback still holding a promoted weak_ptr releases the Session when
  // it returns. It sees previewing == false.
} catch (...) {
}

// On macOS there are no file descriptors: the "fd" is the stable device id
// handed out by device enumeration (see uvc_mac::ListDevices), which the
// Dart openUsbDevice flow passes straight back in.
FFI_PLUGIN_EXPORT int uvc_open_fd(uvc_session_t* session, int fd) try {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  @autoreleasepool {
    std::lock_guard<std::mutex> lifecycle(s.lifecycle_mutex);
    StopPreviewLocked(s);
    CloseDeviceLocked(s);

    std::string unique_id;
    for (const uvc_mac::DeviceInfo& info : uvc_mac::ListDevices()) {
      if (info.device_id == fd) {
        unique_id = info.unique_id;
        break;
      }
    }
    AVCaptureDevice* device =
        unique_id.empty()
            ? nil
            : [AVCaptureDevice deviceWithUniqueID:@(unique_id.c_str())];
    if (device == nil) {
      SetErrorMessage(s, "No video capture device with id %d", fd);
      return kErrorNoDevice;
    }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] !=
        AVAuthorizationStatusAuthorized) {
      SetErrorMessage(s, "Camera access has not been granted to this app");
      return kErrorAccess;
    }

    try {
      {
        std::lock_guard<std::mutex> lock(s.mutex);
        s.unique_id = unique_id;
        s.device = device;
        EnumerateModesLocked(s);
      }
      // Controls are optional. A device without them still streams. A
      // built-in camera that is not a USB device has no ids to find it by.
      std::string usb_error = "This camera has no UVC controls";
      std::unique_ptr<uvc_mac::UsbControlDevice> usb;
      const uvc_mac::UsbIds ids = UsbIdsForDevice(device);
      if (ids.vendor_id != 0 || ids.product_id != 0) {
        usb = uvc_mac::UsbControlDevice::Open(ids, &usb_error);
      }
      std::lock_guard<std::mutex> lock(s.ctrl_mutex);
      s.usb = std::move(usb);
      s.usb_error = usb_error;
    } catch (...) {
      // A failed open leaves no device behind for a later start to use.
      CloseDeviceLocked(s);
      throw;
    }
  }
  return 0;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_start_preview(uvc_session_t* session,
                                        int frame_format, int width,
                                        int height, int fps) try {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  @autoreleasepool {
    std::lock_guard<std::mutex> lifecycle(s.lifecycle_mutex);
    StopPreviewLocked(s);

    AVCaptureDevice* device = nil;
    ModeInfo mode;
    bool found = false;
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      if (s.unique_id.empty() || s.device == nil) {
        SetErrorMessage(s, "No device open");
        return kErrorNoDevice;
      }
      device = s.device;
      for (const ModeInfo& candidate : s.modes) {
        if (candidate.format == frame_format && candidate.width == width &&
            candidate.height == height && candidate.fps == fps) {
          mode = candidate;
          found = true;
          break;
        }
      }
    }
    if (!found) {
      SetErrorMessage(s, "Mode %dx%d@%d (format %d) not reported by device",
                      width, height, fps, frame_format);
      return kErrorInvalidMode;
    }
    if (!device.isConnected) {
      SetErrorMessage(s, "Video capture device disappeared");
      return kErrorNoDevice;
    }

    NSError* error = nil;
    AVCaptureDeviceInput* input =
        [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil) {
      SetErrorMessage(s, "Failed to open the capture device: %s",
                      error.localizedDescription.UTF8String);
      return [AVCaptureDevice
                 authorizationStatusForMediaType:AVMediaTypeVideo] ==
                     AVAuthorizationStatusAuthorized
                 ? kErrorIo
                 : kErrorAccess;
    }

    AVCaptureSession* capture = [[AVCaptureSession alloc] init];
    AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
    // AVFoundation decodes MJPEG and converts YUV. Metal compatibility lets
    // the Flutter texture render the capture buffer itself.
    output.videoSettings = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    output.alwaysDiscardsLateVideoFrames = YES;

    uint64_t generation = 0;
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      s.generation += 1;
      generation = s.generation;
    }
    UvcFrameDelegate* delegate =
        [[UvcFrameDelegate alloc] initWithSession:std::weak_ptr<Session>(owner)
                                       generation:generation];
    [output setSampleBufferDelegate:delegate queue:s.frame_queue];

    [capture beginConfiguration];
    const bool added =
        [capture canAddInput:input] && [capture canAddOutput:output];
    if (added) {
      [capture addInput:input];
      [capture addOutput:output];
    }
    [capture commitConfiguration];
    if (!added) {
      [output setSampleBufferDelegate:nil queue:nil];
      SetErrorMessage(s, "The capture session rejected the device");
      return kErrorBusy;
    }

    {
      std::lock_guard<std::mutex> lock(s.mutex);
      s.frame_w = mode.width;
      s.frame_h = mode.height;
      s.sequence.store(0);
      s.stats = StreamStats();
      s.stats.start_ns = NowNs();
      s.previewing.store(true);
    }
    s.capture = capture;
    s.output = output;
    s.delegate = delegate;

    // The session keeps the format chosen here only while the device stays
    // locked across startRunning.
    NSString* failure = nil;
    if ([device lockForConfiguration:&error]) {
      @try {
        device.activeFormat = mode.native;
        device.activeVideoMinFrameDuration = mode.frame_duration;
        device.activeVideoMaxFrameDuration = mode.frame_duration;
        [capture startRunning];
      } @catch (NSException* exception) {
        failure = exception.reason ?: @"exception";
      }
      [device unlockForConfiguration];
    } else {
      failure = error.localizedDescription ?: @"device is locked";
    }
    if (failure == nil && !capture.isRunning) {
      failure = @"the capture session did not start";
    }
    if (failure != nil) {
      StopPreviewLocked(s);
      SetErrorMessage(s, "Failed to start the stream: %s", failure.UTF8String);
      return kErrorIo;
    }

    std::weak_ptr<Session> weak(owner);
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    s.runtime_error_observer = [center
        addObserverForName:AVCaptureSessionRuntimeErrorNotification
                    object:capture
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  std::shared_ptr<Session> target = weak.lock();
                  if (!target) return;
                  NSError* runtime = note.userInfo[AVCaptureSessionErrorKey];
                  ReportError(*target, "Capture session error: %s",
                              runtime.localizedDescription.UTF8String
                                  ?: "unknown");
                }];
    s.disconnect_observer = [center
        addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                    object:device
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  std::shared_ptr<Session> target = weak.lock();
                  if (!target) return;
                  ReportError(*target, "Video capture device disconnected");
                }];
  }
  return 0;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT void uvc_stop_preview(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(s->lifecycle_mutex);
    StopPreviewLocked(*s);
  }
} catch (...) {
}

FFI_PLUGIN_EXPORT void uvc_close_device(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(s->lifecycle_mutex);
    StopPreviewLocked(*s);
    CloseDeviceLocked(*s);
  }
  // Listeners survive so a bound texture keeps working across a device
  // switch. They only change through their set functions.
} catch (...) {
}

FFI_PLUGIN_EXPORT int uvc_is_previewing(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->previewing.load() ? 1 : 0;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_frame_width(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  return s->frame_w;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_frame_height(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  return s->frame_h;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uvc_session_t* session,
                                                 uint8_t* buffer,
                                                 int buffer_length) {
  return uvc_copy_latest_frame_rgba_with_metadata(
      session, buffer, buffer_length, nullptr, nullptr, nullptr);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uvc_session_t* session, uint8_t* buffer, int buffer_length,
    int* out_width, int* out_height, int64_t* out_sequence) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  const size_t needed = static_cast<size_t>(s->frame_w) * s->frame_h * 4;
  if (s->frame_w <= 0 || s->frame_h <= 0 || s->sequence.load() <= 0 ||
      s->rgba.size() < needed ||
      static_cast<size_t>(buffer_length) < needed) {
    return 0;
  }
  memcpy(buffer, s->rgba.data(), needed);
  if (out_width != nullptr) *out_width = s->frame_w;
  if (out_height != nullptr) *out_height = s->frame_h;
  if (out_sequence != nullptr) *out_sequence = s->sequence.load();
  return static_cast<int>(needed);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_transformed(
    uvc_session_t* session, uint8_t* buffer, int buffer_length, int rotation,
    int flip_h, int flip_v, int* out_width, int* out_height,
    int64_t* out_sequence) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;

  std::lock_guard<std::mutex> lock(s->mutex);
  const int src_w = s->frame_w;
  const int src_h = s->frame_h;
  const size_t src_bytes = static_cast<size_t>(src_w) * src_h * 4;
  if (src_w <= 0 || src_h <= 0 || s->sequence.load() <= 0 ||
      s->rgba.size() < src_bytes) {
    return 0;
  }
  const bool swap = rotation == 90 || rotation == 270;
  const int dst_w = swap ? src_h : src_w;
  const int dst_h = swap ? src_w : src_h;
  const size_t dst_bytes = static_cast<size_t>(dst_w) * dst_h * 4;
  if (static_cast<size_t>(buffer_length) < dst_bytes) return 0;

  TransformPixels(s->rgba.data(), static_cast<size_t>(src_w) * 4, src_w, src_h,
                  rotation, flip_h, flip_v, buffer,
                  static_cast<size_t>(dst_w) * 4, dst_w, dst_h, false);
  if (out_width != nullptr) *out_width = dst_w;
  if (out_height != nullptr) *out_height = dst_h;
  if (out_sequence != nullptr) *out_sequence = s->sequence.load();
  return static_cast<int>(dst_bytes);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_take_picture_jpeg(
    uvc_session_t* session, uint8_t* buffer, int buffer_length, int quality,
    int rotation, int flip_h, int flip_v, int* out_width, int* out_height,
    int64_t* out_sequence) try {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  if (quality < 1) quality = 1;
  if (quality > 100) quality = 100;

  int dst_w = 0;
  int dst_h = 0;
  int64_t sequence = 0;
  std::vector<uint8_t> rgba;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    const int src_w = s.frame_w;
    const int src_h = s.frame_h;
    const size_t src_bytes = static_cast<size_t>(src_w) * src_h * 4;
    if (src_w <= 0 || src_h <= 0 || s.sequence.load() <= 0 ||
        s.rgba.size() < src_bytes) {
      SetErrorMessage(s, "No preview frame available to capture");
      return 0;
    }
    const bool swap = rotation == 90 || rotation == 270;
    dst_w = swap ? src_h : src_w;
    dst_h = swap ? src_w : src_h;
    rgba.resize(static_cast<size_t>(dst_w) * dst_h * 4);
    TransformPixels(s.rgba.data(), static_cast<size_t>(src_w) * 4, src_w,
                    src_h, rotation, flip_h, flip_v, rgba.data(),
                    static_cast<size_t>(dst_w) * 4, dst_w, dst_h, false);
    sequence = s.sequence.load();
  }

  // Encode outside the session mutex so the frame callback never blocks
  // behind JPEG encoding.
  int result = 0;
  @autoreleasepool {
    CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(
        nullptr, rgba.data(), rgba.size(), nullptr);
    CGImageRef image = nullptr;
    if (color_space != nullptr && provider != nullptr) {
      image = CGImageCreate(
          dst_w, dst_h, 8, 32, static_cast<size_t>(dst_w) * 4, color_space,
          static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipLast) |
              kCGBitmapByteOrderDefault,
          provider, nullptr, false, kCGRenderingIntentDefault);
    }
    NSMutableData* jpeg = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr);
    bool encoded = false;
    if (image != nullptr && destination != nullptr) {
      NSDictionary* options = @{
        (id)kCGImageDestinationLossyCompressionQuality :
            @(static_cast<double>(quality) / 100.0)
      };
      CGImageDestinationAddImage(destination, image,
                                 (__bridge CFDictionaryRef)options);
      encoded = CGImageDestinationFinalize(destination);
    }
    if (destination != nullptr) CFRelease(destination);
    if (image != nullptr) CGImageRelease(image);
    if (provider != nullptr) CGDataProviderRelease(provider);
    if (color_space != nullptr) CGColorSpaceRelease(color_space);

    if (!encoded || jpeg.length == 0) {
      SetErrorMessage(s, "JPEG encode failed");
    } else if (jpeg.length > static_cast<NSUInteger>(buffer_length)) {
      SetErrorMessage(
          s, "JPEG output (%llu bytes) exceeds capture buffer (%d bytes)",
          static_cast<unsigned long long>(jpeg.length), buffer_length);
    } else {
      memcpy(buffer, jpeg.bytes, jpeg.length);
      if (out_width != nullptr) *out_width = dst_w;
      if (out_height != nullptr) *out_height = dst_h;
      if (out_sequence != nullptr) *out_sequence = sequence;
      result = static_cast<int>(jpeg.length);
    }
  }
  return result;
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_start_recording(uvc_session_t* session,
                                          const char* path, int bitrate_bps,
                                          int fps_hint, int rotation,
                                          int flip_h, int flip_v) try {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  if (path == nullptr || path[0] == '\0') {
    SetErrorMessage(s, "Recording path must not be empty");
    return kErrorInvalidParam;
  }
  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 90 && r != 180 && r != 270) r = 0;
  const int fps = fps_hint > 0 ? fps_hint : 30;

  @autoreleasepool {
    NSString* file = [NSString stringWithUTF8String:path];
    if (file == nil) {
      SetErrorMessage(s, "Invalid recording path");
      return kErrorInvalidParam;
    }

    // The lifecycle lock keeps a stop from finishing between the preview
    // check and the recording start, which would leave a writer nothing
    // finalizes.
    std::lock_guard<std::mutex> lifecycle(s.lifecycle_mutex);
    int src_w = 0;
    int src_h = 0;
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      if (s.recording.load()) {
        SetErrorMessage(s, "A recording is already in progress");
        return kErrorBusy;
      }
      if (!s.previewing.load() || s.frame_w <= 0 || s.frame_h <= 0 ||
          s.sequence.load() <= 0) {
        SetErrorMessage(
            s, "Recording requires an active preview with delivered frames");
        return kErrorInvalidMode;
      }
      src_w = s.frame_w;
      src_h = s.frame_h;
    }
    const bool swap = r == 90 || r == 270;
    const int out_w = swap ? src_h : src_w;
    const int out_h = swap ? src_w : src_h;
    if ((out_w % 2) != 0 || (out_h % 2) != 0) {
      SetErrorMessage(s, "Recording requires even frame dimensions, got %dx%d",
                      out_w, out_h);
      return kErrorInvalidParam;
    }

    int64_t bitrate = bitrate_bps;
    if (bitrate <= 0) {
      const int64_t heuristic = static_cast<int64_t>(out_w) * out_h * fps / 10;
      bitrate = heuristic < 300000     ? 300000
                : heuristic > 50000000 ? 50000000
                                       : heuristic;
    }

    NSURL* url = [NSURL fileURLWithPath:file];

    NSError* error = nil;
    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:url
                                                     fileType:AVFileTypeMPEG4
                                                        error:&error];
    if (writer == nil) {
      SetErrorMessage(s, "Failed to create MP4 writer for %s: %s", path,
                      error.localizedDescription.UTF8String);
      return kErrorIo;
    }
    AVAssetWriterInput* input = nil;
    AVAssetWriterInputPixelBufferAdaptor* adaptor = nil;
    NSString* failure = nil;
    @try {
      NSDictionary* settings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(out_w),
        AVVideoHeightKey : @(out_h),
        AVVideoCompressionPropertiesKey : @{
          AVVideoAverageBitRateKey : @(bitrate),
          AVVideoExpectedSourceFrameRateKey : @(fps),
          AVVideoProfileLevelKey : AVVideoProfileLevelH264MainAutoLevel,
        },
      };
      input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                 outputSettings:settings];
      input.expectsMediaDataInRealTime = YES;
      adaptor = [AVAssetWriterInputPixelBufferAdaptor
          assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                     sourcePixelBufferAttributes:@{
                                       (id)kCVPixelBufferPixelFormatTypeKey :
                                           @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferWidthKey : @(out_w),
                                       (id)kCVPixelBufferHeightKey : @(out_h),
                                     }];
      if (![writer canAddInput:input]) {
        failure = @"the writer rejected the video input";
      } else {
        [writer addInput:input];
        // The writer refuses a path that already exists. The file goes only
        // now that the settings were accepted.
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        if (![writer startWriting]) {
          failure = writer.error.localizedDescription ?: @"startWriting failed";
        } else {
          [writer startSessionAtSourceTime:kCMTimeZero];
        }
      }
    } @catch (NSException* exception) {
      failure = exception.reason ?: @"exception";
    }
    if (failure != nil) {
      [writer cancelWriting];
      SetErrorMessage(s, "Failed to configure H.264 recording: %s",
                      failure.UTF8String);
      return kErrorNotSupported;
    }

    std::lock_guard<std::mutex> rec_lock(s.rec_mutex);
    s.writer = writer;
    s.writer_input = input;
    s.writer_adaptor = adaptor;
    s.rec_src_w = src_w;
    s.rec_src_h = src_h;
    s.rec_w = out_w;
    s.rec_h = out_h;
    s.rec_rotation = r;
    s.rec_flip_h = flip_h != 0 ? 1 : 0;
    s.rec_flip_v = flip_v != 0 ? 1 : 0;
    s.rec_start_ns = NowNs();
    s.rec_last_us = -1;
    s.rec_frames_written = 0;
    s.rec_frames_dropped = 0;
    s.rec_failed = false;
    s.recording.store(true);
  }
  return 0;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_stop_recording(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  @autoreleasepool {
    return StopRecordingInternal(*s);
  }
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_is_recording(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->recording.load() ? 1 : 0;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int64_t uvc_latest_frame_sequence(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->sequence.load();
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT void uvc_set_frame_listener(uvc_session_t* session,
                                              uvc_frame_listener_t listener,
                                              void* user_data) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->listener_mutex);
  s->frame_listener = listener;
  s->frame_listener_data = listener != nullptr ? user_data : nullptr;
} catch (...) {
}

FFI_PLUGIN_EXPORT void uvc_set_error_listener(uvc_session_t* session,
                                              uvc_error_listener_t listener,
                                              void* user_data) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->listener_mutex);
  s->error_listener = listener;
  s->error_listener_data = listener != nullptr ? user_data : nullptr;
} catch (...) {
}

FFI_PLUGIN_EXPORT int uvc_get_stream_stats_json(uvc_session_t* session,
                                                uint8_t* buffer,
                                                int buffer_length) try {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(owner->mutex);
  const StreamStats& s = owner->stats;
  const int64_t now = NowNs();
  const double elapsed_ms = s.start_ns != 0 ? NsToMs(now - s.start_ns) : 0.0;
  const double elapsed_s = elapsed_ms / 1000.0;
  const double input_fps =
      elapsed_s > 0.0 ? static_cast<double>(s.input_frame_count) / elapsed_s
                      : 0.0;
  const double delivered_fps =
      elapsed_s > 0.0
          ? static_cast<double>(s.delivered_frame_count) / elapsed_s
          : 0.0;
  const double avg_gap_ms =
      s.gap_count > 0 ? s.gap_sum_ms / static_cast<double>(s.gap_count) : 0.0;
  double p95_gap_ms = 0.0;
  if (s.gap_count > 0) {
    std::vector<double> sorted(s.gaps_ms, s.gaps_ms + s.gap_count);
    std::sort(sorted.begin(), sorted.end());
    const size_t idx = static_cast<size_t>(
        static_cast<double>(sorted.size() - 1) * 0.95);
    p95_gap_ms = sorted[idx];
  }
  const double first_frame_latency_ms =
      s.first_frame_ns != 0 && s.start_ns != 0
          ? NsToMs(s.first_frame_ns - s.start_ns)
          : 0.0;

  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                  "{"
                  "\"inputFrameCount\":%llu,"
                  "\"deliveredFrameCount\":%llu,"
                  "\"decodeSuccessCount\":%llu,"
                  "\"decodeFailureCount\":%llu,"
                  "\"callbackLockDropCount\":0,"
                  "\"warmupDropCount\":0,"
                  "\"staleFrameCount\":0,"
                  "\"undersizedFrameCount\":%llu,"
                  "\"invalidMjpegCount\":0,"
                  "\"bufferAllocationFailureCount\":%llu,"
                  "\"previewSurfaceFailureCount\":0,"
                  "\"conversionFailureCount\":%llu,"
                  "\"inputFps\":%.3f,"
                  "\"deliveredFps\":%.3f,"
                  "\"avgInterFrameGapMs\":%.3f,"
                  "\"p95InterFrameGapMs\":%.3f,"
                  "\"maxInterFrameGapMs\":%.3f,"
                  "\"firstFrameLatencyMs\":%.3f,"
                  "\"elapsedMs\":%.3f"
                  "}",
                  static_cast<unsigned long long>(s.input_frame_count),
                  static_cast<unsigned long long>(s.delivered_frame_count),
                  static_cast<unsigned long long>(s.decode_success_count),
                  static_cast<unsigned long long>(s.decode_failure_count),
                  static_cast<unsigned long long>(s.undersized_frame_count),
                  static_cast<unsigned long long>(
                      s.buffer_allocation_failure_count),
                  static_cast<unsigned long long>(s.conversion_failure_count),
                  input_fps, delivered_fps, avg_gap_ms, p95_gap_ms,
                  s.max_gap_ms, first_frame_latency_ms, elapsed_ms)) {
    return 0;
  }
  return static_cast<int>(offset);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uvc_session_t* session,
                                                   uint8_t* buffer,
                                                   int buffer_length) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const ModeInfo& mode : s->modes) {
    if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                    "%s{\"format\":%d,\"formatName\":\"%s\",\"width\":%u,"
                    "\"height\":%u,\"fps\":%d}",
                    first ? "" : ",", mode.format, mode.format_name,
                    static_cast<unsigned>(mode.width),
                    static_cast<unsigned>(mode.height), mode.fps)) {
      return 0;
    }
    first = false;
  }
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "]")) {
    return 0;
  }
  return static_cast<int>(offset);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int64_t uvc_error_count(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  return s->error_count.load();
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes(uvc_session_t* session,
                                              uvc_mode_t* out_modes,
                                              int max_modes) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s || out_modes == nullptr || max_modes <= 0) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->unique_id.empty()) return kErrorNoDevice;
  int count = 0;
  for (const ModeInfo& mode : s->modes) {
    if (count >= max_modes) break;
    out_modes[count].frame_format = mode.format;
    out_modes[count].width = mode.width;
    out_modes[count].height = mode.height;
    out_modes[count].fps = mode.fps;
    count += 1;
  }
  return count;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT const char* uvc_last_error(uvc_session_t* session) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return "";
  std::lock_guard<std::mutex> lock(s->error_mutex);
  memcpy(s->last_error_snapshot, s->last_error, sizeof(s->last_error_snapshot));
  s->last_error_snapshot[sizeof(s->last_error_snapshot) - 1] = '\0';
  return s->last_error_snapshot;
} catch (...) {
  return "";
}

FFI_PLUGIN_EXPORT void uvc_set_log_level(int level) {
  process.log_level.store(level);
}

FFI_PLUGIN_EXPORT void uvc_set_preview_transform(uvc_session_t* session,
                                                 int rotation, int flip_h,
                                                 int flip_v) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  s->rotation = rotation;
  s->flip_h = flip_h != 0 ? 1 : 0;
  s->flip_v = flip_v != 0 ? 1 : 0;
} catch (...) {
}

FFI_PLUGIN_EXPORT void uvc_get_preview_transform(uvc_session_t* session,
                                                 int* rotation, int* flip_h,
                                                 int* flip_v) try {
  if (rotation != nullptr) *rotation = 0;
  if (flip_h != nullptr) *flip_h = 0;
  if (flip_v != nullptr) *flip_v = 0;
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (rotation != nullptr) *rotation = s->rotation;
  if (flip_h != nullptr) *flip_h = s->flip_h;
  if (flip_v != nullptr) *flip_v = s->flip_v;
} catch (...) {
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uvc_session_t* session,
                                            uint8_t* buffer,
                                            int buffer_length) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->ctrl_mutex);
  if (!s->usb) return 0;

  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const CtrlInfo& info : kCtrlTable) {
    // Check bmControls before touching USB, which avoids a stall or a
    // timeout on a control the device does not have.
    if (!Advertised(*s->usb, info)) continue;
    int32_t cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
    if (!CtrlReadLocked(*s, info, uvc_mac::kUvcGetCur, &cur)) continue;
    CtrlReadLocked(*s, info, uvc_mac::kUvcGetMin, &min_val);
    CtrlReadLocked(*s, info, uvc_mac::kUvcGetMax, &max_val);
    CtrlReadLocked(*s, info, uvc_mac::kUvcGetDef, &def_val);
    CtrlReadLocked(*s, info, uvc_mac::kUvcGetRes, &res_val);
    if (res_val <= 0) res_val = 1;
    if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                    "%s{\"id\":%d,\"name\":\"%s\",\"label\":\"%s\","
                    "\"uiType\":\"%s\",\"min\":%d,\"max\":%d,"
                    "\"def\":%d,\"cur\":%d,\"res\":%d}",
                    first ? "" : ",", info.id, info.name, info.label,
                    info.ui_type, min_val, max_val, def_val, cur, res_val)) {
      return 0;
    }
    first = false;
  }
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "]")) {
    return 0;
  }
  return static_cast<int>(offset);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uvc_session_t* session,
                                                    uint8_t* buffer,
                                                    int buffer_length) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->ctrl_mutex);
  if (!s->usb) return 0;

  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const CtrlInfo& info : kCtrlTable) {
    if (!Advertised(*s->usb, info)) continue;
    if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                    "%s{\"id\":%d,\"name\":\"%s\",\"label\":\"%s\","
                    "\"uiType\":\"%s\"}",
                    first ? "" : ",", info.id, info.name, info.label,
                    info.ui_type)) {
      return 0;
    }
    first = false;
  }
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "]")) {
    return 0;
  }
  return static_cast<int>(offset);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(uvc_session_t* session, int ctrl_id) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return INT32_MIN;
  const CtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr) return INT32_MIN;
  std::lock_guard<std::mutex> lock(s->ctrl_mutex);
  int32_t value = 0;
  if (!CtrlReadLocked(*s, *info, uvc_mac::kUvcGetCur, &value)) {
    return INT32_MIN;
  }
  return value;
} catch (...) {
  return INT32_MIN;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_set(uvc_session_t* session, int ctrl_id,
                                   int32_t value) try {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  const CtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr) return kErrorNotSupported;
  uint8_t data[4] = {0, 0, 0, 0};
  switch (info->length) {
    case 1:
      data[0] = static_cast<uint8_t>(value);
      break;
    case 2:
      WriteU16(data, static_cast<uint16_t>(value));
      break;
    default:
      WriteU32(data, static_cast<uint32_t>(value));
      break;
  }
  const int result =
      CompoundSet(session, info->is_ct, info->selector, data, info->length);
  if (result != 0 && result != kErrorNoDevice &&
      result != kErrorNotSupported) {
    SetErrorMessage(*s, "uvc_ctrl_set failed ctrl_id=%d value=%d err=%d",
                    ctrl_id, value, result);
  }
  return result;
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(
    uvc_session_t* session, uint8_t* buffer, int buffer_length) try {
  uint8_t data[4] = {0};
  if (!CompoundGet(session, false, kPuWhiteBalanceComponent, data, 4)) {
    return 0;
  }
  return WriteJson(buffer, buffer_length, "{\"blue\":%u,\"red\":%u}",
                   ReadU16(data), ReadU16(data + 2));
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(
    uvc_session_t* session, uint16_t blue, uint16_t red) try {
  uint8_t data[4];
  WriteU16(data, blue);
  WriteU16(data + 2, red);
  return CompoundSet(session, false, kPuWhiteBalanceComponent, data, 4);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uvc_session_t* session,
                                             uint8_t* buffer,
                                             int buffer_length) try {
  uint8_t data[2] = {0};
  if (!CompoundGet(session, true, kCtFocusRelative, data, 2)) return 0;
  return WriteJson(buffer, buffer_length, "{\"focusRel\":%d,\"speed\":%u}",
                   static_cast<int>(static_cast<int8_t>(data[0])), data[1]);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(uvc_session_t* session,
                                               int8_t focus_rel,
                                               uint8_t speed) try {
  uint8_t data[2] = {static_cast<uint8_t>(focus_rel), speed};
  return CompoundSet(session, true, kCtFocusRelative, data, 2);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uvc_session_t* session,
                                            uint8_t* buffer,
                                            int buffer_length) try {
  uint8_t data[3] = {0};
  if (!CompoundGet(session, true, kCtZoomRelative, data, 3)) return 0;
  return WriteJson(buffer, buffer_length,
                   "{\"zoomRel\":%d,\"digitalZoom\":%u,\"speed\":%u}",
                   static_cast<int>(static_cast<int8_t>(data[0])), data[1],
                   data[2]);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(uvc_session_t* session,
                                              int8_t zoom_rel,
                                              uint8_t digital_zoom,
                                              uint8_t speed) try {
  uint8_t data[3] = {static_cast<uint8_t>(zoom_rel), digital_zoom, speed};
  return CompoundSet(session, true, kCtZoomRelative, data, 3);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uvc_session_t* session,
                                               uint8_t* buffer,
                                               int buffer_length) try {
  uint8_t data[8] = {0};
  if (!CompoundGet(session, true, kCtPanTiltAbsolute, data, 8)) return 0;
  return WriteJson(buffer, buffer_length, "{\"pan\":%d,\"tilt\":%d}",
                   static_cast<int32_t>(ReadU32(data)),
                   static_cast<int32_t>(ReadU32(data + 4)));
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(uvc_session_t* session,
                                                 int32_t pan, int32_t tilt) try {
  uint8_t data[8];
  WriteU32(data, static_cast<uint32_t>(pan));
  WriteU32(data + 4, static_cast<uint32_t>(tilt));
  return CompoundSet(session, true, kCtPanTiltAbsolute, data, 8);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uvc_session_t* session,
                                               uint8_t* buffer,
                                               int buffer_length) try {
  uint8_t data[4] = {0};
  if (!CompoundGet(session, true, kCtPanTiltRelative, data, 4)) return 0;
  return WriteJson(
      buffer, buffer_length,
      "{\"panRel\":%d,\"panSpeed\":%u,\"tiltRel\":%d,\"tiltSpeed\":%u}",
      static_cast<int>(static_cast<int8_t>(data[0])), data[1],
      static_cast<int>(static_cast<int8_t>(data[2])), data[3]);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(uvc_session_t* session,
                                                 int8_t pan_rel,
                                                 uint8_t pan_speed,
                                                 int8_t tilt_rel,
                                                 uint8_t tilt_speed) try {
  uint8_t data[4] = {static_cast<uint8_t>(pan_rel), pan_speed,
                     static_cast<uint8_t>(tilt_rel), tilt_speed};
  return CompoundSet(session, true, kCtPanTiltRelative, data, 4);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uvc_session_t* session,
                                            uint8_t* buffer,
                                            int buffer_length) try {
  uint8_t data[2] = {0};
  if (!CompoundGet(session, true, kCtRollRelative, data, 2)) return 0;
  return WriteJson(buffer, buffer_length, "{\"rollRel\":%d,\"speed\":%u}",
                   static_cast<int>(static_cast<int8_t>(data[0])), data[1]);
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(uvc_session_t* session,
                                              int8_t roll_rel,
                                              uint8_t speed) try {
  uint8_t data[2] = {static_cast<uint8_t>(roll_rel), speed};
  return CompoundSet(session, true, kCtRollRelative, data, 2);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uvc_session_t* session,
                                                  uint8_t* buffer,
                                                  int buffer_length) try {
  uint8_t data[12] = {0};
  if (!CompoundGet(session, true, kCtDigitalWindow, data, 12)) return 0;
  return WriteJson(buffer, buffer_length,
                   "{\"windowTop\":%u,\"windowLeft\":%u,\"windowBottom\":%u,"
                   "\"windowRight\":%u,\"numSteps\":%u,\"numStepsUnits\":%u}",
                   ReadU16(data), ReadU16(data + 2), ReadU16(data + 4),
                   ReadU16(data + 6), ReadU16(data + 8), ReadU16(data + 10));
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uvc_session_t* session, uint16_t window_top, uint16_t window_left,
    uint16_t window_bottom, uint16_t window_right, uint16_t num_steps,
    uint16_t num_steps_units) try {
  uint8_t data[12];
  WriteU16(data, window_top);
  WriteU16(data + 2, window_left);
  WriteU16(data + 4, window_bottom);
  WriteU16(data + 6, window_right);
  WriteU16(data + 8, num_steps);
  WriteU16(data + 10, num_steps_units);
  return CompoundSet(session, true, kCtDigitalWindow, data, 12);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}

FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uvc_session_t* session,
                                                      uint8_t* buffer,
                                                      int buffer_length) try {
  uint8_t data[10] = {0};
  if (!CompoundGet(session, true, kCtRegionOfInterest, data, 10)) return 0;
  return WriteJson(buffer, buffer_length,
                   "{\"roiTop\":%u,\"roiLeft\":%u,\"roiBottom\":%u,"
                   "\"roiRight\":%u,\"autoControls\":%u}",
                   ReadU16(data), ReadU16(data + 2), ReadU16(data + 4),
                   ReadU16(data + 6), ReadU16(data + 8));
} catch (...) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uvc_session_t* session, uint16_t roi_top, uint16_t roi_left,
    uint16_t roi_bottom, uint16_t roi_right, uint16_t auto_controls) try {
  uint8_t data[10];
  WriteU16(data, roi_top);
  WriteU16(data + 2, roi_left);
  WriteU16(data + 4, roi_bottom);
  WriteU16(data + 6, roi_right);
  WriteU16(data + 8, auto_controls);
  return CompoundSet(session, true, kCtRegionOfInterest, data, 10);
} catch (...) {
  return uvc_guard::CurrentExceptionCode();
}
