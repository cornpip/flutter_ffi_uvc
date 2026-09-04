# Roadmap

- Native completion callbacks. Run open and stream start on a per-session
  native worker thread and report completion through the listener, so the
  Dart layer keeps no worker isolates or queue.
- Session release hook. Let `uvc_session_destroy` call a hook the platform
  plugin registers, so the plugin releases its fd, USB connection, and
  texture binding there and the Dart layer keeps no platform finalizer.
- Windows zero-copy preview path. Render NV12/YUY2 to a DXGI shared texture
  instead of the CPU RGBA pixel-buffer path.

## Considered and rejected

- H.264 preview on Linux - other formats cover every resolution.
- Push-based frame stream - pull-only, see `doc/frame-access-design.md`.
- H.264 on Windows - unlocks nothing, see `doc/windows-backend.md`.

Suggestions and device reports are welcome via GitHub issues.
