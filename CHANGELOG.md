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
