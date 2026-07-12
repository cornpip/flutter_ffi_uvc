# ALL_AGENTS_RULE.md

- Read and follow `SECRET_AGENTS_RULE.md` if it exists.

## Scope

- Treat this repository as an Android-only Flutter FFI package for general UVC camera support.
- Keep the package general-purpose. Do not turn it into a single-device integration.
- Keep the existing USB enumeration and Android permission surface minimal — it exists only to open a UVC camera (list devices, acquire permission, hand a file descriptor to the native layer). Do not grow it into general USB-stack management (hub topology, reconnection policies, vendor-specific USB parsing, per-device permission state machines) unless explicitly requested. Session-lifecycle convenience over the existing surface (e.g. a switch-device helper that reorders stop/close/open) is in scope; new USB infrastructure is not.
- Assume the public Dart API wraps a single shared native camera session unless the architecture is intentionally redesigned.

## Native And Preview Strategy

- Keep `libuvc` as the default native preview path.
- Keep MJPEG decode in the native path unless there is a strong reason to move it.
- Prefer improving the existing native path over adding parallel preview pipelines or Dart-side format-specific workarounds.
- Treat `libuvc` stream transport handling as the source of truth.

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
