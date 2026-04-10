import 'dart:io';

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('public entrypoints', () {
    test('exposes the shared camera service as the public interface type', () {
      expect(uvcCamera, isA<UvcCamera>());
    });

    test('fails explicitly on unsupported host platforms', () {
      if (Platform.isAndroid) {
        return;
      }

      expect(
        () => uvcCamera.supportedModes(),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('print host platform', () {
      print('operatingSystem=${Platform.operatingSystem}');
      print('isAndroid=${Platform.isAndroid}');
      print('isWindows=${Platform.isWindows}');
      print('isLinux=${Platform.isLinux}');
      print('isMacOS=${Platform.isMacOS}');
    });
  });
}
