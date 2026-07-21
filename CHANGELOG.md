## 0.8.1

- update changelog.md

## 0.8.0

- add Windows support (x64) — the same Dart API runs on Windows through a new
  Media Foundation backend;
  - `openFd`/`closeFd` are Android-only and throw `UnsupportedError` on
    Windows; use `openUsbDevice`/`closeUsbDevice` there
  - on Windows, `supportedModes()` excludes H264 native types
- example: runs on Windows as well

## 0.7.0

- change `openUsbDevice()` to tear down any existing session first, so
  switching cameras is just another `openUsbDevice` call; on failure nothing
  is left open
- remove duplicate modes from `supportedModes()` results
- add value-based equality (`==`/`hashCode`) to `UvcCameraMode`
- fix a crash when a mode returned by `startPreviewAuto()` was used as the
  selected value of a `DropdownButton` built from `supportedModes()`

## 0.6.0

- add `deviceEvents` (`Stream<UvcDeviceEvent>`) — USB attach/detach events for
  UVC-capable devices; Android only
- add `startPreviewAuto()` / `UvcAutoPreviewResult` — tries candidate modes in
  order (MJPEG-first) and keeps the first mode that streams and verifies
  successfully
- add stall detection: `enableStallDetection(UvcStallDetectionConfig)`,
  `disableStallDetection()`, and `stallEvents` (`Stream<UvcStallEvent>`), with
  optional automatic preview restart
- add typed errors: `UvcErrorCode` (mirrors libuvc `uvc_error_t`) and
  `UvcException`; `UvcPreviewStartResult` gains `nativeErrorCode` and an
  `errorCode` getter

## 0.5.0

- rebuild bundled third-party native libraries with 16 KB page alignment

## 0.4.1

- lower the minimum Dart SDK requirement to `^3.8.1`
- lower plugin Android `compileSdk` from 36 to 35 and pin `ndkVersion` to
  `26.3.11579264` to align with Flutter 3.32.x defaults
- example: set `minSdk = 24` explicitly

## 0.4.0

- improve Android isochronous UVC streaming compatibility by limiting large
  ISO transfers and retrying with a smaller size when the initial submit fails
- fix UVC stream transfer selection to use the endpoint descriptor transfer
  type
- fix a libuvc streaming startup path that could report success with no
  submitted transfers
- relax MJPEG pre-validation so decodable frames are not rejected early

## 0.3.2

- add `getStreamStats()` / `UvcStreamStats` — cumulative native preview
  session stats (input/delivered FPS, drops, decode failures, frame gap
  timing, first-frame latency)

## 0.3.1

- docs: standardize the changelog structure and migration notes

## 0.3.0

- add `copyLatestFrameTransformed(UvcPreviewTransform)` — copies the latest
  frame with rotation and flip applied
- add `UvcPreviewTransform.applyToSize(int width, int height)` — returns the
  post-transform dimensions, for use with `AspectRatio`
- example: fix the preview `AspectRatio` not updating for 90°/270° rotation

## 0.2.0

- **BREAKING**: `startPreview(mode)` now returns
  `Future<UvcPreviewStartResult>` instead of `int` and verifies frame delivery
  before returning
  - update code that uses the returned `int` to read `UvcPreviewStartResult`
  - use `openPreview(mode)` for the previous non-verifying startup behaviour
- add preview transform: rotation (0/90/180/270°) and flip applied to the
  `Texture` output; `copyLatestFrame()` keeps the original orientation
  (`UvcPreviewTransform`, `setPreviewTransform()`, and the rotate/flip
  helpers)
- add streaming error reporting via `UvcCamera.streamErrors`
  (`Stream<UvcStreamError>`)
- add `startPreview` verification policies: `UvcPreviewPolicy.stableFrames`
  (default) or `sequenceOnly`
- fix the USB permission intent to explicitly set the package name
- fix libuvc initialization triggering libusb device discovery

## 0.1.0

- change the standard opening path to `openUsbDevice(deviceId)`; `openFd(fd)`
  remains for self-managed file descriptors
  - get the `deviceId` from `listUsbDevices()`
- change the standard preview path to the Flutter `Texture`
- add USB device management — `UvcUsbDevice`, `ensureCameraPermission()`,
  `listUsbDevices()`, `openUsbDevice()`, `closeUsbDevice()`
- add native preview rendering into a Flutter `Texture` —
  `createPreviewTexture()`, `attachPreviewTexture()`,
  `disposePreviewTexture()`
- change `uvc_stop_preview` to wait for in-flight frame callbacks before
  returning

## 0.0.2

- docs: improve the README (installation, usage, package boundaries)
- example: rename the USB device class to `AndroidUsbDeviceEntry`

## 0.0.1

- initial public release
