// Media Foundation implementation of the flutter_ffi_uvc C ABI.
//
// The Android backend (src/backend_libuvc/flutter_ffi_uvc.c) implements the same exported
// functions on top of libuvc. This file must stay byte-compatible with it at
// the contract level: same symbol names, same JSON shapes for modes /
// controls / stream stats, same error-code conventions (libuvc-style negative
// codes). The Dart layer treats both backends identically.

#include "uvc_mf_backend.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <codecapi.h>  // eAVEncH264VProfile for MP4 recording
#include <dshow.h>  // IAMCameraControl / IAMVideoProcAmp
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <olectl.h>
#include <wincodec.h>  // WIC JPEG encoder for still capture

#include <cwctype>

// KS proxy HRESULTs for unsupported properties, in case olectl.h does not
// provide them in this SDK configuration.
#ifndef E_PROP_ID_UNSUPPORTED
#define E_PROP_ID_UNSUPPORTED ((HRESULT)0x80070490L)
#endif
#ifndef E_PROP_SET_UNSUPPORTED
#define E_PROP_SET_UNSUPPORTED ((HRESULT)0x80070492L)
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
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

#include "../src/include/flutter_ffi_uvc.h"
#include "../src/common/uvc_requests_internal.h"

namespace {

// libuvc uvc_frame_format values, mirrored so mode "format" ints round-trip
// through Dart identically on both platforms.
constexpr int kFormatYuyv = 3;
constexpr int kFormatUyvy = 4;
constexpr int kFormatRgb = 5;
constexpr int kFormatBgr = 6;
constexpr int kFormatMjpeg = 7;
constexpr int kFormatH264 = 8;
constexpr int kFormatGray8 = 9;
constexpr int kFormatNv12 = 17;

// libuvc uvc_error_t codes used by this backend.
constexpr int kErrorIo = -1;            // UVC_ERROR_IO
constexpr int kErrorInvalidParam = -2;  // UVC_ERROR_INVALID_PARAM
constexpr int kErrorNoDevice = -4;      // UVC_ERROR_NO_DEVICE
constexpr int kErrorBusy = -6;          // UVC_ERROR_BUSY
constexpr int kErrorNotSupported = -12; // UVC_ERROR_NOT_SUPPORTED
constexpr int kErrorInvalidMode = -51;  // UVC_ERROR_INVALID_MODE
constexpr int kErrorOther = -99;        // UVC_ERROR_OTHER

constexpr DWORD kVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

struct ModeInfo {
  int format = 0;
  const char* format_name = "UNKNOWN";
  UINT32 width = 0;
  UINT32 height = 0;
  UINT32 fps = 0;
  DWORD native_index = 0;
};

struct StreamStats {
  uint64_t input_frame_count = 0;
  uint64_t delivered_frame_count = 0;
  uint64_t decode_success_count = 0;
  uint64_t decode_failure_count = 0;
  uint64_t undersized_frame_count = 0;
  uint64_t buffer_allocation_failure_count = 0;
  uint64_t conversion_failure_count = 0;
  int64_t start_qpc = 0;
  int64_t first_frame_qpc = 0;
  int64_t last_delivered_qpc = 0;
  double max_gap_ms = 0.0;
  double gap_sum_ms = 0.0;
  // Ring buffer of delivered-frame gaps for the p95 estimate.
  static constexpr size_t kGapCapacity = 512;
  double gaps_ms[kGapCapacity] = {};
  size_t gap_count = 0;
  size_t gap_next = 0;
};

// Process-wide state shared by every session. ProcessState::mutex is a leaf
// lock. Only MFStartup and device enumeration run under it, never a session
// lock or a session's Media Foundation call.
struct ProcessState {
  std::mutex mutex;
  bool mf_started = false;

  // Stable process-lifetime device ids keyed by symbolic link.
  std::map<std::wstring, int> id_by_symlink;
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
//   Session::mutex -> Session::rec_mutex -> Session::error_mutex
//   Session::mutex -> ProcessState::mutex
// Never hold Session::mutex across IMFSourceReader::Flush.
// Never invoke a listener or plugin callback with a session lock held.
struct Session {
  std::mutex mutex;

  // Open device. symlink stays set while a device is open so the source can
  // be re-activated for every preview start.
  std::wstring symlink;
  IMFMediaSource* source = nullptr;
  // Set once the source has streamed. Only then does a preview start need
  // to re-activate it.
  bool source_streamed = false;
  IMFSourceReader* reader = nullptr;
  // Bumped whenever reader is replaced so a late callback from the previous
  // reader is ignored.
  uint64_t reader_generation = 0;
  IAMVideoProcAmp* procamp = nullptr;
  IAMCameraControl* camctrl = nullptr;
  std::vector<ModeInfo> modes;

  // Preview.
  std::atomic<bool> previewing{false};
  HANDLE flush_event = nullptr;
  std::vector<uint8_t> rgba;
  int frame_w = 0;
  int frame_h = 0;
  LONG out_stride = 0;
  std::atomic<int64_t> sequence{0};
  StreamStats stats;

  // Transform applied to the Flutter texture blit only.
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

  // MP4 recording. rec_mutex serializes WriteSample against Finalize.
  IMFSinkWriter* sink_writer = nullptr;
  DWORD sink_stream = 0;
  std::atomic<bool> recording{false};
  std::mutex rec_mutex;
  int rec_src_w = 0, rec_src_h = 0;  // expected preview frame dimensions
  int rec_w = 0, rec_h = 0;          // post-transform (encoded) dimensions
  int rec_rotation = 0, rec_flip_h = 0, rec_flip_v = 0;
  UINT32 rec_fps = 30;
  int64_t rec_start_qpc = 0;
  LONGLONG rec_last_ts = -1;
  // Atomics: bumped under rec_mutex in WriteRecordingFrame but also under
  // Session::mutex in OnReadSample's dimension-mismatch path.
  std::atomic<uint64_t> rec_frames_written{0};
  std::atomic<uint64_t> rec_frames_dropped{0};
  std::vector<uint8_t> rec_rgba;         // frame snapshot taken under mutex
  std::vector<uint8_t> rec_transformed;  // rotated/flipped frame, when needed

  Session() { flush_event = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
  ~Session();
  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;
};

}  // namespace

// Opaque handle handed to Dart. The shared_ptr lets a late Media Foundation
// callback keep the Session alive after uvc_session_destroy freed this
// wrapper.
struct uvc_session {
  std::shared_ptr<Session> impl;
};

namespace {

std::shared_ptr<Session> Impl(uvc_session_t* session) {
  return session != nullptr ? session->impl : nullptr;
}

int64_t QpcNow() {
  LARGE_INTEGER v;
  QueryPerformanceCounter(&v);
  return v.QuadPart;
}

double QpcToMs(int64_t ticks) {
  static LARGE_INTEGER freq = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return f;
  }();
  return static_cast<double>(ticks) * 1000.0 /
         static_cast<double>(freq.QuadPart);
}

// Integer conversion so long recordings keep sub-microsecond precision.
LONGLONG QpcTo100ns(int64_t ticks) {
  static LARGE_INTEGER freq = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return f;
  }();
  const int64_t sec = ticks / freq.QuadPart;
  const int64_t rem = ticks % freq.QuadPart;
  return sec * 10000000LL + rem * 10000000LL / freq.QuadPart;
}

void WriteRecordingFrame(Session& s, int64_t ts_qpc);
int StopRecordingInternal(Session& s);

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
    strncpy_s(s.last_error, message, _TRUNCATE);
  }
  s.error_count.fetch_add(1);
  std::lock_guard<std::mutex> lock(s.listener_mutex);
  if (s.error_listener != nullptr) {
    s.error_listener(s.error_listener_data, message);
  }
}

// Caller holds process.mutex.
bool EnsureMediaFoundationLocked() {
  // Entry points run on the Flutter platform thread and on session worker
  // threads. Media Foundation objects are free-threaded, so a worker thread
  // joins the MTA. The platform thread is already STA and reports
  // RPC_E_CHANGED_MODE, which is fine.
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  (void)hr;
  if (!process.mf_started) {
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
      return false;
    }
    process.mf_started = true;
  }
  return true;
}

bool EnsureMediaFoundation() {
  std::lock_guard<std::mutex> lock(process.mutex);
  return EnsureMediaFoundationLocked();
}

