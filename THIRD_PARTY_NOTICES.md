# Third-Party Notices

This package includes:

- vendored third-party source code for `libuvc`
- for `libusb`: prebuilt shared libraries with public headers (Android) and
  vendored source code (Linux)
- for `libjpeg-turbo`: prebuilt shared libraries with public headers
  (Android) and vendored source code (Linux)

Their licenses remain in force for those components.

Apps that depend on this package pick these notices up automatically. The
`NOTICES` file in the package root carries the same attribution in the format
Flutter's license collector reads, so `showLicensePage()` in a consuming app
lists `libuvc`, `libusb`, and `libjpeg-turbo` alongside this package's BSD-3
license.

## libuvc

- Path: `src/backend_libuvc/libuvc`
- Upstream: `https://github.com/libuvc/libuvc`
- Upstream source base revision:
  `047920bcdfb1dac42424c90de5cc77dfc9fba04d`
- License: BSD License

`libuvc` is redistributed in source form in this repository. The full upstream
license text is kept in:

- `src/backend_libuvc/libuvc/LICENSE.txt`

The vendored `libuvc` source in this repository started from the upstream
revision above and has been modified locally to fit `flutter_ffi_uvc`.

## libusb

- Paths: `src/backend_libuvc/third_party/libusb-android` (Android prebuilts),
  `src/backend_libuvc/third_party/libusb` (Linux sources)
- Upstream: `https://github.com/libusb/libusb`
- Upstream revision for the Android prebuilt binaries and headers:
  `2101df11b92272eebf0355818f84c12fd040e2ff`
- Upstream release for the Linux vendored sources: `1.0.29`
- License: GNU Lesser General Public License, version 2.1 or later

For Android this package vendors `libusb1.0.so` shared libraries and the
associated public header. For Linux it vendors the unmodified upstream
sources reduced to the Linux/POSIX subset, built as part of the plugin (see
`src/backend_libuvc/third_party/libusb/SOURCE.md`). Because `libusb` is
licensed under the LGPL, distributions that include these binaries must
continue to preserve the LGPL notice and comply with the LGPL terms for that
library and any modifications to it.

For convenience, the standard LGPL 2.1 text is provided in:

- `src/backend_libuvc/third_party/libusb-android/COPYING`
- `src/backend_libuvc/third_party/libusb/COPYING`

## libjpeg-turbo

- Paths: `src/backend_libuvc/third_party/libjpeg-turbo` (Android prebuilts),
  `src/backend_libuvc/third_party/libjpeg-turbo-src` (Linux sources)
- Upstream: `https://github.com/libjpeg-turbo/libjpeg-turbo`
- Upstream revision for the Android prebuilt binaries and headers:
  `96c5446cd661b1329ce5c97b297a924c2e2b5c63`
- Upstream release for the Linux vendored sources: `3.2.0`
- License summary: IJG License and Modified BSD (3-clause) License

For Android this package vendors `libjpeg.so` shared libraries and the
associated public headers. For Linux it vendors the unmodified upstream
sources reduced to what the static-library build needs, built as part of the
plugin (see `src/backend_libuvc/third_party/libjpeg-turbo-src/SOURCE.md`).

The upstream project documents `libjpeg-turbo` as being covered by two
compatible BSD-style licenses: the IJG license for the libjpeg API code and the
Modified BSD license for the TurboJPEG API library and related components.

The upstream license texts are kept in this repository as verbatim reference
copies:

- `src/backend_libuvc/third_party/libjpeg-turbo/LICENSE.md`
- `src/backend_libuvc/third_party/libjpeg-turbo/README.ijg`
- `src/backend_libuvc/third_party/libjpeg-turbo-src/LICENSE.md`
- `src/backend_libuvc/third_party/libjpeg-turbo-src/README.ijg`

When distributing binaries that include `libjpeg-turbo`, upstream requires the
following documentation notice:

`This software is based in part on the work of the Independent JPEG Group.`

## Notes for Distributors

- If you modify any vendored third-party source files or headers, keep the
  upstream copyright and license notices intact and add your own
  modification notice.
- If you publish app binaries that bundle the shared libraries from this
  package, the notices ship automatically through the package's `NOTICES`
  file when you build with Flutter. If you surface licenses some other way,
  make sure these notices are included.
- Downstream app distributors that bundle `libusb1.0.so` should review the
  LGPL obligations that apply to that shared library and any modifications to
  it.
