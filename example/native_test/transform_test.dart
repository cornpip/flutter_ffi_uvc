import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ---------------------------------------------------------------------------
// Test-only bindings for uvc_inject_test_frame_rgba.
// Not declared in the public header.
// ---------------------------------------------------------------------------

typedef _NativeInjectFrame = ffi.Void Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int,
  ffi.Int,
);
typedef _DartInjectFrame = void Function(ffi.Pointer<ffi.Uint8>, int, int);

class _UvcTransformTestBindings {
  _UvcTransformTestBindings() {
    _lib = ffi.DynamicLibrary.open('libflutter_ffi_uvc.so');
    _inject = _lib.lookupFunction<_NativeInjectFrame, _DartInjectFrame>(
      'uvc_inject_test_frame_rgba',
    );
  }

  late final ffi.DynamicLibrary _lib;
  late final _DartInjectFrame _inject;

  // Injects a flat list of pixel R values as an RGBA buffer.
  // G=B=0, A=255 for each pixel, so R uniquely identifies the pixel.
  void injectGrid(List<int> rValues, int width, int height) {
    assert(rValues.length == width * height);
    final ffi.Pointer<ffi.Uint8> buf = calloc<ffi.Uint8>(width * height * 4);
    try {
      for (int i = 0; i < rValues.length; i++) {
        buf[i * 4 + 0] = rValues[i]; // R
        buf[i * 4 + 1] = 0;          // G
        buf[i * 4 + 2] = 0;          // B
        buf[i * 4 + 3] = 255;        // A
      }
      _inject(buf, width, height);
    } finally {
      calloc.free(buf);
    }
  }

  void dispose() => _lib.close();
}

// Extracts R values from an RGBA frame in row-major order.
List<int> _rValues(UvcPreviewFrame frame) {
  final Uint8List bytes = frame.rgbaBytes;
  return List<int>.generate(
    frame.width * frame.height,
    (int i) => bytes[i * 4],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _UvcTransformTestBindings bindings;

  // Grid layout (width=2, height=3):
  //   (r=0,c=0)=1  (r=0,c=1)=2
  //   (r=1,c=0)=3  (r=1,c=1)=4
  //   (r=2,c=0)=5  (r=2,c=1)=6
  const int srcW = 2;
  const int srcH = 3;
  const List<int> grid = <int>[1, 2, 3, 4, 5, 6];

  setUpAll(() {
    bindings = _UvcTransformTestBindings();
  });

  tearDownAll(() {
    bindings.dispose();
  });

  setUp(() => bindings.injectGrid(grid, srcW, srcH));

  group('copyLatestFrameTransformed pixel output', () {
    test('identity — pixels unchanged', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        UvcPreviewTransform.identity,
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcW);
      expect(frame.height, srcH);
      expect(_rValues(frame), <int>[1, 2, 3, 4, 5, 6]);
    });

    test('rotate 90° CW — dimensions swapped, pixels remapped', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        const UvcPreviewTransform(rotation: 90),
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcH);  // 3
      expect(frame.height, srcW);  // 2
      expect(_rValues(frame), <int>[5, 3, 1, 6, 4, 2]);
    });

    test('rotate 180° — dimensions unchanged, pixels remapped', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        const UvcPreviewTransform(rotation: 180),
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcW);
      expect(frame.height, srcH);
      expect(_rValues(frame), <int>[6, 5, 4, 3, 2, 1]);
    });

    test('rotate 270° CW — dimensions swapped, pixels remapped', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        const UvcPreviewTransform(rotation: 270),
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcH);  // 3
      expect(frame.height, srcW);  // 2
      expect(_rValues(frame), <int>[2, 4, 6, 1, 3, 5]);
    });

    test('flip horizontal — pixels mirrored left-right', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        const UvcPreviewTransform(flipHorizontal: true),
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcW);
      expect(frame.height, srcH);
      expect(_rValues(frame), <int>[2, 1, 4, 3, 6, 5]);
    });

    test('flip vertical — pixels mirrored top-bottom', () {
      final UvcPreviewFrame? frame = uvcCamera.copyLatestFrameTransformed(
        const UvcPreviewTransform(flipVertical: true),
      );
      expect(frame, isNotNull);
      expect(frame!.width, srcW);
      expect(frame.height, srcH);
      expect(_rValues(frame), <int>[5, 6, 3, 4, 1, 2]);
    });
  });
}
