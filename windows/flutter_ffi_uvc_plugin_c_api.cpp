#include "include/flutter_ffi_uvc/flutter_ffi_uvc_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_ffi_uvc_plugin.h"

void FlutterFfiUvcPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_ffi_uvc::FlutterFfiUvcPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