int ParseHexAfter(const std::wstring& haystack, const wchar_t* needle) {
  std::wstring lower = haystack;
  std::transform(lower.begin(), lower.end(), lower.begin(), ::towlower);
  size_t pos = lower.find(needle);
  if (pos == std::wstring::npos) return 0;
  pos += wcslen(needle);
  if (pos + 4 > lower.size()) return 0;
  return static_cast<int>(wcstoul(lower.substr(pos, 4).c_str(), nullptr, 16));
}

// Caller holds process.mutex.
// Device paths are case-insensitive, and WM_DEVICECHANGE reports them in
// upper case while enumeration reports lower case.
int AssignIdLocked(const std::wstring& symlink) {
  std::wstring key = symlink;
  for (wchar_t& c : key) c = towlower(c);
  auto it = process.id_by_symlink.find(key);
  if (it != process.id_by_symlink.end()) return it->second;
  int id = process.next_device_id++;
  process.id_by_symlink[key] = id;
  return id;
}

// Enumerates MF video capture devices. When target_symlink is non-null, the
// matching IMFActivate is returned addref'd through out_activate. Caller
// holds process.mutex.
std::vector<uvc_win::DeviceInfo> EnumerateLocked(
    const std::wstring* target_symlink, IMFActivate** out_activate) {
  std::vector<uvc_win::DeviceInfo> result;
  if (out_activate != nullptr) *out_activate = nullptr;
  if (!EnsureMediaFoundationLocked()) return result;

  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 1))) return result;
  attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                 MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  HRESULT hr = MFEnumDeviceSources(attrs, &activates, &count);
  attrs->Release();
  if (FAILED(hr)) return result;

  for (UINT32 i = 0; i < count; ++i) {
    WCHAR* symlink = nullptr;
    UINT32 symlink_len = 0;
    WCHAR* friendly = nullptr;
    UINT32 friendly_len = 0;
    activates[i]->GetAllocatedString(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &symlink,
        &symlink_len);
    activates[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
                                     &friendly, &friendly_len);

    uvc_win::DeviceInfo info;
    info.symbolic_link = symlink != nullptr ? symlink : L"";
    info.friendly_name = friendly != nullptr ? friendly : L"";
    info.vendor_id = ParseHexAfter(info.symbolic_link, L"vid_");
    info.product_id = ParseHexAfter(info.symbolic_link, L"pid_");
    info.device_id = AssignIdLocked(info.symbolic_link);
    result.push_back(info);

    if (out_activate != nullptr && target_symlink != nullptr &&
        *out_activate == nullptr && info.symbolic_link == *target_symlink) {
      *out_activate = activates[i];
      activates[i]->AddRef();
    }

    if (symlink != nullptr) CoTaskMemFree(symlink);
    if (friendly != nullptr) CoTaskMemFree(friendly);
    activates[i]->Release();
  }
  CoTaskMemFree(activates);
  return result;
}

std::vector<uvc_win::DeviceInfo> Enumerate(const std::wstring* target_symlink,
                                           IMFActivate** out_activate) {
  std::lock_guard<std::mutex> lock(process.mutex);
  return EnumerateLocked(target_symlink, out_activate);
}

bool SubtypeToFormat(const GUID& subtype, int* format, const char** name) {
  if (subtype == MFVideoFormat_MJPG) {
    *format = kFormatMjpeg;
    *name = "MJPEG";
  } else if (subtype == MFVideoFormat_YUY2) {
    *format = kFormatYuyv;
    *name = "YUYV";
  } else if (subtype == MFVideoFormat_UYVY) {
    *format = kFormatUyvy;
    *name = "UYVY";
  } else if (subtype == MFVideoFormat_NV12) {
    *format = kFormatNv12;
    *name = "NV12";
  } else if (subtype == MFVideoFormat_RGB24) {
    *format = kFormatRgb;
    *name = "RGB";
  } else if (subtype == MFVideoFormat_RGB32) {
    *format = kFormatBgr;
    *name = "BGR";
  } else if (subtype == MFVideoFormat_H264) {
    *format = kFormatH264;
    *name = "H264";
  } else if (subtype == MFVideoFormat_L8) {
    *format = kFormatGray8;
    *name = "GRAY8";
  } else {
    return false;
  }
  return true;
}

// Caller holds s.mutex.
void EnumerateModesLocked(Session& s) {
  s.modes.clear();
  if (s.reader == nullptr) return;
  for (DWORD index = 0;; ++index) {
    IMFMediaType* type = nullptr;
    HRESULT hr = s.reader->GetNativeMediaType(kVideoStream, index, &type);
    if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) break;

    GUID subtype = GUID_NULL;
    UINT32 width = 0, height = 0, num = 0, den = 0;
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width, &height);
    MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &num, &den);
    type->Release();

    ModeInfo mode;
    if (!SubtypeToFormat(subtype, &mode.format, &mode.format_name)) continue;
    if (width == 0 || height == 0) continue;
    // H264 is intentionally excluded from the mode list: an inter-frame codec
    // breaks this package's per-frame validation model. See
    // doc/windows-backend.md.
    if (mode.format == kFormatH264) continue;
    mode.width = width;
    mode.height = height;
    mode.fps = den != 0 ? num / den : 0;
    mode.native_index = index;
    s.modes.push_back(mode);
  }
}

// Caller holds s.mutex.
void RecordDeliveredLocked(Session& s) {
  int64_t now = QpcNow();
  StreamStats& st = s.stats;
  st.delivered_frame_count += 1;
  st.decode_success_count += 1;
  if (st.first_frame_qpc == 0) st.first_frame_qpc = now;
  if (st.last_delivered_qpc != 0) {
    double gap_ms = QpcToMs(now - st.last_delivered_qpc);
    st.gap_sum_ms += gap_ms;
    if (gap_ms > st.max_gap_ms) st.max_gap_ms = gap_ms;
    st.gaps_ms[st.gap_next] = gap_ms;
    st.gap_next = (st.gap_next + 1) % StreamStats::kGapCapacity;
    if (st.gap_count < StreamStats::kGapCapacity) st.gap_count += 1;
  }
  st.last_delivered_qpc = now;
}

// Converts one contiguous RGB32 (BGRX) sample into the session's RGBA
// buffer. Returns true when a frame was delivered. Caller holds s.mutex.
bool ConvertSampleLocked(Session& s, IMFSample* sample) {
  IMFMediaBuffer* buffer = nullptr;
  if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) {
    s.stats.conversion_failure_count += 1;
    return false;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0, cur_len = 0;
  if (FAILED(buffer->Lock(&data, &max_len, &cur_len))) {
    buffer->Release();
    s.stats.conversion_failure_count += 1;
    return false;
  }

  bool delivered = false;
  const int w = s.frame_w;
  const int h = s.frame_h;
  const LONG stride = s.out_stride;
  const size_t abs_stride =
      static_cast<size_t>(stride >= 0 ? stride : -stride);
  const size_t needed = abs_stride * static_cast<size_t>(h);
  if (w <= 0 || h <= 0 || cur_len < needed) {
    s.stats.undersized_frame_count += 1;
    s.stats.decode_failure_count += 1;
  } else {
    const size_t out_bytes = static_cast<size_t>(w) * h * 4;
    if (s.rgba.size() != out_bytes) {
      s.rgba.resize(out_bytes);
    }
    if (s.rgba.size() != out_bytes) {
      s.stats.buffer_allocation_failure_count += 1;
    } else {
      for (int y = 0; y < h; ++y) {
        // Negative stride means bottom-up rows: image row y lives at
        // (h - 1 - y) * |stride|.
        const uint8_t* src =
            data + abs_stride * static_cast<size_t>(
                                    stride >= 0 ? y : (h - 1 - y));
        uint8_t* dst = s.rgba.data() + static_cast<size_t>(w) * 4 * y;
        for (int x = 0; x < w; ++x) {
          dst[0] = src[2];
          dst[1] = src[1];
          dst[2] = src[0];
          dst[3] = 255;
          dst += 4;
          src += 4;
        }
      }
      s.sequence.fetch_add(1);
      RecordDeliveredLocked(s);
      delivered = true;
    }
  }

  buffer->Unlock();
  buffer->Release();
  return delivered;
}

