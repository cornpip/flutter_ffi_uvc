import 'dart:typed_data';

import 'flutter_ffi_uvc_bindings_generated.dart';

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

/// Typed error codes reported by the native UVC layer.
///
/// These mirror the `uvc_error_t` codes from libuvc. APIs that return a raw
/// `int` error code can be mapped through [fromNativeValue].
enum UvcErrorCode {
  /// Input/output error.
  io(-1),

  /// Invalid parameter.
  invalidParam(-2),

  /// Access denied.
  access(-3),

  /// No such device — including a device that was disconnected mid-session.
  noDevice(-4),

  /// Entity not found.
  notFound(-5),

  /// Resource busy.
  busy(-6),

  /// Operation timed out.
  timeout(-7),

  /// Overflow.
  overflow(-8),

  /// Pipe error.
  pipe(-9),

  /// System call interrupted.
  interrupted(-10),

  /// Insufficient memory.
  noMem(-11),

  /// Operation not supported.
  notSupported(-12),

  /// Device is not UVC-compliant.
  invalidDevice(-50),

  /// The requested mode is not supported.
  invalidMode(-51),

  /// Resource has a callback (can't use polling and async).
  callbackExists(-52),

  /// Undefined or unknown error.
  other(-99);

  const UvcErrorCode(this.nativeValue);

  final int nativeValue;

  /// Maps a raw native return code to a typed error code.
  ///
  /// Returns null for `0` (success). Unknown non-zero codes map to [other].
  static UvcErrorCode? fromNativeValue(int nativeValue) {
    if (nativeValue == 0) return null;
    for (final UvcErrorCode code in UvcErrorCode.values) {
      if (code.nativeValue == nativeValue) return code;
    }
    return UvcErrorCode.other;
  }
}

/// Exception carrying a typed UVC error code alongside the native code and
/// the last native error message, for APIs and helpers that throw instead of
/// returning raw integer codes.
class UvcException implements Exception {
  const UvcException({
    required this.code,
    this.nativeCode = 0,
    this.message = '',
  });

  /// Creates an exception from a raw native return code.
  factory UvcException.fromNativeCode(int nativeCode, {String message = ''}) {
    return UvcException(
      code: UvcErrorCode.fromNativeValue(nativeCode) ?? UvcErrorCode.other,
      nativeCode: nativeCode,
      message: message,
    );
  }

  final UvcErrorCode code;
  final int nativeCode;
  final String message;

  @override
  String toString() =>
      'UvcException(${code.name}, nativeCode: $nativeCode'
      '${message.isEmpty ? '' : ', $message'})';
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
    this.sequence = 0,
  });

  final int width;
  final int height;
  final Uint8List rgbaBytes;
  final int sequence;
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

/// An error reported by the native frame pipeline during streaming.
///
/// These are errors that occur inside the frame callback — decode failures,
/// buffer allocation failures, undersized frames, etc. — and are delivered
/// proactively via [UvcCamera.streamErrors] rather than being silently stored
/// in [UvcCamera.lastError].
class UvcStreamError {
  const UvcStreamError({required this.message});

  final String message;

  @override
  String toString() => 'UvcStreamError($message)';
}

/// Snapshot of native stream statistics accumulated for the current session.
///
/// Stats are reset when [UvcCamera.startPreview] begins a new preview session
/// and remain available as a snapshot until the next [UvcCamera.startPreview].
class UvcStreamStats {
  const UvcStreamStats({
    required this.inputFrameCount,
    required this.deliveredFrameCount,
    required this.decodeSuccessCount,
    required this.decodeFailureCount,
    required this.callbackLockDropCount,
    required this.warmupDropCount,
    required this.staleFrameCount,
    required this.undersizedFrameCount,
    required this.invalidMjpegCount,
    required this.bufferAllocationFailureCount,
    required this.previewSurfaceFailureCount,
    required this.conversionFailureCount,
    required this.inputFps,
    required this.deliveredFps,
    required this.avgInterFrameGapMs,
    required this.p95InterFrameGapMs,
    required this.maxInterFrameGapMs,
    required this.firstFrameLatencyMs,
    required this.elapsed,
  });

