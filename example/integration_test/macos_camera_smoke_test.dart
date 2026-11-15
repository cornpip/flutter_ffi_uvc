// Manual smoke test for the macOS backend against a real camera.
//
// Drives the public API end to end: permission, device list, open, preview,
// frame copies, still picture, MP4 recording, preview restart, close. It
// needs a UVC camera attached and is not part of CI. How to run it, and why
// `flutter test -d macos` is often not enough, is in ../README.md.
//
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS camera smoke', (WidgetTester tester) async {
    final Stopwatch clock = Stopwatch()..start();
    void log(String message) =>
        print('[smoke ${clock.elapsedMilliseconds}ms] $message');

    final UvcCamera camera = UvcCamera();
    final List<UvcStreamError> streamErrors = <UvcStreamError>[];
    final subscription = camera.streamErrors.listen(streamErrors.add);
    int? textureId;
    File? recording;
    try {
      expect(
        await camera.ensureCameraPermission(),
        isTrue,
        reason: 'camera access was refused, see the README for how to run',
      );

      final List<UvcUsbDevice> devices = await camera.listUsbDevices();
      for (final UvcUsbDevice device in devices) {
        log('device ${device.deviceId}: ${device.displayName}');
      }
      expect(devices, isNotEmpty, reason: 'no UVC camera attached');

      await camera.openUsbDevice(devices.first.deviceId);
      final List<UvcCameraMode> modes = camera.supportedModes();
      log('${modes.length} modes, '
          '${camera.supportedControls().length} controls');
      expect(modes, isNotEmpty);

      final UvcAutoPreviewResult started = await camera.startPreviewAuto();
      for (final UvcPreviewStartResult attempt in started.attempts) {
        log('start ${attempt.mode.label}: success=${attempt.success} '
            'validFrames=${attempt.validFrameCount} '
            'errors=${attempt.errorCount} '
            '${attempt.elapsed.inMilliseconds}ms ${attempt.lastError ?? ''}');
      }
      expect(started.success, isTrue);
      expect(camera.isPreviewing, isTrue);
      final UvcCameraMode mode = started.mode!;

      textureId = await camera.createPreviewTexture();

      // Frames keep arriving.
      final int sequenceBefore = camera.latestFrameSequence();
      await Future<void>.delayed(const Duration(seconds: 2));
      final int arrived = camera.latestFrameSequence() - sequenceBefore;
      log('$arrived frames in 2s');
      expect(arrived, greaterThan(0));

      final UvcPreviewFrame? frame = camera.copyLatestFrame();
      expect(frame, isNotNull);
      expect(frame!.width, mode.width);
      expect(frame.height, mode.height);
      expect(frame.rgbaBytes.length, frame.width * frame.height * 4);
      // Not asserted: a covered lens is a valid all-black picture.
      log('frame ${frame.width}x${frame.height}, '
          'uniform=${frame.rgbaBytes.every((int b) => b == 0 || b == 255)}');

      final UvcPreviewFrame? rotated = camera.copyLatestFrameTransformed(
        const UvcPreviewTransform(rotation: 90),
      );
      expect(rotated, isNotNull);
      expect(rotated!.width, mode.height);
      expect(rotated.height, mode.width);

      final UvcStillPicture? picture = camera.takePicture();
      expect(picture, isNotNull);
      expect(picture!.width, mode.width);
      expect(picture.height, mode.height);
      // JPEG start-of-image marker.
      expect(picture.jpegBytes.sublist(0, 2), <int>[0xFF, 0xD8]);
      log('picture ${picture.jpegBytes.length} bytes');

      // The app is sandboxed, so the recording goes into its container.
      recording = File(
        '${Directory.systemTemp.path}/uvc_smoke_'
        '${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      camera.startVideoRecording(recording.path);
      expect(camera.isRecording, isTrue);
      await Future<void>.delayed(const Duration(seconds: 3));
      camera.stopVideoRecording();
      expect(camera.isRecording, isFalse);
      expect(recording.existsSync(), isTrue);
      log('recording ${recording.lengthSync()} bytes');
      expect(recording.lengthSync(), greaterThan(0));

      final UvcStreamStats stats = camera.getStreamStats();
      log('stats: delivered=${stats.deliveredFrameCount} '
          'fps=${stats.deliveredFps.toStringAsFixed(1)} '
          'firstFrame=${stats.firstFrameLatencyMs}ms');
      expect(stats.deliveredFrameCount, greaterThan(0));

      // Stop and start again on the same open device.
      await camera.stopPreview();
      expect(camera.isPreviewing, isFalse);
      final UvcPreviewStartResult restarted = await camera.startPreview(mode);
      log('restart: success=${restarted.success} '
          '${restarted.lastError ?? ''}');
      expect(restarted.success, isTrue);
      await camera.stopPreview();

      await camera.closeUsbDevice();
      expect(camera.openedDeviceId, isNull);
      expect(streamErrors, isEmpty);
    } finally {
      await subscription.cancel();
      if (textureId != null) {
        await camera.disposePreviewTexture(textureId);
      }
      await camera.dispose();
      if (recording != null && recording.existsSync()) {
        recording.deleteSync();
      }
    }
  }, skip: !Platform.isMacOS);
}
