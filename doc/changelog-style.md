# Changelog style

Rules for `CHANGELOG.md` entries. The goal is a flat, scannable list where
each bullet carries its own classification, instead of Added/Changed/Fixed
section headings that invite misfiling.

## Structure

- One `## <version>` section per release, newest first. No other headings
  inside a section except an optional `### Migrating from <version>` block.
- Flat `- ` bullets. No Added/Changed/Fixed/Deprecated subheadings.
- Details of a single feature go in nested sub-bullets under that feature —
  including platform caveats of a new feature. A limitation of something new
  is part of the "add" bullet, never a separate "change" entry (nothing
  existing changed).

## Bullet form

- Start each bullet with a lowercase verb that states the kind of change:
  `add`, `change`, `fix`, `remove`, `improve`, `rebuild`, `lower`, …
- Scope prefixes for non-package changes: `docs:`, `example:`.
- State what changed, not why. Rationale lives in `doc/` or commit messages.
  One clause of user-facing consequence is fine ("so switching cameras is
  just another `openUsbDevice` call"); design justification is not.
- Name the public symbols in backticks so entries are searchable
  (`startPreviewAuto()`, `UvcErrorCode`).

## Breaking changes

- Prefix with `**BREAKING**:` only when upgrading requires the user to change
  code (signature/type changes, removals, renamed symbols).
- Behavior improvements that need no code changes are plain `change` bullets,
  even when user-visible — reserving the marker keeps its warning value.
- Put migration steps as sub-bullets of the breaking bullet; use a
  `### Migrating from <version>` section only when a release has several
  breaking items.

## Classification guide

Ask, for each entry: "did something a 0.x-1 user already had become
different?"

- No, it's new → `add` (platform limits of the new thing are its
  sub-bullets).
- Yes, and their code must change → `**BREAKING**:`.
- Yes, but no code changes needed → `change` / `improve`.
- It was broken and now works as intended → `fix`.

## Release notes

GitHub releases copy the version's changelog section verbatim (see the
`gh-release` skill). pub.dev renders the changelog of the latest published
version, so wording fixes to an already-published section only surface with
the next release.
