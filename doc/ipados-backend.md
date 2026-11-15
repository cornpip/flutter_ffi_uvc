# iPadOS backend notes

iPadOS 17 and later let an app use external UVC cameras through AVFoundation,
with device type `AVCaptureDeviceTypeExternal`. There is no separate backend:
`darwin/flutter_ffi_uvc/Sources/flutter_ffi_uvc/uvc_avf_backend.mm` serves
macOS and iPadOS, and the platform differences are `TARGET_OS_*` blocks inside
it. This document records where iPadOS behaves differently and why.

The exported C ABI in `src/include/flutter_ffi_uvc.h` is identical on both
platforms, and it stays unchanged. A feature iPadOS does not have is reported
through a return value (`UVC_ERROR_NOT_SUPPORTED`, `UVC_ERROR_BUSY`) or an
empty list, never through a different signature, an extra parameter, or a new
function.

## Why AVFoundation

The same reason as macOS: the system UVC driver owns the video interfaces and
an app cannot take them over through libusb. On iOS that is not even a choice,
because there is no IOKit and no way to claim an interface.

## Deployment target

- The podspec and `Package.swift` pin iOS 13.0, below the deployment targets
  Flutter generates, so adding the package never raises an app's target.
  Everything iPadOS 17 provides sits behind `@available`, so the backend
  compiles at 13.0 instead of leaning on the app's target.
- On an iPhone, or an iPad below 17.0, the plugin loads and
  `listUsbDevices()` returns an empty list. Nothing asks for camera access and
  the built-in cameras are not touched. The external device type is only added
  to the discovery session when the API exists, because passing a device type
  the system does not know raises `NSInvalidArgumentException`.

## Device identity

- Only devices of type external are listed. macOS also lists the built-in
  camera, as Windows does; iPadOS does not, because a built-in camera is not
  what this package is for and it would arrive with no controls and a
  different rotation model.
- `AVCaptureDevice` has no `modelID` on iOS (macOS parses
  `VendorID_x ProductID_y` out of it) and no `transportType` (so the USB
  transport filter macOS applies does not exist here).
- The `uniqueID` layout is not documented on iOS, so an external camera
  reports `vendorId` and `productId` as 0. The integer `deviceId` is still
  keyed by `uniqueID`, so it is stable for the process lifetime and shared by
  every session, exactly as on macOS.
- Zero ids are not what makes controls unavailable. macOS also lists a camera
  with no ids and streams it fine. The missing piece on iPadOS is IOKit.

## Modes

iPadOS converts formats before an app sees them: `yuvs` and `2vuy` become
`420v`, streaming JPEG and H.264 become `420f`. Every listed mode is therefore
NV12, whatever the camera sends on the wire, and the resolution and frame rate
remain the camera's own.

Two consequences follow from the existing code rather than from a decision:

- The H.264 exclusion macOS documents in `doc/macos-backend.md` is moot here,
  because H.264 never reaches the format list.
- `startPreviewAuto()` orders candidates MJPEG-first. With only NV12
  candidates that ordering does nothing, and the resolution and frame rate
  preference decides.

## Frame pipeline

The capture output asks for BGRA, AVFoundation decodes and converts, the frame
becomes RGBA for `copyLatestFrame*`, and the capture buffer backs the Flutter
texture. None of that differs from macOS.

One thing does: before `startRunning`, the connection is pinned to
`videoRotationAngle = 0`. Some iPad generations deliver pre-rotated buffers
(the SDK documents a 180 degree default for front-camera video data on the
Spring 2024 iPads), and the frame pipeline and the reported frame dimensions
both assume sensor orientation. Pinning the angle keeps the invariant that
`mode.width` and `mode.height` are the buffer's dimensions.

Rotation stays a manual API through `setPreviewTransform()`. An external
camera moves independently of the iPad, so no automatic angle is correct for
every use, and the package already exposes rotation and flips.

## One stream at a time

iPadOS runs one `AVCaptureSession` at a time. Starting a second one stops the
first, so a preview start claims a process-wide slot and a second start fails
with `UVC_ERROR_BUSY` instead of silently killing the stream that is running.

- The slot lives in the session registry, next to the ids and pins, and is
  released by `StopPreviewLocked` on every teardown path and by
  `uvc_session_finalize` when it retires an entry.
- `UVC_ERROR_BUSY` is the code an open of a claimed device already returns, so
  a caller handles it the same way.
