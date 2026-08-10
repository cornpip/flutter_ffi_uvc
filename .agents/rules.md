# .agents/rules.md

Read this first. Read other docs only when the task touches that area.

- Follow `SECRET_AGENTS_RULE.md` (repo root) if it exists.

## Read-On-Demand

- Public API surface, new features, platform-specific members: read `.agents/docs/scope.md`.
- Native backends, preview pipeline, formats (H264), mode validation: read `.agents/docs/native-strategy.md`.
- `CHANGELOG.md` entry: read `.agents/docs/changelog-style.md`.
- Windows backend behavior, H264 rationale: read `doc/windows-backend.md`.
- Frame access API shape: read `doc/frame-access-design.md`.

## Always Apply

- Published production package: never break the public API or change default behavior without an explicit request.
- Native declarations changed: regenerate bindings with `dart run ffigen --config ffigen.yaml`.
- Release commit subjects end with the version in parentheses: `Add takePicture(): native JPEG still capture (0.10.0)`.
