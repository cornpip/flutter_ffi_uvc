# .agents/rules.md

Read this first. Read other docs only when the task touches that area.

- Follow `SECRET_AGENTS_RULE.md` (repo root) if it exists.
- Repo conventions (commit prefixes, changelog `-wip` flow, engineering rules) are defined in `CONTRIBUTING.md` (repo root); follow it.

## Read-On-Demand

- Public API surface, new features, platform-specific members: read `.agents/docs/scope.md`.
- Native backends, preview pipeline, formats (H264), mode validation: read `.agents/docs/native-strategy.md`.
- `CHANGELOG.md` entry: read `.agents/docs/changelog-style.md`.
- Version bump / release: read `.agents/docs/release-checklist.md`.
- `LICENSE`, `NOTICES`, or a bundled third-party component changed: read `.agents/docs/license-notices.md`.
- Windows backend behavior, H264 rationale: read `doc/windows-backend.md`.
- Frame access API shape: read `doc/frame-access-design.md`.

## Agent-Specific

- Git actions that write history (commit, push, amend, tag, reset) require the user's explicit permission for that specific action, asked in the current exchange. Prior stated intent is not permission.
