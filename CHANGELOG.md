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
