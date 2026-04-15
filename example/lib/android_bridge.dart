import 'package:flutter/services.dart';

class AndroidBridge {
  const AndroidBridge({
    MethodChannel channel = const MethodChannel(
      'flutter_ffi_uvc_example/gallery',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<String?> saveImageToGallery(
    List<int> bytes, {
    required String displayName,
    String mimeType = 'image/png',
  }) {
    return _channel.invokeMethod<String>('saveImageToGallery', <String, Object?>{
      'bytes': bytes,
      'displayName': displayName,
      'mimeType': mimeType,
    });
  }
}
