## 1.0.0

- **BREAKING** `stopPreview()`, `closeFd()`, `openFd()`, and `openPreview()`
  return a `Future`. Lifecycle calls on one instance run one at a time in
  call order. `stopPreview()`, `closeUsbDevice()`, and `dispose()` interrupt
  a `startPreview()` in progress, which reports `UvcErrorCode.interrupted`
- **BREAKING** calls that can fail throw `UvcException` instead of returning
  an int code: `openUsbDevice()`, `openFd()`, `openPreview()`,
  `startVideoRecording()`, `stopVideoRecording()`, `setControl()`, and the
  compound control setters
- **BREAKING** remove `closeDevice()`, deprecated since 0.1.0. Use
  `closeFd()`
- add multiple simultaneous cameras: `UvcCamera()` creates an independent
  instance and `dispose()` releases it. `uvcCamera` stays the shared default
  - `deviceEvents` is shared by all instances
  - `openUsbDevice()` fails with `UvcErrorCode.busy` for a device another
    instance already holds open
  - an undisposed instance that is garbage collected or lost to a hot
    restart releases its camera and platform connection
- add `openedDeviceId`
- improve the lifecycle calls to do their native work off the UI thread:
  `openUsbDevice()`, `openFd()`, `openPreview()`, `startPreview()`,
  `startPreviewAuto()`, `stopPreview()`, `closeFd()`, `closeUsbDevice()`,
  and `dispose()`
- change detach handling: an instance whose device is unplugged closes the
  device itself, after the `deviceEvents` event is delivered
- change `lastError` on Windows to clear once frames are delivered again,
  matching Android and Linux
- fix `ensureCameraPermission()` never completing for a second concurrent
  caller on Android
- fix an `openUsbDevice()` waiting on the Android USB permission dialog never
  completing when the activity is recreated meanwhile
- fix a freeze when a stream error arrived while the camera was being
  closed or released
- fix Windows detach events not matching the opened device
- fix Windows detach events carrying the device path instead of its name
- fix mode switching on Windows failing with `MF_E_INVALIDREQUEST`
- example: add camera slots for previewing several cameras at once

## 0.12.1

- fix the Kotlin Gradle Plugin warning Flutter reports for this package when
  the app builds with AGP 9 or later
- example: upgrade to Gradle 9.3.1, AGP 9.1.0, and Kotlin 2.4.0

## 0.12.0

- add Linux support (x64): the same Dart API runs on Linux desktop through
  the bundled libuvc backend
  - libusb and libjpeg-turbo are bundled and built with the plugin, so no
    system libraries are needed; `nasm` is optional (x86_64 SIMD, faster
    MJPEG decode)
  - the app needs read-write access to the camera's `/dev/bus/usb` node,
    which usually means a udev rule
  - `deviceEvents` reports attach/detach on Linux as well (previously
    Android and Windows only)
  - H.264 modes are not listed and `startVideoRecording()` is not yet
    available on Linux; `openFd`/`closeFd` stay Android-only
- add a `NOTICES` file so `showLicensePage()` in a consuming app lists the
  bundled `libuvc`, `libusb`, and `libjpeg-turbo` notices, not just this
  package's BSD-3 license

## 0.11.0

- add H.264 UVC format support (Android)
  - H.264 modes now appear in `supportedModes()` and preview with
    `startPreview()` like any other format; decoding is hardware
    (MediaCodec, NEON conversion on arm64) and the texture,
    `copyLatestFrame()`, `takePicture()`, and `startVideoRecording()` all
    work unchanged
  - frames before the stream's first keyframe are dropped and counted as
    warmup; under load the display frame rate adapts while decoding keeps
    up, and on UVC 1.5 cameras with an Encoding Unit the package requests
    sync frames to recover quickly from transport corruption
  - `startPreviewAuto()` never auto-selects an H.264 mode; opt in with an
    explicit `startPreview()`
  - Windows keeps H.264 excluded from the preview mode list (rationale in
    `doc/windows-backend.md`)
- change the Android native build to always compile optimized
  (RelWithDebInfo); debug app builds previously ran the frame pipeline at
  -O0

## 0.10.0

- add `startVideoRecording()` / `stopVideoRecording()` / `isRecording` — MP4
  (H.264) video recording of the preview stream, encoded natively while the
  live preview keeps running; Android via MediaCodec/MediaMuxer, Windows via
  the Media Foundation Sink Writer
  - requires an active preview; finalizes automatically when the preview
    stops, the mode changes, or the device closes
  - applies `previewTransform` by default, captured once at start; accepts an
    explicit `transform` and a `bitrateBps` (default derived from resolution
    and frame rate)
  - video only — camera microphones are separate USB audio devices and are
    not recorded
- example: record button saves MP4 to the gallery on Android and the Pictures
  folder on Windows

## 0.9.0

- add `takePicture()` — native JPEG encode of the latest preview frame,
  returned as a `UvcStillPicture` with ready-to-save `jpegBytes`; use it to
  save picture files, and keep using `copyLatestFrame()` for raw-RGBA pixel access
  - applies `previewTransform` by default; accepts an explicit `transform`
    and a `quality` (1-100, default 90)
  - Android encodes via the bundled libjpeg-turbo; Windows via the OS WIC
    JPEG encoder
- example: capture saves JPEG via `takePicture()` by default, with a
  lossless-PNG toggle that demonstrates Dart-side encoding of RGBA from
  `copyLatestFrameTransformed()`

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
