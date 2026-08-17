# Contributing

## Commits

Commit subjects start with a type prefix:

- `feat` / `fix` / `perf` / `change`: package-visible changes
- `docs` / `example`: shipped non-code changes (docs and the example app
  are part of the published package)
- `chore`: repo-internal work (agent rules, skills, tooling)

Split mixed commits so each part keeps its prefix. The version no longer
belongs in the subject; the `-wip` changelog section carries it.

## Changelog

The topmost CHANGELOG section is `## <version>-wip`; it accumulates
bullets for the next release.

- Every non-`chore` commit adds its bullet to that section in the same
  commit. If the section does not exist yet, open it and set pubspec
  `version:` to the same `-wip` value in that commit.
- Pick the smallest bump the accumulated changes justify (docs or fix:
  patch); rename the section heading and pubspec when a later change
  needs a bigger bump.
- `chore` commits add no bullet by default; include one when it is worth
  recording.
- Bullet style: `.agents/docs/changelog-style.md`.

## Engineering rules

- When native declarations change, regenerate bindings with
  `dart run ffigen --config ffigen.yaml`.
- All platforms implement the same exported C ABI and emit byte-compatible
  JSON, so a change lands in the libuvc backend (Android/Linux) and the
  Windows backend together.

## Tests

- Package tests: `flutter test` at the repo root.
