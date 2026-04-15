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

## Preview transform controls

Add explicit preview transform controls so apps can flip the live preview or
rotate it in 90-degree steps without changing the underlying camera session.

Planned approach:

- Add shared preview transform state in the native preview path for quarter-turn
  rotation plus horizontal and vertical flip flags
- Apply the transform during native preview rendering to the attached Flutter
  `Texture`, including width/height swapping for 90-degree and 270-degree output
- Keep the decoded preview source buffer in its original orientation and apply
  transforms only in the native blit/output step so live preview controls do
  not implicitly redefine the shared frame buffer contents
- Expose Dart APIs for both absolute and incremental updates, such as
  `setPreviewTransform(...)`, `rotatePreviewClockwise()`, and
  `togglePreviewFlipHorizontal()`
- Keep `copyLatestFrame()` semantics stable by defaulting to the untransformed
  RGBA buffer unless transformed frame export is explicitly added as a separate
  API later
