## 0.2.0

### Breaking changes

* `startPreview(mode)` now returns `Future<UvcPreviewStartResult>` instead of `int` and verifies frame delivery on startup.
* If you are migrating from 0.1.x and want the previous behaviour, replace `startPreview(mode)` with `openPreview(mode)`.

### Added

* Preview transform: rotation (0/90/180/270°) and flip (horizontal/vertical) applied to the Flutter `Texture` output. `copyLatestFrame()` always returns the original camera orientation unaffected. See `UvcPreviewTransform`, `setPreviewTransform()`, and the convenience helpers `rotatePreviewClockwise()`, `rotatePreviewCounterClockwise()`, `togglePreviewFlipHorizontal()`, `togglePreviewFlipVertical()`.
* Streaming error reporting: frame pipeline errors (decode failures, undersized frames, buffer allocation failures) are now delivered proactively via `UvcCamera.streamErrors` (`Stream<UvcStreamError>`).
* `startPreview(mode, {policy, consecutiveValidFrames, timeout})` — starts the preview stream and verifies frame delivery before returning. `UvcPreviewPolicy.stableFrames` (default) verifies both frame delivery and frame validity; `UvcPreviewPolicy.sequenceOnly` verifies frame delivery only. On success the stream remains running; on failure preview is stopped. Returns `UvcPreviewStartResult`.

### Fixed

* USB permission intent now explicitly sets the package name, improving permission reliability on Android.
* libuvc initialization no longer triggers libusb device discovery

## 0.1.0

### Breaking changes

* USB opening: use `openUsbDevice(deviceId)` instead of managing a file descriptor manually. `openFd(fd)` remains available for advanced use.
* Preview: Flutter `Texture` is now the standard preview path. `copyLatestFrame()` is recommended for capture or frame inspection.

### Added

* USB device management is now handled by the package — `UvcUsbDevice`, `ensureCameraPermission()`, `listUsbDevices()`, `openUsbDevice()`, `closeUsbDevice()`.
* Native preview renders directly into a Flutter `Texture` via `ANativeWindow` — `createPreviewTexture()`, `attachPreviewTexture()`, `disposePreviewTexture()`.
* `uvc_stop_preview` now waits for any in-flight frame callback to finish before returning.

## 0.0.2

* Improve README documentation, including installation, usage, and package boundary clarifications.
* Rename the example USB device class to `AndroidUsbDeviceEntry` to better reflect its role.

## 0.0.1

* Initial public release.
