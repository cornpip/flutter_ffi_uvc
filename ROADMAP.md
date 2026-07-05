# Roadmap

Planned and completed work areas, ordered by expected impact. Items marked
done landed in the version noted next to them.

## Stability & API robustness

- [x] **USB attach/detach events** (`deviceEvents`) — react when a camera is
  plugged in or unplugged mid-session. (0.6.0)
- [x] **Typed error codes** (`UvcErrorCode`, `UvcException`,
  `UvcPreviewStartResult.errorCode`) — branch on failures instead of parsing
  `lastError` strings. (0.6.0)
- [x] **Stall detection and recovery** (`enableStallDetection`, `stallEvents`,
  optional auto-restart) — detect silent frame delivery stops and recover
  without user interaction. (0.6.0)
- [x] **Automatic mode selection** (`startPreviewAuto`) — try descriptor
  modes in a reliability-ordered sequence and keep the first mode that
  streams and verifies. (0.6.0)

## Features under consideration

- [ ] **Still capture API** — native JPEG encode of the latest frame via the
  bundled libjpeg-turbo (`takePicture()` returning encoded bytes), so apps do
  not have to encode RGBA themselves.
- [ ] **Push-based frame stream** — `Stream<UvcPreviewFrame>` with an FPS cap
  as an alternative to polling `copyLatestFrame()`, for ML inference and
  frame-processing pipelines.
- [ ] **Video recording** — MP4 recording of the preview stream via
  MediaCodec/MediaMuxer.

## Long-term / needs architectural decision

- [ ] **Multiple simultaneous cameras** — requires redesigning the single
  shared native session model.
- [ ] **H.264 UVC format support** — needs a MediaCodec decode path; shares
  infrastructure with video recording.

Suggestions and device reports are welcome via GitHub issues.
