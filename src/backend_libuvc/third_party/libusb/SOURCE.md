# Vendored libusb

- Upstream: https://github.com/libusb/libusb
- Version: 1.0.29 (release tarball)
- License: LGPL-2.1 (`COPYING`; also mirrored in the repo-root
  `THIRD_PARTY_NOTICES.md` and `NOTICES`)
- Contents: unmodified sources, reduced to the Linux/POSIX subset the Linux
  plugin build compiles
- `config/config.h`: generated on Linux by the upstream `configure` script
  with `--disable-udev`; contains only glibc-stable feature defines, so one
  copy serves x64 and arm64

Used by the Linux build only. Android uses the prebuilt
`third_party/libusb-android` instead.
