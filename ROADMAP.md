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

- [ ] **Still capture API** — native JPEG encode of the latest frame
  (`takePicture()` returning encoded bytes), so apps do not have to encode
  RGBA themselves. Android via the bundled libjpeg-turbo; Windows via the OS
  imaging stack (WIC or the Media Foundation JPEG encoder).
- [ ] **Push-based frame stream** — `Stream<UvcPreviewFrame>` with an FPS cap
  as an alternative to polling `copyLatestFrame()`, for ML inference and
  frame-processing pipelines.
- [ ] **Video recording** — MP4 recording of the preview stream. Android via
  MediaCodec/MediaMuxer; Windows via the Media Foundation Sink Writer.

## Long-term / needs architectural decision

- [ ] **Multiple simultaneous cameras** — requires redesigning the single
  shared native session model.
- [ ] **H.264 UVC format support** — needs a MediaCodec decode path on
  Android and a pass-through (no-decode) design on Windows, where H264 native
  types are deliberately excluded from the preview mode list (see
  `doc/windows-backend.md`); shares infrastructure with video recording.
- [ ] **Windows zero-copy preview path** — render NV12/YUY2 straight to a
  DXGI shared texture (`GpuSurfaceTexture` + D3D11) instead of the current
  CPU RGBA pixel-buffer path. Only worth doing if profiling shows CPU cost at
  high resolutions, or together with video recording (hardware encoders
  consume NV12 directly); `copyLatestFrame()` keeps requiring an RGBA
  readback path either way.

Suggestions and device reports are welcome via GitHub issues.
