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

When distributing binaries that include `libjpeg-turbo`, upstream requires the
following documentation notice:

`This software is based in part on the work of the Independent JPEG Group.`

The upstream Modified BSD text is reproduced below because the vendored Android
shared libraries in this package rely on `libjpeg-turbo`:

```text
Copyright (C) 2009-2026 D. R. Commander
Copyright (C) 2018-2023 Randy <randy408@protonmail.com>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of the libjpeg-turbo Project nor the names of its
  contributors may be used to endorse or promote products derived from this
  software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS",
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

The upstream roll-up license explanation is available at:

- `https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/LICENSE.md`
- `https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/README.ijg`

## Notes for Distributors

- If you modify any vendored third-party source files or headers, keep the
  upstream copyright and license notices intact and add your own
  modification notice.
- If you publish app binaries that bundle the shared libraries from this
  package, ensure your product documentation or notices include this file.
- Downstream app distributors that bundle `libusb1.0.so` should review the
  LGPL obligations that apply to that shared library and any modifications to
  it.
