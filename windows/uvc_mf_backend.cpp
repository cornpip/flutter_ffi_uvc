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
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "../src/include/flutter_ffi_uvc.h"

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

class SourceReaderCallback;

struct BackendState {
  std::mutex mutex;
  bool mf_started = false;

  // Stable process-lifetime device ids keyed by symbolic link.
  std::map<std::wstring, int> id_by_symlink;
  int next_device_id = 1;

  // Open session.
  IMFMediaSource* source = nullptr;
  IMFSourceReader* reader = nullptr;
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

  std::atomic<uvc_frame_listener_t> frame_listener{nullptr};
  std::atomic<uvc_error_listener_t> error_listener{nullptr};
  void (*plugin_frame_cb)(void*) = nullptr;
  void* plugin_frame_ctx = nullptr;

  std::mutex error_mutex;
  char last_error[512] = {0};

  std::atomic<int> log_level{1};

  // MP4 recording. rec_mutex serializes WriteSample against Finalize; the
  // lock order is g.mutex -> rec_mutex (never the reverse).
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
  // g.mutex in OnReadSample's dimension-mismatch path.
  std::atomic<uint64_t> rec_frames_written{0};
  std::atomic<uint64_t> rec_frames_dropped{0};
  std::vector<uint8_t> rec_rgba;         // frame snapshot taken under g.mutex
  std::vector<uint8_t> rec_transformed;  // rotated/flipped frame, when needed
};

BackendState g;

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

void WriteRecordingFrame(int64_t ts_qpc);
int StopRecordingInternal();

void SetErrorMessage(const char* fmt, ...) {
  std::lock_guard<std::mutex> lock(g.error_mutex);
  va_list args;
  va_start(args, fmt);
  vsnprintf(g.last_error, sizeof(g.last_error), fmt, args);
  va_end(args);
}

