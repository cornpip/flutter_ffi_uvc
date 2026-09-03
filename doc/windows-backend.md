# Windows backend notes

The Windows backend (`windows/uvc_mf_backend.cpp`) implements the same native
contract as the Android libuvc backend — same exported C ABI
(`src/include/flutter_ffi_uvc.h`), same JSON shapes for modes / controls / stream
stats, same libuvc-style error codes — on top of the in-box Media Foundation
stack (`usbvideo.sys` + Source Reader). No libusb, no driver replacement:
cameras that work in the Windows Camera app work here.

This document records the Windows-specific behavior and the reasoning behind
the deliberate differences.

## Dependencies

The backend links only Windows SDK import libraries (`mfplat`, `mfreadwrite`,
`ole32`, …) and calls system DLLs that ship with Windows — nothing is
vendored and nothing extra is bundled with the app. Building requires the
Visual Studio "Desktop development with C++" workload (which installs the
Windows SDK); at runtime the Media Foundation DLLs are part of the OS.

One exception: Windows **"N" editions** (EU variants sold without media
features) do not include the Media Foundation DLLs. On those systems the user
must install Microsoft's free
[Media Feature Pack](https://support.microsoft.com/en-us/topic/media-feature-pack-for-windows-10-11-n-31cd4f2a-1e17-28e5-e2c8-7f41a1a0b0f3)
before any camera (or media) functionality works — this affects every Media
Foundation consumer, not just this package. Regular Home/Pro editions are
unaffected.

## Mode enumeration

`supportedModes()` on Windows is built from the camera's native Media
Foundation media types. Two things follow from that:

1. **The list is longer than on Android.** Media Foundation reports every
   format × resolution × frame-rate combination the camera advertises as a
   separate media type. A typical webcam advertising 4 formats, 8 resolutions,
   and 3–5 frame rates produces a list of 100+ modes. This is not the backend
   over-reporting — it is the camera's full capability set, which Android's
   libuvc parser only partially surfaces (libuvc reads uncompressed and MJPEG
   frame descriptors; frame-based NV12/H264 descriptors are typically not
   listed there).
2. **Formats you may see:** `MJPEG`, `YUYV`, `UYVY`, `NV12`, `RGB`, `BGR`,
   `GRAY8`. The `format` integers in `UvcCameraMode` mirror libuvc's
   `uvc_frame_format` values on both platforms, so mode objects round-trip
   identically.
3. **Some listed formats are synthesized by the OS, not the camera.** Since
   Windows 10 1607 camera access goes through the Camera Frame Server, which
   decodes MJPEG/YUY2 once (so multiple apps can share the stream) and
   advertises the converted output — typically `NV12` — as if it were a
   native type. A camera whose USB descriptors only declare MJPEG + YUY2 will
   therefore still show NV12 modes on Windows (verified with USBTreeView's
   Kernel Streaming "Video Modes" dump). Selecting such a mode works fine;
   the USB link still carries the camera's real format and the OS converts
   in between, so bandwidth characteristics follow the underlying format.

Descriptor-reported modes remain *candidates*, not guarantees — the same
validation policy as Android applies (`startPreview` frame verification,
`startPreviewAuto` fallback loop).

## Why H264 is excluded from the preview mode list

Cameras that advertise H264 native types do **not** get H264 entries in
`supportedModes()` on Windows. This is a policy choice, not a Media
Foundation limitation. The trade is one-sided:

- **Cost of listing it**: inter-frame coding breaks the per-frame validation
  model. Nothing renders until a keyframe arrives (colliding with
  `startPreview`'s verification timeout), and a corrupted reference frame
  poisons every following frame until the next keyframe while the decoder
  still reports success.
- **Benefit of listing it**: none. The Camera Frame Server already
  advertises decoded types (NV12 and friends) covering the camera's
  resolutions, so no capability is reachable only through H264.

Android weighs the same trade the other way: there H264 often guards modes
that exist in no other format, so the Android backend decodes it for
preview.

An H264 pass-through recording path (camera stream muxed to MP4 with no
decode or re-encode, preview mutually excluded) was built during 0.11.0
development and deliberately dropped: a Windows-only, preview-excluding API
did not fit the package's surface. If demand appears, the Sink Writer
approach is known viable (same native media type as stream and input type,
gate on `MFSampleExtension_CleanPoint`, rebase timestamps).

## Sessions

Every camera handle is a `uvc_session_t` declared in
`src/include/flutter_ffi_uvc.h`. A session owns its own media source, Source
Reader, RGBA frame buffer, preview state, recorder, listeners, and last-error
text, so two sessions can stream two cameras at the same time without
touching each other. The only process-wide state is Media Foundation
startup, the stable device-id table used by enumeration, and the log level.
The plugin layer binds a session to a Flutter texture through
`attachPreviewTexture`, which takes the session pointer as an integer
`sessionHandle`, and one session drives at most one texture. The
device-enumeration channel calls carry no session.

## Frame pipeline

- The Source Reader is configured with
  `MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING` and an RGB32 output
  type, so Media Foundation performs MJPEG decode and YUV conversion. The
  backend converts BGRX to RGBA into the session's frame buffer that
  `copyLatestFrame*` and the attached Flutter texture read.
- Because decode happens inside Media Foundation, the MJPEG-specific stream
  stats (`invalidMjpegCount`, `warmupDropCount`, `staleFrameCount`,
  `callbackLockDropCount`, `previewSurfaceFailureCount`) are structurally
  always `0` on Windows. Failure surfaces instead through
  `decodeFailureCount` / `conversionFailureCount` / `undersizedFrameCount`
  and `streamErrors`.

## Controls

Standard controls map to `IAMVideoProcAmp` / `IAMCameraControl`:
brightness, contrast, hue, saturation, sharpness, gamma, gain, backlight
compensation, white balance (+auto), exposure (+AE mode), focus (+auto),
iris, zoom, roll, and absolute pan/tilt.

- **Exposure values are converted** between the IAMCameraControl log2-seconds
  scale and UVC's 100 µs units, so `exposureAbs` values mean the same thing
  on Android and Windows.
- Compound relative controls (focus/zoom/pan-tilt/roll relative, digital
  window, region of interest) and `debugBmControls` require raw UVC access
  that Media Foundation does not expose; they return `notSupported` / empty
  results on Windows.

## Device identity and lifecycle

- Windows has no file descriptors. `openUsbDevice(deviceId)` resolves the id
  to a Media Foundation symbolic link; ids are stable for the process
  lifetime and shared by all sessions. `openFd`/`closeFd` are Android-only and **throw
  `UnsupportedError` on Windows** — internally the native open call reuses
  the same entry point with the device id, but that mapping is an
  implementation detail the public fd API deliberately does not expose.
- There is no runtime USB permission. `ensureCameraPermission()` returns
  true; the OS camera privacy toggle ("Let desktop apps access your camera")
  surfaces as an open/stream failure instead.
- `deviceEvents` attach/detach notifications come from `WM_DEVICECHANGE`
  registration on the `KSCATEGORY_VIDEO_CAMERA` interface class.
