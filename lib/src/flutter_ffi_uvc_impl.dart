import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'flutter_ffi_uvc_bindings_generated.dart';
import 'uvc_camera_api.dart';

class _FlutterFfiUvcCamera implements UvcCamera {
  _FlutterFfiUvcCamera();
  static const MethodChannel _textureChannel = MethodChannel(
    'flutter_ffi_uvc/texture',
  );
  static const MethodChannel _usbChannel = MethodChannel('flutter_ffi_uvc/usb');

  void _resetPreviewState() {}

  UvcPreviewFrame? _copyFrameWithMetadata(
    int Function(
      Pointer<Uint8> buffer,
      int bufferLength,
      Pointer<Int> width,
      Pointer<Int> height,
      Pointer<Int64> sequence,
    )
    nativeCopy,
  ) {
    final int width = _bindings.uvc_frame_width();
    final int height = _bindings.uvc_frame_height();
    if (width <= 0 || height <= 0) {
      return null;
    }

    final int expectedBytes = width * height * 4;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(expectedBytes);
    final Pointer<Int> nativeWidth = calloc<Int>();
    final Pointer<Int> nativeHeight = calloc<Int>();
    final Pointer<Int64> nativeSequence = calloc<Int64>();
    try {
      final int copiedBytes = nativeCopy(
        nativeBuffer,
        expectedBytes,
        nativeWidth,
        nativeHeight,
        nativeSequence,
      );
      if (copiedBytes <= 0) {
        return null;
      }
      return UvcPreviewFrame(
        width: nativeWidth.value,
        height: nativeHeight.value,
        rgbaBytes: Uint8List.fromList(nativeBuffer.asTypedList(copiedBytes)),
        sequence: nativeSequence.value,
      );
    } finally {
      calloc.free(nativeBuffer);
      calloc.free(nativeWidth);
      calloc.free(nativeHeight);
      calloc.free(nativeSequence);
    }
  }

  UvcPreviewFrame? _copyLatestFrameInternal() => _copyFrameWithMetadata(
    _bindings.uvc_copy_latest_frame_rgba_with_metadata,
  );

  @override
  void setLogLevel(UvcLogLevel level) {
    _bindings.uvc_set_log_level(level.nativeValue);
  }

