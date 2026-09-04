#include "flutter_ffi_uvc_plugin.h"

#include <dbt.h>

#include <flutter/event_stream_handler_functions.h>

#include <cwctype>
#include <mutex>
#include <string>
#include <variant>

#include "uvc_mf_backend.h"

// The plugin reuses the exported FFI frame-copy entry points implemented by
// uvc_mf_backend.cpp for texture rendering.
#include "../src/include/flutter_ffi_uvc.h"

namespace flutter_ffi_uvc {

namespace {

// KSCATEGORY_VIDEO_CAMERA - the device interface class Media Foundation
// enumerates for video capture devices.
const GUID kVideoCameraClass = {
    0xE5323777,
    0xF976,
    0x4F5B,
    {0x9B, 0x55, 0xB9, 0x46, 0x99, 0xC4, 0x6E, 0x44}};

constexpr wchar_t kNotifyWindowClass[] = L"FlutterFfiUvcDeviceNotify";

// Pins the session with a registry id for the scope so uvc_session_destroy
// waits until the ABI calls made here have returned. Holds nothing when the
// id is not a live session.
class SessionPin {
 public:
  explicit SessionPin(int64_t id)
      : session_(id > 0 ? uvc_session_acquire_id(static_cast<uint64_t>(id))
                        : nullptr) {}
  ~SessionPin() {
    if (session_ != nullptr) uvc_session_release(session_);
  }
  SessionPin(const SessionPin&) = delete;
  SessionPin& operator=(const SessionPin&) = delete;
  uvc_session_t* get() const { return session_; }

 private:
  uvc_session_t* session_;
};

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int length = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                   static_cast<int>(wide.size()), nullptr, 0,
                                   nullptr, nullptr);
  std::string utf8(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), length, nullptr, nullptr);
  return utf8;
}

int64_t Int64FromArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(std::string(key)));
  if (it == args.end()) return -1;
  if (const auto* as32 = std::get_if<int32_t>(&it->second)) return *as32;
  if (const auto* as64 = std::get_if<int64_t>(&it->second)) return *as64;
  return -1;
}

// The Dart side passes the session's registry id (uvc_session_id).
int64_t SessionIdFromArgs(const flutter::EncodableMap* args) {
  if (args == nullptr) return 0;
  int64_t id = Int64FromArg(*args, "sessionHandle");
  return id > 0 ? id : 0;
}

flutter::EncodableMap DeviceToMap(const uvc_win::DeviceInfo& info) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("deviceId"),
       flutter::EncodableValue(info.device_id)},
      {flutter::EncodableValue("deviceName"),
       flutter::EncodableValue(Utf8FromWide(info.symbolic_link))},
      {flutter::EncodableValue("vendorId"),
       flutter::EncodableValue(info.vendor_id)},
      {flutter::EncodableValue("productId"),
       flutter::EncodableValue(info.product_id)},
      {flutter::EncodableValue("productName"),
       flutter::EncodableValue(Utf8FromWide(info.friendly_name))},
      {flutter::EncodableValue("manufacturerName"),
       flutter::EncodableValue(std::string())},
      {flutter::EncodableValue("serialNumber"),
       flutter::EncodableValue(std::string())},
      {flutter::EncodableValue("hasPermission"),
       flutter::EncodableValue(true)},
  };
}

bool EqualsIgnoreCase(const std::wstring& a, const std::wstring& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (towlower(a[i]) != towlower(b[i])) return false;
  }
  return true;
}

int ParseHexAfter(const std::wstring& haystack, const wchar_t* needle) {
  std::wstring lower;
  lower.reserve(haystack.size());
  for (wchar_t c : haystack) lower.push_back(towlower(c));
  size_t pos = lower.find(needle);
  if (pos == std::wstring::npos) return 0;
  pos += wcslen(needle);
  if (pos + 4 > lower.size()) return 0;
  return static_cast<int>(wcstoul(lower.substr(pos, 4).c_str(), nullptr, 16));
}

}  // namespace

