import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/flutter_ffi_uvc_bindings_generated.dart';

/// Package-wide native UVC log verbosity.
///
/// This controls logs emitted by the shared native camera session. Because this
/// package exposes a single shared native session, the configured level applies
/// globally rather than per device instance.
enum UvcLogLevel {
  error(0),
  warn(1),
  info(2),
  debug(3),
  trace(4);

  const UvcLogLevel(this.nativeValue);

  final int nativeValue;
}

/// Public identifier for a UVC camera control.
///
/// Known standard controls are exposed as static constants. Unknown or
/// vendor-specific controls can still be represented through [fromNativeValue].
final class UvcControlId {
  const UvcControlId._(this.nativeValue, this.debugName);

  factory UvcControlId.fromNativeValue(int nativeValue) {
    return switch (nativeValue) {
      UVC_CTRL_ID_BRIGHTNESS => brightness,
      UVC_CTRL_ID_CONTRAST => contrast,
      UVC_CTRL_ID_HUE => hue,
      UVC_CTRL_ID_SATURATION => saturation,
      UVC_CTRL_ID_SHARPNESS => sharpness,
      UVC_CTRL_ID_GAMMA => gamma,
      UVC_CTRL_ID_GAIN => gain,
      UVC_CTRL_ID_BACKLIGHT_COMPENSATION => backlightCompensation,
      UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE => whiteBalanceTemperature,
      UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO => whiteBalanceTemperatureAuto,
      UVC_CTRL_ID_POWER_LINE_FREQUENCY => powerLineFrequency,
      UVC_CTRL_ID_CONTRAST_AUTO => contrastAuto,
      UVC_CTRL_ID_HUE_AUTO => hueAuto,
      UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO => whiteBalanceComponentAuto,
      UVC_CTRL_ID_DIGITAL_MULTIPLIER => digitalMultiplier,
      UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT => digitalMultiplierLimit,
      UVC_CTRL_ID_ANALOG_VIDEO_STANDARD => analogVideoStandard,
      UVC_CTRL_ID_ANALOG_LOCK_STATUS => analogLockStatus,
      UVC_CTRL_ID_SCANNING_MODE => scanningMode,
      UVC_CTRL_ID_EXPOSURE_ABS => exposureAbs,
      UVC_CTRL_ID_EXPOSURE_REL => exposureRel,
      UVC_CTRL_ID_AE_MODE => aeMode,
      UVC_CTRL_ID_AE_PRIORITY => aePriority,
      UVC_CTRL_ID_FOCUS_ABS => focusAbs,
      UVC_CTRL_ID_FOCUS_AUTO => focusAuto,
      UVC_CTRL_ID_IRIS_ABS => irisAbs,
      UVC_CTRL_ID_IRIS_REL => irisRel,
      UVC_CTRL_ID_ZOOM_ABS => zoomAbs,
      UVC_CTRL_ID_ROLL_ABS => rollAbs,
      UVC_CTRL_ID_PRIVACY => privacy,
      UVC_CTRL_ID_FOCUS_SIMPLE => focusSimple,
      _ => UvcControlId._(nativeValue, 'unknown($nativeValue)'),
    };
  }

