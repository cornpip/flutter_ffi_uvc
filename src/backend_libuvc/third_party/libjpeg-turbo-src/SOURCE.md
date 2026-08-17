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

Used by the Linux build only. Android uses the prebuilt
`third_party/libjpeg-turbo` instead.