// Source Reader callback bound to one session through a weak_ptr, so after
// uvc_session_destroy the lock() fails and the callback returns early.
// A callback already running keeps the Session alive through the promoted
// shared_ptr and sees reader == nullptr and previewing == false.
class SourceReaderCallback : public IMFSourceReaderCallback {
 public:
  SourceReaderCallback(std::weak_ptr<Session> session, uint64_t generation)
      : session_(std::move(session)), generation_(generation) {}

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (riid == IID_IUnknown || riid == __uuidof(IMFSourceReaderCallback)) {
      *ppv = static_cast<IMFSourceReaderCallback*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override {
    return InterlockedIncrement(&ref_count_);
  }
  STDMETHODIMP_(ULONG) Release() override {
    ULONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return count;
  }

  // IMFSourceReaderCallback
  STDMETHODIMP OnReadSample(HRESULT hr_status, DWORD /*stream_index*/,
                            DWORD stream_flags, LONGLONG /*timestamp*/,
                            IMFSample* sample) override {
    std::shared_ptr<Session> owner = session_.lock();
    if (!owner) return S_OK;
    Session& s = *owner;

    bool delivered = false;
    bool request_next = false;
    bool record_frame = false;
    int64_t record_ts = 0;
    IMFSourceReader* reader = nullptr;
    int64_t sequence = 0;
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      if (!s.previewing.load() || s.reader == nullptr ||
          s.reader_generation != generation_) {
        return S_OK;
      }
      s.stats.input_frame_count += 1;
      if (SUCCEEDED(hr_status) && sample != nullptr) {
        delivered = ConvertSampleLocked(s, sample);
        sequence = s.sequence.load();
        if (delivered) {
          // A delivered frame clears the last error, as on the libuvc backend.
          std::lock_guard<std::mutex> error_lock(s.error_mutex);
          s.last_error[0] = '\0';
        }
      } else if (FAILED(hr_status)) {
        s.stats.decode_failure_count += 1;
      }
      if (delivered && s.recording.load()) {
        if (s.frame_w == s.rec_src_w && s.frame_h == s.rec_src_h) {
          const size_t bytes =
              static_cast<size_t>(s.frame_w) * s.frame_h * 4;
          if (s.rec_rgba.size() != bytes) s.rec_rgba.resize(bytes);
          memcpy(s.rec_rgba.data(), s.rgba.data(), bytes);
          record_frame = true;
          record_ts = QpcNow();
        } else {
          s.rec_frames_dropped += 1;
        }
      }
      bool fatal = FAILED(hr_status) ||
                   (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0 ||
                   (stream_flags & MF_SOURCE_READERF_ERROR) != 0;
      request_next = s.previewing.load() && !fatal;
      if (request_next) {
        reader = s.reader;
        reader->AddRef();
      }
    }

    if (FAILED(hr_status)) {
      ReportError(s, "Media Foundation ReadSample failed: 0x%08lX",
                  static_cast<unsigned long>(hr_status));
    }
    if (delivered) {
      std::lock_guard<std::mutex> lock(s.listener_mutex);
      if (s.frame_listener != nullptr) {
        s.frame_listener(s.frame_listener_data, sequence);
      }
    }
    // Encode before requesting the next sample so this callback stays the
    // only writer of the recording snapshot buffer.
    if (record_frame) {
      WriteRecordingFrame(s, record_ts);
    }
    if (reader != nullptr) {
      reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr, nullptr);
      reader->Release();
    }
    return S_OK;
  }

  STDMETHODIMP OnFlush(DWORD /*stream_index*/) override {
    std::shared_ptr<Session> owner = session_.lock();
    if (!owner) return S_OK;
    std::lock_guard<std::mutex> lock(owner->mutex);
    if (owner->reader_generation == generation_ && owner->flush_event != nullptr) {
      SetEvent(owner->flush_event);
    }
    return S_OK;
  }

  STDMETHODIMP OnEvent(DWORD /*stream_index*/,
                       IMFMediaEvent* /*event*/) override {
    return S_OK;
  }

 private:
  ~SourceReaderCallback() = default;
  LONG ref_count_ = 1;
  std::weak_ptr<Session> session_;
  uint64_t generation_;
};

// Creates a Source Reader on the open media source, replacing any existing
// one. Caller holds s.mutex and has stopped the preview.
bool CreateReaderLocked(Session& s, const std::shared_ptr<Session>& owner) {
  if (s.reader != nullptr) {
    s.reader->Release();
    s.reader = nullptr;
  }
  s.reader_generation += 1;

  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 3))) {
    SetErrorMessage(s, "MFCreateAttributes failed");
    return false;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  // Keep the media source alive when a reader is released so it can be
  // reused by the next reader. CloseDeviceLocked shuts it down explicitly.
  attrs->SetUINT32(MF_SOURCE_READER_DISCONNECT_MEDIASOURCE_ON_SHUTDOWN, TRUE);
  SourceReaderCallback* callback = new SourceReaderCallback(
      std::weak_ptr<Session>(owner), s.reader_generation);
  attrs->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback);
  callback->Release();  // The attribute store holds the reference now.

  HRESULT hr = MFCreateSourceReaderFromMediaSource(s.source, attrs, &s.reader);
  attrs->Release();
  if (FAILED(hr) || s.reader == nullptr) {
    s.reader = nullptr;
    SetErrorMessage(s, "MFCreateSourceReaderFromMediaSource failed: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return false;
  }
  return true;
}

// Stops preview and waits for in-flight callbacks to drain. Must be called
// WITHOUT s.mutex held: OnReadSample takes the mutex, and MF only completes
// Flush after pending callbacks return.
void StopPreviewInternal(Session& s) {
  StopRecordingInternal(s);
  IMFSourceReader* reader = nullptr;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.previewing.exchange(false)) return;
    reader = s.reader;
    if (reader != nullptr) reader->AddRef();
    if (s.flush_event != nullptr) ResetEvent(s.flush_event);
  }
  if (reader != nullptr) {
    if (SUCCEEDED(reader->Flush(kVideoStream)) && s.flush_event != nullptr) {
      WaitForSingleObject(s.flush_event, 3000);
    }
    reader->Release();
  }
}

// Caller holds s.mutex. The destructor calls it unlocked because no other
// reference is left.
void CloseDeviceLocked(Session& s);

// Activates the media source for s.symlink, creates its reader, and lists
// the modes. Caller holds s.mutex with no device open. The Frame Server
// rejects native type changes on a source that already streamed, so every
// preview start re-activates the source.
int OpenSourceLocked(Session& s, const std::shared_ptr<Session>& owner) {
  IMFActivate* activate = nullptr;
  Enumerate(&s.symlink, &activate);
  if (activate == nullptr) {
    SetErrorMessage(s, "Video capture device disappeared");
    return kErrorNoDevice;
  }
  HRESULT hr = activate->ActivateObject(IID_PPV_ARGS(&s.source));
  activate->Release();
  if (FAILED(hr) || s.source == nullptr) {
    SetErrorMessage(s, "Failed to activate media source: 0x%08lX",
                    static_cast<unsigned long>(hr));
    s.source = nullptr;
    return kErrorIo;
  }

  // Control interfaces are optional. A device without them still streams.
  s.source->QueryInterface(IID_PPV_ARGS(&s.procamp));
  s.source->QueryInterface(IID_PPV_ARGS(&s.camctrl));

  if (!CreateReaderLocked(s, owner)) {
    CloseDeviceLocked(s);
    return kErrorIo;
  }
  EnumerateModesLocked(s);
  return 0;
}

void CloseDeviceLocked(Session& s) {
  if (s.reader != nullptr) {
    s.reader->Release();
    s.reader = nullptr;
  }
  if (s.procamp != nullptr) {
    s.procamp->Release();
    s.procamp = nullptr;
  }
  if (s.camctrl != nullptr) {
    s.camctrl->Release();
    s.camctrl = nullptr;
  }
  if (s.source != nullptr) {
    s.source->Shutdown();
    s.source->Release();
    s.source = nullptr;
  }
  s.modes.clear();
  s.source_streamed = false;
  s.frame_w = 0;
  s.frame_h = 0;
  s.sequence.store(0);
  s.rgba.clear();
}

Session::~Session() {
  // uvc_session_destroy already stopped and closed everything. This only
  // covers leftovers when the last reference dropped some other way.
  if (sink_writer != nullptr) {
    sink_writer->Release();
    sink_writer = nullptr;
  }
  CloseDeviceLocked(*this);
  if (flush_event != nullptr) {
    CloseHandle(flush_event);
    flush_event = nullptr;
  }
}

