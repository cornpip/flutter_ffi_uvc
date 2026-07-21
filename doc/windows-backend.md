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

## Why H264 is excluded

Cameras that advertise H264 native types do **not** get H264 entries in
`supportedModes()` on Windows. This is intentional, not a limitation of Media
Foundation (which could decode it). The reasons:

1. **Inter-frame coding breaks the per-frame validation model.** This
   package's core guarantees — "N consecutive decodable frames means the mode
   is healthy", "a bad frame is dropped in isolation" — assume every frame is
   independently decodable, which holds for MJPEG and uncompressed formats.
   H264 frames reference each other across a GOP:
   - Stream start cannot produce an image until a keyframe arrives, which can
     take seconds and collides with `startPreview`'s verification timeout.
   - A corrupted reference frame poisons every following frame until the next
     keyframe while the decoder keeps reporting *success* — the package's
     "decode success == valid frame" signal becomes meaningless.
   - Stall auto-recovery gets slower: every restart rebuilds decoder state and
     waits for a keyframe again.
2. **No Android counterpart.** The Android backend (libuvc + libjpeg-turbo)
   has no H264 decode path. Listing H264 only on Windows would make the same
   app see different mode sets per platform, against the one-API design.
3. **Fragmented exposure across devices.** UVC H264 ships in several
   incompatible flavors (UVC 1.5 frame-based, UVC 1.1 vendor extensions,
   H264-muxed-in-MJPEG). How `usbvideo.sys` surfaces each varies by device,
   making "listed but never streams" modes likely.
4. **No preview benefit.** H264 trades decode latency and pipeline complexity
   for USB bandwidth, which MJPEG already handles for local preview. H264
   makes sense for recording/streaming pipelines, which are out of scope for
   this package's preview model.

If a recording feature ever lands on the roadmap, H264 should return as a
separate pass-through path (no decode), not as a preview mode.

## Frame pipeline

- The Source Reader is configured with
  `MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING` and an RGB32 output
  type, so Media Foundation performs MJPEG decode and YUV conversion. The
  backend converts BGRX → RGBA into the shared frame buffer that
  `copyLatestFrame*` and the Flutter texture read.
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
  lifetime. `openFd`/`closeFd` are Android-only and **throw
  `UnsupportedError` on Windows** — internally the native open call reuses
  the same entry point with the device id, but that mapping is an
  implementation detail the public fd API deliberately does not expose.
- There is no runtime USB permission. `ensureCameraPermission()` returns
  true; the OS camera privacy toggle ("Let desktop apps access your camera")
  surfaces as an open/stream failure instead.
- `deviceEvents` attach/detach notifications come from `WM_DEVICECHANGE`
  registration on the `KSCATEGORY_VIDEO_CAMERA` interface class.