  static const UvcControlId brightness = UvcControlId._(
    UVC_CTRL_ID_BRIGHTNESS,
    'brightness',
  );
  static const UvcControlId contrast = UvcControlId._(
    UVC_CTRL_ID_CONTRAST,
    'contrast',
  );
  static const UvcControlId hue = UvcControlId._(UVC_CTRL_ID_HUE, 'hue');
  static const UvcControlId saturation = UvcControlId._(
    UVC_CTRL_ID_SATURATION,
    'saturation',
  );
  static const UvcControlId sharpness = UvcControlId._(
    UVC_CTRL_ID_SHARPNESS,
    'sharpness',
  );
  static const UvcControlId gamma = UvcControlId._(UVC_CTRL_ID_GAMMA, 'gamma');
  static const UvcControlId gain = UvcControlId._(UVC_CTRL_ID_GAIN, 'gain');
  static const UvcControlId backlightCompensation = UvcControlId._(
    UVC_CTRL_ID_BACKLIGHT_COMPENSATION,
    'backlightCompensation',
  );
  static const UvcControlId whiteBalanceTemperature = UvcControlId._(
    UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE,
    'whiteBalanceTemperature',
  );
  static const UvcControlId whiteBalanceTemperatureAuto = UvcControlId._(
    UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO,
    'whiteBalanceTemperatureAuto',
  );
  static const UvcControlId powerLineFrequency = UvcControlId._(
    UVC_CTRL_ID_POWER_LINE_FREQUENCY,
    'powerLineFrequency',
  );
  static const UvcControlId contrastAuto = UvcControlId._(
    UVC_CTRL_ID_CONTRAST_AUTO,
    'contrastAuto',
  );
  static const UvcControlId hueAuto = UvcControlId._(
    UVC_CTRL_ID_HUE_AUTO,
    'hueAuto',
  );
  static const UvcControlId whiteBalanceComponentAuto = UvcControlId._(
    UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO,
    'whiteBalanceComponentAuto',
  );
  static const UvcControlId digitalMultiplier = UvcControlId._(
    UVC_CTRL_ID_DIGITAL_MULTIPLIER,
    'digitalMultiplier',
  );
  static const UvcControlId digitalMultiplierLimit = UvcControlId._(
    UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT,
    'digitalMultiplierLimit',
  );
  static const UvcControlId analogVideoStandard = UvcControlId._(
    UVC_CTRL_ID_ANALOG_VIDEO_STANDARD,
    'analogVideoStandard',
  );
  static const UvcControlId analogLockStatus = UvcControlId._(
    UVC_CTRL_ID_ANALOG_LOCK_STATUS,
    'analogLockStatus',
  );
  static const UvcControlId scanningMode = UvcControlId._(
    UVC_CTRL_ID_SCANNING_MODE,
    'scanningMode',
  );
  static const UvcControlId exposureAbs = UvcControlId._(
    UVC_CTRL_ID_EXPOSURE_ABS,
    'exposureAbs',
  );
  static const UvcControlId exposureRel = UvcControlId._(
    UVC_CTRL_ID_EXPOSURE_REL,
    'exposureRel',
  );
  static const UvcControlId aeMode = UvcControlId._(
    UVC_CTRL_ID_AE_MODE,
    'aeMode',
  );
  static const UvcControlId aePriority = UvcControlId._(
    UVC_CTRL_ID_AE_PRIORITY,
    'aePriority',
  );
  static const UvcControlId focusAbs = UvcControlId._(
    UVC_CTRL_ID_FOCUS_ABS,
    'focusAbs',
  );
  static const UvcControlId focusAuto = UvcControlId._(
    UVC_CTRL_ID_FOCUS_AUTO,
    'focusAuto',
  );
  static const UvcControlId irisAbs = UvcControlId._(
    UVC_CTRL_ID_IRIS_ABS,
    'irisAbs',
  );
  static const UvcControlId irisRel = UvcControlId._(
    UVC_CTRL_ID_IRIS_REL,
    'irisRel',
  );
  static const UvcControlId zoomAbs = UvcControlId._(
    UVC_CTRL_ID_ZOOM_ABS,
    'zoomAbs',
  );
  static const UvcControlId rollAbs = UvcControlId._(
    UVC_CTRL_ID_ROLL_ABS,
    'rollAbs',
  );
  static const UvcControlId privacy = UvcControlId._(
    UVC_CTRL_ID_PRIVACY,
    'privacy',
  );
  static const UvcControlId focusSimple = UvcControlId._(
    UVC_CTRL_ID_FOCUS_SIMPLE,
    'focusSimple',
  );

  final int nativeValue;
  final String debugName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UvcControlId && other.nativeValue == nativeValue;

  @override
  int get hashCode => nativeValue.hashCode;

  @override
  String toString() => 'UvcControlId($debugName)';
}

/// UI/interaction kind for a control value.
enum UvcControlKind {
  integer,
  boolean,
  enumLike;

