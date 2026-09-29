#ifndef FLUTTER_FFI_UVC_MACOS_UVC_AVF_BACKEND_H_
#define FLUTTER_FFI_UVC_MACOS_UVC_AVF_BACKEND_H_

// Internal interface between the AVFoundation backend and the Flutter plugin
// layer, both linked into the same binary. The Dart-facing surface of the
// backend is the C ABI declared in src/include/flutter_ffi_uvc.h. This header
// only carries what the plugin needs beyond that ABI: device enumeration for
// the platform channels and the pixel buffer a Flutter texture renders.

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#include <string>
#include <vector>

typedef struct uvc_session uvc_session_t;

namespace uvc_mac {

struct DeviceInfo {
  int device_id = -1;
  // AVCaptureDevice.uniqueID
  std::string unique_id;
  std::string name;
  std::string manufacturer;
  int vendor_id = 0;
  int product_id = 0;
};

// Enumerates external USB cameras and the built-in camera. Device ids are
// stable for the lifetime of the process (keyed by uniqueID), matching what
// uvc_open_fd() accepts on macOS.
std::vector<DeviceInfo> ListDevices();

bool DeviceExists(int device_id);

// A discovery session for the devices ListDevices reports. AVFoundation
// posts connection notifications only while one exists.
AVCaptureDeviceDiscoverySession* CreateDiscoverySession();

// True for the devices ListDevices reports.
bool IsListedDevice(AVCaptureDevice* device);

// Describes a device, assigning its stable id if needed. Works for a device
// that was just disconnected, which enumeration no longer lists.
DeviceInfo InfoForDevice(AVCaptureDevice* device);

// Latest preview frame as a BGRA pixel buffer with the session's preview
// transform applied, or NULL before the first frame. The caller releases it.
CVPixelBufferRef CopyPreviewPixelBuffer(uvc_session_t* session);

}  // namespace uvc_mac

#endif  // FLUTTER_FFI_UVC_MACOS_UVC_AVF_BACKEND_H_
