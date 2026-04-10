## 0.0.1

* Initial public release.
* Added Android Flutter FFI plugin support for UVC cameras using vendored
  `libuvc`.
* Added shared `uvcCamera` API for opening a device from a platform-provided
  file descriptor, reading supported modes, starting and stopping preview, and
  copying the latest RGBA preview frame.
* Added UVC control read/write support through `UvcCameraControl`,
  `getControl(...)`, and `setControl(...)`.
* Exposed typed public control identifiers through `UvcControlId` and
  `UvcControlKind` so apps do not need raw integer control IDs.
* Expanded single-value CT/PU control coverage to a broader set of standard
  `libuvc` selectors.
* Added typed APIs for compound controls such as white balance components,
  pan/tilt, zoom relative, roll relative, digital window, and region of
  interest.
* Added example app showing Android permission handling, USB device open flow,
  preview rendering, and camera control usage.
* Added bundled third-party license notices for vendored native dependencies.
