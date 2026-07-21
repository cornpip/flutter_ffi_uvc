#ifndef FLUTTER_PLUGIN_FLUTTER_FFI_UVC_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_FFI_UVC_PLUGIN_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

namespace flutter_ffi_uvc {

// Windows counterpart of the Android FlutterFfiUvcPlugin: implements the
// flutter_ffi_uvc/texture and flutter_ffi_uvc/usb method channels and the
// flutter_ffi_uvc/device_events event channel over the Media Foundation
// backend living in the same DLL.
class FlutterFfiUvcPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit FlutterFfiUvcPlugin(flutter::PluginRegistrarWindows* registrar);
  ~FlutterFfiUvcPlugin() override;

  FlutterFfiUvcPlugin(const FlutterFfiUvcPlugin&) = delete;
  FlutterFfiUvcPlugin& operator=(const FlutterFfiUvcPlugin&) = delete;

 private:
  struct PreviewTexture {
    std::unique_ptr<flutter::TextureVariant> variant;
    FlutterDesktopPixelBuffer pixel_buffer{};
    std::vector<uint8_t> pixels;
  };

  void HandleTextureCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleUsbCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  const FlutterDesktopPixelBuffer* CopyPixelBuffer(PreviewTexture* texture);
  static void OnNativeFrameAvailable(void* context);

  // Device attach/detach notifications via a hidden window. Created while the
  // event channel has a listener.
  void StartDeviceNotifications();
  void StopDeviceNotifications();
  void OnDeviceChange(WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK NotifyWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  flutter::TextureRegistrar* textures_ = nullptr;
  std::map<int64_t, std::unique_ptr<PreviewTexture>> preview_textures_;
  int64_t attached_texture_id_ = -1;

  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      device_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      device_event_sink_;
  HWND notify_hwnd_ = nullptr;
  HDEVNOTIFY device_notify_ = nullptr;
};

}  // namespace flutter_ffi_uvc

#endif  // FLUTTER_PLUGIN_FLUTTER_FFI_UVC_PLUGIN_H_