// static
void FlutterFfiUvcPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<FlutterFfiUvcPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

FlutterFfiUvcPlugin::FlutterFfiUvcPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), textures_(registrar->texture_registrar()) {
  auto texture_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_ffi_uvc/texture",
          &flutter::StandardMethodCodec::GetInstance());
  texture_channel->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleTextureCall(call, std::move(result));
      });

  auto usb_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_ffi_uvc/usb",
          &flutter::StandardMethodCodec::GetInstance());
  usb_channel->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleUsbCall(call, std::move(result));
  });

  device_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_ffi_uvc/device_events",
          &flutter::StandardMethodCodec::GetInstance());
  device_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* /*arguments*/,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            device_event_sink_ = std::move(events);
            StartDeviceNotifications();
            return nullptr;
          },
          [this](const flutter::EncodableValue* /*arguments*/)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            StopDeviceNotifications();
            device_event_sink_.reset();
            return nullptr;
          }));
}

FlutterFfiUvcPlugin::~FlutterFfiUvcPlugin() {
  StopDeviceNotifications();
  for (auto& entry : preview_textures_) {
    DetachTexture(entry.second.get());
    // The raster thread may still be inside CopyPixelBuffer. Free the
    // texture only once the engine confirms it is unregistered.
    PreviewTexture* raw = entry.second.release();
    textures_->UnregisterTexture(entry.first, [raw]() { delete raw; });
  }
}

// static
void FlutterFfiUvcPlugin::OnNativeFrameAvailable(void* context,
                                                 int64_t /*sequence*/) {
  // Called from the Media Foundation delivery thread;
  // MarkTextureFrameAvailable is thread-safe. The texture outlives this call:
  // clearing the listener in DetachTexture returns only after it has finished.
  auto* texture = static_cast<PreviewTexture*>(context);
  texture->plugin->textures_->MarkTextureFrameAvailable(texture->texture_id);
}

void FlutterFfiUvcPlugin::DetachTexture(PreviewTexture* texture) {
  // The Dart side may already have destroyed the session. The pin then fails
  // and there is no listener left to clear.
  SessionPin pin(texture->session.exchange(0));
  if (pin.get() != nullptr) {
    uvc_set_frame_listener(pin.get(), nullptr, nullptr);
  }
}

const FlutterDesktopPixelBuffer* FlutterFfiUvcPlugin::CopyPixelBuffer(
    PreviewTexture* texture) {
  // Raster thread. The texture can be detached and its session destroyed
  // while this runs. The pin keeps the session alive until the copy is done.
  SessionPin pin(texture->session.load());
  uvc_session_t* session = pin.get();
  if (session == nullptr) return nullptr;
  int frame_w = uvc_frame_width(session);
  int frame_h = uvc_frame_height(session);
  if (frame_w <= 0 || frame_h <= 0) return nullptr;

  int rotation = 0, flip_h = 0, flip_v = 0;
  uvc_win::GetPreviewTransform(session, &rotation, &flip_h, &flip_v);
  const bool swap = rotation == 90 || rotation == 270;
  const int out_w = swap ? frame_h : frame_w;
  const int out_h = swap ? frame_w : frame_h;
  texture->pixels.resize(static_cast<size_t>(out_w) * out_h * 4);

  int copied_w = 0, copied_h = 0;
  int64_t sequence = 0;
  int copied = uvc_copy_latest_frame_rgba_transformed(
      session, texture->pixels.data(),
      static_cast<int>(texture->pixels.size()), rotation, flip_h, flip_v,
      &copied_w, &copied_h, &sequence);
  if (copied <= 0) return nullptr;

  texture->pixel_buffer.buffer = texture->pixels.data();
  texture->pixel_buffer.width = static_cast<size_t>(copied_w);
  texture->pixel_buffer.height = static_cast<size_t>(copied_h);
  texture->pixel_buffer.release_callback = nullptr;
  texture->pixel_buffer.release_context = nullptr;
  return &texture->pixel_buffer;
}