// Sets last_error and pushes the message to the Dart stream-error listener.
void ReportError(const char* fmt, ...) {
  char message[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(message, sizeof(message), fmt, args);
  va_end(args);
  {
    std::lock_guard<std::mutex> lock(g.error_mutex);
    strncpy_s(g.last_error, message, _TRUNCATE);
  }
  uvc_error_listener_t listener = g.error_listener.load();
  if (listener != nullptr) {
    listener(message);
  }
}

bool EnsureMediaFoundation() {
  // The platform thread already runs STA COM in a Flutter runner; this only
  // covers standalone use (tests). RPC_E_CHANGED_MODE is fine.
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  (void)hr;
  if (!g.mf_started) {
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
      SetErrorMessage("MFStartup failed");
      return false;
    }
    g.mf_started = true;
  }
  if (g.flush_event == nullptr) {
    g.flush_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  }
  return true;
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

int AssignIdLocked(const std::wstring& symlink) {
  auto it = g.id_by_symlink.find(symlink);
  if (it != g.id_by_symlink.end()) return it->second;
  int id = g.next_device_id++;
  g.id_by_symlink[symlink] = id;
  return id;
}

// Enumerates MF video capture devices. When target_symlink is non-null, the
// matching IMFActivate is returned addref'd through out_activate.
std::vector<uvc_win::DeviceInfo> EnumerateLocked(
    const std::wstring* target_symlink, IMFActivate** out_activate) {
  std::vector<uvc_win::DeviceInfo> result;
  if (out_activate != nullptr) *out_activate = nullptr;
  if (!EnsureMediaFoundation()) return result;

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

void EnumerateModesLocked() {
  g.modes.clear();
  if (g.reader == nullptr) return;
  for (DWORD index = 0;; ++index) {
    IMFMediaType* type = nullptr;
    HRESULT hr = g.reader->GetNativeMediaType(kVideoStream, index, &type);
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
    g.modes.push_back(mode);
  }
}

void RecordDeliveredLocked() {
  int64_t now = QpcNow();
  StreamStats& s = g.stats;
  s.delivered_frame_count += 1;
  s.decode_success_count += 1;
  if (s.first_frame_qpc == 0) s.first_frame_qpc = now;
  if (s.last_delivered_qpc != 0) {
    double gap_ms = QpcToMs(now - s.last_delivered_qpc);
    s.gap_sum_ms += gap_ms;
    if (gap_ms > s.max_gap_ms) s.max_gap_ms = gap_ms;
    s.gaps_ms[s.gap_next] = gap_ms;
    s.gap_next = (s.gap_next + 1) % StreamStats::kGapCapacity;
    if (s.gap_count < StreamStats::kGapCapacity) s.gap_count += 1;
  }
  s.last_delivered_qpc = now;
}

// Converts one contiguous RGB32 (BGRX) sample into the shared RGBA buffer.
// Returns true when a frame was delivered. Caller holds g.mutex.
bool ConvertSampleLocked(IMFSample* sample) {
  IMFMediaBuffer* buffer = nullptr;
  if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) {
    g.stats.conversion_failure_count += 1;
    return false;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0, cur_len = 0;
  if (FAILED(buffer->Lock(&data, &max_len, &cur_len))) {
    buffer->Release();
    g.stats.conversion_failure_count += 1;
    return false;
  }

  bool delivered = false;
  const int w = g.frame_w;
  const int h = g.frame_h;
  const LONG stride = g.out_stride;
  const size_t abs_stride =
      static_cast<size_t>(stride >= 0 ? stride : -stride);
  const size_t needed = abs_stride * static_cast<size_t>(h);
  if (w <= 0 || h <= 0 || cur_len < needed) {
    g.stats.undersized_frame_count += 1;
    g.stats.decode_failure_count += 1;
  } else {
    const size_t out_bytes = static_cast<size_t>(w) * h * 4;
    if (g.rgba.size() != out_bytes) {
      g.rgba.resize(out_bytes);
    }
    if (g.rgba.size() != out_bytes) {
      g.stats.buffer_allocation_failure_count += 1;
    } else {
      for (int y = 0; y < h; ++y) {
        // Negative stride means bottom-up rows: image row y lives at
        // (h - 1 - y) * |stride|.
        const uint8_t* src =
            data + abs_stride * static_cast<size_t>(
                                    stride >= 0 ? y : (h - 1 - y));
        uint8_t* dst = g.rgba.data() + static_cast<size_t>(w) * 4 * y;
        for (int x = 0; x < w; ++x) {
          dst[0] = src[2];
          dst[1] = src[1];
          dst[2] = src[0];
          dst[3] = 255;
          dst += 4;
          src += 4;
        }
      }
      g.sequence.fetch_add(1);
      RecordDeliveredLocked();
      delivered = true;
    }
  }

  buffer->Unlock();
  buffer->Release();
  return delivered;
}

class SourceReaderCallback : public IMFSourceReaderCallback {
 public:
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
    bool delivered = false;
    bool request_next = false;
    bool record_frame = false;
    int64_t record_ts = 0;
    IMFSourceReader* reader = nullptr;
    int64_t sequence = 0;
    {
      std::lock_guard<std::mutex> lock(g.mutex);
      if (!g.previewing.load() || g.reader == nullptr) {
        return S_OK;
      }
      g.stats.input_frame_count += 1;
      if (SUCCEEDED(hr_status) && sample != nullptr) {
        delivered = ConvertSampleLocked(sample);
        sequence = g.sequence.load();
      } else if (FAILED(hr_status)) {
        g.stats.decode_failure_count += 1;
      }
      if (delivered && g.recording.load()) {
        if (g.frame_w == g.rec_src_w && g.frame_h == g.rec_src_h) {
          const size_t bytes =
              static_cast<size_t>(g.frame_w) * g.frame_h * 4;
          if (g.rec_rgba.size() != bytes) g.rec_rgba.resize(bytes);
          memcpy(g.rec_rgba.data(), g.rgba.data(), bytes);
          record_frame = true;
          record_ts = QpcNow();
        } else {
          g.rec_frames_dropped += 1;
        }
      }
      bool fatal = FAILED(hr_status) ||
                   (stream_flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0 ||
                   (stream_flags & MF_SOURCE_READERF_ERROR) != 0;
      request_next = g.previewing.load() && !fatal;
      if (request_next) {
        reader = g.reader;
        reader->AddRef();
      }
    }

    if (FAILED(hr_status)) {
      ReportError("Media Foundation ReadSample failed: 0x%08lX",
                  static_cast<unsigned long>(hr_status));
    }
    if (delivered) {
      uvc_frame_listener_t listener = g.frame_listener.load();
      if (listener != nullptr) listener(sequence);
      void (*plugin_cb)(void*) = nullptr;
      void* plugin_ctx = nullptr;
      {
        std::lock_guard<std::mutex> lock(g.mutex);
        plugin_cb = g.plugin_frame_cb;
        plugin_ctx = g.plugin_frame_ctx;
      }
      if (plugin_cb != nullptr) plugin_cb(plugin_ctx);
    }
    // Encode before requesting the next sample so this callback stays the
    // only writer of the recording snapshot buffer.
    if (record_frame) {
      WriteRecordingFrame(record_ts);
    }
    if (reader != nullptr) {
      reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr, nullptr);
      reader->Release();
    }
    return S_OK;
  }

  STDMETHODIMP OnFlush(DWORD /*stream_index*/) override {
    if (g.flush_event != nullptr) SetEvent(g.flush_event);
    return S_OK;
  }

  STDMETHODIMP OnEvent(DWORD /*stream_index*/,
                       IMFMediaEvent* /*event*/) override {
    return S_OK;
  }

 private:
  ~SourceReaderCallback() = default;
  LONG ref_count_ = 1;
};

// Stops preview and waits for in-flight callbacks to drain. Must be called
// WITHOUT g.mutex held: OnReadSample takes the mutex, and MF only completes
// Flush after pending callbacks return.
void StopPreviewInternal() {
  StopRecordingInternal();
  IMFSourceReader* reader = nullptr;
  {
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.previewing.exchange(false)) return;
    reader = g.reader;
    if (reader != nullptr) reader->AddRef();
    if (g.flush_event != nullptr) ResetEvent(g.flush_event);
  }
  if (reader != nullptr) {
    if (SUCCEEDED(reader->Flush(kVideoStream)) && g.flush_event != nullptr) {
      WaitForSingleObject(g.flush_event, 3000);
    }
    reader->Release();
  }
}

