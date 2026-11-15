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

## Issues and milestones

Work is tracked with GitHub issues, grouped by release in milestones (e.g.
`1.2.0`). An issue is only open or closed, there are no status columns.

When a change has an issue, the branch name starts with its number (e.g.
`9-ipados-support`), the PR description says `Closes #<n>`, and the PR goes
in the same milestone, so merging closes the issue. Commit subjects carry no
issue number.

## Prose

Avoid em dashes in anything written for this repo (docs, CHANGELOG, code
comments, commit messages). Use a comma or a separate sentence.

## Engineering rules

- What the package covers and how the public API treats platform
  differences: `doc/scope.md`.
- Rules every native backend follows: `doc/native-strategy.md`.
- When native declarations change, regenerate bindings with
  `dart run ffigen --config ffigen.yaml`.
- All platforms implement the same exported C ABI and emit byte-compatible
  JSON, so a change lands in the libuvc backend (Android/Linux), the
  Windows backend, and the Apple backend (macOS/iPadOS) together.

## Tests

- Package tests: `flutter test` at the repo root.
