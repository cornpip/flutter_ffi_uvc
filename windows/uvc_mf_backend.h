#ifndef FLUTTER_FFI_UVC_WINDOWS_UVC_MF_BACKEND_H_
#define FLUTTER_FFI_UVC_WINDOWS_UVC_MF_BACKEND_H_

// Internal (in-DLL) interface between the Media Foundation backend and the
// Flutter plugin layer. The Dart-facing surface of the backend is the C ABI
// declared in ../src/include/flutter_ffi_uvc.h; this header only carries what the
// plugin needs beyond that ABI (device enumeration for the platform channels
// and the texture frame-available hook).

#include <string>
#include <vector>

namespace uvc_win {

struct DeviceInfo {
  int device_id = -1;
  std::wstring symbolic_link;
  std::wstring friendly_name;
  int vendor_id = 0;
  int product_id = 0;
};

// Enumerates UVC-capable video capture devices through Media Foundation.
// Device ids are stable for the lifetime of the process (keyed by symbolic
// link), matching what uvc_open_fd() accepts on Windows.
std::vector<DeviceInfo> ListDevices();

bool DeviceExists(int device_id);

// Returns (assigning if needed) the stable device id for a symbolic link.
// Used by detach notifications, where the device is no longer enumerable.
int IdForSymbolicLink(const std::wstring& symbolic_link);

void GetPreviewTransform(int* rotation, int* flip_h, int* flip_v);

// Called from the frame delivery thread whenever a new preview frame landed
// in the shared RGBA buffer. Pass nullptr to clear.
void SetFrameAvailableCallback(void (*callback)(void* context), void* context);

}  // namespace uvc_win

#endif  // FLUTTER_FFI_UVC_WINDOWS_UVC_MF_BACKEND_H_
