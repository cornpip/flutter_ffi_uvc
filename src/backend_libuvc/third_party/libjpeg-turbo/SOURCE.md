# Vendored libjpeg-turbo

- Upstream: https://github.com/libjpeg-turbo/libjpeg-turbo
- Version: 3.2.0 (release tarball)
- License: BSD-3-Clause, IJG, and zlib (`LICENSE.md`; also mirrored in the
  repo-root `THIRD_PARTY_NOTICES.md` and `NOTICES`)
- Contents: unmodified sources, reduced to what the static-library build
  needs (docs, test images, and bindings removed)
- SIMD: on x86_64 the assembly needs `nasm` at build time; the Linux plugin
  build enables SIMD only when nasm is found and otherwise falls back to the
  plain C paths. arm64 SIMD needs no extra tools.

The Linux build compiles these sources directly. Android uses the static
libraries in `third_party/libjpeg-turbo-android`, built from these sources
with NDK 26.3.11579264 and stripped of debug info:

```sh
cmake -S . -B out/<abi> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=<abi> -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_SIMD=ON
cmake --build out/<abi> --target jpeg-static
llvm-strip --strip-debug out/<abi>/libjpeg.a
```

Copy `libjpeg.a` from `out/<abi>` into
`third_party/libjpeg-turbo-android/<abi>`, and `jconfig.h`, `jconfigint.h`,
and `jversion.h` into its `include` directory. x86_64 needs `nasm` for SIMD.