bool AppendJson(char* buffer, size_t capacity, size_t* offset, const char* fmt,
                ...) {
  if (*offset >= capacity) return false;
  va_list args;
  va_start(args, fmt);
  int written = vsnprintf(buffer + *offset, capacity - *offset, fmt, args);
  va_end(args);
  if (written < 0 ||
      static_cast<size_t>(written) >= capacity - *offset) {
    return false;
  }
  *offset += static_cast<size_t>(written);
  return true;
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

enum class CtrlBackend {
  kProcAmp,      // IAMVideoProcAmp value property
  kProcAmpAuto,  // auto flag of an IAMVideoProcAmp property (bool)
  kCamCtrl,      // IAMCameraControl value property
  kCamCtrlAuto,  // auto flag of an IAMCameraControl property (bool)
  kExposure,     // CameraControl_Exposure with log2 <-> 100us conversion
  kAeMode,       // UVC AE mode bitmap over the Exposure auto flag
};

struct WinCtrlInfo {
  int id;
  const char* name;
  const char* label;
  const char* ui_type;
  CtrlBackend backend;
  long prop;
};

// Names / labels / uiTypes mirror the Android k_ctrl_table entries so the
// Dart-visible control metadata matches across platforms.
const WinCtrlInfo kCtrlTable[] = {
    {UVC_CTRL_ID_BRIGHTNESS, "brightness", "Brightness", "slider",
     CtrlBackend::kProcAmp, VideoProcAmp_Brightness},
    {UVC_CTRL_ID_CONTRAST, "contrast", "Contrast", "slider",
     CtrlBackend::kProcAmp, VideoProcAmp_Contrast},
    {UVC_CTRL_ID_HUE, "hue", "Hue", "slider", CtrlBackend::kProcAmp,
     VideoProcAmp_Hue},
    {UVC_CTRL_ID_SATURATION, "saturation", "Saturation", "slider",
     CtrlBackend::kProcAmp, VideoProcAmp_Saturation},
    {UVC_CTRL_ID_SHARPNESS, "sharpness", "Sharpness", "slider",
     CtrlBackend::kProcAmp, VideoProcAmp_Sharpness},
    {UVC_CTRL_ID_GAMMA, "gamma", "Gamma", "slider", CtrlBackend::kProcAmp,
     VideoProcAmp_Gamma},
    {UVC_CTRL_ID_GAIN, "gain", "Gain", "slider", CtrlBackend::kProcAmp,
     VideoProcAmp_Gain},
    {UVC_CTRL_ID_BACKLIGHT_COMPENSATION, "backlight_compensation",
     "Backlight Compensation", "slider", CtrlBackend::kProcAmp,
     VideoProcAmp_BacklightCompensation},
    {UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE, "white_balance_temperature",
     "White Balance Temperature", "slider", CtrlBackend::kProcAmp,
     VideoProcAmp_WhiteBalance},
    {UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO, "white_balance_temp_auto",
     "Auto White Balance", "bool", CtrlBackend::kProcAmpAuto,
     VideoProcAmp_WhiteBalance},
    {UVC_CTRL_ID_AE_MODE, "ae_mode", "Exposure Mode", "enum",
     CtrlBackend::kAeMode, CameraControl_Exposure},
    {UVC_CTRL_ID_EXPOSURE_ABS, "exposure_abs", "Exposure Time", "slider",
     CtrlBackend::kExposure, CameraControl_Exposure},
    {UVC_CTRL_ID_FOCUS_ABS, "focus_abs", "Focus", "slider",
     CtrlBackend::kCamCtrl, CameraControl_Focus},
    {UVC_CTRL_ID_FOCUS_AUTO, "focus_auto", "Auto Focus", "bool",
     CtrlBackend::kCamCtrlAuto, CameraControl_Focus},
    {UVC_CTRL_ID_IRIS_ABS, "iris_abs", "Iris", "slider",
     CtrlBackend::kCamCtrl, CameraControl_Iris},
    {UVC_CTRL_ID_ZOOM_ABS, "zoom_abs", "Zoom", "slider",
     CtrlBackend::kCamCtrl, CameraControl_Zoom},
    {UVC_CTRL_ID_ROLL_ABS, "roll_abs", "Roll", "slider",
     CtrlBackend::kCamCtrl, CameraControl_Roll},
};

const WinCtrlInfo* FindCtrl(int ctrl_id) {
  for (const WinCtrlInfo& info : kCtrlTable) {
    if (info.id == ctrl_id) return &info;
  }
  return nullptr;
}

// UVC EXPOSURE_TIME_ABSOLUTE is in 100us units; IAMCameraControl exposure is
// log2(seconds). Convert so exposure values mean the same thing on Android
// and Windows.
int32_t ExposureUvcFromLog2(long log2_value) {
  double seconds = std::pow(2.0, static_cast<double>(log2_value));
  double units = seconds * 10000.0;
  if (units < 1.0) units = 1.0;
  if (units > 2147483647.0) units = 2147483647.0;
  return static_cast<int32_t>(std::lround(units));
}

long ExposureLog2FromUvc(int32_t uvc_value) {
  double seconds = static_cast<double>(uvc_value < 1 ? 1 : uvc_value) / 10000.0;
  return static_cast<long>(std::lround(std::log2(seconds)));
}

int MapCtrlHr(HRESULT hr) {
  if (SUCCEEDED(hr)) return 0;
  if (hr == E_NOTIMPL || hr == E_PROP_ID_UNSUPPORTED ||
      hr == E_PROP_SET_UNSUPPORTED || hr == E_INVALIDARG) {
    return kErrorNotSupported;
  }
  return kErrorIo;
}

// Reads value/range for one control. Returns false when unsupported.
// Caller holds s.mutex.
bool CtrlReadLocked(Session& s, const WinCtrlInfo& info, long* cur,
                    long* min_val, long* max_val, long* def_val,
                    long* res_val) {
  *min_val = 0;
  *max_val = 0;
  *def_val = 0;
  *res_val = 1;
  long flags = 0, caps = 0, value = 0, step = 1;
  switch (info.backend) {
    case CtrlBackend::kProcAmp:
    case CtrlBackend::kProcAmpAuto: {
      if (s.procamp == nullptr) return false;
      if (FAILED(s.procamp->Get(info.prop, &value, &flags))) return false;
      long dmin = 0, dmax = 0, ddef = 0;
      if (FAILED(s.procamp->GetRange(info.prop, &dmin, &dmax, &step, &ddef,
                                     &caps))) {
        return false;
      }
      if (info.backend == CtrlBackend::kProcAmpAuto) {
        if ((caps & VideoProcAmp_Flags_Auto) == 0) return false;
        *cur = (flags & VideoProcAmp_Flags_Auto) != 0 ? 1 : 0;
        *min_val = 0;
        *max_val = 1;
        *def_val = 1;
        *res_val = 1;
      } else {
        *cur = value;
        *min_val = dmin;
        *max_val = dmax;
        *def_val = ddef;
        *res_val = step > 0 ? step : 1;
      }
      return true;
    }
    case CtrlBackend::kCamCtrl:
    case CtrlBackend::kCamCtrlAuto:
    case CtrlBackend::kExposure:
    case CtrlBackend::kAeMode: {
      if (s.camctrl == nullptr) return false;
      if (FAILED(s.camctrl->Get(info.prop, &value, &flags))) return false;
      long dmin = 0, dmax = 0, ddef = 0;
      if (FAILED(s.camctrl->GetRange(info.prop, &dmin, &dmax, &step, &ddef,
                                     &caps))) {
        return false;
      }
      if (info.backend == CtrlBackend::kCamCtrlAuto) {
        if ((caps & CameraControl_Flags_Auto) == 0) return false;
        *cur = (flags & CameraControl_Flags_Auto) != 0 ? 1 : 0;
        *min_val = 0;
        *max_val = 1;
        *def_val = 1;
        *res_val = 1;
      } else if (info.backend == CtrlBackend::kExposure) {
        *cur = ExposureUvcFromLog2(value);
        *min_val = ExposureUvcFromLog2(dmin);
        *max_val = ExposureUvcFromLog2(dmax);
        *def_val = ExposureUvcFromLog2(ddef);
        *res_val = 1;
      } else if (info.backend == CtrlBackend::kAeMode) {
        // UVC AE mode bitmap: 1 = manual, 2 = auto.
        *cur = (flags & CameraControl_Flags_Auto) != 0 ? 2 : 1;
        *min_val = 1;
        *max_val = 2;
        *def_val = (caps & CameraControl_Flags_Auto) != 0 ? 2 : 1;
        *res_val = 1;
      } else {
        *cur = value;
        *min_val = dmin;
        *max_val = dmax;
        *def_val = ddef;
        *res_val = step > 0 ? step : 1;
      }
      return true;
    }
  }
  return false;
}

// Caller holds s.mutex.
int CtrlSetLocked(Session& s, const WinCtrlInfo& info, int32_t value) {
  switch (info.backend) {
    case CtrlBackend::kProcAmp: {
      if (s.procamp == nullptr) return kErrorNoDevice;
      return MapCtrlHr(
          s.procamp->Set(info.prop, value, VideoProcAmp_Flags_Manual));
    }
    case CtrlBackend::kProcAmpAuto: {
      if (s.procamp == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      s.procamp->Get(info.prop, &cur, &flags);
      return MapCtrlHr(s.procamp->Set(
          info.prop, cur,
          value != 0 ? VideoProcAmp_Flags_Auto : VideoProcAmp_Flags_Manual));
    }
    case CtrlBackend::kCamCtrl: {
      if (s.camctrl == nullptr) return kErrorNoDevice;
      return MapCtrlHr(
          s.camctrl->Set(info.prop, value, CameraControl_Flags_Manual));
    }
    case CtrlBackend::kCamCtrlAuto: {
      if (s.camctrl == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      s.camctrl->Get(info.prop, &cur, &flags);
      return MapCtrlHr(s.camctrl->Set(
          info.prop, cur,
          value != 0 ? CameraControl_Flags_Auto : CameraControl_Flags_Manual));
    }
    case CtrlBackend::kExposure: {
      if (s.camctrl == nullptr) return kErrorNoDevice;
      return MapCtrlHr(s.camctrl->Set(info.prop, ExposureLog2FromUvc(value),
                                      CameraControl_Flags_Manual));
    }
    case CtrlBackend::kAeMode: {
      if (s.camctrl == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      s.camctrl->Get(info.prop, &cur, &flags);
      // UVC AE mode: 1 = manual; any auto bit (2/4/8) maps to MF auto.
      return MapCtrlHr(s.camctrl->Set(
          info.prop, cur,
          value == 1 ? CameraControl_Flags_Manual : CameraControl_Flags_Auto));
    }
  }
  return kErrorNotSupported;
}

// Copies src RGBA pixels into dst applying rotation (0/90/180/270 clockwise)
// and flips. dst must hold dst_w * dst_h * 4 bytes, where dst_w/dst_h are the
// post-rotation dimensions.
void TransformRgba(const uint8_t* src, int src_w, int src_h, int rotation,
                   int flip_h, int flip_v, uint8_t* dst, int dst_w, int dst_h) {
  for (int y = 0; y < dst_h; ++y) {
    for (int x = 0; x < dst_w; ++x) {
      int ox = flip_h != 0 ? dst_w - 1 - x : x;
      int oy = flip_v != 0 ? dst_h - 1 - y : y;
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
      memcpy(dst + (static_cast<size_t>(y) * dst_w + x) * 4,
             src + (static_cast<size_t>(sy) * src_w + sx) * 4, 4);
    }
  }
}

// ---------------------------------------------------------------------------
// MP4 recording (Sink Writer)
// ---------------------------------------------------------------------------

// Feeds one RGB32 sample built from the recording snapshot to the Sink
// Writer. Called from OnReadSample without s.mutex held. The snapshot buffer
// has a single writer because the next ReadSample is only requested after
// this returns.
void WriteRecordingFrame(Session& s, int64_t ts_qpc) {
  std::lock_guard<std::mutex> lock(s.rec_mutex);
  if (!s.recording.load() || s.sink_writer == nullptr) return;

  const uint8_t* frame = s.rec_rgba.data();
  if (s.rec_rotation != 0 || s.rec_flip_h != 0 || s.rec_flip_v != 0) {
    const size_t bytes = static_cast<size_t>(s.rec_w) * s.rec_h * 4;
    if (s.rec_transformed.size() != bytes) s.rec_transformed.resize(bytes);
    TransformRgba(s.rec_rgba.data(), s.rec_src_w, s.rec_src_h, s.rec_rotation,
                  s.rec_flip_h, s.rec_flip_v, s.rec_transformed.data(),
                  s.rec_w, s.rec_h);
    frame = s.rec_transformed.data();
  }

  const DWORD bytes = static_cast<DWORD>(s.rec_w) * s.rec_h * 4;
  IMFMediaBuffer* buffer = nullptr;
  if (FAILED(MFCreateMemoryBuffer(bytes, &buffer))) {
    s.rec_frames_dropped += 1;
    return;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0;
  if (FAILED(buffer->Lock(&data, &max_len, nullptr)) || max_len < bytes) {
    buffer->Release();
    s.rec_frames_dropped += 1;
    return;
  }
  // RGB32 samples without an explicit stride are bottom-up: write rows in
  // reverse order and swap RGBA to BGRX.
  for (int y = 0; y < s.rec_h; ++y) {
    const uint8_t* src = frame + static_cast<size_t>(y) * s.rec_w * 4;
    uint8_t* dst = data + static_cast<size_t>(s.rec_h - 1 - y) * s.rec_w * 4;
    for (int x = 0; x < s.rec_w; ++x) {
      dst[0] = src[2];
      dst[1] = src[1];
      dst[2] = src[0];
      dst[3] = 0;
      dst += 4;
      src += 4;
    }
  }
  buffer->Unlock();
  buffer->SetCurrentLength(bytes);

  IMFSample* sample = nullptr;
  if (FAILED(MFCreateSample(&sample))) {
    buffer->Release();
    s.rec_frames_dropped += 1;
    return;
  }
  sample->AddBuffer(buffer);
  LONGLONG ts = QpcTo100ns(ts_qpc - s.rec_start_qpc);
  if (ts <= s.rec_last_ts) ts = s.rec_last_ts + 1;
  sample->SetSampleTime(ts);
  sample->SetSampleDuration(10000000LL / (s.rec_fps > 0 ? s.rec_fps : 30));
  const HRESULT hr = s.sink_writer->WriteSample(s.sink_stream, sample);
  sample->Release();
  buffer->Release();
  if (FAILED(hr)) {
    s.rec_frames_dropped += 1;
    ReportError(s, "Recording WriteSample failed: 0x%08lX",
                static_cast<unsigned long>(hr));
    return;
  }
  s.rec_last_ts = ts;
  s.rec_frames_written += 1;
}

// Stops accepting frames, then drains and finalizes the MP4 outside
// rec_mutex so an in-flight WriteRecordingFrame can finish first.
int StopRecordingInternal(Session& s) {
  IMFSinkWriter* writer = nullptr;
  uint64_t written = 0;
  {
    std::lock_guard<std::mutex> lock(s.rec_mutex);
    if (!s.recording.exchange(false)) return 0;
    writer = s.sink_writer;
    s.sink_writer = nullptr;
    written = s.rec_frames_written.load();
  }
  int result = 0;
  if (writer != nullptr) {
    const HRESULT hr = writer->Finalize();
    if (FAILED(hr)) {
      SetErrorMessage(s, "Failed to finalize recording: 0x%08lX",
                      static_cast<unsigned long>(hr));
      result = kErrorIo;
    } else if (written == 0) {
      SetErrorMessage(s, "Recording produced no encoded frames");
      result = kErrorIo;
    }
    writer->Release();
  }
  return result;
}

}  // namespace

// ---------------------------------------------------------------------------
// Internal plugin-facing API
// ---------------------------------------------------------------------------

namespace uvc_win {

std::vector<DeviceInfo> ListDevices() { return Enumerate(nullptr, nullptr); }

bool DeviceExists(int device_id) {
  for (const DeviceInfo& info : Enumerate(nullptr, nullptr)) {
    if (info.device_id == device_id) return true;
  }
  return false;
}

int IdForSymbolicLink(const std::wstring& symbolic_link) {
  std::lock_guard<std::mutex> lock(process.mutex);
  return AssignIdLocked(symbolic_link);
}

void GetPreviewTransform(uvc_session_t* session, int* rotation, int* flip_h,
                         int* flip_v) {
  if (rotation != nullptr) *rotation = 0;
  if (flip_h != nullptr) *flip_h = 0;
  if (flip_v != nullptr) *flip_v = 0;
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (rotation != nullptr) *rotation = s->rotation;
  if (flip_h != nullptr) *flip_h = s->flip_h;
  if (flip_v != nullptr) *flip_v = s->flip_v;
}

}  // namespace uvc_win

// ---------------------------------------------------------------------------
// Exported C ABI (see ../src/include/flutter_ffi_uvc.h)
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT uvc_session_t* uvc_session_create(void) {
  uvc_session* session = nullptr;
  try {
    session = new uvc_session();
    session->impl = std::make_shared<Session>();
  } catch (...) {
    delete session;
    return nullptr;
  }
  if (session->impl->flush_event == nullptr) {
    delete session;
    return nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(registry.mutex);
    RegistryEntry entry;
    entry.id = registry.next_id++;
    registry.live[session] = entry;
  }
  return session;
}

FFI_PLUGIN_EXPORT uint64_t uvc_session_id(uvc_session_t* session) {
  if (session == nullptr) return 0;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  return it == registry.live.end() ? 0 : it->second.id;
}

FFI_PLUGIN_EXPORT uvc_session_t* uvc_session_acquire_id(uint64_t id) {
  if (id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(registry.mutex);
  for (auto& entry : registry.live) {
    if (entry.second.id != id || entry.second.destroying) continue;
    entry.second.pins += 1;
    return const_cast<uvc_session_t*>(entry.first);
  }
  return nullptr;
}

FFI_PLUGIN_EXPORT int uvc_session_acquire(uvc_session_t* session) {
  if (session == nullptr) return 0;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  if (it == registry.live.end() || it->second.destroying) return 0;
  it->second.pins += 1;
  return 1;
}

FFI_PLUGIN_EXPORT void uvc_session_release(uvc_session_t* session) {
  if (session == nullptr) return;
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.live.find(session);
  if (it == registry.live.end() || it->second.pins <= 0) return;
  it->second.pins -= 1;
  if (it->second.pins == 0) registry.unpinned.notify_all();
}

FFI_PLUGIN_EXPORT void uvc_session_destroy(uvc_session_t* session) {
  uvc_requests_destroy(session, 0);
}

void uvc_session_finalize(uvc_session_t* session) {
  if (session == nullptr) return;
  // Closing first leaves Session::mutex free while the retire below waits
  // for pins a plugin still holds.
  {
    std::shared_ptr<Session> s = Impl(session);
    if (s) {
      StopPreviewInternal(*s);
      std::lock_guard<std::mutex> lock(s->mutex);
      CloseDeviceLocked(*s);
      s->symlink.clear();
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
  // it returns. It sees reader == nullptr and previewing == false.
}

// On Windows there are no file descriptors: the "fd" is the stable device id
// handed out by device enumeration (see uvc_win::ListDevices), which the
// Dart openUsbDevice flow passes straight back in.
FFI_PLUGIN_EXPORT int uvc_open_fd(uvc_session_t* session, int fd) {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  StopPreviewInternal(s);
  std::lock_guard<std::mutex> lock(s.mutex);
  if (!EnsureMediaFoundation()) {
    SetErrorMessage(s, "MFStartup failed");
    return kErrorOther;
  }
  CloseDeviceLocked(s);

  std::wstring symlink;
  for (const uvc_win::DeviceInfo& info : Enumerate(nullptr, nullptr)) {
    if (info.device_id == fd) {
      symlink = info.symbolic_link;
      break;
    }
  }
  if (symlink.empty()) {
    SetErrorMessage(s, "No video capture device with id %d", fd);
    return kErrorNoDevice;
  }

  s.symlink = symlink;
  const int result = OpenSourceLocked(s, owner);
  if (result != 0) s.symlink.clear();
  return result;
}

FFI_PLUGIN_EXPORT int uvc_start_preview(uvc_session_t* session,
                                        int frame_format, int width,
                                        int height, int fps) {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return kErrorInvalidParam;
  Session& s = *owner;
  StopPreviewInternal(s);
  std::lock_guard<std::mutex> lock(s.mutex);
  if (s.symlink.empty()) {
    SetErrorMessage(s, "No device open");
    return kErrorNoDevice;
  }
  // A source that already streamed cannot change type. See OpenSourceLocked.
  if (s.source_streamed || s.source == nullptr) {
    CloseDeviceLocked(s);
    const int reopen = OpenSourceLocked(s, owner);
    if (reopen != 0) return reopen;
  }

  const ModeInfo* mode = nullptr;
  for (const ModeInfo& candidate : s.modes) {
    if (candidate.format == frame_format &&
        candidate.width == static_cast<UINT32>(width) &&
        candidate.height == static_cast<UINT32>(height) &&
        candidate.fps == static_cast<UINT32>(fps)) {
      mode = &candidate;
      break;
    }
  }
  if (mode == nullptr) {
    SetErrorMessage(s, "Mode %dx%d@%d (format %d) not reported by device",
                    width, height, fps, frame_format);
    return kErrorInvalidMode;
  }

  s.reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  s.reader->SetStreamSelection(kVideoStream, TRUE);

  IMFMediaType* native = nullptr;
  HRESULT hr =
      s.reader->GetNativeMediaType(kVideoStream, mode->native_index, &native);
  if (FAILED(hr)) {
    SetErrorMessage(s, "GetNativeMediaType failed: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorInvalidMode;
  }
  hr = s.reader->SetCurrentMediaType(kVideoStream, nullptr, native);
  native->Release();
  if (FAILED(hr)) {
    SetErrorMessage(s, "SetCurrentMediaType(native) failed: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorInvalidMode;
  }

  IMFMediaType* out_type = nullptr;
  if (FAILED(MFCreateMediaType(&out_type))) {
    SetErrorMessage(s, "MFCreateMediaType failed");
    return kErrorOther;
  }
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  MFSetAttributeSize(out_type, MF_MT_FRAME_SIZE, mode->width, mode->height);
  hr = s.reader->SetCurrentMediaType(kVideoStream, nullptr, out_type);
  out_type->Release();
  if (FAILED(hr)) {
    SetErrorMessage(s, "SetCurrentMediaType(RGB32) failed: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorNotSupported;
  }

  IMFMediaType* current = nullptr;
  LONG stride = static_cast<LONG>(mode->width) * 4;
  if (SUCCEEDED(s.reader->GetCurrentMediaType(kVideoStream, &current))) {
    UINT32 stride_attr = 0;
    if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_attr))) {
      stride = static_cast<LONG>(static_cast<INT32>(stride_attr));
    }
    current->Release();
  }

  s.frame_w = static_cast<int>(mode->width);
  s.frame_h = static_cast<int>(mode->height);
  s.out_stride = stride;
  s.sequence.store(0);
  s.stats = StreamStats();
  s.stats.start_qpc = QpcNow();
  s.previewing.store(true);
  s.source_streamed = true;

  hr = s.reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr,
                            nullptr);
  if (FAILED(hr)) {
    s.previewing.store(false);
    SetErrorMessage(s, "ReadSample kick-off failed: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorIo;
  }
  return 0;
}

FFI_PLUGIN_EXPORT void uvc_stop_preview(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  StopPreviewInternal(*s);
}

FFI_PLUGIN_EXPORT void uvc_close_device(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  StopPreviewInternal(*s);
  {
    std::lock_guard<std::mutex> lock(s->mutex);
    CloseDeviceLocked(*s);
    s->symlink.clear();
  }
  // Listeners survive so a bound texture keeps working across a device
  // switch. They only change through their set functions.
}

FFI_PLUGIN_EXPORT int uvc_is_previewing(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->previewing.load() ? 1 : 0;
}

FFI_PLUGIN_EXPORT int uvc_frame_width(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  return s->frame_w;
}

FFI_PLUGIN_EXPORT int uvc_frame_height(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  return s->frame_h;
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uvc_session_t* session,
                                                 uint8_t* buffer,
                                                 int buffer_length) {
  return uvc_copy_latest_frame_rgba_with_metadata(
      session, buffer, buffer_length, nullptr, nullptr, nullptr);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uvc_session_t* session, uint8_t* buffer, int buffer_length,
    int* out_width, int* out_height, int64_t* out_sequence) {
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
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_transformed(
    uvc_session_t* session, uint8_t* buffer, int buffer_length, int rotation,
    int flip_h, int flip_v, int* out_width, int* out_height,
    int64_t* out_sequence) {
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

  TransformRgba(s->rgba.data(), src_w, src_h, rotation, flip_h, flip_v,
                buffer, dst_w, dst_h);
  if (out_width != nullptr) *out_width = dst_w;
  if (out_height != nullptr) *out_height = dst_h;
  if (out_sequence != nullptr) *out_sequence = s->sequence.load();
  return static_cast<int>(dst_bytes);
}

FFI_PLUGIN_EXPORT int uvc_take_picture_jpeg(
    uvc_session_t* session, uint8_t* buffer, int buffer_length, int quality,
    int rotation, int flip_h, int flip_v, int* out_width, int* out_height,
    int64_t* out_sequence) {
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
    TransformRgba(s.rgba.data(), src_w, src_h, rotation, flip_h, flip_v,
                  rgba.data(), dst_w, dst_h);
    sequence = s.sequence.load();
  }

  // Encode outside the session mutex so OnReadSample never blocks behind
  // JPEG encoding. WIC needs COM on this thread. EnsureMediaFoundation covers
  // standalone (test) callers, and is a no-op on the Flutter platform thread.
  if (!EnsureMediaFoundation()) {
    SetErrorMessage(s, "MFStartup failed");
    return 0;
  }

  // WIC's JPEG encoder consumes 24bpp BGR.
  const size_t pixel_count = static_cast<size_t>(dst_w) * dst_h;
  std::vector<uint8_t> bgr(pixel_count * 3);
  for (size_t i = 0; i < pixel_count; ++i) {
    bgr[i * 3 + 0] = rgba[i * 4 + 2];
    bgr[i * 3 + 1] = rgba[i * 4 + 1];
    bgr[i * 3 + 2] = rgba[i * 4 + 0];
  }

  IWICImagingFactory* factory = nullptr;
  IStream* stream = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* frame = nullptr;
  IPropertyBag2* props = nullptr;
  int result = 0;

  do {
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (SUCCEEDED(hr)) {
      hr = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
    }
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &props);
    if (SUCCEEDED(hr)) {
      PROPBAG2 option = {};
      option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
      VARIANT value;
      VariantInit(&value);
      value.vt = VT_R4;
      value.fltVal = static_cast<float>(quality) / 100.0f;
      props->Write(1, &option, &value);  // Best effort; default quality is fine.
      hr = frame->Initialize(props);
    }
    if (SUCCEEDED(hr)) hr = frame->SetSize(dst_w, dst_h);
    WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&fmt);
    if (SUCCEEDED(hr) && !IsEqualGUID(fmt, GUID_WICPixelFormat24bppBGR)) {
      SetErrorMessage(s, "WIC JPEG encoder rejected 24bpp BGR input");
      break;
    }
    const UINT stride = static_cast<UINT>(dst_w) * 3;
    if (SUCCEEDED(hr)) {
      hr = frame->WritePixels(dst_h, stride, stride * dst_h, bgr.data());
    }
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    if (FAILED(hr)) {
      SetErrorMessage(s, "JPEG encode failed (hr=0x%08lx)",
                      static_cast<unsigned long>(hr));
      break;
    }

    // The HGLOBAL stream's end position is the number of bytes written.
    LARGE_INTEGER zero = {};
    ULARGE_INTEGER end = {};
    if (FAILED(stream->Seek(zero, STREAM_SEEK_END, &end)) ||
        end.QuadPart == 0) {
      SetErrorMessage(s, "JPEG encode produced no output");
      break;
    }
    if (end.QuadPart > static_cast<ULONGLONG>(buffer_length)) {
      SetErrorMessage(s,
                      "JPEG output (%llu bytes) exceeds capture buffer (%d bytes)",
                      end.QuadPart, buffer_length);
      break;
    }
    HGLOBAL hglobal = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &hglobal))) {
      SetErrorMessage(s, "Failed to read back encoded JPEG stream");
      break;
    }
    void* data = GlobalLock(hglobal);
    if (data == nullptr) {
      SetErrorMessage(s, "Failed to lock encoded JPEG stream memory");
      break;
    }
    memcpy(buffer, data, static_cast<size_t>(end.QuadPart));
    GlobalUnlock(hglobal);

    if (out_width != nullptr) *out_width = dst_w;
    if (out_height != nullptr) *out_height = dst_h;
    if (out_sequence != nullptr) *out_sequence = sequence;
    result = static_cast<int>(end.QuadPart);
  } while (false);

  if (props != nullptr) props->Release();
  if (frame != nullptr) frame->Release();
  if (encoder != nullptr) encoder->Release();
  if (stream != nullptr) stream->Release();
  if (factory != nullptr) factory->Release();
  return result;
}

FFI_PLUGIN_EXPORT int uvc_start_recording(uvc_session_t* session,
                                          const char* path, int bitrate_bps,
                                          int fps_hint, int rotation,
                                          int flip_h, int flip_v) {
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
  const UINT32 fps = fps_hint > 0 ? static_cast<UINT32>(fps_hint) : 30;

  std::lock_guard<std::mutex> lock(s.mutex);
  if (s.recording.load()) {
    SetErrorMessage(s, "A recording is already in progress");
    return kErrorBusy;
  }
  if (!s.previewing.load() || s.frame_w <= 0 || s.frame_h <= 0 ||
      s.sequence.load() <= 0) {
    SetErrorMessage(s,
                    "Recording requires an active preview with delivered frames");
    return kErrorInvalidMode;
  }
  if (!EnsureMediaFoundation()) {
    SetErrorMessage(s, "MFStartup failed");
    return kErrorOther;
  }

  const int src_w = s.frame_w;
  const int src_h = s.frame_h;
  const bool swap = r == 90 || r == 270;
  const int out_w = swap ? src_h : src_w;
  const int out_h = swap ? src_w : src_h;
  if ((out_w % 2) != 0 || (out_h % 2) != 0) {
    SetErrorMessage(s, "Recording requires even frame dimensions, got %dx%d",
                    out_w, out_h);
    return kErrorInvalidParam;
  }

  UINT32 bitrate;
  if (bitrate_bps > 0) {
    bitrate = static_cast<UINT32>(bitrate_bps);
  } else {
    const int64_t heuristic = static_cast<int64_t>(out_w) * out_h * fps / 10;
    bitrate = static_cast<UINT32>(
        heuristic < 300000 ? 300000
        : heuristic > 50000000 ? 50000000
                               : heuristic);
  }

  const int wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wide_len <= 0) {
    SetErrorMessage(s, "Invalid recording path");
    return kErrorInvalidParam;
  }
  std::wstring wpath(static_cast<size_t>(wide_len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, &wpath[0], wide_len);
  wpath.resize(static_cast<size_t>(wide_len) - 1);

  IMFAttributes* attrs = nullptr;
  IMFSinkWriter* writer = nullptr;
  DWORD stream = 0;
  HRESULT hr = MFCreateAttributes(&attrs, 2);
  if (SUCCEEDED(hr)) {
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    // Force the MP4 container so the path's extension does not matter.
    attrs->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    hr = MFCreateSinkWriterFromURL(wpath.c_str(), nullptr, attrs, &writer);
  }
  if (attrs != nullptr) attrs->Release();
  if (FAILED(hr) || writer == nullptr) {
    SetErrorMessage(s, "Failed to create MP4 writer for %s: 0x%08lX", path,
                    static_cast<unsigned long>(hr));
    return kErrorIo;
  }

  IMFMediaType* out_type = nullptr;
  hr = MFCreateMediaType(&out_type);
  if (SUCCEEDED(hr)) {
    out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    out_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    out_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
    MFSetAttributeSize(out_type, MF_MT_FRAME_SIZE, out_w, out_h);
    MFSetAttributeRatio(out_type, MF_MT_FRAME_RATE, fps, 1);
    MFSetAttributeRatio(out_type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = writer->AddStream(out_type, &stream);
    out_type->Release();
  }
  if (SUCCEEDED(hr)) {
    IMFMediaType* in_type = nullptr;
    hr = MFCreateMediaType(&in_type);
    if (SUCCEEDED(hr)) {
      in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      MFSetAttributeSize(in_type, MF_MT_FRAME_SIZE, out_w, out_h);
      MFSetAttributeRatio(in_type, MF_MT_FRAME_RATE, fps, 1);
      MFSetAttributeRatio(in_type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      hr = writer->SetInputMediaType(stream, in_type, nullptr);
      in_type->Release();
    }
  }
  if (SUCCEEDED(hr)) hr = writer->BeginWriting();
  if (FAILED(hr)) {
    writer->Release();
    SetErrorMessage(s, "Failed to configure H.264 recording: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorNotSupported;
  }

  {
    std::lock_guard<std::mutex> rec_lock(s.rec_mutex);
    s.sink_writer = writer;
    s.sink_stream = stream;
    s.rec_src_w = src_w;
    s.rec_src_h = src_h;
    s.rec_w = out_w;
    s.rec_h = out_h;
    s.rec_rotation = r;
    s.rec_flip_h = flip_h != 0 ? 1 : 0;
    s.rec_flip_v = flip_v != 0 ? 1 : 0;
    s.rec_fps = fps;
    s.rec_start_qpc = QpcNow();
    s.rec_last_ts = -1;
    s.rec_frames_written = 0;
    s.rec_frames_dropped = 0;
    s.rec_rgba.clear();
    s.recording.store(true);
  }
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_stop_recording(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return StopRecordingInternal(*s);
}

FFI_PLUGIN_EXPORT int uvc_is_recording(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->recording.load() ? 1 : 0;
}

FFI_PLUGIN_EXPORT int64_t uvc_latest_frame_sequence(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  return s->sequence.load();
}

FFI_PLUGIN_EXPORT void uvc_set_frame_listener(uvc_session_t* session,
                                              uvc_frame_listener_t listener,
                                              void* user_data) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->listener_mutex);
  s->frame_listener = listener;
  s->frame_listener_data = listener != nullptr ? user_data : nullptr;
}

FFI_PLUGIN_EXPORT void uvc_set_error_listener(uvc_session_t* session,
                                              uvc_error_listener_t listener,
                                              void* user_data) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  std::lock_guard<std::mutex> lock(s->listener_mutex);
  s->error_listener = listener;
  s->error_listener_data = listener != nullptr ? user_data : nullptr;
}

FFI_PLUGIN_EXPORT int uvc_get_stream_stats_json(uvc_session_t* session,
                                                uint8_t* buffer,
                                                int buffer_length) {
  std::shared_ptr<Session> owner = Impl(session);
  if (!owner) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(owner->mutex);
  const StreamStats& s = owner->stats;
  const int64_t now = QpcNow();
  const double elapsed_ms =
      s.start_qpc != 0 ? QpcToMs(now - s.start_qpc) : 0.0;
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
    size_t idx = static_cast<size_t>(
        static_cast<double>(sorted.size() - 1) * 0.95);
    p95_gap_ms = sorted[idx];
  }
  const double first_frame_latency_ms =
      s.first_frame_qpc != 0 && s.start_qpc != 0
          ? QpcToMs(s.first_frame_qpc - s.start_qpc)
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
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uvc_session_t* session,
                                                   uint8_t* buffer,
                                                   int buffer_length) {
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
                    mode.width, mode.height, static_cast<int>(mode.fps))) {
      return 0;
    }
    first = false;
  }
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "]")) {
    return 0;
  }
  return static_cast<int>(offset);
}

