# Native And Preview Strategy

- Android: keep `libuvc` as the default native preview path, and treat `libuvc` stream transport handling as the source of truth there. Prefer libuvc's existing descriptor parsing; any fallback parsing stays narrowly scoped (parser inputs, descriptor placement) and never replaces the libuvc data model.
- Windows: the native backend is Media Foundation (`windows/uvc_mf_backend.cpp`). Do not introduce libusb/WinUSB paths on Windows; they require replacing the in-box `usbvideo.sys` driver and are out of scope.
- Linux: reuses the Android backend (`src/backend_libuvc/flutter_ffi_uvc.c` + bundled libuvc) compiled into the plugin `.so` (`linux/`). Enumeration is sysfs, opening is an `open(2)` fd through the same `uvc_wrap` path as Android. libusb and libjpeg-turbo sources are vendored (`third_party/libusb`, `third_party/libjpeg-turbo-src`): libjpeg-turbo links static, libusb stays a separate shared `libusb1.0.so` because it is LGPL and must remain replaceable. No H.264 modes on Linux (out of scope, see `ROADMAP.md`) and no recording (undecided).
- H264: keep it out of the Windows mode list, never let `startPreviewAuto` select it, and do not re-add the removed Windows pass-through recording path unless explicitly requested (rationale: `doc/windows-backend.md`).
- All backends implement the same exported C ABI and emit byte-compatible JSON (modes, controls, stream stats) so the Dart layer stays backend-agnostic. When the ABI or a JSON contract changes, change the libuvc backend (Android/Linux) and the Windows backend together.
- Keep MJPEG decode in the native path unless there is a strong reason to move it.
- Frame access from Dart is pull-only (`copyLatestFrame()`). Do not add a push-based frame stream (rationale: `doc/frame-access-design.md`).
- Prefer improving the existing native paths over adding parallel preview pipelines or Dart-side format-specific workarounds.
- Replacing a bundled Android third-party `.so` means rebuilding it with 16 KB page alignment (required by Android 15); the plugin's own library gets that from `-Wl,-z,max-page-size=16384` in `src/CMakeLists.txt`, the prebuilts only from how they were built.

## Validation

- Treat descriptor parsing, stream start, frame delivery, and frame decode as separate validation stages.
- Descriptor-reported modes are candidates, not guaranteed-safe defaults. A mode is healthy only if it streams and delivers decodable frames without native instability; otherwise reject it and move to the next candidate.
