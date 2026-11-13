# Release checklist

## Collect

- [ ] `git fetch --tags` (local tags can lag GitHub)
- [ ] Review `git log v<last>..HEAD --oneline` against the `-wip` section
      for missed bullets

## Version settings

- [ ] `pubspec.yaml` `version:` (drop the `-wip` suffix)
- [ ] `CHANGELOG.md` `## <version>` section (rename from `-wip`; bullets
      only)
- [ ] `flutter pub get` in `example/` (refresh the tracked lock)

## After the release commit

- [ ] Publish with the `gh-release` skill, which tags `v<version>` and
      copies the CHANGELOG section as the release notes
