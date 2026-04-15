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
7. Consume frames via `copyLatestFrame()` (polling) or `latestFrameStream()` (notified).
8. Call `uvcCamera.stopPreview()` when preview is no longer needed.
9. When finished, call `uvcCamera.closeDevice()` and close the Android `UsbDeviceConnection`.

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

### Consuming frames

After `startPreview`, there are two ways to consume frames. Both always
deliver the latest available frame at the time of consumption — intermediate
frames are not buffered and will be skipped if Dart cannot keep up with the
camera's output rate.

#### Option 1 — `latestFrameStream`: native-notification-driven

Use this when you want to react as closely as possible to each frame the
device produces. The native layer notifies Dart on each frame arrival, which
triggers a pull of the latest frame. The native listener is registered on
`.listen()` and released when `stopPreview()` or `closeDevice()` is called.
The stream subscription ends automatically at that point.

```dart
final int result = uvcCamera.startPreview(mode);
if (result != 0) {
  throw Exception('Failed to start preview: ${uvcCamera.lastError}');
}

uvcCamera.latestFrameStream().listen(
  (UvcPreviewFrame frame) {
    // frame.rgbaBytes, frame.width, frame.height
  },
);

// Releases the native listener and closes the stream.
// The subscription ends automatically.
uvcCamera.stopPreview();
```

#### Option 2 — `copyLatestFrame`: timer-based polling

Use this when you want to control how often the display updates, e.g. to cap
rendering at a specific rate or decouple preview rendering from the camera's
output rate.

```dart
final int result = uvcCamera.startPreview(mode);
if (result != 0) {
  throw Exception('Failed to start preview: ${uvcCamera.lastError}');
}

final Timer timer = Timer.periodic(
  mode.recommendedPollingInterval + const Duration(milliseconds: 16),
  (_) {
    final UvcPreviewFrame? frame = uvcCamera.copyLatestFrame();
    if (frame != null) {
      // frame.rgbaBytes, frame.width, frame.height
    }
  },
);

// Cancel when preview is no longer needed.
timer.cancel();
uvcCamera.stopPreview();
```

`mode.recommendedPollingInterval` is derived from the selected mode's fps:

- `60fps` -> about `16ms`
- `30fps` -> about `33ms`
- `24fps` -> about `42ms`
- `15fps` -> about `67ms`
- `10fps` -> about `100ms`
- `5fps` -> about `200ms`

A longer interval reduces the polling rate. For example, adding
`const Duration(milliseconds: 16)` gives roughly:

- `60fps` mode: `16ms + 16ms = 32ms` -> about `31fps`
- `30fps` mode: `33ms + 16ms = 49ms` -> about `20fps`
- `24fps` mode: `42ms + 16ms = 58ms` -> about `17fps`
- `15fps` mode: `67ms + 16ms = 83ms` -> about `12fps`
- `10fps` mode: `100ms + 16ms = 116ms` -> about `8.6fps`
- `5fps` mode: `200ms + 16ms = 216ms` -> about `4.6fps`

Calculation formula:
- `polling interval in ms ~= 1000 / fps`
- `polling rate in fps ~= 1000 / polling interval in ms`

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

- `UvcCamera`
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
