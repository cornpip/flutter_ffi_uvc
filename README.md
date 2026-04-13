# flutter_ffi_uvc

This package is a Flutter plugin backed by native `libuvc`, `libusb`, and `libjpeg-turbo`.

## Platform support

- Android only

## What this package does
- Opens a UVC camera from an already acquired platform file descriptor
- Lists camera modes reported by the native UVC layer
- Starts and stops uvc preview
- Copies the latest preview frame as RGBA bytes
- Reads and writes supported UVC controls

## What this package does not do

This package does not enumerate USB devices or request Android USB permission
for you. The app must do that on the platform side first, then pass the opened
device file descriptor to `uvcCamera.openFd(...)`.

In other words, this package handles the UVC/native camera session after the
Android side has already:

- found a USB camera device
- obtained user permission to access it
- opened the device and acquired a file descriptor

See the example app for one way to do that with a `MethodChannel`.

## Android FD-based design

This package intentionally uses an Android file-descriptor handoff instead of
asking `libuvc` to enumerate and open devices by itself.

In a typical desktop `libuvc` flow, native code would:

1. initialize `libuvc`
2. enumerate or find a matching UVC device
3. open that device directly in native code

On Android, USB access is owned by the framework. Apps normally:

1. enumerate devices with `UsbManager`
2. request user permission through the Android USB APIs
3. open the selected device with `UsbManager.openDevice(...)`
4. obtain `UsbDeviceConnection.fileDescriptor`

This package starts after that point. The app passes the already opened file
descriptor into `uvcCamera.openFd(fd)`, and the native layer wraps that open
device for `libuvc`-based UVC control and streaming.

That separation is intentional:

- Android app/platform code owns USB device discovery, selection, and permission
- this package owns the shared native UVC camera session after the device is
  already open

## Installation

Add the dependency:

```yaml
dependencies:
  flutter_ffi_uvc: ^0.0.1
```

Import the package and use the shared `uvcCamera` service directly:

```dart
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

final List<UvcCameraMode> modes = uvcCamera.supportedModes();
```

Widgets or app-level state objects can optionally accept a `UvcCamera`
parameter and default it to `uvcCamera`. That keeps normal package usage simple
while making tests and previews easier to fake.

```dart
class UvcPreviewPage extends StatefulWidget {
  const UvcPreviewPage({
    super.key,
    this.camera = uvcCamera,
  });

  final UvcCamera camera;
}
```

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

## Typical lifecycle

The intended usage flow is:

1. Request Android camera and USB device permission in app/platform code.
2. Open the USB device on the Android side and obtain a file descriptor.
3. Optionally call `uvcCamera.setLogLevel(...)`.
4. Call `uvcCamera.openFd(fd)`.
5. Read `uvcCamera.supportedModes()`.
6. Pick a mode and call `uvcCamera.startPreview(mode)`.
7. Poll `uvcCamera.copyLatestFrame()` while preview is active.
8. Call `uvcCamera.stopPreview()` when preview is no longer needed.
9. Call `uvcCamera.closeDevice()` before releasing the device.

## Logging

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

## Minimal usage example

This package expects a valid file descriptor from platform code:

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

## Controls

`supportedControls()` returns the controls exposed by the currently opened
device, including min/max/default/current values. `getControl(...)` and
`setControl(...)` use typed `UvcControlId` values instead of raw integer IDs.  
For device debugging, `debugBmControls()` returns the controls advertised by
descriptor `bmControls` without `GET_CUR` probing. This is useful when a device
reports a control bit but rejects or mishandles `GET_CUR`.

Control labels should be treated as UI display text, not as stable programmatic identifiers. 
Use UvcControlId instead when identifying controls in code.

```dart
final int? autoFocus = uvcCamera.getControl(UvcControlId.focusAuto);
await Future<void>.delayed(const Duration(milliseconds: 100));
uvcCamera.setControl(UvcControlId.focusAuto, autoFocus == 0 ? 1 : 0);
```

Compound UVC controls that carry more than one value are exposed through typed
APIs instead of being flattened into a single integer:

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

## Example app

The bundled example app demonstrates:

- Android permission flow
- USB device enumeration
- opening the USB device and passing its file descriptor into this package
- preview rendering
- basic camera control interactions

The example app defines its own Android-side USB enumeration model for UI
selection. That model is not part of this package API, and package consumers
can replace it with their own platform code as long as they pass a valid file
descriptor to `uvcCamera.openFd(...)`.


## Licensing

This package is licensed under the BSD 3-Clause License. 
Bundled third-party components keep their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependency
license notices, including `libuvc`, `libusb`, and `libjpeg-turbo`.