  const UvcStreamStats.zero()
    : inputFrameCount = 0,
      deliveredFrameCount = 0,
      decodeSuccessCount = 0,
      decodeFailureCount = 0,
      callbackLockDropCount = 0,
      warmupDropCount = 0,
      staleFrameCount = 0,
      undersizedFrameCount = 0,
      invalidMjpegCount = 0,
      bufferAllocationFailureCount = 0,
      previewSurfaceFailureCount = 0,
      conversionFailureCount = 0,
      inputFps = 0,
      deliveredFps = 0,
      avgInterFrameGapMs = 0,
      p95InterFrameGapMs = 0,
      maxInterFrameGapMs = 0,
      firstFrameLatencyMs = 0,
      elapsed = Duration.zero;

  factory UvcStreamStats.fromJson(Map<String, dynamic> json) {
    return UvcStreamStats(
      inputFrameCount: json['inputFrameCount'] as int,
      deliveredFrameCount: json['deliveredFrameCount'] as int,
      decodeSuccessCount: json['decodeSuccessCount'] as int,
      decodeFailureCount: json['decodeFailureCount'] as int,
      callbackLockDropCount: json['callbackLockDropCount'] as int,
      warmupDropCount: json['warmupDropCount'] as int,
      staleFrameCount: json['staleFrameCount'] as int,
      undersizedFrameCount: json['undersizedFrameCount'] as int,
      invalidMjpegCount: json['invalidMjpegCount'] as int,
      bufferAllocationFailureCount:
          json['bufferAllocationFailureCount'] as int,
      previewSurfaceFailureCount: json['previewSurfaceFailureCount'] as int,
      conversionFailureCount: json['conversionFailureCount'] as int,
      inputFps: (json['inputFps'] as num).toDouble(),
      deliveredFps: (json['deliveredFps'] as num).toDouble(),
      avgInterFrameGapMs: (json['avgInterFrameGapMs'] as num).toDouble(),
      p95InterFrameGapMs: (json['p95InterFrameGapMs'] as num).toDouble(),
      maxInterFrameGapMs: (json['maxInterFrameGapMs'] as num).toDouble(),
      firstFrameLatencyMs: (json['firstFrameLatencyMs'] as num).toDouble(),
      elapsed: Duration(
        microseconds: ((json['elapsedMs'] as num).toDouble() * 1000).round(),
      ),
    );
  }

  /// Total number of source frames observed by the native frame callback.
  final int inputFrameCount;

  /// Total number of frames successfully delivered after conversion/update.
  final int deliveredFrameCount;

  /// Total number of frames that completed native decode/convert successfully.
  final int decodeSuccessCount;

  /// Total number of frames rejected or failed during decode/convert.
  final int decodeFailureCount;

  /// Number of callbacks dropped because the previous callback was still busy.
  final int callbackLockDropCount;

  /// Number of MJPEG warmup frames intentionally dropped at stream start.
  final int warmupDropCount;

  /// Number of frames treated as stale, such as non-incrementing source sequence.
  final int staleFrameCount;

  /// Number of frames rejected because the payload was smaller than expected.
  final int undersizedFrameCount;

  /// Number of MJPEG frames rejected as structurally invalid.
  final int invalidMjpegCount;

  /// Number of RGB/RGBA buffer allocation or growth failures.
  final int bufferAllocationFailureCount;

  /// Number of preview surface update failures on the native preview path.
  final int previewSurfaceFailureCount;

  /// Number of failures reported by native pixel format conversion.
  final int conversionFailureCount;

  /// Average source frame rate observed at the native callback boundary.
  final double inputFps;

  /// Average delivered frame rate for successfully processed frames.
  final double deliveredFps;

  /// Average gap, in milliseconds, between successfully delivered frames.
  final double avgInterFrameGapMs;

