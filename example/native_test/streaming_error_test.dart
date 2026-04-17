import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ---------------------------------------------------------------------------
// Test-only bindings for uvc_trigger_test_error.
// The function is compiled into libflutter_ffi_uvc.so but is NOT declared in
// the public header, so it is not part of the generated bindings.
// ---------------------------------------------------------------------------

typedef _NativeTriggerTestError = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _DartTriggerTestError = void Function(ffi.Pointer<ffi.Char>);

class _UvcTestBindings {
  _UvcTestBindings() {
    _lib = ffi.DynamicLibrary.open('libflutter_ffi_uvc.so');
    _trigger = _lib.lookupFunction<_NativeTriggerTestError, _DartTriggerTestError>(
      'uvc_trigger_test_error',
    );
  }

  late final ffi.DynamicLibrary _lib;
  late final _DartTriggerTestError _trigger;

  void triggerError(String message) {
    final ffi.Pointer<Utf8> ptr = message.toNativeUtf8();
    try {
      _trigger(ptr.cast<ffi.Char>());
    } finally {
      calloc.free(ptr);
    }
  }

  void dispose() => _lib.close();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _UvcTestBindings testBindings;

  setUpAll(() {
    testBindings = _UvcTestBindings();
  });

  tearDownAll(() {
    testBindings.dispose();
  });

  group('Native streaming error (uvc_trigger_test_error)', () {
    test('single triggered error arrives on streamErrors', () async {
      final List<UvcStreamError> received = <UvcStreamError>[];
      final StreamSubscription<UvcStreamError> sub =
          uvcCamera.streamErrors.listen(received.add);

      testBindings.triggerError('native error A');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(received, hasLength(1));
      expect(received.first.message, 'native error A');
    });

    test('multiple triggered errors arrive in order', () async {
      final List<String> messages = <String>[];
      final StreamSubscription<UvcStreamError> sub =
          uvcCamera.streamErrors.listen((UvcStreamError e) => messages.add(e.message));

      testBindings.triggerError('error 1');
      testBindings.triggerError('error 2');
      testBindings.triggerError('error 3');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(messages, containsAllInOrder(<String>['error 1', 'error 2', 'error 3']));
    });

    test('broadcast: two subscribers both receive the error', () async {
      final List<UvcStreamError> received1 = <UvcStreamError>[];
      final List<UvcStreamError> received2 = <UvcStreamError>[];

      final StreamSubscription<UvcStreamError> sub1 =
          uvcCamera.streamErrors.listen(received1.add);
      final StreamSubscription<UvcStreamError> sub2 =
          uvcCamera.streamErrors.listen(received2.add);

      testBindings.triggerError('broadcast native error');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub1.cancel();
      await sub2.cancel();

      expect(received1, hasLength(1));
      expect(received2, hasLength(1));
      expect(received1.first.message, received2.first.message);
    });

    test('cancelled subscription no longer receives errors', () async {
      final List<UvcStreamError> received = <UvcStreamError>[];
      final StreamSubscription<UvcStreamError> sub =
          uvcCamera.streamErrors.listen(received.add);

      testBindings.triggerError('before cancel');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      testBindings.triggerError('after cancel');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, hasLength(1));
      expect(received.first.message, 'before cancel');
    });
  });
}
