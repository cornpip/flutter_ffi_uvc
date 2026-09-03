# Roadmap

- Windows zero-copy preview path. Render NV12/YUY2 to a DXGI shared texture
  instead of the CPU RGBA pixel-buffer path.

## Considered and rejected

- H.264 preview on Linux - other formats cover every resolution.
- Push-based frame stream - pull-only, see `doc/frame-access-design.md`.
- H.264 on Windows - unlocks nothing, see `doc/windows-backend.md`.

Suggestions and device reports are welcome via GitHub issues.