void FlutterFfiUvcPlugin::HandleTextureCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "createPreviewTexture") {
    auto texture = std::make_unique<PreviewTexture>();
    PreviewTexture* raw = texture.get();
    texture->plugin = this;
    texture->variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [this, raw](size_t /*width*/, size_t /*height*/)
                -> const FlutterDesktopPixelBuffer* {
              return CopyPixelBuffer(raw);
            }));
    int64_t texture_id = textures_->RegisterTexture(texture->variant.get());
    if (texture_id < 0) {
      result->Error("texture_create_failed", "RegisterTexture failed");
      return;
    }
    texture->texture_id = texture_id;
    preview_textures_[texture_id] = std::move(texture);
    result->Success(flutter::EncodableValue(texture_id));
    return;
  }

  if (method == "disposePreviewTexture") {
    int64_t texture_id = args != nullptr ? Int64FromArg(*args, "textureId") : -1;
    auto it = preview_textures_.find(texture_id);
    if (it != preview_textures_.end()) {
      std::unique_ptr<PreviewTexture> texture = std::move(it->second);
      preview_textures_.erase(it);
      DetachTexture(texture.get());
      // The raster thread may still be inside CopyPixelBuffer. Free the
      // texture only once the engine confirms it is unregistered.
      PreviewTexture* raw = texture.release();
      textures_->UnregisterTexture(texture_id, [raw]() { delete raw; });
    }
    result->Success();
    return;
  }

  if (method == "attachPreviewTexture") {
    int64_t texture_id = args != nullptr ? Int64FromArg(*args, "textureId") : -1;
    auto it = preview_textures_.find(texture_id);
    if (it == preview_textures_.end()) {
      result->Error("texture_not_found", "Unknown textureId");
      return;
    }
    const int64_t session_id = SessionIdFromArgs(args);
    SessionPin pin(session_id);
    uvc_session_t* session = pin.get();
    if (session == nullptr) {
      result->Error("invalid_session",
                    "sessionHandle is missing or not a live session");
      return;
    }
    PreviewTexture* texture = it->second.get();
    // A session drives at most one texture. Unbind it from any other texture
    // and unbind this texture from any other session.
    for (auto& entry : preview_textures_) {
      PreviewTexture* other = entry.second.get();
      if (other != texture && other->session.load() == session_id) {
        other->session.store(0);
      }
    }
    if (texture->session.load() != session_id) DetachTexture(texture);
    texture->session.store(session_id);
    uvc_set_frame_listener(session, &FlutterFfiUvcPlugin::OnNativeFrameAvailable,
                           texture);
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterFfiUvcPlugin::HandleUsbCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "ensureCameraPermission") {
    // Windows desktop apps have no runtime camera permission dialog; OS
    // privacy settings surface as open/stream failures instead.
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "listUsbDevices") {
    flutter::EncodableList devices;
    for (const uvc_win::DeviceInfo& info : uvc_win::ListDevices()) {
      devices.push_back(flutter::EncodableValue(DeviceToMap(info)));
    }
    result->Success(flutter::EncodableValue(devices));
    return;
  }

  if (method == "openUsbDevice") {
    const int64_t session_id = SessionIdFromArgs(args);
    const int64_t request_id =
        args != nullptr ? Int64FromArg(*args, "requestId") : 0;
    int64_t device_id = args != nullptr ? Int64FromArg(*args, "deviceId") : -1;
    if (session_id == 0 || request_id <= 0) {
      result->Error("invalid_args", "sessionHandle and requestId are required.");
      return;
    }
    if (device_id < 0 || !uvc_win::DeviceExists(static_cast<int>(device_id))) {
      result->Error("device_not_found",
                    "No UVC device with id " + std::to_string(device_id));
      return;
    }
    // There is no fd on Windows. The device id goes to the queued open,
    // where uvc_open_fd interprets it. Nothing to release afterwards, so
    // the plugin registers no platform listener.
    SessionPin pin(session_id);
    if (pin.get() != nullptr) {
      uvc_supply_fd(pin.get(), request_id, static_cast<int>(device_id));
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterFfiUvcPlugin::StartDeviceNotifications() {
  if (notify_hwnd_ != nullptr) return;

  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &FlutterFfiUvcPlugin::NotifyWndProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kNotifyWindowClass;
  RegisterClassW(&window_class);  // Idempotent; may already exist.

  // A hidden top-level window: message-only windows do not receive
  // WM_DEVICECHANGE broadcasts.
  notify_hwnd_ = CreateWindowExW(0, kNotifyWindowClass, L"", WS_POPUP, 0, 0, 0,
                                 0, nullptr, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
  if (notify_hwnd_ == nullptr) return;
  SetWindowLongPtrW(notify_hwnd_, GWLP_USERDATA,
                    reinterpret_cast<LONG_PTR>(this));

  DEV_BROADCAST_DEVICEINTERFACE_W filter = {};
  filter.dbcc_size = sizeof(filter);
  filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
  filter.dbcc_classguid = kVideoCameraClass;
  device_notify_ = RegisterDeviceNotificationW(notify_hwnd_, &filter,
                                               DEVICE_NOTIFY_WINDOW_HANDLE);
}

void FlutterFfiUvcPlugin::StopDeviceNotifications() {
  if (device_notify_ != nullptr) {
    UnregisterDeviceNotification(device_notify_);
    device_notify_ = nullptr;
  }
  if (notify_hwnd_ != nullptr) {
    DestroyWindow(notify_hwnd_);
    notify_hwnd_ = nullptr;
  }
}

// static
LRESULT CALLBACK FlutterFfiUvcPlugin::NotifyWndProc(HWND hwnd, UINT message,
                                                    WPARAM wparam,
                                                    LPARAM lparam) {
  if (message == WM_DEVICECHANGE) {
    auto* self = reinterpret_cast<FlutterFfiUvcPlugin*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self != nullptr) {
      self->OnDeviceChange(wparam, lparam);
    }
    return TRUE;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void FlutterFfiUvcPlugin::OnDeviceChange(WPARAM wparam, LPARAM lparam) {
  if (device_event_sink_ == nullptr) return;
  if (wparam != DBT_DEVICEARRIVAL && wparam != DBT_DEVICEREMOVECOMPLETE) {
    return;
  }
  auto* header = reinterpret_cast<DEV_BROADCAST_HDR*>(lparam);
  if (header == nullptr ||
      header->dbch_devicetype != DBT_DEVTYP_DEVICEINTERFACE) {
    return;
  }
  auto* broadcast =
      reinterpret_cast<DEV_BROADCAST_DEVICEINTERFACE_W*>(lparam);
  std::wstring symbolic_link(broadcast->dbcc_name);
  const bool attached = wparam == DBT_DEVICEARRIVAL;

  flutter::EncodableMap device_map;
  bool found = false;
  if (attached) {
    for (const uvc_win::DeviceInfo& info : uvc_win::ListDevices()) {
      if (EqualsIgnoreCase(info.symbolic_link, symbolic_link)) {
        device_map = DeviceToMap(info);
        found = true;
        break;
      }
    }
  }
  if (!found) {
    // Detached devices (and attach races) are no longer enumerable; build the
    // entry from the interface path alone.
    uvc_win::DeviceInfo info;
    info.symbolic_link = symbolic_link;
    info.vendor_id = ParseHexAfter(symbolic_link, L"vid_");
    info.product_id = ParseHexAfter(symbolic_link, L"pid_");
    info.device_id = uvc_win::IdForSymbolicLink(symbolic_link);
    device_map = DeviceToMap(info);
  }

  device_event_sink_->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("event"),
       flutter::EncodableValue(attached ? "attached" : "detached")},
      {flutter::EncodableValue("device"), flutter::EncodableValue(device_map)},
  }));
}

}  // namespace flutter_ffi_uvc
