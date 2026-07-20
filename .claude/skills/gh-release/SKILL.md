---
name: gh-release
description: Create a GitHub release for the current package version, using the matching CHANGELOG section verbatim as the release notes (the repo's established release format).
argument-hint: "[version, e.g. 0.7.0 — defaults to pubspec.yaml version]"
disable-model-invocation: true
---

Create a GitHub release following this repo's established format: tag and
title are `v<version>`, the body is the CHANGELOG section for that version
copied verbatim (subheadings and bullets only, no `## <version>` heading),
and the tag points at the main merge commit.

## Steps

1. **Resolve the version.** Use `$ARGUMENTS` if given; otherwise read
   `version:` from `pubspec.yaml`. Call it `<version>` below.

2. **Preconditions — stop and tell the user if any fail:**
   - `git fetch origin main`, then confirm the release commit for
     `<version>` is on `origin/main` (e.g. the `Bump version to <version>
     and update changelog` commit or its merge commit). If main doesn't
     contain it, the feature branch probably hasn't been merged yet.
   - `gh release view v<version>` must fail (release/tag must not already
     exist).
   - The CHANGELOG must have a `## <version>` section.

3. **Extract the release notes** from `CHANGELOG.md`: the content between
   `## <version>` and the next `## ` heading, with the heading line and
   surrounding blank lines stripped. Write it to a scratchpad file and show
   it to the user so they can spot a stale or wrong section.

4. **Create the release:**
   ```bash
   gh release create v<version> --target main --title v<version> \
     --notes-file <notes-file>
   ```
   Note: `--target` must be a branch name or full 40-char SHA — short SHAs
   are rejected with HTTP 422.

5. **Verify:** `gh release list --limit 3` — the new release must appear and
   be marked `Latest`. Report the release URL.

## Notes

- Publishing to pub.dev is a separate manual step (`dart pub publish`); do
  not attempt it from this skill, but remind the user it remains.
