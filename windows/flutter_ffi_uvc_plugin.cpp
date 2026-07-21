#include "flutter_ffi_uvc_plugin.h"

#include <dbt.h>

#include <flutter/event_stream_handler_functions.h>

#include <cwctype>
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
  uvc_win::SetFrameAvailableCallback(nullptr, nullptr);
  StopDeviceNotifications();
  for (auto& entry : preview_textures_) {
    textures_->UnregisterTexture(entry.first);
  }
}

// static
void FlutterFfiUvcPlugin::OnNativeFrameAvailable(void* context) {
  auto* self = static_cast<FlutterFfiUvcPlugin*>(context);
  // Called from the Media Foundation delivery thread;
  // MarkTextureFrameAvailable is thread-safe.
  if (self->attached_texture_id_ >= 0) {
    self->textures_->MarkTextureFrameAvailable(self->attached_texture_id_);
  }
}

const FlutterDesktopPixelBuffer* FlutterFfiUvcPlugin::CopyPixelBuffer(
    PreviewTexture* texture) {
  int frame_w = uvc_frame_width();
  int frame_h = uvc_frame_height();
  if (frame_w <= 0 || frame_h <= 0) return nullptr;

  int rotation = 0, flip_h = 0, flip_v = 0;
  uvc_win::GetPreviewTransform(&rotation, &flip_h, &flip_v);
  const bool swap = rotation == 90 || rotation == 270;
  const int out_w = swap ? frame_h : frame_w;
  const int out_h = swap ? frame_w : frame_h;
  texture->pixels.resize(static_cast<size_t>(out_w) * out_h * 4);

  int copied_w = 0, copied_h = 0;
  int64_t sequence = 0;
  int copied = uvc_copy_latest_frame_rgba_transformed(
      texture->pixels.data(), static_cast<int>(texture->pixels.size()),
      rotation, flip_h, flip_v, &copied_w, &copied_h, &sequence);
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
    preview_textures_[texture_id] = std::move(texture);
    result->Success(flutter::EncodableValue(texture_id));
    return;
  }

  if (method == "disposePreviewTexture") {
    int64_t texture_id = args != nullptr ? Int64FromArg(*args, "textureId") : -1;
    if (texture_id == attached_texture_id_) {
      uvc_win::SetFrameAvailableCallback(nullptr, nullptr);
      attached_texture_id_ = -1;
    }
    auto it = preview_textures_.find(texture_id);
    if (it != preview_textures_.end()) {
      textures_->UnregisterTexture(texture_id);
      preview_textures_.erase(it);
    }
    result->Success();
    return;
  }

  if (method == "attachPreviewTexture") {
    int64_t texture_id = args != nullptr ? Int64FromArg(*args, "textureId") : -1;
    if (preview_textures_.find(texture_id) == preview_textures_.end()) {
      result->Error("texture_not_found", "Unknown textureId");
      return;
    }
    attached_texture_id_ = texture_id;
    uvc_win::SetFrameAvailableCallback(&FlutterFfiUvcPlugin::OnNativeFrameAvailable,
                                       this);
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
    int64_t device_id = args != nullptr ? Int64FromArg(*args, "deviceId") : -1;
    if (device_id < 0 || !uvc_win::DeviceExists(static_cast<int>(device_id))) {
      result->Error("device_not_found",
                    "No UVC device with id " + std::to_string(device_id));
      return;
    }
    // There is no fd on Windows; the Dart layer passes this value straight to
    // uvc_open_fd, where it is interpreted as the device id.
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("fileDescriptor"),
         flutter::EncodableValue(device_id)},
    }));
    return;
  }

  if (method == "closeUsbDevice") {
    // The native session is closed by the Dart layer through uvc_close_device;
    // there is no separate OS-level connection to release on Windows.
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
