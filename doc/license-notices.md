# License and notices

Attributions, upstream revisions, and what each bundled component is:
`THIRD_PARTY_NOTICES.md`.

Flutter's collector reads `NOTICES` in preference to `LICENSE`, and it is the
only path by which the bundled components' notices reach a consuming app. That
matters most for `libusb`, which is LGPL-2.1, and for `libjpeg-turbo`, whose
IJG license requires the sentence "This software is based in part on the work
of the Independent JPEG Group." in product documentation.

The `NOTICES` multi-license format is Flutter's, not ours. Follow the
`LicenseCollector` doc comment in
`packages/flutter_tools/lib/src/license_collector.dart` in the installed SDK.

Keep these in sync:

- `NOTICES` holds verbatim copies of `LICENSE` and of each vendored upstream
  license file, with a short attribution note before each. Re-sync a copy
  whenever its source file changes.
- A new, updated, or newly modified bundled component updates both
  `THIRD_PARTY_NOTICES.md` and `NOTICES`.

Verify: `flutter build bundle` in `example/`, then gunzip
`example/build/flutter_assets/NOTICES.Z` and confirm every block of `NOTICES`
appears there as its own entry.