  static UvcControlKind fromUiType(String uiType) {
    return switch (uiType) {
      'bool' => UvcControlKind.boolean,
      'enum' => UvcControlKind.enumLike,
      _ => UvcControlKind.integer,
    };
  }
}

/// A single preview frame copied from the native shared camera state.
class UvcPreviewFrame {
  const UvcPreviewFrame({
    required this.width,
    required this.height,
    required this.rgbaBytes,
  });

  final int width;
  final int height;
  final Uint8List rgbaBytes;
}

/// A camera mode reported by the native UVC layer.
class UvcCameraMode {
  const UvcCameraMode({
    required this.frameFormat,
    required this.formatName,
    required this.width,
    required this.height,
    required this.fps,
  });

  factory UvcCameraMode.fromJson(Map<String, dynamic> json) {
    return UvcCameraMode(
      frameFormat: json['format'] as int,
      formatName: json['formatName'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      fps: json['fps'] as int,
    );
  }

  final int frameFormat;
  final String formatName;
  final int width;
  final int height;
  final int fps;

  String get label => '$formatName ${width}x$height @ ${fps}fps';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'format': frameFormat,
      'formatName': formatName,
      'width': width,
      'height': height,
      'fps': fps,
    };
  }
}

/// Metadata and current value for a UVC control exposed by the device.
class UvcCameraControl {
  const UvcCameraControl({
    required this.id,
    required this.name,
    required this.label,
    required this.kind,
    required this.min,
    required this.max,
    required this.def,
    required this.cur,
    required this.res,
  });

  factory UvcCameraControl.fromJson(Map<String, dynamic> json) {
    return UvcCameraControl(
      id: UvcControlId.fromNativeValue(json['id'] as int),
      name: json['name'] as String,
      label: json['label'] as String,
      kind: UvcControlKind.fromUiType(json['uiType'] as String),
      min: json['min'] as int,
      max: json['max'] as int,
      def: json['def'] as int,
      cur: json['cur'] as int,
      res: json['res'] as int,
    );
  }

  /// Stable public identifier for the control.
  final UvcControlId id;
  final String name;

  /// Human-readable label from the native layer for display purposes.
  final String label;

  /// Value shape and common UI representation for this control.
  final UvcControlKind kind;

  final int min;
  final int max;
  final int def;
  final int cur;

  /// Step/resolution.
  final int res;

  UvcCameraControl copyWithCur(int newCur) => UvcCameraControl(
    id: id,
    name: name,
    label: label,
    kind: kind,
    min: min,
    max: max,
    def: def,
    cur: newCur,
    res: res,
  );
}

/// Control metadata reported from descriptor bmControls without GET_* probing.
class UvcBmControlInfo {
  const UvcBmControlInfo({
    required this.id,
    required this.name,
    required this.label,
    required this.kind,
  });

  factory UvcBmControlInfo.fromJson(Map<String, dynamic> json) {
    return UvcBmControlInfo(
      id: UvcControlId.fromNativeValue(json['id'] as int),
      name: json['name'] as String,
      label: json['label'] as String,
      kind: UvcControlKind.fromUiType(json['uiType'] as String),
    );
  }

  final UvcControlId id;
  final String name;
  final String label;
  final UvcControlKind kind;
}

class UvcWhiteBalanceComponent {
  const UvcWhiteBalanceComponent({required this.blue, required this.red});

  factory UvcWhiteBalanceComponent.fromJson(Map<String, dynamic> json) {
    return UvcWhiteBalanceComponent(
      blue: json['blue'] as int,
      red: json['red'] as int,
    );
  }

  final int blue;
  final int red;
}

class UvcFocusRelativeControl {
  const UvcFocusRelativeControl({required this.focusRel, required this.speed});

  factory UvcFocusRelativeControl.fromJson(Map<String, dynamic> json) {
    return UvcFocusRelativeControl(
      focusRel: json['focusRel'] as int,
      speed: json['speed'] as int,
    );
  }

  final int focusRel;
  final int speed;
}

