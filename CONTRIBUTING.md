# Contributing

## Commits

Commit subjects start with a type prefix:

- `feat` / `fix` / `perf` / `change`: package code
- `docs` / `example`: documentation and the example app
- `chore`: everything else (agent rules, CI, tooling)

Split mixed commits so each part keeps its prefix.

## Changelog

The topmost CHANGELOG section is `## <version>-wip`. It accumulates
bullets for the next release. Pull requests keep the `-wip` suffix, in
both the heading and pubspec `version:`. The release commit drops it.

- `feat`, `fix`, `perf`, and `change` commits add their bullet in the
  same commit. Other commits add one only when the change matters to a
  user of the package.
- The first commit after a release opens the `-wip` section and sets
  pubspec `version:` to match.
- Pick the smallest bump the accumulated changes justify; rename the
  section heading and pubspec when a later change needs a bigger bump.
- Flat `- ` bullets, details of one change as sub-bullets under it. Start
  with a lowercase verb (`add`, `change`, `fix`, ...) or a scope prefix
  (`docs:`, `example:`). Name symbols in backticks.

## Engineering rules

- When native declarations change, regenerate bindings with
  `dart run ffigen --config ffigen.yaml`.
- All platforms implement the same exported C ABI and emit byte-compatible
  JSON, so a change lands in the libuvc backend (Android/Linux) and the
  Windows backend together.

## Tests

- Package tests: `flutter test` at the repo root.