  /// 95th percentile of delivered-frame gaps, in milliseconds.
  final double p95InterFrameGapMs;

  /// Maximum delivered-frame gap observed in the current session, in milliseconds.
  final double maxInterFrameGapMs;

  /// Time from preview start to the first successfully delivered frame, in milliseconds.
  final double firstFrameLatencyMs;

  /// Total elapsed time for the current or last preview session snapshot.
  final Duration elapsed;

  Map<String, Object?> toJson() => <String, Object?>{
    'inputFrameCount': inputFrameCount,
    'deliveredFrameCount': deliveredFrameCount,
    'decodeSuccessCount': decodeSuccessCount,
    'decodeFailureCount': decodeFailureCount,
    'callbackLockDropCount': callbackLockDropCount,
    'warmupDropCount': warmupDropCount,
    'staleFrameCount': staleFrameCount,
    'undersizedFrameCount': undersizedFrameCount,
    'invalidMjpegCount': invalidMjpegCount,
    'bufferAllocationFailureCount': bufferAllocationFailureCount,
    'previewSurfaceFailureCount': previewSurfaceFailureCount,
    'conversionFailureCount': conversionFailureCount,
    'inputFps': inputFps,
    'deliveredFps': deliveredFps,
    'avgInterFrameGapMs': avgInterFrameGapMs,
    'p95InterFrameGapMs': p95InterFrameGapMs,
    'maxInterFrameGapMs': maxInterFrameGapMs,
    'firstFrameLatencyMs': firstFrameLatencyMs,
    'elapsedMs': elapsed.inMicroseconds / 1000.0,
  };
}

/// Result of starting preview for a given mode.
///
/// [startPreview] starts the preview stream for [mode] and waits until enough
/// valid frames have been observed. On success the preview stream remains
/// running. On failure the preview is stopped before the result is returned.
class UvcPreviewStartResult {
  const UvcPreviewStartResult({
    required this.mode,
    required this.success,
    required this.validFrameCount,
    required this.consecutiveValidFrames,
    required this.errorCount,
    required this.elapsed,
    this.lastError,
    this.nativeErrorCode = 0,
  });

  final UvcCameraMode mode;
  final bool success;
  final int validFrameCount;
  final int consecutiveValidFrames;
  final int errorCount;
  final Duration elapsed;
  final String? lastError;

  /// Raw native return code when stream startup itself failed, otherwise 0.
  ///
  /// Verification failures (stream started but frames never became valid)
  /// keep this at 0; inspect [lastError] and the frame counters instead.
  final int nativeErrorCode;

  /// Typed error code for [nativeErrorCode], or null when it is 0.
  UvcErrorCode? get errorCode => UvcErrorCode.fromNativeValue(nativeErrorCode);
}

/// Policy controlling how [UvcCamera.startPreview] verifies frame delivery.
enum UvcPreviewPolicy {
  /// Require consecutive valid frames without an intervening stream error.
  stableFrames,

  /// Only require that the delivered frame sequence increases at least once.
  sequenceOnly,
}