void CloseDeviceLocked() {
  if (g.reader != nullptr) {
    g.reader->Release();
    g.reader = nullptr;
  }
  if (g.procamp != nullptr) {
    g.procamp->Release();
    g.procamp = nullptr;
  }
  if (g.camctrl != nullptr) {
    g.camctrl->Release();
    g.camctrl = nullptr;
  }
  if (g.source != nullptr) {
    g.source->Shutdown();
    g.source->Release();
    g.source = nullptr;
  }
  g.modes.clear();
  g.frame_w = 0;
  g.frame_h = 0;
  g.sequence.store(0);
  g.rgba.clear();
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
// Caller holds g.mutex.
bool CtrlReadLocked(const WinCtrlInfo& info, long* cur, long* min_val,
                    long* max_val, long* def_val, long* res_val) {
  *min_val = 0;
  *max_val = 0;
  *def_val = 0;
  *res_val = 1;
  long flags = 0, caps = 0, value = 0, step = 1;
  switch (info.backend) {
    case CtrlBackend::kProcAmp:
    case CtrlBackend::kProcAmpAuto: {
      if (g.procamp == nullptr) return false;
      if (FAILED(g.procamp->Get(info.prop, &value, &flags))) return false;
      long dmin = 0, dmax = 0, ddef = 0;
      if (FAILED(g.procamp->GetRange(info.prop, &dmin, &dmax, &step, &ddef,
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
      if (g.camctrl == nullptr) return false;
      if (FAILED(g.camctrl->Get(info.prop, &value, &flags))) return false;
      long dmin = 0, dmax = 0, ddef = 0;
      if (FAILED(g.camctrl->GetRange(info.prop, &dmin, &dmax, &step, &ddef,
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

// Caller holds g.mutex.
int CtrlSetLocked(const WinCtrlInfo& info, int32_t value) {
  switch (info.backend) {
    case CtrlBackend::kProcAmp: {
      if (g.procamp == nullptr) return kErrorNoDevice;
      return MapCtrlHr(
          g.procamp->Set(info.prop, value, VideoProcAmp_Flags_Manual));
    }
    case CtrlBackend::kProcAmpAuto: {
      if (g.procamp == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      g.procamp->Get(info.prop, &cur, &flags);
      return MapCtrlHr(g.procamp->Set(
          info.prop, cur,
          value != 0 ? VideoProcAmp_Flags_Auto : VideoProcAmp_Flags_Manual));
    }
    case CtrlBackend::kCamCtrl: {
      if (g.camctrl == nullptr) return kErrorNoDevice;
      return MapCtrlHr(
          g.camctrl->Set(info.prop, value, CameraControl_Flags_Manual));
    }
    case CtrlBackend::kCamCtrlAuto: {
      if (g.camctrl == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      g.camctrl->Get(info.prop, &cur, &flags);
      return MapCtrlHr(g.camctrl->Set(
          info.prop, cur,
          value != 0 ? CameraControl_Flags_Auto : CameraControl_Flags_Manual));
    }
    case CtrlBackend::kExposure: {
      if (g.camctrl == nullptr) return kErrorNoDevice;
      return MapCtrlHr(g.camctrl->Set(info.prop, ExposureLog2FromUvc(value),
                                      CameraControl_Flags_Manual));
    }
    case CtrlBackend::kAeMode: {
      if (g.camctrl == nullptr) return kErrorNoDevice;
      long cur = 0, flags = 0;
      g.camctrl->Get(info.prop, &cur, &flags);
      // UVC AE mode: 1 = manual; any auto bit (2/4/8) maps to MF auto.
      return MapCtrlHr(g.camctrl->Set(
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
// Writer. Called from OnReadSample without g.mutex held; the snapshot buffer
// has a single writer because the next ReadSample is only requested after
// this returns.
void WriteRecordingFrame(int64_t ts_qpc) {
  std::lock_guard<std::mutex> lock(g.rec_mutex);
  if (!g.recording.load() || g.sink_writer == nullptr) return;

  const uint8_t* frame = g.rec_rgba.data();
  if (g.rec_rotation != 0 || g.rec_flip_h != 0 || g.rec_flip_v != 0) {
    const size_t bytes = static_cast<size_t>(g.rec_w) * g.rec_h * 4;
    if (g.rec_transformed.size() != bytes) g.rec_transformed.resize(bytes);
    TransformRgba(g.rec_rgba.data(), g.rec_src_w, g.rec_src_h, g.rec_rotation,
                  g.rec_flip_h, g.rec_flip_v, g.rec_transformed.data(),
                  g.rec_w, g.rec_h);
    frame = g.rec_transformed.data();
  }

  const DWORD bytes = static_cast<DWORD>(g.rec_w) * g.rec_h * 4;
  IMFMediaBuffer* buffer = nullptr;
  if (FAILED(MFCreateMemoryBuffer(bytes, &buffer))) {
    g.rec_frames_dropped += 1;
    return;
  }
  BYTE* data = nullptr;
  DWORD max_len = 0;
  if (FAILED(buffer->Lock(&data, &max_len, nullptr)) || max_len < bytes) {
    buffer->Release();
    g.rec_frames_dropped += 1;
    return;
  }
  // RGB32 samples without an explicit stride are bottom-up: write rows in
  // reverse order and swap RGBA to BGRX.
  for (int y = 0; y < g.rec_h; ++y) {
    const uint8_t* src = frame + static_cast<size_t>(y) * g.rec_w * 4;
    uint8_t* dst = data + static_cast<size_t>(g.rec_h - 1 - y) * g.rec_w * 4;
    for (int x = 0; x < g.rec_w; ++x) {
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
    g.rec_frames_dropped += 1;
    return;
  }
  sample->AddBuffer(buffer);
  LONGLONG ts = QpcTo100ns(ts_qpc - g.rec_start_qpc);
  if (ts <= g.rec_last_ts) ts = g.rec_last_ts + 1;
  sample->SetSampleTime(ts);
  sample->SetSampleDuration(10000000LL / (g.rec_fps > 0 ? g.rec_fps : 30));
  const HRESULT hr = g.sink_writer->WriteSample(g.sink_stream, sample);
  sample->Release();
  buffer->Release();
  if (FAILED(hr)) {
    g.rec_frames_dropped += 1;
    ReportError("Recording WriteSample failed: 0x%08lX",
                static_cast<unsigned long>(hr));
    return;
  }
  g.rec_last_ts = ts;
  g.rec_frames_written += 1;
}

// Stops accepting frames, then drains and finalizes the MP4 outside
// rec_mutex so an in-flight WriteRecordingFrame can finish first.
int StopRecordingInternal() {
  IMFSinkWriter* writer = nullptr;
  uint64_t written = 0;
  {
    std::lock_guard<std::mutex> lock(g.rec_mutex);
    if (!g.recording.exchange(false)) return 0;
    writer = g.sink_writer;
    g.sink_writer = nullptr;
    written = g.rec_frames_written.load();
  }
  int result = 0;
  if (writer != nullptr) {
    const HRESULT hr = writer->Finalize();
    if (FAILED(hr)) {
      SetErrorMessage("Failed to finalize recording: 0x%08lX",
                      static_cast<unsigned long>(hr));
      result = kErrorIo;
    } else if (written == 0) {
      SetErrorMessage("Recording produced no encoded frames");
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

std::vector<DeviceInfo> ListDevices() {
  std::lock_guard<std::mutex> lock(g.mutex);
  return EnumerateLocked(nullptr, nullptr);
}

bool DeviceExists(int device_id) {
  std::lock_guard<std::mutex> lock(g.mutex);
  for (const DeviceInfo& info : EnumerateLocked(nullptr, nullptr)) {
    if (info.device_id == device_id) return true;
  }
  return false;
}

int IdForSymbolicLink(const std::wstring& symbolic_link) {
  std::lock_guard<std::mutex> lock(g.mutex);
  return AssignIdLocked(symbolic_link);
}

void GetPreviewTransform(int* rotation, int* flip_h, int* flip_v) {
  std::lock_guard<std::mutex> lock(g.mutex);
  if (rotation != nullptr) *rotation = g.rotation;
  if (flip_h != nullptr) *flip_h = g.flip_h;
  if (flip_v != nullptr) *flip_v = g.flip_v;
}

void SetFrameAvailableCallback(void (*callback)(void* context),
                               void* context) {
  std::lock_guard<std::mutex> lock(g.mutex);
  g.plugin_frame_cb = callback;
  g.plugin_frame_ctx = context;
}

}  // namespace uvc_win

// ---------------------------------------------------------------------------
// Exported C ABI (see ../src/include/flutter_ffi_uvc.h)
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int sum(int a, int b) { return a + b; }

FFI_PLUGIN_EXPORT int sum_long_running(int a, int b) {
  Sleep(5000);
  return a + b;
}

// On Windows there are no file descriptors: the "fd" is the stable device id
// handed out by device enumeration (see uvc_win::ListDevices), which the
// Dart openUsbDevice flow passes straight back in.
FFI_PLUGIN_EXPORT int uvc_open_fd(int fd) {
  StopPreviewInternal();
  std::lock_guard<std::mutex> lock(g.mutex);
  if (!EnsureMediaFoundation()) {
    return kErrorOther;
  }
  CloseDeviceLocked();

  std::wstring symlink;
  for (const uvc_win::DeviceInfo& info : EnumerateLocked(nullptr, nullptr)) {
    if (info.device_id == fd) {
      symlink = info.symbolic_link;
      break;
    }
  }
  if (symlink.empty()) {
    SetErrorMessage("No video capture device with id %d", fd);
    return kErrorNoDevice;
  }

  IMFActivate* activate = nullptr;
  EnumerateLocked(&symlink, &activate);
  if (activate == nullptr) {
    SetErrorMessage("Device %d disappeared during open", fd);
    return kErrorNoDevice;
  }
  HRESULT hr = activate->ActivateObject(IID_PPV_ARGS(&g.source));
  activate->Release();
  if (FAILED(hr) || g.source == nullptr) {
    SetErrorMessage("Failed to activate media source: 0x%08lX",
                 static_cast<unsigned long>(hr));
    g.source = nullptr;
    return kErrorIo;
  }

  // Control interfaces are optional; a device without them still streams.
  g.source->QueryInterface(IID_PPV_ARGS(&g.procamp));
  g.source->QueryInterface(IID_PPV_ARGS(&g.camctrl));

  IMFAttributes* attrs = nullptr;
  if (FAILED(MFCreateAttributes(&attrs, 2))) {
    CloseDeviceLocked();
    SetErrorMessage("MFCreateAttributes failed");
    return kErrorOther;
  }
  attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  SourceReaderCallback* callback = new SourceReaderCallback();
  attrs->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback);
  callback->Release();  // The attribute store holds the reference now.

  hr = MFCreateSourceReaderFromMediaSource(g.source, attrs, &g.reader);
  attrs->Release();
  if (FAILED(hr) || g.reader == nullptr) {
    CloseDeviceLocked();
    SetErrorMessage("MFCreateSourceReaderFromMediaSource failed: 0x%08lX",
                 static_cast<unsigned long>(hr));
    return kErrorIo;
  }

  EnumerateModesLocked();
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_start_preview(int frame_format, int width,
                                        int height, int fps) {
  StopPreviewInternal();
  std::lock_guard<std::mutex> lock(g.mutex);
  if (g.reader == nullptr) {
    SetErrorMessage("No device open");
    return kErrorNoDevice;
  }

  const ModeInfo* mode = nullptr;
  for (const ModeInfo& candidate : g.modes) {
    if (candidate.format == frame_format &&
        candidate.width == static_cast<UINT32>(width) &&
        candidate.height == static_cast<UINT32>(height) &&
        candidate.fps == static_cast<UINT32>(fps)) {
      mode = &candidate;
      break;
    }
  }
  if (mode == nullptr) {
    SetErrorMessage("Mode %dx%d@%d (format %d) not reported by device", width,
                 height, fps, frame_format);
    return kErrorInvalidMode;
  }

  g.reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  g.reader->SetStreamSelection(kVideoStream, TRUE);

  IMFMediaType* native = nullptr;
  HRESULT hr =
      g.reader->GetNativeMediaType(kVideoStream, mode->native_index, &native);
  if (FAILED(hr)) {
    SetErrorMessage("GetNativeMediaType failed: 0x%08lX",
                 static_cast<unsigned long>(hr));
    return kErrorInvalidMode;
  }
  hr = g.reader->SetCurrentMediaType(kVideoStream, nullptr, native);
  native->Release();
  if (FAILED(hr)) {
    SetErrorMessage("SetCurrentMediaType(native) failed: 0x%08lX",
                 static_cast<unsigned long>(hr));
    return kErrorInvalidMode;
  }

  IMFMediaType* out_type = nullptr;
  if (FAILED(MFCreateMediaType(&out_type))) {
    SetErrorMessage("MFCreateMediaType failed");
    return kErrorOther;
  }
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  MFSetAttributeSize(out_type, MF_MT_FRAME_SIZE, mode->width, mode->height);
  hr = g.reader->SetCurrentMediaType(kVideoStream, nullptr, out_type);
  out_type->Release();
  if (FAILED(hr)) {
    SetErrorMessage("SetCurrentMediaType(RGB32) failed: 0x%08lX",
                 static_cast<unsigned long>(hr));
    return kErrorNotSupported;
  }

  IMFMediaType* current = nullptr;
  LONG stride = static_cast<LONG>(mode->width) * 4;
  if (SUCCEEDED(g.reader->GetCurrentMediaType(kVideoStream, &current))) {
    UINT32 stride_attr = 0;
    if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_attr))) {
      stride = static_cast<LONG>(static_cast<INT32>(stride_attr));
    }
    current->Release();
  }

  g.frame_w = static_cast<int>(mode->width);
  g.frame_h = static_cast<int>(mode->height);
  g.out_stride = stride;
  g.sequence.store(0);
  g.stats = StreamStats();
  g.stats.start_qpc = QpcNow();
  g.previewing.store(true);

  hr = g.reader->ReadSample(kVideoStream, 0, nullptr, nullptr, nullptr,
                            nullptr);
  if (FAILED(hr)) {
    g.previewing.store(false);
    SetErrorMessage("ReadSample kick-off failed: 0x%08lX",
                 static_cast<unsigned long>(hr));
    return kErrorIo;
  }
  return 0;
}

FFI_PLUGIN_EXPORT void uvc_stop_preview(void) { StopPreviewInternal(); }

FFI_PLUGIN_EXPORT void uvc_close_device(void) {
  StopPreviewInternal();
  std::lock_guard<std::mutex> lock(g.mutex);
  CloseDeviceLocked();
}

FFI_PLUGIN_EXPORT int uvc_is_previewing(void) {
  return g.previewing.load() ? 1 : 0;
}

FFI_PLUGIN_EXPORT int uvc_frame_width(void) {
  std::lock_guard<std::mutex> lock(g.mutex);
  return g.frame_w;
}

FFI_PLUGIN_EXPORT int uvc_frame_height(void) {
  std::lock_guard<std::mutex> lock(g.mutex);
  return g.frame_h;
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uint8_t* buffer,
                                                 int buffer_length) {
  return uvc_copy_latest_frame_rgba_with_metadata(buffer, buffer_length,
                                                  nullptr, nullptr, nullptr);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uint8_t* buffer, int buffer_length, int* out_width, int* out_height,
    int64_t* out_sequence) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  const size_t needed = static_cast<size_t>(g.frame_w) * g.frame_h * 4;
  if (g.frame_w <= 0 || g.frame_h <= 0 || g.sequence.load() <= 0 ||
      g.rgba.size() < needed ||
      static_cast<size_t>(buffer_length) < needed) {
    return 0;
  }
  memcpy(buffer, g.rgba.data(), needed);
  if (out_width != nullptr) *out_width = g.frame_w;
  if (out_height != nullptr) *out_height = g.frame_h;
  if (out_sequence != nullptr) *out_sequence = g.sequence.load();
  return static_cast<int>(needed);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_transformed(
    uint8_t* buffer, int buffer_length, int rotation, int flip_h, int flip_v,
    int* out_width, int* out_height, int64_t* out_sequence) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;

  std::lock_guard<std::mutex> lock(g.mutex);
  const int src_w = g.frame_w;
  const int src_h = g.frame_h;
  const size_t src_bytes = static_cast<size_t>(src_w) * src_h * 4;
  if (src_w <= 0 || src_h <= 0 || g.sequence.load() <= 0 ||
      g.rgba.size() < src_bytes) {
    return 0;
  }
  const bool swap = rotation == 90 || rotation == 270;
  const int dst_w = swap ? src_h : src_w;
  const int dst_h = swap ? src_w : src_h;
  const size_t dst_bytes = static_cast<size_t>(dst_w) * dst_h * 4;
  if (static_cast<size_t>(buffer_length) < dst_bytes) return 0;

  TransformRgba(g.rgba.data(), src_w, src_h, rotation, flip_h, flip_v, buffer,
                dst_w, dst_h);
  if (out_width != nullptr) *out_width = dst_w;
  if (out_height != nullptr) *out_height = dst_h;
  if (out_sequence != nullptr) *out_sequence = g.sequence.load();
  return static_cast<int>(dst_bytes);
}

FFI_PLUGIN_EXPORT int uvc_take_picture_jpeg(
    uint8_t* buffer, int buffer_length, int quality, int rotation, int flip_h,
    int flip_v, int* out_width, int* out_height, int64_t* out_sequence) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  if (quality < 1) quality = 1;
  if (quality > 100) quality = 100;

  int dst_w = 0;
  int dst_h = 0;
  int64_t sequence = 0;
  std::vector<uint8_t> rgba;
  {
    std::lock_guard<std::mutex> lock(g.mutex);
    const int src_w = g.frame_w;
    const int src_h = g.frame_h;
    const size_t src_bytes = static_cast<size_t>(src_w) * src_h * 4;
    if (src_w <= 0 || src_h <= 0 || g.sequence.load() <= 0 ||
        g.rgba.size() < src_bytes) {
      SetErrorMessage("No preview frame available to capture");
      return 0;
    }
    const bool swap = rotation == 90 || rotation == 270;
    dst_w = swap ? src_h : src_w;
    dst_h = swap ? src_w : src_h;
    rgba.resize(static_cast<size_t>(dst_w) * dst_h * 4);
    TransformRgba(g.rgba.data(), src_w, src_h, rotation, flip_h, flip_v,
                  rgba.data(), dst_w, dst_h);
    sequence = g.sequence.load();
  }

  // Encode outside the state mutex so OnReadSample never blocks behind JPEG
  // encoding. WIC needs COM on this thread; EnsureMediaFoundation covers
  // standalone (test) callers, and is a no-op on the Flutter platform thread.
  if (!EnsureMediaFoundation()) return 0;

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
      SetErrorMessage("WIC JPEG encoder rejected 24bpp BGR input");
      break;
    }
    const UINT stride = static_cast<UINT>(dst_w) * 3;
    if (SUCCEEDED(hr)) {
      hr = frame->WritePixels(dst_h, stride, stride * dst_h, bgr.data());
    }
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    if (FAILED(hr)) {
      SetErrorMessage("JPEG encode failed (hr=0x%08lx)",
                      static_cast<unsigned long>(hr));
      break;
    }

    // The HGLOBAL stream's end position is the number of bytes written.
    LARGE_INTEGER zero = {};
    ULARGE_INTEGER end = {};
    if (FAILED(stream->Seek(zero, STREAM_SEEK_END, &end)) ||
        end.QuadPart == 0) {
      SetErrorMessage("JPEG encode produced no output");
      break;
    }
    if (end.QuadPart > static_cast<ULONGLONG>(buffer_length)) {
      SetErrorMessage("JPEG output (%llu bytes) exceeds capture buffer (%d bytes)",
                      end.QuadPart, buffer_length);
      break;
    }
    HGLOBAL hglobal = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &hglobal))) {
      SetErrorMessage("Failed to read back encoded JPEG stream");
      break;
    }
    void* data = GlobalLock(hglobal);
    if (data == nullptr) {
      SetErrorMessage("Failed to lock encoded JPEG stream memory");
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

FFI_PLUGIN_EXPORT int uvc_start_recording(
    const char* path, int bitrate_bps, int fps_hint, int rotation, int flip_h,
    int flip_v) {
  if (path == nullptr || path[0] == '\0') {
    SetErrorMessage("Recording path must not be empty");
    return kErrorInvalidParam;
  }
  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 90 && r != 180 && r != 270) r = 0;
  const UINT32 fps = fps_hint > 0 ? static_cast<UINT32>(fps_hint) : 30;

  std::lock_guard<std::mutex> lock(g.mutex);
  if (g.recording.load()) {
    SetErrorMessage("A recording is already in progress");
    return kErrorBusy;
  }
  if (!g.previewing.load() || g.frame_w <= 0 || g.frame_h <= 0 ||
      g.sequence.load() <= 0) {
    SetErrorMessage("Recording requires an active preview with delivered frames");
    return kErrorInvalidMode;
  }
  if (!EnsureMediaFoundation()) return kErrorOther;

  const int src_w = g.frame_w;
  const int src_h = g.frame_h;
  const bool swap = r == 90 || r == 270;
  const int out_w = swap ? src_h : src_w;
  const int out_h = swap ? src_w : src_h;
  if ((out_w % 2) != 0 || (out_h % 2) != 0) {
    SetErrorMessage("Recording requires even frame dimensions, got %dx%d",
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
    SetErrorMessage("Invalid recording path");
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
    SetErrorMessage("Failed to create MP4 writer for %s: 0x%08lX", path,
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
    SetErrorMessage("Failed to configure H.264 recording: 0x%08lX",
                    static_cast<unsigned long>(hr));
    return kErrorNotSupported;
  }

  {
    std::lock_guard<std::mutex> rec_lock(g.rec_mutex);
    g.sink_writer = writer;
    g.sink_stream = stream;
    g.rec_src_w = src_w;
    g.rec_src_h = src_h;
    g.rec_w = out_w;
    g.rec_h = out_h;
    g.rec_rotation = r;
    g.rec_flip_h = flip_h != 0 ? 1 : 0;
    g.rec_flip_v = flip_v != 0 ? 1 : 0;
    g.rec_fps = fps;
    g.rec_start_qpc = QpcNow();
    g.rec_last_ts = -1;
    g.rec_frames_written = 0;
    g.rec_frames_dropped = 0;
    g.rec_rgba.clear();
    g.recording.store(true);
  }
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_stop_recording(void) {
  return StopRecordingInternal();
}

FFI_PLUGIN_EXPORT int uvc_is_recording(void) {
  return g.recording.load() ? 1 : 0;
}

FFI_PLUGIN_EXPORT int64_t uvc_latest_frame_sequence(void) {
  return g.sequence.load();
}

FFI_PLUGIN_EXPORT void uvc_set_frame_listener(uvc_frame_listener_t listener) {
  g.frame_listener.store(listener);
}

FFI_PLUGIN_EXPORT void uvc_set_error_listener(uvc_error_listener_t listener) {
  g.error_listener.store(listener);
}

FFI_PLUGIN_EXPORT int uvc_get_stream_stats_json(uint8_t* buffer,
                                                int buffer_length) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  const StreamStats& s = g.stats;
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

FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uint8_t* buffer,
                                                   int buffer_length) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const ModeInfo& mode : g.modes) {
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

FFI_PLUGIN_EXPORT const char* uvc_last_error(void) { return g.last_error; }

FFI_PLUGIN_EXPORT void uvc_set_log_level(int level) {
  g.log_level.store(level);
}

FFI_PLUGIN_EXPORT void uvc_set_preview_transform(int rotation, int flip_h,
                                                 int flip_v) {
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  g.rotation = rotation;
  g.flip_h = flip_h != 0 ? 1 : 0;
  g.flip_v = flip_v != 0 ? 1 : 0;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uint8_t* buffer,
                                            int buffer_length) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  if (g.source == nullptr) return 0;

  char* json = reinterpret_cast<char*>(buffer);
  size_t offset = 0;
  if (!AppendJson(json, static_cast<size_t>(buffer_length), &offset, "[")) {
    return 0;
  }
  bool first = true;
  for (const WinCtrlInfo& info : kCtrlTable) {
    long cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
    if (!CtrlReadLocked(info, &cur, &min_val, &max_val, &def_val, &res_val)) {
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
FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uint8_t* /*buffer*/,
                                                    int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(int ctrl_id) {
  std::lock_guard<std::mutex> lock(g.mutex);
  const WinCtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr || g.source == nullptr) return INT32_MIN;
  long cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
  if (!CtrlReadLocked(*info, &cur, &min_val, &max_val, &def_val, &res_val)) {
    return INT32_MIN;
  }
  return static_cast<int32_t>(cur);
}

FFI_PLUGIN_EXPORT int uvc_ctrl_set(int ctrl_id, int32_t value) {
  std::lock_guard<std::mutex> lock(g.mutex);
  const WinCtrlInfo* info = FindCtrl(ctrl_id);
  if (info == nullptr) return kErrorNotSupported;
  if (g.source == nullptr) return kErrorNoDevice;
  return CtrlSetLocked(*info, value);
}

FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(
    uint8_t* /*buffer*/, int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(
    uint16_t /*blue*/, uint16_t /*red*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uint8_t* /*buffer*/,
                                             int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(int8_t /*focus_rel*/,
                                               uint8_t /*speed*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uint8_t* /*buffer*/,
                                            int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(int8_t /*zoom_rel*/,
                                              uint8_t /*digital_zoom*/,
                                              uint8_t /*speed*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uint8_t* buffer,
                                               int buffer_length) {
  if (buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(g.mutex);
  if (g.camctrl == nullptr) return 0;
  long pan = 0, tilt = 0, flags = 0;
  if (FAILED(g.camctrl->Get(CameraControl_Pan, &pan, &flags)) ||
      FAILED(g.camctrl->Get(CameraControl_Tilt, &tilt, &flags))) {
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

FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(int32_t pan, int32_t tilt) {
  std::lock_guard<std::mutex> lock(g.mutex);
  if (g.camctrl == nullptr) return kErrorNoDevice;
  int result = MapCtrlHr(
      g.camctrl->Set(CameraControl_Pan, pan, CameraControl_Flags_Manual));
  if (result != 0) return result;
  return MapCtrlHr(
      g.camctrl->Set(CameraControl_Tilt, tilt, CameraControl_Flags_Manual));
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uint8_t* /*buffer*/,
                                               int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(int8_t /*pan_rel*/,
                                                 uint8_t /*pan_speed*/,
                                                 int8_t /*tilt_rel*/,
                                                 uint8_t /*tilt_speed*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uint8_t* /*buffer*/,
                                            int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(int8_t /*roll_rel*/,
                                              uint8_t /*speed*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uint8_t* /*buffer*/,
                                                  int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uint16_t /*window_top*/, uint16_t /*window_left*/,
    uint16_t /*window_bottom*/, uint16_t /*window_right*/,
    uint16_t /*num_steps*/, uint16_t /*num_steps_units*/) {
  return kErrorNotSupported;
}

FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uint8_t* /*buffer*/,
                                                      int /*buffer_length*/) {
  return 0;
}

FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uint16_t /*roi_top*/, uint16_t /*roi_left*/, uint16_t /*roi_bottom*/,
    uint16_t /*roi_right*/, uint16_t /*auto_controls*/) {
  return kErrorNotSupported;
}