- `UVC_ERROR_NOT_SUPPORTED` would be the wrong report here: the backend can
  stream, the resource is simply taken by another session.
- Several cameras at once would need `AVCaptureMultiCamSession`, which changes
  the session model and adds per-format eligibility rules.

## Lost streams and interruptions

A stream can end without the app calling `stopPreview()`, and the slot has to
follow the stream rather than the call.

- Device unplugged: the disconnect observer reports
  `Video capture device disconnected` through `streamErrors` and releases the
  slot. A second instance can then start a preview even if the first one was
  never stopped, which would otherwise fail with `UVC_ERROR_BUSY` while
  nothing streams.
- Runtime error: reported through `streamErrors`, and the slot is released for
  the same reason.
- Interruption: `AVCaptureSessionWasInterruptedNotification` is reported
  through `streamErrors` with the reason on iPadOS. Apple documents
  interruptions as the consequence of backgrounding or of another client
  taking the hardware, and the session resumes on its own when the
  interruption ends. The slot stays claimed across an interruption for that
  reason.

Releasing the slot does not clear the session's own state: `capture` is still
set and `uvc_is_previewing()` still reports 1 until the app calls
`stopPreview()` or closes the device. A later start on the same session stops
the dead capture session first, as it does for any start.

### Measured on hardware

On an iPad Pro 12.9-inch (5th generation) with iPadOS 26:

- Unplugging while a camera streamed reported `Video capture device
  disconnected`, and the device closed. After replugging, a second instance
  opened the same camera and streamed. The example closes a detached device
  through `deviceEvents` as well, so this run does not separate the native
  release from that path; it shows the sequence works end to end.
- Backgrounding the app stopped frame delivery, and no interruption
  notification reached it. The notification is probably posted while the app
  is suspended, so the handler never runs, or the platform does not post it
  for an external camera. The stall watchdog is what noticed: after its
  timeout it restarted the preview on its own and reported recovery. An app
  with stall detection enabled recovers from backgrounding without handling
  interruptions.

## Controls

There is no IOKit, so the UVC class requests every control is made of cannot be
sent. `uvc_usb_controls.cpp` compiles to a stub on iOS: `Open` always fails
with a message saying why, and `Request` returns `UVC_ERROR_NOT_SUPPORTED`.
The header and the class shape are unchanged, so the backend keeps one code
path and a session streams with an empty control list.

What a caller sees:

- `supportedControls()` and `debugBmControls()` return an empty list.
- `getControl()` returns `null` for a control that is not there, the same as
  for any unsupported control on the other platforms.
- `setControl()` fails with `UVC_ERROR_NOT_SUPPORTED` and a message naming
  iPadOS.

AVFoundation does expose zoom, and exposure and focus on some cameras. Those
are not raw UVC values, and the control table on every other platform is raw
UVC values. Mapping them in would change what the JSON means, so it would need
its own API surface and is out of scope here.

## Recording

`AVAssetWriter` with an H.264 input, the same as macOS. The path has to be
writable by the app, which on iPadOS means inside the app container, for
example its Documents directory.

## Permissions and packaging

- `NSCameraUsageDescription` in `Info.plist`. No entitlement is needed, unlike
  the `com.apple.security.device.usb` entitlement macOS asks for, because no
  USB device is opened.
- Plugins are linked into the app binary on iOS, so Dart uses
  `DynamicLibrary.process()` instead of opening a framework.
- An archived build needs `STRIP_STYLE = non-global` in
  `ios/Flutter/Release.xcconfig`, the same trap the README documents for
  macOS. Measured on the example: an archive keeps 73 exported `uvc_` symbols
  with the setting and 0 without it.

## File descriptors

There are none. `uvc_open_fd` receives the enumeration device id, as on Windows
and macOS, and nothing has to be released after it. `openFd` and `closeFd`
stay Android-only in Dart, which throws `UnsupportedError` there; that guard
is in the Dart layer and does not touch the ABI.

## Not verified on hardware yet

The build, the symbols in both packaging modes, and the compile at iOS 13.0
are verified. Three behaviors are still assumptions taken from Apple's
documentation and the WWDC23 session on external cameras: the NV12-only mode
list, the identity of a `deviceId` across an unplug and replug, and the default
orientation of delivered buffers. Each is checked by hand on an iPad Pro and
the results belong here once they are in.
