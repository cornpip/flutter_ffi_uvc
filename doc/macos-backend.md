# macOS backend notes

The macOS backend
(`macos/flutter_ffi_uvc/Sources/flutter_ffi_uvc/uvc_avf_backend.mm`)
implements the same native contract as the other backends: same exported C
ABI (`src/include/flutter_ffi_uvc.h`), same JSON shapes for modes / controls
/ stream stats, same libuvc-style error codes. Streaming runs on
AVFoundation and the system UVC driver. Controls go to the camera as UVC
class requests over IOKit.

This document records the macOS-specific behavior and the reasoning behind
the deliberate differences.

## Why not libuvc

The system UVC driver owns the video interfaces of every camera, and an
ordinary app cannot take them over through libusb. The libuvc backend that
Linux reuses is therefore not an option.

## Dependencies

Only system frameworks: AVFoundation, CoreMedia, CoreVideo, Accelerate,
ImageIO, and IOKit. Nothing is vendored. The deployment target is macOS
10.15, the first release with `AVCaptureDeviceDiscoverySession`.

## Build layout

The plugin builds with both CocoaPods (`macos/flutter_ffi_uvc.podspec`) and
Swift Package Manager (`macos/flutter_ffi_uvc/Package.swift`) from one set
of sources.

- Everything is Objective-C++ or C++. A Swift package target cannot mix
  Swift with C++, and the backend shares `src/common/uvc_requests.cpp` with
  the other platforms.
- Neither build system compiles files outside the package directory, so
  `uvc_requests.cpp` in the sources is a forwarder that includes
  `src/common/uvc_requests.cpp` by relative path. The ABI header is included
  the same way.
- Objective-C++ gets no module autolinking, so the podspec names the
  `FlutterMacOS` framework in `OTHER_LDFLAGS`.
- `Package.swift` leaves out the `FlutterFramework` dependency so the plugin
  builds on every supported Flutter version. Flutter declares that package
  in its plugin template from 3.44 and not in 3.41 and earlier. Flutter 3.47
  builds without it and prints a warning. Add the dependency once the
  minimum Flutter version is 3.44 or later.
- The podspec reads its version from `pubspec.yaml`.

With CocoaPods and dynamic frameworks the ABI lives in
`flutter_ffi_uvc.framework`. With Swift Package Manager, the default from
Flutter 3.44, or static CocoaPods linkage, it is linked into the app binary. The Dart side tries the
framework and falls back to the process. On Apple platforms
`FFI_PLUGIN_EXPORT` carries `used` so the linker keeps symbols that only
Dart refers to. That covers dead stripping only. An archive of a
statically linked app strips all symbols by default, which removes them, so
such an app sets `STRIP_STYLE = non-global`. `flutter build macos` keeps
them either way.

## Permission and entitlements

- Camera access is a real runtime permission. `ensureCameraPermission()`
  and `openUsbDevice()` ask for it when it is undecided. A refused
  permission fails the open with `UVC_ERROR_ACCESS`.
- The app needs `NSCameraUsageDescription`, and when sandboxed the
  `com.apple.security.device.camera` entitlement.
- Controls need `com.apple.security.device.usb` in a sandboxed app. Without
  it the IOKit device cannot be reached: the session streams,
  `supportedControls()` is empty, and setters fail with
  `UVC_ERROR_NOT_SUPPORTED` and a message naming the entitlement.

## Device identity and lifecycle

- Listed are external USB cameras (device type external, transport type
  USB, and a vendor or product id) and the built-in camera, as Windows lists
  it. A Continuity Camera reports the built-in type by default and is left
  out through `isContinuityCamera`.
- A camera with no vendor or product id, which a built-in camera can be,
  gets no USB control device: `supportedControls()` is empty and setters
  fail with `UVC_ERROR_NOT_SUPPORTED`. The built-in camera has not been
  tested on hardware.
- There are no file descriptors. `openUsbDevice(deviceId)` resolves the id
  to an `AVCaptureDevice.uniqueID`. Ids are stable for the process lifetime
  and shared by all sessions. `openFd`/`closeFd` throw `UnsupportedError`.
- The vendor and product id come from `modelID`
  (`UVC Camera VendorID_x ProductID_y`). The `uniqueID` of a UVC camera is
  `0x` + USB location id + vendor id + product id in hex, which is how the
  IOKit device is found. That layout is not documented, so the location is
  only trusted when the ids in it agree with `modelID`. Otherwise the IOKit
  device is matched by vendor and product id, and only when exactly one
  device carries them.
- `deviceEvents` come from `AVCaptureDeviceWasConnectedNotification` and
  `AVCaptureDeviceWasDisconnectedNotification`.

## Mode enumeration

`supportedModes()` is built from `AVCaptureDevice.formats`, one mode per
format and supported frame rate. Formats: `MJPEG`, `YUYV`, `UYVY`, `NV12`.
The `format` integers mirror libuvc's `uvc_frame_format` values.

H.264 formats are left out for the reason given in
`doc/windows-backend.md`: an inter-frame codec breaks the per-frame
validation model, and the other formats cover the resolutions.

## Frame pipeline

- A preview start builds a new `AVCaptureSession`. The device stays locked
  for configuration across `startRunning`, which is what keeps the session
  from replacing the chosen `activeFormat` with its preset.
- The video data output delivers BGRA, so AVFoundation performs MJPEG decode
  and YUV conversion. Each frame is converted to RGBA into the session's
  frame buffer for `copyLatestFrame*`, and the capture buffer itself is kept
  for the Flutter texture.
- With no preview transform the texture renders the capture buffer without
  a copy. With a transform it renders a new buffer built from the RGBA
  frame.
- As on Windows, decode happens outside the backend, so the MJPEG-specific
  stream stats are always `0`.
- The texture is told about a new frame on the main thread, not on the
  capture queue.

## Recording

`AVAssetWriter` with an H.264 video input. Frames are appended from the
capture queue, the capture buffer itself when no transform is set. A file
already at the path is removed once the writer accepted the settings,
because the writer refuses an existing file.

## Controls

Requests are control transfers on endpoint 0 through
`IOUSBDeviceInterface::DeviceRequestTO`. The device is never opened or
claimed, so the system driver and a running stream are not disturbed.

- The VideoControl descriptors are parsed for the interface number, the
  camera terminal, the first processing unit, and their `bmControls`.
- The control table matches the libuvc backend. That includes the relative
  and compound controls and `debugBmControls`, which Windows cannot provide.
- Values are raw UVC values, as on Android and Linux.