class UvcZoomRelativeControl {
  const UvcZoomRelativeControl({
    required this.zoomRel,
    required this.digitalZoom,
    required this.speed,
  });

  factory UvcZoomRelativeControl.fromJson(Map<String, dynamic> json) {
    return UvcZoomRelativeControl(
      zoomRel: json['zoomRel'] as int,
      digitalZoom: json['digitalZoom'] as int,
      speed: json['speed'] as int,
    );
  }

  final int zoomRel;
  final int digitalZoom;
  final int speed;
}

class UvcPanTiltAbsoluteControl {
  const UvcPanTiltAbsoluteControl({required this.pan, required this.tilt});

  factory UvcPanTiltAbsoluteControl.fromJson(Map<String, dynamic> json) {
    return UvcPanTiltAbsoluteControl(
      pan: json['pan'] as int,
      tilt: json['tilt'] as int,
    );
  }

  final int pan;
  final int tilt;
}

class UvcPanTiltRelativeControl {
  const UvcPanTiltRelativeControl({
    required this.panRel,
    required this.panSpeed,
    required this.tiltRel,
    required this.tiltSpeed,
  });

  factory UvcPanTiltRelativeControl.fromJson(Map<String, dynamic> json) {
    return UvcPanTiltRelativeControl(
      panRel: json['panRel'] as int,
      panSpeed: json['panSpeed'] as int,
      tiltRel: json['tiltRel'] as int,
      tiltSpeed: json['tiltSpeed'] as int,
    );
  }

  final int panRel;
  final int panSpeed;
  final int tiltRel;
  final int tiltSpeed;
}

class UvcRollRelativeControl {
  const UvcRollRelativeControl({required this.rollRel, required this.speed});

  factory UvcRollRelativeControl.fromJson(Map<String, dynamic> json) {
    return UvcRollRelativeControl(
      rollRel: json['rollRel'] as int,
      speed: json['speed'] as int,
    );
  }

  final int rollRel;
  final int speed;
}

class UvcDigitalWindowControl {
  const UvcDigitalWindowControl({
    required this.windowTop,
    required this.windowLeft,
    required this.windowBottom,
    required this.windowRight,
    required this.numSteps,
    required this.numStepsUnits,
  });

  factory UvcDigitalWindowControl.fromJson(Map<String, dynamic> json) {
    return UvcDigitalWindowControl(
      windowTop: json['windowTop'] as int,
      windowLeft: json['windowLeft'] as int,
      windowBottom: json['windowBottom'] as int,
      windowRight: json['windowRight'] as int,
      numSteps: json['numSteps'] as int,
      numStepsUnits: json['numStepsUnits'] as int,
    );
  }

  final int windowTop;
  final int windowLeft;
  final int windowBottom;
  final int windowRight;
  final int numSteps;
  final int numStepsUnits;
}

class UvcRegionOfInterestControl {
  const UvcRegionOfInterestControl({
    required this.roiTop,
    required this.roiLeft,
    required this.roiBottom,
    required this.roiRight,
    required this.autoControls,
  });

  factory UvcRegionOfInterestControl.fromJson(Map<String, dynamic> json) {
    return UvcRegionOfInterestControl(
      roiTop: json['roiTop'] as int,
      roiLeft: json['roiLeft'] as int,
      roiBottom: json['roiBottom'] as int,
      roiRight: json['roiRight'] as int,
      autoControls: json['autoControls'] as int,
    );
  }

  final int roiTop;
  final int roiLeft;
  final int roiBottom;
  final int roiRight;
  final int autoControls;
}

/// High-level camera API for the shared native UVC session.
///
/// This package exposes a single shared camera service through [uvcCamera].
/// The implementation wraps native global state, so it does not model multiple
/// independent camera instances in Dart.
abstract interface class UvcCamera {
  /// Sets the package-wide native UVC log level.
  ///
  /// This may be called before opening a device or while a device is already
  /// active. The setting applies to the shared native camera session.
  void setLogLevel(UvcLogLevel level);

  /// Opens a UVC device using an already acquired platform file descriptor.
  int openFd(int fd);

