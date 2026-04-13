# flutter_ffi_uvc

This package is a Flutter plugin backed by native `libuvc`.

## Android support

- Android only
- `minSdk 24`
- Supported ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`

## What this package does
- Opens a UVC camera from an already acquired platform file descriptor
- Lists camera modes reported by the native UVC layer
- Starts and stops UVC preview
- Copies the latest preview frame as RGBA bytes
- Reads and writes supported UVC controls

## Android USB ownership and handoff

This package expects the host Android app to pass an already acquired file
descriptor into `uvcCamera.openFd(fd)`.

The Android host app typically:

1. enumerates devices with `UsbManager`
2. requests user permission through the Android USB APIs
3. opens the selected device with `UsbManager.openDevice(...)`
4. obtains `UsbDeviceConnection.fileDescriptor`

The host app owns USB device access and `UsbDeviceConnection` lifetime.  
This package only manages UVC streaming and control for that opened device.


## Installation

```sh
flutter pub add flutter_ffi_uvc
```
Or add `flutter_ffi_uvc` to the dependencies section of your `pubspec.yaml`.

## Usage

### Typical lifecycle

The intended usage flow is:

1. Request Android camera and USB device permission in app/platform code.
2. Open the USB device on the Android side and obtain a file descriptor.
3. Optionally call `uvcCamera.setLogLevel(...)`.
4. Call `uvcCamera.openFd(fd)`.
5. Read `uvcCamera.supportedModes()`.
6. Pick a mode and call `uvcCamera.startPreview(mode)`.
7. Poll `uvcCamera.copyLatestFrame()` while preview is active.
8. Call `uvcCamera.stopPreview()` when preview is no longer needed. 
9. When finished, call `uvcCamera.closeDevice()` and close the Android `UsbDeviceConnection`.

### Single-camera model

This plugin is designed around a single, shared global `uvcCamera` instance. It supports one connected camera at a time:

```dart
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

class UvcPreviewPage extends StatefulWidget {
  const UvcPreviewPage({
    super.key,
    this.camera = uvcCamera,
  });

  final UvcCamera camera;
}
```

### Minimal usage example

```dart
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

Future<void> startUvcPreview(int fd) async {
  uvcCamera.setLogLevel(UvcLogLevel.warn);

  final int openResult = uvcCamera.openFd(fd);
  if (openResult != 0) {
    throw Exception('Failed to open UVC device: ${uvcCamera.lastError}');
  }

  final List<UvcCameraMode> modes = uvcCamera.supportedModes();
  if (modes.isEmpty) {
    uvcCamera.closeDevice();
    throw Exception('No supported UVC modes were reported.');
  }

  final UvcCameraMode mode = modes.first;
  final int previewResult = uvcCamera.startPreview(mode);
  if (previewResult != 0) {
    uvcCamera.closeDevice();
    throw Exception('Failed to start preview: ${uvcCamera.lastError}');
  }

  final UvcPreviewFrame? frame = uvcCamera.copyLatestFrame();
  if (frame != null) {
    print('Received ${frame.width}x${frame.height} RGBA frame');
  }
}
```

### Controls

`supportedControls()` returns the controls exposed by the currently opened
device, including min/max/default/current values. `getControl(...)` and
`setControl(...)` use typed `UvcControlId` values instead of raw integer IDs.  
For device debugging, `debugBmControls()` returns the controls advertised by
descriptor `bmControls` without `GET_CUR` probing. This is useful when a device
reports a control bit but rejects or mishandles `GET_CUR`.

Control labels are for display only. Use `UvcControlId` to identify controls in code:

```dart
final int? autoFocus = uvcCamera.getControl(UvcControlId.focusAuto);
await Future<void>.delayed(const Duration(milliseconds: 100));
uvcCamera.setControl(UvcControlId.focusAuto, autoFocus == 0 ? 1 : 0);
```

Compound UVC controls are exposed as typed APIs instead of a single integer:

```dart
final UvcPanTiltAbsoluteControl? panTilt =
    uvcCamera.getPanTiltAbsoluteControl();

if (panTilt != null) {
  uvcCamera.setPanTiltAbsoluteControl(
    UvcPanTiltAbsoluteControl(
      pan: panTilt.pan + 10,
      tilt: panTilt.tilt,
    ),
  );
}
```
### Logging

You can change the log level for the underlying libuvc layer at runtime:

```dart
uvcCamera.setLogLevel(UvcLogLevel.warn);
```

Available levels are:

- `UvcLogLevel.error`
- `UvcLogLevel.warn`
- `UvcLogLevel.info`
- `UvcLogLevel.debug`
- `UvcLogLevel.trace`

If you do not call `uvcCamera.setLogLevel(...)`, the package defaults to `UvcLogLevel.info`.

## Example app

The bundled example app demonstrates:

- Android USB permission and device setup
- preview rendering
- basic camera control interactions

The example app uses its own `AndroidUsbDeviceEntry` model for USB device
selection UI. That model is not part of this package API.

## Primary API

Most users will interact with these primary API entry points:

- uvcCamera
- UvcCamera
- UvcCameraMode
- UvcPreviewFrame
- UvcCameraControl
- UvcControlId
- UvcControlKind

Debugging APIs are also available when needed:

- UvcLogLevel
- UvcBmControlInfo
- debugBmControls()

Do not depend on the generated bindings directly unless you are working on the
package internals.

## Licensing

This package is licensed under the BSD 3-Clause License. 
Bundled third-party components keep their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependency
license notices, including `libuvc`, `libusb`, and `libjpeg-turbo`.
