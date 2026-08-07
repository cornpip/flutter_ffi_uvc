# ALL_AGENTS_RULE.md

- Read and follow `SECRET_AGENTS_RULE.md` if it exists.

## Scope

- Treat this repository as a Flutter FFI package for general UVC camera support on Android and Windows.
- The public Dart API (`UvcCamera` and its data types) is one platform-neutral surface. Platform differences live in the native backends behind the shared C ABI (`src/include/flutter_ffi_uvc.h`) and the shared MethodChannel contracts; do not fork the Dart API per platform.
- Members that only make sense on one platform (e.g. `openFd`/`closeFd`, `debugBmControls`) stay in the API, documented as platform-specific, and fail with `UnsupportedError` or an empty/`notSupported` result elsewhere.
- Keep the package general-purpose. Do not turn it into a single-device integration; device-specific behavior is allowed only as a narrowly scoped quirk with clear justification.
- Keep the existing USB enumeration and Android permission surface minimal — it exists only to open a UVC camera (list devices, acquire permission, hand a file descriptor to the native layer). Do not grow it into general USB-stack management (hub topology, reconnection policies, vendor-specific USB parsing, per-device permission state machines) unless explicitly requested. Session-lifecycle behavior over the existing surface (e.g. openUsbDevice safely tearing down the previous session before switching devices) is in scope; new USB infrastructure is not.
- Assume the public Dart API wraps a single shared native camera session unless the architecture is intentionally redesigned.

## Native And Preview Strategy

- Android: keep `libuvc` as the default native preview path, and treat `libuvc` stream transport handling as the source of truth there. Prefer libuvc's existing descriptor parsing; any fallback parsing stays narrowly scoped (parser inputs, descriptor placement) and never replaces the libuvc data model.
- Windows: the native backend is Media Foundation (`windows/uvc_mf_backend.cpp`). Do not introduce libusb/WinUSB paths on Windows — they require replacing the in-box `usbvideo.sys` driver and are out of scope.
- H264 native types are deliberately excluded from the Windows mode list; do not re-add them as preview modes (rationale: `doc/windows-backend.md`).
- Both backends implement the same exported C ABI and emit byte-compatible JSON (modes, controls, stream stats) so the Dart layer stays backend-agnostic. When the ABI or a JSON contract changes, change both backends together.
- Keep MJPEG decode in the native path unless there is a strong reason to move it.
- Frame access from Dart is pull-only (`copyLatestFrame()`). Do not add a push-based frame stream (rationale: `doc/frame-access-design.md`).
- Prefer improving the existing native paths over adding parallel preview pipelines or Dart-side format-specific workarounds.

## Validation

- Treat descriptor parsing, stream start, frame delivery, and frame decode as separate validation stages.
- Descriptor-reported modes are candidates, not guaranteed-safe defaults. A mode is healthy only if it streams and delivers decodable frames without native instability; otherwise reject it and move to the next candidate.

## Conventions

- Follow `doc/changelog-style.md` for all `CHANGELOG.md` entries: flat verb-first bullets, no Added/Changed/Fixed headings, `**BREAKING**:` only when user code must change.
- Follow `doc/commit-style.md` for commit messages: capitalized imperative verb first, no type prefixes, version suffix `(0.x.y)` on release commits.
- If native declarations change, regenerate bindings with `dart run ffigen --config ffigen.yaml`.
