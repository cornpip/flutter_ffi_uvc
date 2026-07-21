# ALL_AGENTS_RULE.md

- Read and follow `SECRET_AGENTS_RULE.md` if it exists.

## Scope

- Treat this repository as a Flutter FFI package for general UVC camera support on Android and Windows.
- The public Dart API (`UvcCamera` and its data types) is one platform-neutral surface. Platform differences live in the native backends behind the shared C ABI (`src/include/flutter_ffi_uvc.h`) and the shared MethodChannel contracts; do not fork the Dart API per platform.
- Members that only make sense on one platform (e.g. `openFd`/`closeFd`, `debugBmControls`) stay in the API, documented as platform-specific, and fail with `UnsupportedError` or an empty/`notSupported` result elsewhere.
- Keep the package general-purpose. Do not turn it into a single-device integration.
- Keep the existing USB enumeration and Android permission surface minimal — it exists only to open a UVC camera (list devices, acquire permission, hand a file descriptor to the native layer). Do not grow it into general USB-stack management (hub topology, reconnection policies, vendor-specific USB parsing, per-device permission state machines) unless explicitly requested. Session-lifecycle behavior over the existing surface (e.g. openUsbDevice safely tearing down the previous session before switching devices) is in scope; new USB infrastructure is not.
- Assume the public Dart API wraps a single shared native camera session unless the architecture is intentionally redesigned.

## Native And Preview Strategy

- Android: keep `libuvc` as the default native preview path, and treat `libuvc` stream transport handling as the source of truth there.
- Windows: the native backend is Media Foundation (`windows/uvc_mf_backend.cpp`). Do not introduce libusb/WinUSB paths on Windows — they require replacing the in-box `usbvideo.sys` driver and are out of scope.
- H264 native types are deliberately excluded from the Windows mode list; do not re-add them as preview modes (rationale: `doc/windows-backend.md`).
- Both backends implement the same exported C ABI and emit byte-compatible JSON (modes, controls, stream stats) so the Dart layer stays backend-agnostic. When the ABI or a JSON contract changes, change both backends together.
- Keep MJPEG decode in the native path unless there is a strong reason to move it.
- Prefer improving the existing native paths over adding parallel preview pipelines or Dart-side format-specific workarounds.

## Generated Files

- If native declarations change, regenerate bindings with `dart run ffigen --config ffigen.yaml`.

## Package Design

- Avoid device-specific hardcoding unless it is isolated as a narrowly scoped quirk with clear justification.
- Use descriptor-reported modes as candidate inputs, not as guaranteed-safe preview defaults.

## Validation

- Treat descriptor parsing, stream start, frame delivery, and frame decode as separate validation stages.
- Do not consider a mode healthy unless it streams and produces decodable frames without native instability.
- Do not trust descriptor-reported modes without runtime frame validation.
- If a mode starts but produces invalid, undersized, or non-decodable frames, reject it and move to another candidate instead of trusting descriptors alone.

## Descriptor Parsing

- Be tolerant of UVC descriptor placement differences across Android and libusb environments.
- Prefer existing `libuvc` parsing paths first.
- If fallback parsing is needed, keep it narrowly scoped to parser inputs and descriptor location handling.
- Do not replace the `libuvc` data model with repository-specific parsing unless there is no smaller viable fix.
