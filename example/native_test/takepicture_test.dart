import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;

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

class _UvcTakePictureTestBindings {
  _UvcTakePictureTestBindings() {
    _lib = ffi.DynamicLibrary.open('libflutter_ffi_uvc.so');
    _inject = _lib.lookupFunction<_NativeInjectFrame, _DartInjectFrame>(
      'uvc_inject_test_frame_rgba',
    );
  }

  late final ffi.DynamicLibrary _lib;
  late final _DartInjectFrame _inject;

  // Injects a solid-color RGBA frame.
  void injectSolid(int r, int g, int b, int width, int height) {
    final ffi.Pointer<ffi.Uint8> buf = calloc<ffi.Uint8>(width * height * 4);
    try {
      for (int i = 0; i < width * height; i++) {
        buf[i * 4 + 0] = r;
        buf[i * 4 + 1] = g;
        buf[i * 4 + 2] = b;
        buf[i * 4 + 3] = 255;
      }
      _inject(buf, width, height);
    } finally {
      calloc.free(buf);
    }
  }

  void dispose() => _lib.close();
}

Future<ui.Image> _decodeJpeg(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _UvcTakePictureTestBindings bindings;

  const int srcW = 32;
  const int srcH = 16;

  setUpAll(() {
    bindings = _UvcTakePictureTestBindings();
  });

  tearDownAll(() {
    bindings.dispose();
  });

  group('takePicture JPEG output', () {
    // Group-scoped so it runs after every top-level setUp in the combined
    // native-test suite (transform_test's top-level inject would otherwise
    // overwrite this frame).
    setUp(() => bindings.injectSolid(200, 40, 40, srcW, srcH));

    test('identity — valid JPEG with source dimensions', () async {
      final UvcStillPicture? picture = uvcCamera.takePicture(
        transform: UvcPreviewTransform.identity,
      );
      expect(picture, isNotNull, reason: uvcCamera.lastError);
      expect(picture!.width, srcW);
      expect(picture.height, srcH);
      expect(picture.sequence, greaterThan(0));

      // JPEG SOI / EOI markers.
      final Uint8List jpeg = picture.jpegBytes;
      expect(jpeg.length, greaterThan(4));
      expect(jpeg[0], 0xFF);
      expect(jpeg[1], 0xD8);
      expect(jpeg[jpeg.length - 2], 0xFF);
      expect(jpeg[jpeg.length - 1], 0xD9);

      // Decodable, with matching dimensions and approximately the injected
      // color (JPEG is lossy).
      final ui.Image image = await _decodeJpeg(jpeg);
      expect(image.width, srcW);
      expect(image.height, srcH);
      final ByteData? pixels = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      expect(pixels, isNotNull);
      final int centerOffset = ((srcH ~/ 2) * srcW + srcW ~/ 2) * 4;
      expect((pixels!.getUint8(centerOffset + 0) - 200).abs(), lessThan(20));
      expect((pixels.getUint8(centerOffset + 1) - 40).abs(), lessThan(20));
      expect((pixels.getUint8(centerOffset + 2) - 40).abs(), lessThan(20));
      image.dispose();
    });

    test('rotate 90° CW — encoded dimensions swapped', () async {
      final UvcStillPicture? picture = uvcCamera.takePicture(
        transform: const UvcPreviewTransform(rotation: 90),
      );
      expect(picture, isNotNull, reason: uvcCamera.lastError);
      expect(picture!.width, srcH);
      expect(picture.height, srcW);

      final ui.Image image = await _decodeJpeg(picture.jpegBytes);
      expect(image.width, srcH);
      expect(image.height, srcW);
      image.dispose();
    });

    test('quality parameter changes encoded size', () {
      final UvcStillPicture? high = uvcCamera.takePicture(
        quality: 95,
        transform: UvcPreviewTransform.identity,
      );
      final UvcStillPicture? low = uvcCamera.takePicture(
        quality: 10,
        transform: UvcPreviewTransform.identity,
      );
      expect(high, isNotNull);
      expect(low, isNotNull);
      expect(low!.jpegBytes.length, lessThan(high!.jpegBytes.length));
    });
  });
}
