# AGENTS.md

Read this first. Read other docs only when the task touches that area.

Repo conventions (commit prefixes, changelog `-wip` flow, issues and
milestones, prose style, engineering rules) are defined in
`CONTRIBUTING.md`. Follow it.

## Read-On-Demand

- Public API surface, new features, platform-specific members: read
  `doc/scope.md`.
- Native backends, preview pipeline, formats (H264), mode validation: read
  `doc/native-strategy.md`.
- Version bump / release: read `doc/release-checklist.md`.
- `LICENSE`, `NOTICES`, or a bundled third-party component changed: read
  `doc/license-notices.md`.
- Windows backend behavior, H264 rationale: read `doc/windows-backend.md`.
- macOS backend behavior, build layout, entitlements: read
  `doc/macos-backend.md`.
- Frame access API shape: read `doc/frame-access-design.md`.

## Agent-Specific

- Git actions that write history (commit, push, amend, tag, reset) require
  the user's explicit permission for that specific action, asked in the
  current exchange. Prior stated intent is not permission.
- Do not add AI attribution (a "Generated with ..." line or a
  `Co-Authored-By` AI trailer) to commit messages or PR descriptions.
- When one of these docs disagrees with the code (a renamed file, a
  removed API), follow the code and fix the doc in the same change.