  /// Starts preview with the given [mode].
  int startPreview(UvcCameraMode mode);

  /// Stops the active preview stream.
  void stopPreview();

  /// Closes the active native device/session.
  void closeDevice();

  /// Whether the shared native preview stream is currently running.
  bool get isPreviewing;

  /// Last error message reported by the native layer.
  String get lastError;

  /// Copies the latest RGBA frame from the shared native preview buffer.
  UvcPreviewFrame? copyLatestFrame();

  /// Returns all controls supported by the currently opened device.
  List<UvcCameraControl> supportedControls();

  /// Returns controls present in descriptor bmControls without GET_* probing.
  ///
  /// Intended for debugging device quirks where descriptor exposure and
  /// readable/writable behavior differ.
  List<UvcBmControlInfo> debugBmControls();

  /// Returns the current value for a specific UVC control.
  int? getControl(UvcControlId controlId);

  /// Sets a specific UVC control value.
  int setControl(UvcControlId controlId, int value);

  UvcWhiteBalanceComponent? getWhiteBalanceComponent();
  int setWhiteBalanceComponent(UvcWhiteBalanceComponent value);
  UvcFocusRelativeControl? getFocusRelativeControl();
  int setFocusRelativeControl(UvcFocusRelativeControl value);
  UvcZoomRelativeControl? getZoomRelativeControl();
  int setZoomRelativeControl(UvcZoomRelativeControl value);
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl();
  int setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value);
  UvcPanTiltRelativeControl? getPanTiltRelativeControl();
  int setPanTiltRelativeControl(UvcPanTiltRelativeControl value);
  UvcRollRelativeControl? getRollRelativeControl();
  int setRollRelativeControl(UvcRollRelativeControl value);
  UvcDigitalWindowControl? getDigitalWindowControl();
  int setDigitalWindowControl(UvcDigitalWindowControl value);
  UvcRegionOfInterestControl? getRegionOfInterestControl();
  int setRegionOfInterestControl(UvcRegionOfInterestControl value);

  /// Returns the camera modes reported by the currently opened device.
  List<UvcCameraMode> supportedModes();
}

class _FlutterFfiUvcCamera implements UvcCamera {
  const _FlutterFfiUvcCamera();

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
  int openFd(int fd) => _bindings.uvc_open_fd(fd);

  @override
  int startPreview(UvcCameraMode mode) {
    return _bindings.uvc_start_preview(
      mode.frameFormat,
      mode.width,
      mode.height,
      mode.fps,
    );
  }

  @override
  void stopPreview() => _bindings.uvc_stop_preview();

  @override
  void closeDevice() => _bindings.uvc_close_device();

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
  UvcPreviewFrame? copyLatestFrame() {
    final int width = _bindings.uvc_frame_width();
    final int height = _bindings.uvc_frame_height();
    if (width <= 0 || height <= 0) {
      return null;
    }

    final int expectedBytes = width * height * 4;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(expectedBytes);
    try {
      final int copiedBytes = _bindings.uvc_copy_latest_frame_rgba(
        nativeBuffer,
        expectedBytes,
      );
      if (copiedBytes <= 0) {
        return null;
      }
      return UvcPreviewFrame(
        width: width,
        height: height,
        rgbaBytes: Uint8List.fromList(nativeBuffer.asTypedList(copiedBytes)),
      );
    } finally {
      calloc.free(nativeBuffer);
    }
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
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'flutter_ffi_uvc is supported only on Android.',
    );
  }
  return _cachedDylib ??= DynamicLibrary.open('lib$_libName.so');
}

FlutterFfiUvcBindings get _bindings =>
    _cachedBindings ??= FlutterFfiUvcBindings(_dylib);

/// Shared package-level UVC camera service.
///
/// Import `package:flutter_ffi_uvc/flutter_ffi_uvc.dart` and use this object
/// directly instead of instantiating your own camera wrapper or using the
/// generated bindings. The generated bindings are an implementation detail.
const UvcCamera uvcCamera = _FlutterFfiUvcCamera();
