## 0.7.0

### Changed

* `openUsbDevice()` now safely tears down any existing session first — stopping a running preview and closing the previous device — so switching cameras is just another `openUsbDevice` call, with no manual `closeUsbDevice` needed in between. On any failure nothing is left open: a partially opened device is closed before the error is reported.
* `supportedModes()` no longer returns duplicate modes. A device can report the same format/resolution/fps combination more than once (e.g. two frame intervals rounding to the same integer fps); the returned list now contains each mode only once.

### Added

* `UvcCameraMode` now implements value-based equality (`==`/`hashCode`) over format, resolution, and fps.

### Fixed

* Fixed a crash when a mode returned by `startPreviewAuto()` was used as the selected value of a `DropdownButton` built from `supportedModes()` — the same mode from the two calls did not compare equal.

## 0.6.0

### Added

* `deviceEvents` (`Stream<UvcDeviceEvent>`) — USB attach/detach events for UVC-capable devices, so apps can react when a camera is plugged in or unplugged mid-session. Android only.
* `startPreviewAuto()` / `UvcAutoPreviewResult` — tries candidate modes in order (MJPEG-first, resolution/fps descending by default) and keeps the first mode that streams and verifies successfully. Per-mode verification results are returned in `UvcAutoPreviewResult.attempts`.
* Stall detection: `enableStallDetection(UvcStallDetectionConfig)`, `disableStallDetection()`, and `stallEvents` (`Stream<UvcStallEvent>`). Detects when frame delivery stops while previewing and can optionally stop and restart the preview automatically with the most recent `startPreview` parameters.
* Typed errors: `UvcErrorCode` (mirrors libuvc `uvc_error_t`) and `UvcException`. `UvcPreviewStartResult` gains `nativeErrorCode` and an `errorCode` getter for stream startup failures.

## 0.5.0

### Fixed

* Rebuilt bundled third-party native libraries with 16 KB page alignment.

## 0.4.1

### Changed

* Lowered minimum Dart SDK requirement to `^3.8.1`.
* Lowered plugin Android `compileSdk` from 36 to 35 and pinned `ndkVersion` to `26.3.11579264` to align with Flutter 3.32.x defaults.
* Example app: set `minSdk = 24` explicitly to satisfy the plugin's minimum Android API requirement.

## 0.4.0

### Fixed

* Improved Android isochronous UVC streaming compatibility by limiting large ISO transfers and retrying with a smaller transfer size when initial submit fails.
* Fixed UVC stream transfer selection to use the endpoint descriptor transfer type instead of assuming interfaces with multiple altsettings are always isochronous.
* Fixed a libuvc streaming startup path that could report success even when no USB transfers were submitted.
* Relaxed MJPEG pre-validation so decodable frames are not rejected before libjpeg-turbo can process them.

## 0.3.2

### Added

* `getStreamStats()` / `UvcStreamStats` — exposes cumulative native preview session stats such as input and delivered FPS, drop counts, decode failures, frame gap timing, and first-frame latency.

## 0.3.1

### Changed

* Standardized the changelog structure and migration notes.

## 0.3.0

### Added

* `copyLatestFrameTransformed(UvcPreviewTransform)` — copies the latest frame with rotation and flip applied to the pixel data.
* `UvcPreviewTransform.applyToSize(int width, int height)` — returns the width and height after applying the transform, for use with `AspectRatio` when displaying the preview `Texture`.

### Fixed

* Example: `AspectRatio` for the preview `Texture` was not updated when rotation was 90° or 270°.

## 0.2.0

### Breaking changes

* `startPreview(mode)` now returns `Future<UvcPreviewStartResult>` instead of `int` and verifies frame delivery on startup before returning.

### Migration notes

* Update code that uses the `int` returned by `startPreview(mode)` to use `UvcPreviewStartResult` instead.
* Use `openPreview(mode)` instead of `startPreview(mode)` if you want the previous non-verifying startup behaviour.

### Added

* Preview transform: rotation (0/90/180/270°) and flip (horizontal/vertical) applied to the Flutter `Texture` output. `copyLatestFrame()` always returns the original camera orientation unaffected. See `UvcPreviewTransform`, `setPreviewTransform()`, and the convenience helpers `rotatePreviewClockwise()`, `rotatePreviewCounterClockwise()`, `togglePreviewFlipHorizontal()`, `togglePreviewFlipVertical()`.
* Streaming error reporting: frame pipeline errors (decode failures, undersized frames, buffer allocation failures) are now delivered proactively via `UvcCamera.streamErrors` (`Stream<UvcStreamError>`).
* `startPreview(mode, {policy, consecutiveValidFrames, timeout})` — starts the preview stream and verifies frame delivery before returning. `UvcPreviewPolicy.stableFrames` (default) verifies both frame delivery and frame validity; `UvcPreviewPolicy.sequenceOnly` verifies frame delivery only. On success the stream remains running; on failure preview is stopped. Returns `UvcPreviewStartResult`.

### Fixed

* USB permission intent now explicitly sets the package name, improving permission reliability on Android.
* libuvc initialization no longer triggers libusb device discovery

## 0.1.0

### Changed

* `openUsbDevice(deviceId)` is now the standard USB opening path.
* `openFd(fd)` remains available if you need to manage the USB file descriptor yourself.
* Flutter `Texture` is now the standard preview path.
* `copyLatestFrame()` is recommended for capture or frame inspection.

### Migration notes

* Use `openUsbDevice(deviceId)` instead of `openFd(fd)`. Get the `deviceId` from `listUsbDevices()`.

### Added

* USB device management is now handled by the package — `UvcUsbDevice`, `ensureCameraPermission()`, `listUsbDevices()`, `openUsbDevice()`, `closeUsbDevice()`.
* Native preview renders directly into a Flutter `Texture` via `ANativeWindow` — `createPreviewTexture()`, `attachPreviewTexture()`, `disposePreviewTexture()`.
* `uvc_stop_preview` now waits for any in-flight frame callback to finish before returning.

## 0.0.2

* Improve README documentation, including installation, usage, and package boundary clarifications.
* Rename the example USB device class to `AndroidUsbDeviceEntry` to better reflect its role.

## 0.0.1

* Initial public release.
