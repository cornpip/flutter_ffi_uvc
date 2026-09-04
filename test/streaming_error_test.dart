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
  Future<void> dispose() async {}
  @override
  void setLogLevel(UvcLogLevel level) {}
  @override
  Future<bool> ensureCameraPermission() async => false;
  @override
  Future<List<UvcUsbDevice>> listUsbDevices() async => const [];
  @override
  Future<void> openUsbDevice(int deviceId) async {}
  @override
  Future<void> closeUsbDevice() async {}
  @override
  int? get openedDeviceId => null;
  @override
  Future<void> openFd(int fd) async {}
  @override
  Future<void> openPreview(UvcCameraMode mode) async {}
  @override
  Future<UvcPreviewStartResult> startPreview(
    UvcCameraMode mode, {
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration timeout = const Duration(seconds: 2),
  }) async => UvcPreviewStartResult(
    mode: mode,
    success: false,
    validFrameCount: 0,
    consecutiveValidFrames: 0,
    errorCount: 0,
    elapsed: Duration.zero,
  );
  @override
  Future<UvcAutoPreviewResult> startPreviewAuto({
    List<UvcCameraMode>? candidates,
    UvcAutoPreviewPreference preference = UvcAutoPreviewPreference.reliability,
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration perModeTimeout = const Duration(seconds: 2),
    int maxCandidates = 8,
  }) async => const UvcAutoPreviewResult(attempts: []);
  @override
  Stream<UvcDeviceEvent> get deviceEvents => const Stream.empty();
  @override
  Stream<UvcStallEvent> get stallEvents => const Stream.empty();
  @override
  void enableStallDetection([
    UvcStallDetectionConfig config = const UvcStallDetectionConfig(),
  ]) {}
  @override
  void disableStallDetection() {}
  @override
  Future<void> stopPreview() async {}
  @override
  Future<void> closeFd() async {}
  @override
  bool get isPreviewing => false;
  @override
  String get lastError => '';
  @override
  UvcPreviewFrame? copyLatestFrame() => null;
  @override
  UvcPreviewFrame? copyLatestFrameTransformed(UvcPreviewTransform transform) => null;
  @override
  UvcStillPicture? takePicture({int quality = 90, UvcPreviewTransform? transform}) => null;
  @override
  void startVideoRecording(String path,
      {int bitrateBps = 0, UvcPreviewTransform? transform}) {}
  @override
  void stopVideoRecording() {}
  @override
  bool get isRecording => false;
  @override
  int latestFrameSequence() => 0;
  @override
  UvcStreamStats getStreamStats() => const UvcStreamStats.zero();
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
  void setControl(UvcControlId controlId, int value) {}
  @override
  UvcWhiteBalanceComponent? getWhiteBalanceComponent() => null;
  @override
  void setWhiteBalanceComponent(UvcWhiteBalanceComponent value) {}
  @override
  UvcFocusRelativeControl? getFocusRelativeControl() => null;
  @override
  void setFocusRelativeControl(UvcFocusRelativeControl value) {}
  @override
  UvcZoomRelativeControl? getZoomRelativeControl() => null;
  @override
  void setZoomRelativeControl(UvcZoomRelativeControl value) {}
  @override
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl() => null;
  @override
  void setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value) {}
  @override
  UvcPanTiltRelativeControl? getPanTiltRelativeControl() => null;
  @override
  void setPanTiltRelativeControl(UvcPanTiltRelativeControl value) {}
  @override
  UvcRollRelativeControl? getRollRelativeControl() => null;
  @override
  void setRollRelativeControl(UvcRollRelativeControl value) {}
  @override
  UvcDigitalWindowControl? getDigitalWindowControl() => null;
  @override
  void setDigitalWindowControl(UvcDigitalWindowControl value) {}
  @override
  UvcRegionOfInterestControl? getRegionOfInterestControl() => null;
  @override
  void setRegionOfInterestControl(UvcRegionOfInterestControl value) {}
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
