import 'package:flutter/services.dart';

import 'package:flutter_ffi_uvc_example/usb/android_usb_device_entry.dart';

class AndroidUsbBridge {
  const AndroidUsbBridge({
    MethodChannel channel = const MethodChannel(
      'flutter_ffi_uvc_example/usb',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<bool> ensureCameraPermission() async {
    return await _channel.invokeMethod<bool>('ensureCameraPermission') ?? false;
  }

  Future<List<AndroidUsbDeviceEntry>> listUsbDevices() async {
    final List<Object?>? rawDevices = await _channel
        .invokeListMethod<Object?>('listUsbDevices');
    return (rawDevices ?? <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(AndroidUsbDeviceEntry.fromMap)
        .toList();
  }

  Future<int> openUsbDevice(int deviceId) async {
    final Map<Object?, Object?>? result = await _channel
        .invokeMapMethod<Object?, Object?>('openUsbDevice', <String, Object?>{
          'deviceId': deviceId,
        });
    return result?['fileDescriptor'] as int? ?? -1;
  }

  Future<void> closeUsbDevice() {
    return _channel.invokeMethod<void>('closeUsbDevice');
  }

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
