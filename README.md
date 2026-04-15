# flutter_ffi_uvc

**This package is based on `libuvc`.**

## Support

- Android only
- `minSdk 24`
- Supported ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`

## Features

- Lists UVC-capable USB devices and manages USB permission
- Opens a UVC camera device
- Lists camera modes reported
- Starts and stops UVC preview
- Copies the latest preview frame as RGBA bytes
- Renders preview directly into a Flutter `Texture` on Android
- Reads and writes supported UVC controls

## Installation

```sh
flutter pub add flutter_ffi_uvc
```

Or add `flutter_ffi_uvc` to the dependencies section of your `pubspec.yaml`.

## Usage

### Typical lifecycle

1. Call `uvcCamera.ensureCameraPermission()` if your app requires the `CAMERA` permission.
2. Call `uvcCamera.listUsbDevices()` to discover attached UVC cameras.
3. Call `uvcCamera.openUsbDevice(deviceId)` to request USB permission and open the device.
4. Read `uvcCamera.supportedModes()`.
5. Pick a mode and call `uvcCamera.startPreview(mode)`.
6. For live preview on Android, prefer attaching a Flutter `Texture`.
7. Use `copyLatestFrame()` only when you need frame bytes in Dart, such as for capture or inspection.
8. Call `uvcCamera.stopPreview()` when preview is no longer needed.
9. When finished, call `uvcCamera.closeUsbDevice()`.

### Single-camera model

This plugin is designed around a single, shared global `uvcCamera` instance. It supports one connected camera at a time:

```dart
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

class UvcPreviewPage extends StatefulWidget {
  UvcPreviewPage({
    super.key,
    UvcCamera? camera,
  }) : camera = camera ?? uvcCamera;

  final UvcCamera camera;
}
```

### USB Device discovery and opening

```dart
// List attached UVC cameras
final List<UvcUsbDevice> devices = await uvcCamera.listUsbDevices();

// Open a device — requests USB permission if not already granted
final int result = await uvcCamera.openUsbDevice(devices.first.deviceId);
if (result != 0) {
  print('Open failed: ${uvcCamera.lastError}');
}
```

`openUsbDevice` requests USB permission from the user if needed before opening the device. 
It throws a `PlatformException` if the USB layer fails (e.g. permission denied, device not found) 
and returns a negative native error code if the UVC layer fails to initialize.

To close and release the USB connection:

```dart
await uvcCamera.closeUsbDevice();
```

#### Advanced: opening by file descriptor

If your app manages USB device access independently, pass an already-acquired file descriptor directly:

```dart
// fd: int from UsbDeviceConnection.fileDescriptor
uvcCamera.openFd(fd);
```

### Preview & Capture

#### Live preview with Texture

Attach a Flutter `Texture` before starting the stream:

```dart
final int textureId = await uvcCamera.createPreviewTexture();
await uvcCamera.attachPreviewTexture(
  textureId,
  width: mode.width,
  height: mode.height,
);
uvcCamera.startPreview(mode);
```

Display it with Flutter's `Texture` widget:

```dart
AspectRatio(
  aspectRatio: mode.width / mode.height,
  child: Texture(textureId: textureId),
)
```

On teardown:

```dart
uvcCamera.stopPreview();
await uvcCamera.disposePreviewTexture(textureId);
```

#### Capture

To get frame bytes in Dart — for snapshot, processing, or inspection — call
`copyLatestFrame()` while preview is running:

```dart
final UvcPreviewFrame? frame = uvcCamera.copyLatestFrame();
if (frame != null) {
  // frame.rgbaBytes: RGBA pixel data (width * height * 4 bytes)
  // frame.width, frame.height: frame dimensions
}
```

#### Frame drop behavior

When the native callback is already processing a frame, incoming callbacks are
dropped rather than queued.

Dropped callbacks are visible at `UvcLogLevel.trace`:

```text
dropping frame callback because previous callback is still processing
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

- USB device discovery and permission handling
- Preview rendering via Flutter `Texture`
- Basic camera control interactions

## Primary API

Most users will interact with these primary API entry points:

- `UvcCamera`
- `UvcUsbDevice`
- `UvcCameraMode`
- `UvcPreviewFrame`
- `UvcCameraControl`
- `UvcControlId`
- `UvcControlKind`

Debugging APIs are also available when needed:

- `UvcLogLevel`
- `UvcBmControlInfo`
- `debugBmControls()`

Do not depend on the generated bindings directly unless you are working on the
package internals.

## RoadMap

For upcoming work areas and current planning direction, see [ROADMAP.md](ROADMAP.md).

## Licensing

This package is licensed under the BSD 3-Clause License. 
Bundled third-party components keep their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependency
license notices, including `libuvc`, `libusb`, and `libjpeg-turbo`.