FFI_PLUGIN_EXPORT int64_t uvc_error_count(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  return s->error_count.load();
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes(uvc_session_t* session,
                                              uvc_mode_t* out_modes,
                                              int max_modes) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s || out_modes == nullptr || max_modes <= 0) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->symlink.empty()) return kErrorNoDevice;
  int count = 0;
  for (const ModeInfo& mode : s->modes) {
    if (count >= max_modes) break;
    out_modes[count].frame_format = mode.format;
    out_modes[count].width = static_cast<int>(mode.width);
    out_modes[count].height = static_cast<int>(mode.height);
    out_modes[count].fps = static_cast<int>(mode.fps);
    count += 1;
  }
  return count;
}

FFI_PLUGIN_EXPORT const char* uvc_last_error(uvc_session_t* session) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return "";
  std::lock_guard<std::mutex> lock(s->error_mutex);
  memcpy(s->last_error_snapshot, s->last_error, sizeof(s->last_error_snapshot));
  s->last_error_snapshot[sizeof(s->last_error_snapshot) - 1] = '\0';
  return s->last_error_snapshot;
}

FFI_PLUGIN_EXPORT void uvc_set_log_level(int level) {
  process.log_level.store(level);
}

FFI_PLUGIN_EXPORT void uvc_set_preview_transform(uvc_session_t* session,
                                                 int rotation, int flip_h,
                                                 int flip_v) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  s->rotation = rotation;
  s->flip_h = flip_h != 0 ? 1 : 0;
  s->flip_v = flip_v != 0 ? 1 : 0;
}

