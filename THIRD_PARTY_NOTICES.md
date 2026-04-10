# Third-Party Notices

This package includes:

- vendored third-party source code for `libuvc`
- third-party public headers and prebuilt shared libraries for `libusb`
- third-party public headers and prebuilt shared libraries for `libjpeg-turbo`

Their licenses remain in force for those components.

## libuvc

- Path: `src/libuvc`
- Upstream: `https://github.com/libuvc/libuvc`
- Upstream source base revision:
  `047920bcdfb1dac42424c90de5cc77dfc9fba04d`
- License: BSD License

`libuvc` is redistributed in source form in this repository. The full upstream
license text is kept in:

- `src/libuvc/LICENSE.txt`

The vendored `libuvc` source in this repository started from the upstream
revision above and has been modified locally to fit `flutter_ffi_uvc`.

## libusb

- Path: `src/third_party/libusb-android`
- Upstream: `https://github.com/libusb/libusb`
- Upstream revision for vendored headers and prebuilt binaries:
  `2101df11b92272eebf0355818f84c12fd040e2ff`
- License: GNU Lesser General Public License, version 2.1 or later

This package vendors Android `libusb1.0.so` shared libraries and the associated
public header. It does not vendor the full upstream `libusb` source tree.
Because `libusb` is licensed under the LGPL, distributions that include these
binaries must continue to preserve the LGPL notice and comply with the LGPL
terms for that library and any modifications to it.

For convenience, the standard LGPL 2.1 text is provided in:

- `src/third_party/libusb-android/COPYING`

## libjpeg-turbo

- Path: `src/third_party/libjpeg-turbo`
- Upstream: `https://github.com/libjpeg-turbo/libjpeg-turbo`
- Upstream revision for vendored headers and prebuilt binaries:
  `96c5446cd661b1329ce5c97b297a924c2e2b5c63`
- License summary: IJG License and Modified BSD (3-clause) License

This package vendors Android `libjpeg.so` shared libraries and the associated
public headers. It does not vendor the full upstream `libjpeg-turbo` source
tree.

The upstream project documents `libjpeg-turbo` as being covered by two
compatible BSD-style licenses: the IJG license for the libjpeg API code and the
Modified BSD license for the TurboJPEG API library and related components.

The upstream license texts are kept in this repository as verbatim reference
copies:

- `src/third_party/libjpeg-turbo/LICENSE.md`
- `src/third_party/libjpeg-turbo/README.ijg`

When distributing binaries that include `libjpeg-turbo`, upstream requires the
following documentation notice:

`This software is based in part on the work of the Independent JPEG Group.`

## Notes for Distributors

- If you modify any vendored third-party source files or headers, keep the
  upstream copyright and license notices intact and add your own
  modification notice.
- If you publish app binaries that bundle the shared libraries from this
  package, ensure your product documentation or notices include this file.
- Downstream app distributors that bundle `libusb1.0.so` should review the
  LGPL obligations that apply to that shared library and any modifications to
  it.
