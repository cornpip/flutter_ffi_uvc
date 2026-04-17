import 'dart:async';

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake camera that exposes a controllable streamErrors sink for testing.
// ---------------------------------------------------------------------------

class _FakeCamera implements UvcCamera {
  final StreamController<UvcStreamError> _errorController =
      StreamController<UvcStreamError>.broadcast();

  void injectError(String message) =>
      _errorController.add(UvcStreamError(message: message));

  void close() => _errorController.close();

  @override
  Stream<UvcStreamError> get streamErrors => _errorController.stream;

  // --- unused stubs ---
  @override
  void setLogLevel(UvcLogLevel level) {}
  @override
  Future<bool> ensureCameraPermission() async => false;
  @override
  Future<List<UvcUsbDevice>> listUsbDevices() async => const [];
  @override
  Future<int> openUsbDevice(int deviceId) async => -1;
  @override
  Future<void> closeUsbDevice() async {}
  @override
  int openFd(int fd) => -1;
  @override
  int startPreview(UvcCameraMode mode) => -1;
  @override
  void stopPreview() {}
  @override
  void closeFd() {}
  @override
  @Deprecated('Use closeFd() instead.')
  void closeDevice() {}
  @override
  bool get isPreviewing => false;
  @override
  String get lastError => '';
  @override
  UvcPreviewFrame? copyLatestFrame() => null;
  @override
  int latestFrameSequence() => 0;
  @override
  Future<int> createPreviewTexture() async => -1;
  @override
  Future<void> disposePreviewTexture(int textureId) async {}
  @override
  Future<void> attachPreviewTexture(int textureId,
      {int? width, int? height}) async {}
  @override
  List<UvcCameraControl> supportedControls() => const [];
  @override
  List<UvcBmControlInfo> debugBmControls() => const [];
  @override
  int? getControl(UvcControlId controlId) => null;
  @override
  int setControl(UvcControlId controlId, int value) => -1;
  @override
  UvcWhiteBalanceComponent? getWhiteBalanceComponent() => null;
  @override
  int setWhiteBalanceComponent(UvcWhiteBalanceComponent value) => -1;
  @override
  UvcFocusRelativeControl? getFocusRelativeControl() => null;
  @override
  int setFocusRelativeControl(UvcFocusRelativeControl value) => -1;
  @override
  UvcZoomRelativeControl? getZoomRelativeControl() => null;
  @override
  int setZoomRelativeControl(UvcZoomRelativeControl value) => -1;
  @override
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl() => null;
  @override
  int setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value) => -1;
  @override
  UvcPanTiltRelativeControl? getPanTiltRelativeControl() => null;
  @override
  int setPanTiltRelativeControl(UvcPanTiltRelativeControl value) => -1;
  @override
  UvcRollRelativeControl? getRollRelativeControl() => null;
  @override
  int setRollRelativeControl(UvcRollRelativeControl value) => -1;
  @override
  UvcDigitalWindowControl? getDigitalWindowControl() => null;
  @override
  int setDigitalWindowControl(UvcDigitalWindowControl value) => -1;
  @override
  UvcRegionOfInterestControl? getRegionOfInterestControl() => null;
  @override
  int setRegionOfInterestControl(UvcRegionOfInterestControl value) => -1;
  @override
  List<UvcCameraMode> supportedModes() => const [];
  @override
  UvcPreviewTransform get previewTransform => UvcPreviewTransform.identity;
  @override
  void setPreviewTransform(UvcPreviewTransform transform) {}
  @override
  void rotatePreviewClockwise() {}
  @override
  void rotatePreviewCounterClockwise() {}
  @override
  void togglePreviewFlipHorizontal() {}
  @override
  void togglePreviewFlipVertical() {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UvcStreamError', () {
    test('toString includes message', () {
      const UvcStreamError err = UvcStreamError(message: 'decode failed');
      expect(err.toString(), contains('decode failed'));
    });

    test('message is preserved exactly', () {
      const String msg = 'Frame too small: expected>=1228800 actual=0';
      expect(UvcStreamError(message: msg).message, msg);
    });
  });

  group('streamErrors stream', () {
    late _FakeCamera camera;

    setUp(() => camera = _FakeCamera());
    tearDown(() => camera.close());

    test('delivers single injected error to subscriber', () async {
      final List<UvcStreamError> received = <UvcStreamError>[];
      final StreamSubscription<UvcStreamError> sub =
          camera.streamErrors.listen(received.add);

      camera.injectError('uvc_any2rgb failed');

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received, hasLength(1));
      expect(received.first.message, 'uvc_any2rgb failed');
    });

    test('delivers multiple errors in order', () async {
      final List<String> messages = <String>[];
      final StreamSubscription<UvcStreamError> sub =
          camera.streamErrors.listen((UvcStreamError e) => messages.add(e.message));

      camera.injectError('error 1');
      camera.injectError('error 2');
      camera.injectError('error 3');

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(messages, <String>['error 1', 'error 2', 'error 3']);
    });

    test('broadcast: all subscribers receive each error', () async {
      final List<UvcStreamError> received1 = <UvcStreamError>[];
      final List<UvcStreamError> received2 = <UvcStreamError>[];

      final StreamSubscription<UvcStreamError> sub1 =
          camera.streamErrors.listen(received1.add);
      final StreamSubscription<UvcStreamError> sub2 =
          camera.streamErrors.listen(received2.add);

      camera.injectError('broadcast error');

      await Future<void>.delayed(Duration.zero);
      await sub1.cancel();
      await sub2.cancel();

      expect(received1, hasLength(1));
      expect(received2, hasLength(1));
      expect(received1.first.message, received2.first.message);
    });

    test('subscriber added after error misses past events', () async {
      camera.injectError('before subscription');

      await Future<void>.delayed(Duration.zero);

      final List<UvcStreamError> received = <UvcStreamError>[];
      final StreamSubscription<UvcStreamError> sub =
          camera.streamErrors.listen(received.add);

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(received, isEmpty);
    });

    test('cancelled subscription no longer receives errors', () async {
      final List<UvcStreamError> received = <UvcStreamError>[];
      final StreamSubscription<UvcStreamError> sub =
          camera.streamErrors.listen(received.add);

      camera.injectError('before cancel');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      camera.injectError('after cancel');
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
    });
  });
}
