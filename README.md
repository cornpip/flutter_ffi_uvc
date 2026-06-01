# flutter_ffi_uvc

**This package is based on `libuvc`.**

It provides Android UVC camera access, including USB device handling,
preview streaming to a Flutter `Texture`, frame access from Dart, preview
transforms, stream diagnostics, and UVC camera controls.

<img src="./readme_img/260430.gif" alt="app_image_2" width="300"/>

## Supported Platforms

- Android(arm64-v8a, x86_64, armeabi-v7a)
- Dart SDK: `>=3.8.1 <4.0.0`
- Android minSdk: `24`

## Installation

```sh
flutter pub add flutter_ffi_uvc
```

## How it works

This package combines three layers:

- Android USB Host API — device discovery, USB permission, and acquiring the file descriptor for the connected device.
- libusb — wraps that file descriptor and handles the actual USB communication.
- libuvc — sits on top of libusb and handles the UVC protocol: mode negotiation, frame streaming, and camera controls.

## Usage

### Typical lifecycle

1. Call `uvcCamera.ensureCameraPermission()` if your app requires the `CAMERA` permission.
2. Call `uvcCamera.listUsbDevices()` to discover attached UVC cameras.
3. Call `uvcCamera.openUsbDevice(deviceId)` to request USB permission and open the device.
4. Read `uvcCamera.supportedModes()`.
5. Pick a mode and call `await uvcCamera.startPreview(mode)` — starts the stream and verifies frame delivery.
6. On success, attach a Flutter `Texture` via `attachPreviewTexture` for live preview on Android.
7. Use `copyLatestFrame()` when you need frame bytes in Dart, such as for capture or inspection.
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

`openUsbDevice` goes through the Android USB layer to acquire permission and a file
descriptor, then passes it to libusb to open the session. It throws a
`PlatformException` if the Android layer fails, and returns a non-zero code if
libusb/libuvc fails to initialize.

To close and release the USB connection:

```dart
await uvcCamera.closeUsbDevice();
```

#### Alternative: opening by file descriptor

If your app manages USB access independently, pass the file descriptor directly to
skip the Android layer:

```dart
// fd: int from UsbDeviceConnection.fileDescriptor
uvcCamera.openFd(fd);
```

### Preview & Capture

#### Live preview with Texture

Create a texture, start preview, then attach the texture once the stream is confirmed running:

```dart
final int textureId = await uvcCamera.createPreviewTexture();

// stableFrames (default): verifies both frame delivery and frame validity.
// sequenceOnly: verifies frame delivery only — frame validity is not checked.
final UvcPreviewStartResult result = await uvcCamera.startPreview(
  mode,
  policy: UvcPreviewPolicy.stableFrames,
);
if (result.success) {
  await uvcCamera.attachPreviewTexture(
    textureId,
    width: mode.width,
    height: mode.height,
  );
}
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

#### Preview transform

Rotation and flip are applied to the Flutter `Texture` output only.

```dart
// Absolute: set rotation and flip in one call
uvcCamera.setPreviewTransform(
  const UvcPreviewTransform(rotation: 90, flipHorizontal: true),
);

// Incremental helpers
uvcCamera.rotatePreviewClockwise();          // +90° each call
uvcCamera.rotatePreviewCounterClockwise();   // -90° each call
uvcCamera.togglePreviewFlipHorizontal();     // mirror left-right
uvcCamera.togglePreviewFlipVertical();       // mirror top-bottom

// Read current state
final UvcPreviewTransform t = uvcCamera.previewTransform;
```

`rotation` accepts `0`, `90`, `180`, or `270` (clockwise degrees). Values
outside this set are normalised to `0` by the native layer.

For 90° and 270° rotations the output dimensions are swapped. Use
`applyToSize()` to get the correct dimensions for the `AspectRatio` widget:

```dart
final (int w, int h) = uvcCamera.previewTransform.applyToSize(mode.width, mode.height);
AspectRatio(
  aspectRatio: w / h,
  child: Texture(textureId: textureId),
)
```

#### Capture

To get frame bytes in Dart — call `copyLatestFrame()` while preview is running:

```dart
final UvcPreviewFrame? frame = uvcCamera.copyLatestFrame();
if (frame != null) {
  // frame.rgbaBytes: RGBA pixel data (width * height * 4 bytes)
  // frame.width, frame.height: frame dimensions
}
```

To capture with the current preview transform applied:

```dart
final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
  uvcCamera.previewTransform,
);
```

`frame.width` and `frame.height` reflect the post-transform dimensions.

#### Preview state

`uvcCamera.isPreviewing` returns `true` while the native stream callback is
active — that is, after a successful `startPreview()` and before `stopPreview()`
or device close. Use it to guard UI state or skip work when preview is not
running.

#### Frame drop behavior

When the native callback is already processing a frame, incoming callbacks are
dropped rather than queued.

Dropped callbacks are visible at `UvcLogLevel.trace`:

```text
dropping frame callback because previous callback is still processing
```

#### Stream stats

Use `getStreamStats()` to read cumulative native stats for the current preview
session, including input/delivered FPS, decode failures, dropped frames,
inter-frame gap timing, and first-frame latency.

Stats reset when a new `startPreview()` session begins.

#### Streaming error reporting

Frame pipeline errors — decode failures, undersized frames, buffer allocation
failures — are delivered proactively via `streamErrors` rather than being
silently stored in `lastError`.

Subscribe once when the widget is initialised and cancel on dispose:

```dart
StreamSubscription<UvcStreamError>? _streamErrorSub;

@override
void initState() {
  super.initState();
  _streamErrorSub = uvcCamera.streamErrors.listen((UvcStreamError error) {
    // handle error, e.g. show a SnackBar
    print(error.message);
  });
}

@override
void dispose() {
  _streamErrorSub?.cancel();
  super.dispose();
}
```

`streamErrors` is a broadcast stream, so multiple subscribers are allowed.  
Errors are only emitted while a native error listener is active.

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

## Key Classes

Most users will interact with these classes:

- `UvcCamera`
- `UvcStreamError`
- `UvcUsbDevice`
- `UvcCameraMode`
- `UvcPreviewFrame`
- `UvcPreviewStartResult`
- `UvcPreviewPolicy`
- `UvcPreviewTransform`
- `UvcCameraControl`
- `UvcControlId`
- `UvcControlKind`

Useful debugging classes:

- `UvcStreamStats`
- `UvcLogLevel`
- `UvcBmControlInfo`

## RoadMap

For upcoming work areas and current planning direction, see [ROADMAP.md](ROADMAP.md).

## Licensing

This package is licensed under the BSD 3-Clause License. 
Bundled third-party components keep their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependency
license notices, including `libuvc`, `libusb`, and `libjpeg-turbo`.
