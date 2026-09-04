# Roadmap

- Native device claim. Move the open-device claim into the session registry
  so the `UvcErrorCode.busy` check is decided in one place at request time.
- Listener cleanup on collection. Close the two `NativeCallable`s of an
  instance that is garbage collected without `dispose()`.
- Windows zero-copy preview path. Render NV12/YUY2 to a DXGI shared texture
  instead of the CPU RGBA pixel-buffer path.

## Considered and rejected

- H.264 preview on Linux - other formats cover every resolution.
- Push-based frame stream - pull-only, see `doc/frame-access-design.md`.
- H.264 on Windows - unlocks nothing, see `doc/windows-backend.md`.

Suggestions and device reports are welcome via GitHub issues.
