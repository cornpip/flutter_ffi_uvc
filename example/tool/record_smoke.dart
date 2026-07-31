// Manual smoke test for MP4 recording against the built Windows plugin DLL.
//
// Talks straight to the exported C ABI, so it needs a UVC camera attached and
// a prior `flutter build windows --debug` in this example. Run from the
// example directory:
//
//   dart run tool/record_smoke.dart [width height [rotation]]
//
// With no arguments the smallest MJPEG mode is used; pass a resolution to
// force a specific mode and optionally a rotation (0/90/180/270) to exercise
// the transform path.
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _OpenFdC = Int32 Function(Int32);
typedef _OpenFd = int Function(int);
typedef _JsonC = Int32 Function(Pointer<Uint8>, Int32);
typedef _Json = int Function(Pointer<Uint8>, int);
typedef _StartPreviewC = Int32 Function(Int32, Int32, Int32, Int32);
typedef _StartPreview = int Function(int, int, int, int);
typedef _SequenceC = Int64 Function();
typedef _Sequence = int Function();
typedef _StartRecordingC =
    Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Int32, Int32);
typedef _StartRecording = int Function(Pointer<Utf8>, int, int, int, int, int);
typedef _IntVoidC = Int32 Function();
typedef _IntVoid = int Function();
typedef _VoidVoidC = Void Function();
typedef _VoidVoid = void Function();
typedef _LastErrorC = Pointer<Utf8> Function();

Future<void> main(List<String> args) async {
  final int? wantWidth = args.isNotEmpty ? int.parse(args[0]) : null;
  final int? wantHeight = args.length > 1 ? int.parse(args[1]) : null;
  final int rotation = args.length > 2 ? int.parse(args[2]) : 0;
  final String debugDir =
      '${Directory.current.path}\\build\\windows\\x64\\runner\\Debug';
  // Pre-load the engine DLL so the plugin DLL's dependency resolves without
  // relying on the process search path.
  DynamicLibrary.open('$debugDir\\flutter_windows.dll');
  final DynamicLibrary lib =
      DynamicLibrary.open('$debugDir\\flutter_ffi_uvc_plugin.dll');

  final _OpenFd openFd = lib.lookupFunction<_OpenFdC, _OpenFd>('uvc_open_fd');
  final _Json modesJson = lib.lookupFunction<_JsonC, _Json>(
    'uvc_get_supported_modes_json',
  );
  final _StartPreview startPreview = lib
      .lookupFunction<_StartPreviewC, _StartPreview>('uvc_start_preview');
  final _Sequence latestSequence = lib.lookupFunction<_SequenceC, _Sequence>(
    'uvc_latest_frame_sequence',
  );
  final _StartRecording startRecording = lib
      .lookupFunction<_StartRecordingC, _StartRecording>('uvc_start_recording');
  final _IntVoid stopRecording = lib.lookupFunction<_IntVoidC, _IntVoid>(
    'uvc_stop_recording',
  );
  final _IntVoid isRecording = lib.lookupFunction<_IntVoidC, _IntVoid>(
    'uvc_is_recording',
  );
  final _VoidVoid stopPreview = lib.lookupFunction<_VoidVoidC, _VoidVoid>(
    'uvc_stop_preview',
  );
  final _VoidVoid closeDevice = lib.lookupFunction<_VoidVoidC, _VoidVoid>(
    'uvc_close_device',
  );
  final Pointer<Utf8> Function() lastError = lib
      .lookupFunction<_LastErrorC, Pointer<Utf8> Function()>('uvc_last_error');

  String err() => lastError().toDartString();

  // Device ids are assigned in enumeration order starting at 1.
  int opened = -1;
  for (int id = 1; id <= 4; id++) {
    final int result = openFd(id);
    if (result == 0) {
      opened = id;
      break;
    }
    print('open device $id failed: $result (${err()})');
  }
  if (opened < 0) {
    print('FAIL: no camera could be opened');
    exit(1);
  }
  print('opened device id $opened');

  final Pointer<Uint8> buffer = calloc<Uint8>(64 * 1024);
  final int jsonBytes = modesJson(buffer, 64 * 1024);
  if (jsonBytes <= 0) {
    print('FAIL: no supported modes (${err()})');
    exit(1);
  }
  final List<dynamic> modes =
      jsonDecode(utf8.decode(buffer.asTypedList(jsonBytes))) as List<dynamic>;
  calloc.free(buffer);
  print('device reports ${modes.length} mode entries');

  // Prefer a small MJPEG mode for a quick start, else take the first mode.
  final Iterable<Map<String, dynamic>> candidates = modes
      .cast<Map<String, dynamic>>()
      .where(
        (m) =>
            (wantWidth == null || m['width'] == wantWidth) &&
            (wantHeight == null || m['height'] == wantHeight),
      );
  Map<String, dynamic> pick = candidates
      .where((m) => m['formatName'] == 'MJPEG')
      .fold<Map<String, dynamic>?>(null, (best, m) {
        if (best == null) return m;
        final int bestArea = (best['width'] as int) * (best['height'] as int);
        final int area = (m['width'] as int) * (m['height'] as int);
        return area < bestArea ? m : best;
      }) ??
      candidates.first;
  print('using mode: $pick');

  final int startResult = startPreview(
    pick['format'] as int,
    pick['width'] as int,
    pick['height'] as int,
    pick['fps'] as int,
  );
  if (startResult != 0) {
    print('FAIL: startPreview -> $startResult (${err()})');
    exit(1);
  }

  final Stopwatch clock = Stopwatch()..start();
  while (latestSequence() < 3) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      print('FAIL: no frames delivered within 5s (${err()})');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  print('frames flowing (sequence=${latestSequence()})');

  final String outPath =
      '${Directory.systemTemp.path}\\uvc_record_smoke.mp4';
  final File outFile = File(outPath);
  if (outFile.existsSync()) outFile.deleteSync();

  final Pointer<Utf8> nativePath = outPath.toNativeUtf8(allocator: calloc);
  final int recStart = startRecording(nativePath, 0, 0, rotation, 0, 0);
  calloc.free(nativePath);
  if (recStart != 0) {
    print('FAIL: startRecording -> $recStart (${err()})');
    exit(1);
  }
  print('recording to $outPath (isRecording=${isRecording()})');

  final int seqBefore = latestSequence();
  await Future<void>.delayed(const Duration(seconds: 5));
  final int seqAfter = latestSequence();
  print('captured ~${seqAfter - seqBefore} frames in 5s');

  // With `preview-stop` as the 4th argument, skip uvc_stop_recording and rely
  // on uvc_stop_preview auto-finalizing the file.
  if (args.length > 3 && args[3] == 'preview-stop') {
    print('stopping preview with recording still active (auto-finalize)');
    stopPreview();
  } else {
    final int recStop = stopRecording();
    if (recStop != 0) {
      print('FAIL: stopRecording -> $recStop (${err()})');
      exit(1);
    }
    stopPreview();
  }
  if (isRecording() != 0) {
    print('FAIL: isRecording still true after stop');
    exit(1);
  }
  closeDevice();

  if (!outFile.existsSync()) {
    print('FAIL: output file missing');
    exit(1);
  }
  final int size = outFile.lengthSync();
  final List<int> head = outFile.openSync().readSync(12);
  final String brand = String.fromCharCodes(head.sublist(4, 8));
  print('output: $size bytes, header box "$brand"');
  if (size < 10 * 1024 || brand != 'ftyp') {
    print('FAIL: output does not look like a valid MP4');
    exit(1);
  }
  print('PASS');
}