/// Preview transform applied to the live Flutter Texture output.
///
/// [rotation] is a clockwise angle in degrees; only 0, 90, 180, and 270 are
/// accepted — other values are normalised to 0 by the native layer.
/// [flipHorizontal] mirrors the rendered image left-right.
/// [flipVertical] mirrors the rendered image top-bottom.
///
/// Transforms are applied during the native blit step and do not affect the
/// shared RGBA buffer returned by [UvcCamera.copyLatestFrame].
class UvcPreviewTransform {
  const UvcPreviewTransform({
    this.rotation = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  final int rotation;
  final bool flipHorizontal;
  final bool flipVertical;

  static const UvcPreviewTransform identity = UvcPreviewTransform();

  UvcPreviewTransform copyWith({
    int? rotation,
    bool? flipHorizontal,
    bool? flipVertical,
  }) => UvcPreviewTransform(
    rotation: rotation ?? this.rotation,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    flipVertical: flipVertical ?? this.flipVertical,
  );

  /// Returns the effective [width] and [height] after applying this transform.
  ///
  /// For 90° and 270° rotations the dimensions are swapped; flip flags do not
  /// affect the size.
  (int width, int height) applyToSize(int width, int height) =>
      (rotation == 90 || rotation == 270)
          ? (height, width)
          : (width, height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UvcPreviewTransform &&
          other.rotation == rotation &&
          other.flipHorizontal == flipHorizontal &&
          other.flipVertical == flipVertical;

  @override
  int get hashCode => Object.hash(rotation, flipHorizontal, flipVertical);

  @override
  String toString() =>
      'UvcPreviewTransform(rotation: $rotation, '
      'flipH: $flipHorizontal, flipV: $flipVertical)';
}

/// Information about a UVC-capable USB device discovered on Android.
class UvcUsbDevice {
  const UvcUsbDevice({
    required this.deviceId,
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.productName,
    required this.manufacturerName,
    required this.serialNumber,
    required this.hasPermission,
  });

  factory UvcUsbDevice.fromMap(Map<Object?, Object?> map) {
    return UvcUsbDevice(
      deviceId: map['deviceId'] as int? ?? -1,
      deviceName: map['deviceName'] as String? ?? '',
      vendorId: map['vendorId'] as int? ?? 0,
      productId: map['productId'] as int? ?? 0,
      productName: map['productName'] as String? ?? '',
      manufacturerName: map['manufacturerName'] as String? ?? '',
      serialNumber: map['serialNumber'] as String? ?? '',
      hasPermission: map['hasPermission'] as bool? ?? false,
    );
  }

  final int deviceId;
  final String deviceName;
  final int vendorId;
  final int productId;
  final String productName;
  final String manufacturerName;
  final String serialNumber;
  final bool hasPermission;

  /// Human-readable label combining product name and USB ID.
  String get displayName {
    final String label = productName.isNotEmpty ? productName : deviceName;
    return '$label (${vendorId.toRadixString(16)}:${productId.toRadixString(16)})';
  }

  /// Secondary detail line: manufacturer, serial number, permission state.
  String get details {
    final List<String> parts = <String>[
      if (manufacturerName.isNotEmpty) manufacturerName,
      if (serialNumber.isNotEmpty) 'S/N $serialNumber',
      hasPermission ? 'permission granted' : 'permission required',
    ];
    return parts.join(' • ');
  }
}

/// Kind of USB device lifecycle event reported by [UvcCamera.deviceEvents].
enum UvcDeviceEventType {
  /// A UVC-capable USB device was plugged in.
  attached,

  /// A UVC-capable USB device was unplugged.
  detached,
}

/// A USB attach/detach event for a UVC-capable device. Android only.
///
/// Detach events for the currently opened device mean the native session has
/// lost its transport; call [UvcCamera.closeUsbDevice] (or [UvcCamera.closeFd])
/// and re-open when the device returns.
class UvcDeviceEvent {
  const UvcDeviceEvent({required this.type, required this.device});

  factory UvcDeviceEvent.fromMap(Map<Object?, Object?> map) {
    return UvcDeviceEvent(
      type: map['event'] == 'attached'
          ? UvcDeviceEventType.attached
          : UvcDeviceEventType.detached,
      device: UvcUsbDevice.fromMap(
        (map['device'] as Map<Object?, Object?>?) ?? <Object?, Object?>{},
      ),
    );
  }

  final UvcDeviceEventType type;
  final UvcUsbDevice device;

  @override
  String toString() => 'UvcDeviceEvent(${type.name}, ${device.displayName})';
}

/// Configuration for preview stall detection.
///
/// A stall is declared when the delivered frame sequence stops advancing for
/// longer than [stallTimeout] while the preview stream is running.
class UvcStallDetectionConfig {
  const UvcStallDetectionConfig({
    this.stallTimeout = const Duration(seconds: 2),
    this.checkInterval = const Duration(milliseconds: 500),
    this.autoRestart = false,
    this.maxRestartAttempts = 3,
  });

  /// How long the frame sequence may stay unchanged before a stall is declared.
  final Duration stallTimeout;

  /// How often the watchdog samples the native frame sequence.
  final Duration checkInterval;

  /// Whether to automatically stop and restart the preview after a stall.
  ///
  /// The restart reuses the mode and verification parameters of the most
  /// recent [UvcCamera.startPreview] call.
  final bool autoRestart;

  /// Maximum consecutive automatic restart attempts per stall episode.
  ///
  /// The attempt counter resets once frames are delivered again.
  final int maxRestartAttempts;
}

/// Phase of a stall episode reported on [UvcCamera.stallEvents].
enum UvcStallEventType {
  /// No new frames were delivered for at least the configured stall timeout.
  stalled,

  /// An automatic restart attempt brought frame delivery back.
  restartSucceeded,

  /// An automatic restart attempt failed.
  restartFailed,
}

/// A stall detection or recovery event for the shared preview stream.
class UvcStallEvent {
  const UvcStallEvent({
    required this.type,
    required this.mode,
    required this.silence,
    this.restartAttempt = 0,
    this.restartResult,
  });

  final UvcStallEventType type;

  /// The mode the preview was running in when the stall was detected.
  final UvcCameraMode mode;

  /// Time since the last delivered frame when the event was emitted.
  final Duration silence;

  /// 1-based restart attempt number; 0 for [UvcStallEventType.stalled].
  final int restartAttempt;

  /// Verification result of the restart attempt, if one was made.
  final UvcPreviewStartResult? restartResult;

  @override
  String toString() =>
      'UvcStallEvent(${type.name}, mode: ${mode.label}, '
      'silence: ${silence.inMilliseconds}ms'
      '${restartAttempt > 0 ? ', attempt: $restartAttempt' : ''})';
}

/// Ordering strategy for the default candidate list of
/// [UvcCamera.startPreviewAuto].
///
/// Both strategies try MJPEG before uncompressed formats — compressed modes
/// are far less likely to exceed USB bandwidth on Android — and differ only in
/// how resolutions are ordered within each format group. Ignored when an
/// explicit `candidates` list is passed.
enum UvcAutoPreviewPreference {
  /// Prefer modes most likely to attach and stream: smaller resolutions and
  /// lower frame rates first.
  reliability,

  /// Prefer the best-looking mode that works: larger resolutions and higher
  /// frame rates first.
  quality,
}

/// Result of [UvcCamera.startPreviewAuto].
///
/// [attempts] holds the per-mode verification results in the order they were
/// tried, ending with the successful attempt when [success] is true.
class UvcAutoPreviewResult {
  const UvcAutoPreviewResult({required this.attempts});

  final List<UvcPreviewStartResult> attempts;

  /// Whether some candidate mode started and verified successfully.
  bool get success => attempts.isNotEmpty && attempts.last.success;

  /// The verification result of the mode that is now streaming, if any.
  UvcPreviewStartResult? get selected => success ? attempts.last : null;

  /// The mode that is now streaming, if any.
  UvcCameraMode? get mode => selected?.mode;
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

  /// Requests the CAMERA permission. Android only.
  ///
  /// Returns true if the permission is already granted or the user grants it.
  Future<bool> ensureCameraPermission();

  /// Lists USB devices that expose a UVC video interface. Android only.
  Future<List<UvcUsbDevice>> listUsbDevices();

  /// Stream of USB attach/detach events for UVC-capable devices. Android only.
  ///
  /// This is a broadcast stream; the underlying Android receiver is registered
  /// while at least one listener is subscribed. When the currently opened
  /// device reports [UvcDeviceEventType.detached], the native session has lost
  /// its transport — stop the preview and call [closeUsbDevice] or [closeFd].
  Stream<UvcDeviceEvent> get deviceEvents;

  /// Opens a USB device by [deviceId], acquiring USB permission if needed,
  /// then passes the resulting file descriptor to the native UVC layer.
  ///
  /// Returns 0 on success, or a negative native error code.
  /// Throws [PlatformException] if the USB layer fails (e.g. permission denied,
  /// device not found).
  Future<int> openUsbDevice(int deviceId);

  /// Closes the active USB device connection. Android only.
  Future<void> closeUsbDevice();

  /// Safely tears down the current session and opens [deviceId]. Android only.
  ///
  /// Stops any running preview, closes the active USB device, then opens the
  /// device identified by [deviceId] — the correct teardown order for moving
  /// the shared native session from one device to another.
  ///
  /// Mode selection and preview start are intentionally left to the caller:
  /// follow a successful switch with [startPreviewAuto] or [startPreview].
  ///
  /// Returns 0 on success, or a negative native error code from the open.
  /// Throws [PlatformException] if the USB layer fails (e.g. permission denied,
  /// device not found), same as [openUsbDevice].
  Future<int> switchUsbDevice(int deviceId);

  /// Opens a UVC device using an already acquired platform file descriptor.
  int openFd(int fd);

  /// Starts the native preview stream for [mode] without frame verification.
  ///
  /// Returns 0 on success, or a non-zero error code. To also verify that
  /// frames are delivered correctly, use [startPreview] instead.
  int openPreview(UvcCameraMode mode);

  /// Starts the preview stream for [mode] and verifies frame delivery.
  ///
  /// Waits until at least [consecutiveValidFrames] valid frames have been
  /// observed without an intervening stream error, or until [timeout] elapses.
  ///
  /// On success, the preview stream remains running. On failure, the preview
  /// is stopped before the result is returned.
  Future<UvcPreviewStartResult> startPreview(
    UvcCameraMode mode, {
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration timeout = const Duration(seconds: 2),
  });

  /// Tries candidate modes in order and keeps the first one that streams and
  /// verifies successfully.
  ///
  /// Descriptor-reported modes are candidates, not guaranteed-safe defaults —
  /// a mode may negotiate but never deliver decodable frames. This helper
  /// encodes the recommended fallback loop: each candidate goes through the
  /// same verification as [startPreview] and is rejected on failure.
  ///
  /// [candidates] defaults to [supportedModes] ordered by [preference] —
  /// MJPEG-first, then by resolution and frame rate ascending for
  /// [UvcAutoPreviewPreference.reliability] (the default) or descending for
  /// [UvcAutoPreviewPreference.quality] — capped at [maxCandidates]. Pass an
  /// explicit [candidates] list to control the order yourself; [preference] is
  /// then ignored.
  ///
  /// On success the preview stream remains running in the returned
  /// [UvcAutoPreviewResult.mode]. On total failure all attempts are stopped
  /// and the per-mode results are available in [UvcAutoPreviewResult.attempts].
  Future<UvcAutoPreviewResult> startPreviewAuto({
    List<UvcCameraMode>? candidates,
    UvcAutoPreviewPreference preference = UvcAutoPreviewPreference.reliability,
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration perModeTimeout = const Duration(seconds: 2),
    int maxCandidates = 8,
  });

  /// Stops the active preview stream.
  void stopPreview();

  /// Closes the native UVC session opened via [openFd].
  ///
  /// Use this when the file descriptor was acquired and managed outside of this
  /// package (e.g. passed directly from platform code). It closes the native
  /// session without touching the Android USB channel.
  ///
  /// If the device was opened with [openUsbDevice], use [closeUsbDevice]
  /// instead — it closes both the native session and the USB connection.
  void closeFd();

  /// Closes the active native device/session.
  ///
  /// Deprecated: use [closeFd] instead.
  @Deprecated('Use closeFd() instead.')
  void closeDevice();

  /// Whether the shared native preview stream is currently running.
  bool get isPreviewing;

  /// Last error message reported by the native layer.
  String get lastError;

  /// Stream of errors emitted by the native frame pipeline.
  ///
  /// Errors occurring during frame decode, buffer allocation, or format
  /// conversion are reported here instead of being silently stored in
  /// [lastError]. Subscribe before calling [startPreview] to avoid missing
  /// early errors. The stream remains open for the lifetime of the camera
  /// session; errors stop arriving after [closeUsbDevice] or [closeFd].
  Stream<UvcStreamError> get streamErrors;

  /// Enables watchdog-based stall detection for the shared preview stream.
  ///
  /// While enabled, the delivered frame sequence is sampled every
  /// [UvcStallDetectionConfig.checkInterval]; if it stops advancing for
  /// [UvcStallDetectionConfig.stallTimeout] while [isPreviewing] is true, a
  /// [UvcStallEventType.stalled] event is emitted on [stallEvents] once per
  /// stall episode. With [UvcStallDetectionConfig.autoRestart] the preview is
  /// stopped and restarted with the parameters of the most recent
  /// [startPreview] call.
  ///
  /// Calling this again replaces the previous configuration. Detection stays
  /// enabled across preview sessions until [disableStallDetection].
  void enableStallDetection([
    UvcStallDetectionConfig config = const UvcStallDetectionConfig(),
  ]);

  /// Disables stall detection.
  ///
  /// An automatic restart attempt that is already in flight completes its
  /// current verification (bounded by the restart timeout) before it notices
  /// detection is disabled; no further attempts follow and no more events are
  /// emitted. If that attempt happens to succeed, the preview keeps running.
  void disableStallDetection();

  /// Stream of stall detection and recovery events.
  ///
  /// Events are only emitted while stall detection is enabled via
  /// [enableStallDetection]. This is a broadcast stream.
  Stream<UvcStallEvent> get stallEvents;

  /// Copies the latest RGBA frame from the shared native preview buffer.
  UvcPreviewFrame? copyLatestFrame();

  /// Copies the latest RGBA frame with [transform] applied to the pixel data.
  ///
  /// The returned frame's [UvcPreviewFrame.width] and [UvcPreviewFrame.height]
  /// reflect the post-transform dimensions (swapped for 90° / 270° rotation).
  UvcPreviewFrame? copyLatestFrameTransformed(UvcPreviewTransform transform);

  /// Returns the latest delivered preview frame sequence.
  ///
  /// This is a lightweight metadata read intended for FPS counters or liveness
  /// checks without copying full frame bytes into Dart.
  int latestFrameSequence();

  /// Returns the latest cumulative native stream statistics snapshot.
  ///
  /// Stats are reset when [startPreview] starts a new preview session.
  UvcStreamStats getStreamStats();

  /// Creates a Flutter texture suitable for native preview rendering.
  ///
  /// The returned texture ID can be displayed with Flutter's [Texture] widget.
  Future<int> createPreviewTexture();

  /// Releases a texture created by [createPreviewTexture].
  Future<void> disposePreviewTexture(int textureId);

  /// Attaches the shared native preview stream to an existing texture.
  ///
  /// A subsequent [startPreview] call renders into the attached texture.
  Future<void> attachPreviewTexture(int textureId, {int? width, int? height});

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

  // ---------------------------------------------------------------------------
  // Preview transform controls
  // ---------------------------------------------------------------------------

  /// Current preview transform applied to the Flutter Texture output.
  UvcPreviewTransform get previewTransform;

  /// Replaces the entire preview transform in a single call.
  void setPreviewTransform(UvcPreviewTransform transform);

  /// Rotates the preview 90° clockwise relative to the current rotation.
  void rotatePreviewClockwise();

  /// Rotates the preview 90° counter-clockwise relative to the current rotation.
  void rotatePreviewCounterClockwise();

  /// Toggles the left-right mirror flag on the preview output.
  void togglePreviewFlipHorizontal();

  /// Toggles the top-bottom mirror flag on the preview output.
  void togglePreviewFlipVertical();
}