  T? _readJsonObject<T>(
    int Function(Pointer<Uint8> buffer, int bufferLength) nativeCall,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    const int bufferLength = 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = nativeCall(nativeBuffer, bufferLength);
      if (copiedBytes <= 0) {
        return null;
      }
      final String jsonString = nativeBuffer.cast<Utf8>().toDartString(
        length: copiedBytes,
      );
      return fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
    } finally {
      calloc.free(nativeBuffer);
    }
  }

  @override
  Future<bool> ensureCameraPermission() async {
    _ensureAndroid();
    return await _usbChannel.invokeMethod<bool>('ensureCameraPermission') ??
        false;
  }

  @override
  Future<List<UvcUsbDevice>> listUsbDevices() async {
    _ensureAndroid();
    final List<Object?>? raw =
        await _usbChannel.invokeListMethod<Object?>('listUsbDevices');
    return (raw ?? <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(UvcUsbDevice.fromMap)
        .toList();
  }

  @override
  Future<int> openUsbDevice(int deviceId) async {
    _ensureAndroid();
    final Map<Object?, Object?>? result = await _usbChannel
        .invokeMapMethod<Object?, Object?>(
      'openUsbDevice',
      <String, Object?>{'deviceId': deviceId},
    );
    final int fd = result?['fileDescriptor'] as int? ?? -1;
    return openFd(fd);
  }

  @override
  Future<void> closeUsbDevice() async {
    _ensureAndroid();
    _bindings.uvc_close_device();
    await _usbChannel.invokeMethod<void>('closeUsbDevice');
  }

  @override
  int openFd(int fd) => _bindings.uvc_open_fd(fd);

  @override
  int startPreview(UvcCameraMode mode) {
    _resetPreviewState();
    final int startResult = _bindings.uvc_start_preview(
      mode.frameFormat,
      mode.width,
      mode.height,
      mode.fps,
    );
    if (startResult != 0) {
      return startResult;
    }
    return startResult;
  }

  @override
  void stopPreview() {
    _bindings.uvc_stop_preview();
    _resetPreviewState();
  }

  @override
  void closeFd() {
    _bindings.uvc_close_device();
    _resetPreviewState();
  }

  @override
  void closeDevice() => closeFd();

  @override
  bool get isPreviewing => _bindings.uvc_is_previewing() != 0;

  @override
  String get lastError {
    final Pointer<Char> pointer = _bindings.uvc_last_error().cast<Char>();
    if (pointer == nullptr) {
      return '';
    }
    return pointer.cast<Utf8>().toDartString();
  }

  @override
  UvcPreviewFrame? copyLatestFrame() => _copyLatestFrameInternal();

  @override
  int latestFrameSequence() => _bindings.uvc_latest_frame_sequence();

  @override
  Future<int> createPreviewTexture() async {
    _ensureAndroid();
    final int? textureId = await _textureChannel.invokeMethod<int>(
      'createPreviewTexture',
    );
    if (textureId == null) {
      throw PlatformException(
        code: 'texture_create_failed',
        message: 'Texture creation returned null.',
      );
    }
    return textureId;
  }

  @override
  Future<void> disposePreviewTexture(int textureId) async {
    _ensureAndroid();
    await _textureChannel.invokeMethod<void>(
      'disposePreviewTexture',
      <String, Object?>{'textureId': textureId},
    );
  }

  @override
  Future<void> attachPreviewTexture(
    int textureId, {
    int? width,
    int? height,
  }) async {
    _ensureAndroid();
    await _textureChannel.invokeMethod<void>(
      'attachPreviewTexture',
      <String, Object?>{
        'textureId': textureId,
        ...?width == null ? null : <String, Object?>{'width': width},
        ...?height == null ? null : <String, Object?>{'height': height},
      },
    );
  }

  /// Returns all controls the connected device supports, including current
  /// value and range info. Returns an empty list if no device is open or
  /// the device exposes no UVC controls.
  @override
  List<UvcCameraControl> supportedControls() {
    const int bufferLength = 32 * 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = _bindings.uvc_ctrl_get_all_json(
        nativeBuffer,
        bufferLength,
      );
      if (copiedBytes <= 0) {
        return const <UvcCameraControl>[];
      }
      final String jsonString = nativeBuffer.cast<Utf8>().toDartString(
        length: copiedBytes,
      );
      final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded
          .map(
            (dynamic item) =>
                UvcCameraControl.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } finally {
      calloc.free(nativeBuffer);
    }
  }

  @override
  List<UvcBmControlInfo> debugBmControls() {
    const int bufferLength = 16 * 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = _bindings.uvc_ctrl_get_bm_controls_json(
        nativeBuffer,
        bufferLength,
      );
      if (copiedBytes <= 0) {
        return const <UvcBmControlInfo>[];
      }
      final String jsonString = nativeBuffer.cast<Utf8>().toDartString(
        length: copiedBytes,
      );
      final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded
          .map(
            (dynamic item) =>
                UvcBmControlInfo.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } finally {
      calloc.free(nativeBuffer);
    }
  }

  /// Returns the current value of [controlId]. Returns null if the device is
  /// not open or the control is not supported.
  @override
  int? getControl(UvcControlId controlId) {
    final int result = _bindings.uvc_ctrl_get(controlId.nativeValue);
    // INT32_MIN == -2147483648 signals an error from the native layer
    if (result == -2147483648) {
      return null;
    }
    return result;
  }

  /// Sets [controlId] to [value]. Returns 0 on success, negative on error.
  @override
  int setControl(UvcControlId controlId, int value) =>
      _bindings.uvc_ctrl_set(controlId.nativeValue, value);

  @override
  UvcWhiteBalanceComponent? getWhiteBalanceComponent() => _readJsonObject(
    _bindings.uvc_get_white_balance_component_json,
    UvcWhiteBalanceComponent.fromJson,
  );

  @override
  int setWhiteBalanceComponent(UvcWhiteBalanceComponent value) =>
      _bindings.uvc_set_white_balance_component_values(value.blue, value.red);

  @override
  UvcFocusRelativeControl? getFocusRelativeControl() => _readJsonObject(
    _bindings.uvc_get_focus_rel_json,
    UvcFocusRelativeControl.fromJson,
  );

  @override
  int setFocusRelativeControl(UvcFocusRelativeControl value) =>
      _bindings.uvc_set_focus_rel_values(value.focusRel, value.speed);

  @override
  UvcZoomRelativeControl? getZoomRelativeControl() => _readJsonObject(
    _bindings.uvc_get_zoom_rel_json,
    UvcZoomRelativeControl.fromJson,
  );

  @override
  int setZoomRelativeControl(UvcZoomRelativeControl value) => _bindings
      .uvc_set_zoom_rel_values(value.zoomRel, value.digitalZoom, value.speed);

  @override
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_abs_json,
    UvcPanTiltAbsoluteControl.fromJson,
  );

  @override
  int setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value) =>
      _bindings.uvc_set_pantilt_abs_values(value.pan, value.tilt);

  @override
  UvcPanTiltRelativeControl? getPanTiltRelativeControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_rel_json,
    UvcPanTiltRelativeControl.fromJson,
  );

  @override
  int setPanTiltRelativeControl(UvcPanTiltRelativeControl value) =>
      _bindings.uvc_set_pantilt_rel_values(
        value.panRel,
        value.panSpeed,
        value.tiltRel,
        value.tiltSpeed,
      );

  @override
  UvcRollRelativeControl? getRollRelativeControl() => _readJsonObject(
    _bindings.uvc_get_roll_rel_json,
    UvcRollRelativeControl.fromJson,
  );

  @override
  int setRollRelativeControl(UvcRollRelativeControl value) =>
      _bindings.uvc_set_roll_rel_values(value.rollRel, value.speed);

  @override
  UvcDigitalWindowControl? getDigitalWindowControl() => _readJsonObject(
    _bindings.uvc_get_digital_window_json,
    UvcDigitalWindowControl.fromJson,
  );

  @override
  int setDigitalWindowControl(UvcDigitalWindowControl value) =>
      _bindings.uvc_set_digital_window_values(
        value.windowTop,
        value.windowLeft,
        value.windowBottom,
        value.windowRight,
        value.numSteps,
        value.numStepsUnits,
      );

  @override
  UvcRegionOfInterestControl? getRegionOfInterestControl() => _readJsonObject(
    _bindings.uvc_get_region_of_interest_json,
    UvcRegionOfInterestControl.fromJson,
  );

  @override
  int setRegionOfInterestControl(UvcRegionOfInterestControl value) =>
      _bindings.uvc_set_region_of_interest_values(
        value.roiTop,
        value.roiLeft,
        value.roiBottom,
        value.roiRight,
        value.autoControls,
      );

  @override
  List<UvcCameraMode> supportedModes() {
    const int bufferLength = 64 * 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = _bindings.uvc_get_supported_modes_json(
        nativeBuffer,
        bufferLength,
      );
      if (copiedBytes <= 0) {
        return const <UvcCameraMode>[];
      }

      final String jsonString = nativeBuffer.cast<Utf8>().toDartString(
        length: copiedBytes,
      );
      final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded
          .map(
            (dynamic item) =>
                UvcCameraMode.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } finally {
      calloc.free(nativeBuffer);
    }
  }
}

const String _libName = 'flutter_ffi_uvc';

DynamicLibrary? _cachedDylib;
FlutterFfiUvcBindings? _cachedBindings;

DynamicLibrary get _dylib {
  _ensureAndroid();
  return _cachedDylib ??= DynamicLibrary.open('lib$_libName.so');
}

void _ensureAndroid() {
  if (!Platform.isAndroid) {
    throw UnsupportedError('flutter_ffi_uvc is supported only on Android.');
  }
}

FlutterFfiUvcBindings get _bindings =>
    _cachedBindings ??= FlutterFfiUvcBindings(_dylib);

/// Shared package-level UVC camera service.
///
/// Import `package:flutter_ffi_uvc/flutter_ffi_uvc.dart` and use this object
/// directly instead of instantiating your own camera wrapper or using the
/// generated bindings. The generated bindings are an implementation detail.
final UvcCamera uvcCamera = _FlutterFfiUvcCamera();
