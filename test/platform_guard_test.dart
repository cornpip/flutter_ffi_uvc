import 'dart:io';

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('public entrypoints', () {
    test('exposes the shared camera service as the public interface type', () {
      expect(uvcCamera, isA<UvcCamera>());
    });

    test('fd-based APIs are Android-only and fail fast elsewhere', () {
      if (Platform.isAndroid) {
        return;
      }

      // On Windows and Linux the platform itself is supported, but openFd is
      // not the supported opening path there; it must throw instead of
      // silently reinterpreting the value.
      expect(() => uvcCamera.openFd(3), throwsA(isA<UnsupportedError>()));
      expect(() => uvcCamera.closeFd(), throwsA(isA<UnsupportedError>()));
    });

    test('fails explicitly on unsupported host platforms', () {
      // Android, Windows, and Linux are supported platforms: there the guard
      // passes and native calls only work with the plugin library present,
      // which a pure Dart test host does not provide.
      if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
        return;
      }

      expect(
        () => uvcCamera.supportedModes(),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