FFI_PLUGIN_EXPORT void uvc_get_preview_transform(uvc_session_t* session,
                                                 int* rotation, int* flip_h,
                                                 int* flip_v) {
  uvc_win::GetPreviewTransform(session, rotation, flip_h, flip_v);
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uvc_session_t* session,
                                            uint8_t* buffer,
                                            int buffer_length) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->source == nullptr) return 0;

  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const WinCtrlInfo& info : kCtrlTable) {
    long cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
    if (!CtrlReadLocked(*s, info, &cur, &min_val, &max_val, &def_val,
                        &res_val)) {
      continue;
    }
    if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                    "%s{\"id\":%d,\"name\":\"%s\",\"label\":\"%s\","
                    "\"uiType\":\"%s\",\"min\":%ld,\"max\":%ld,"
                    "\"def\":%ld,\"cur\":%ld,\"res\":%ld}",
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
}

// Raw descriptor bmControls are not reachable through Media Foundation.
FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uvc_session_t* /*session*/,
                                                    uint8_t* /*buffer*/,
                                                    int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(uvc_session_t* session, int ctrl_id) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return INT32_MIN;
  std::lock_guard<std::mutex> lock(s->mutex);
  const WinCtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr || s->source == nullptr) return INT32_MIN;
  long cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
  if (!CtrlReadLocked(*s, *info, &cur, &min_val, &max_val, &def_val,
                      &res_val)) {
    return INT32_MIN;
  }
  return static_cast<int32_t>(cur);
}

