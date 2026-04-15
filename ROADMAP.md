# Roadmap

## Streaming error reporting

Add a dedicated native error listener so that errors occurring during frame
callback processing (decode failures, buffer issues, etc.) are proactively
reported to the Dart side instead of being silently stored in `last_error`.

Planned approach:

- Add `uvc_error_listener_t` callback type and `uvc_set_error_listener()` to the
  native layer, called from within `frame_callback` on error conditions
- Expose a `Stream<UvcStreamError>` (or similar) on `UvcCamera` in Dart so
  callers can subscribe to runtime errors without polling `lastError`
