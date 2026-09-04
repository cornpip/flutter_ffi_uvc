# Roadmap

- 1.0 API cleanup. Make the lifecycle API async throughout so every call
  queues instead of being refused or cancelled, and return `UvcErrorCode`
  instead of raw ints.
- Native completion callbacks. Run open and stream start on a per-session
  native worker thread and report completion through the listener, so the
  Dart layer keeps no worker isolates or queue.
- Windows zero-copy preview path. Render NV12/YUY2 to a DXGI shared texture
  instead of the CPU RGBA pixel-buffer path.

## Considered and rejected

- H.264 preview on Linux - other formats cover every resolution.
- Push-based frame stream - pull-only, see `doc/frame-access-design.md`.
- H.264 on Windows - unlocks nothing, see `doc/windows-backend.md`.

Suggestions and device reports are welcome via GitHub issues.