FFI_PLUGIN_EXPORT int uvc_ctrl_set(uvc_session_t* session, int ctrl_id,
                                   int32_t value) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  const WinCtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr) return kErrorNotSupported;
  if (s->source == nullptr) return kErrorNoDevice;
  return CtrlSetLocked(*s, *info, value);
}

FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(
    uvc_session_t* /*session*/, uint8_t* /*buffer*/, int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(
    uvc_session_t* session, uint16_t /*blue*/, uint16_t /*red*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uvc_session_t* /*session*/,
                                             uint8_t* /*buffer*/,
                                             int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(uvc_session_t* session,
                                               int8_t /*focus_rel*/,
                                               uint8_t /*speed*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uvc_session_t* /*session*/,
                                            uint8_t* /*buffer*/,
                                            int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(uvc_session_t* session,
                                              int8_t /*zoom_rel*/,
                                              uint8_t /*digital_zoom*/,
                                              uint8_t /*speed*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uvc_session_t* session,
                                               uint8_t* buffer,
                                               int buffer_length) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return 0;
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->camctrl == nullptr) return 0;
  long pan = 0, tilt = 0, flags = 0;
  if (FAILED(s->camctrl->Get(CameraControl_Pan, &pan, &flags)) ||
      FAILED(s->camctrl->Get(CameraControl_Tilt, &tilt, &flags))) {
    return 0;
  }
  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset,
                  "{\"pan\":%ld,\"tilt\":%ld}", pan, tilt)) {
    return 0;
  }
  return static_cast<int>(offset);
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(uvc_session_t* session,
                                                 int32_t pan, int32_t tilt) {
  std::shared_ptr<Session> s = Impl(session);
  if (!s) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->camctrl == nullptr) return kErrorNoDevice;
  int result = MapCtrlHr(
      s->camctrl->Set(CameraControl_Pan, pan, CameraControl_Flags_Manual));
  if (result != 0) return result;
  return MapCtrlHr(
      s->camctrl->Set(CameraControl_Tilt, tilt, CameraControl_Flags_Manual));
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uvc_session_t* /*session*/,
                                               uint8_t* /*buffer*/,
                                               int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(uvc_session_t* session,
                                                 int8_t /*pan_rel*/,
                                                 uint8_t /*pan_speed*/,
                                                 int8_t /*tilt_rel*/,
                                                 uint8_t /*tilt_speed*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uvc_session_t* /*session*/,
                                            uint8_t* /*buffer*/,
                                            int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(uvc_session_t* session,
                                              int8_t /*roll_rel*/,
                                              uint8_t /*speed*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uvc_session_t* /*session*/,
                                                  uint8_t* /*buffer*/,
                                                  int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uvc_session_t* session, uint16_t /*window_top*/, uint16_t /*window_left*/,
    uint16_t /*window_bottom*/, uint16_t /*window_right*/,
    uint16_t /*num_steps*/, uint16_t /*num_steps_units*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(
    uvc_session_t* /*session*/, uint8_t* /*buffer*/, int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uvc_session_t* session, uint16_t /*roi_top*/, uint16_t /*roi_left*/,
    uint16_t /*roi_bottom*/, uint16_t /*roi_right*/,
    uint16_t /*auto_controls*/) {
  return session == nullptr ? kErrorInvalidParam : kErrorNotSupported;
}
