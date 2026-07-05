import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'flutter_ffi_uvc_bindings_generated.dart';
import 'uvc_camera_api.dart';

class _PreviewRequest {
  const _PreviewRequest({
    required this.mode,
    required this.policy,
    required this.consecutiveValidFrames,
    required this.timeout,
  });

  final UvcCameraMode mode;
  final UvcPreviewPolicy policy;
  final int consecutiveValidFrames;
  final Duration timeout;
}

class _FlutterFfiUvcCamera implements UvcCamera {
  _FlutterFfiUvcCamera();
  static const MethodChannel _textureChannel = MethodChannel(
    'flutter_ffi_uvc/texture',
  );
  static const MethodChannel _usbChannel = MethodChannel('flutter_ffi_uvc/usb');
  static const EventChannel _deviceEventChannel = EventChannel(
    'flutter_ffi_uvc/device_events',
  );

  UvcPreviewTransform _previewTransform = UvcPreviewTransform.identity;

  final StreamController<UvcStreamError> _streamErrorController =
      StreamController<UvcStreamError>.broadcast();
  NativeCallable<Void Function(Pointer<Char>)>? _errorCallable;

  Stream<UvcDeviceEvent>? _deviceEventStream;

  // Stall detection state. The session epoch increments whenever the user
  // starts/stops/closes the preview session so an in-flight automatic restart
  // can detect it has been superseded and abort.
  final StreamController<UvcStallEvent> _stallEventController =
      StreamController<UvcStallEvent>.broadcast();
  UvcStallDetectionConfig? _stallConfig;
  Timer? _stallTimer;
  int _sessionEpoch = 0;
  int _stallLastSequence = 0;
  // Monotonic clock for stall timing so wall-clock adjustments (NTP, manual
  // time changes) can neither fake nor mask a stall.
  final Stopwatch _stallClock = Stopwatch()..start();
  Duration _stallLastProgress = Duration.zero;
  bool _inStallEpisode = false;
  bool _restartInProgress = false;
  int _restartAttempts = 0;
  _PreviewRequest? _lastPreviewRequest;

  void _setupNativeErrorListener() {
    if (_errorCallable != null) return;
    _errorCallable = NativeCallable<Void Function(Pointer<Char>)>.listener(_onNativeError);
    _bindings.uvc_set_error_listener(_errorCallable!.nativeFunction);
  }

  void _tearDownNativeErrorListener() {
    _bindings.uvc_set_error_listener(nullptr);
    _errorCallable?.close();
    _errorCallable = null;
  }

  void _onNativeError(Pointer<Char> messagePtr) {
    final String message = messagePtr.cast<Utf8>().toDartString();
    if (message.isNotEmpty) {
      _streamErrorController.add(UvcStreamError(message: message));
    }
  }

  void _resetPreviewState() {}

  Future<UvcPreviewStartResult> _startPreviewInternal(
    UvcCameraMode mode, {
    required UvcPreviewPolicy policy,
    required int requiredConsecutiveValidFrames,
    required Duration timeout,
  }) async {
    if (policy == UvcPreviewPolicy.stableFrames &&
        requiredConsecutiveValidFrames <= 0) {
      throw ArgumentError.value(
        requiredConsecutiveValidFrames,
        'requiredConsecutiveValidFrames',
        'Must be greater than 0.',
      );
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    final Stream<UvcStreamError> errors = streamErrors;
    int errorCount = 0;
    int observedErrorGeneration = 0;
    int latestObservedErrorGeneration = 0;
    String? lastError;
    int totalValidFrames = 0;
    int consecutiveValidFrames = 0;
    int lastSequence = latestFrameSequence();
    final Completer<void> errorReady = Completer<void>();
    late final StreamSubscription<UvcStreamError> errorSub;
    errorSub = errors.listen((UvcStreamError error) {
      errorCount += 1;
      latestObservedErrorGeneration += 1;
      lastError = error.message;
      consecutiveValidFrames = 0;
      if (!errorReady.isCompleted) {
        errorReady.complete();
      }
    });

    try {
      final int startResult = openPreview(mode);
      if (startResult != 0) {
        final String error = this.lastError;
        return UvcPreviewStartResult(
          mode: mode,
          success: false,
          validFrameCount: 0,
          consecutiveValidFrames: 0,
          errorCount: 0,
          elapsed: stopwatch.elapsed,
          lastError: error.isNotEmpty ? error : null,
          nativeErrorCode: startResult,
        );
      }

      while (stopwatch.elapsed < timeout) {
        if (policy == UvcPreviewPolicy.sequenceOnly) {
          final int latestSequence = latestFrameSequence();
          if (latestSequence > 0) {
            return UvcPreviewStartResult(
              mode: mode,
              success: true,
              validFrameCount: latestSequence,
              consecutiveValidFrames: latestSequence,
              errorCount: errorCount,
              elapsed: stopwatch.elapsed,
              lastError: lastError,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }

        if (latestObservedErrorGeneration != observedErrorGeneration) {
          observedErrorGeneration = latestObservedErrorGeneration;
          lastSequence = latestFrameSequence();
          consecutiveValidFrames = 0;
        }

        final int latestSequence = latestFrameSequence();
        final int delta = latestSequence - lastSequence;
        if (delta > 0) {
          totalValidFrames += delta;
          consecutiveValidFrames += delta;
          lastSequence = latestSequence;
          if (consecutiveValidFrames >= requiredConsecutiveValidFrames) {
            return UvcPreviewStartResult(
              mode: mode,
              success: true,
              validFrameCount: totalValidFrames,
              consecutiveValidFrames: consecutiveValidFrames,
              errorCount: errorCount,
              elapsed: stopwatch.elapsed,
              lastError: lastError,
            );
          }
        }

        await Future.any(<Future<void>>[
          Future<void>.delayed(const Duration(milliseconds: 50)),
          if (!errorReady.isCompleted) errorReady.future,
        ]);
      }

      final String error = lastError ?? this.lastError;
      _stopPreviewNative();
      return UvcPreviewStartResult(
        mode: mode,
        success: false,
        validFrameCount: totalValidFrames,
        consecutiveValidFrames: consecutiveValidFrames,
        errorCount: errorCount,
        elapsed: stopwatch.elapsed,
        lastError: error.isNotEmpty ? error : null,
      );
    } finally {
      await errorSub.cancel();
      stopwatch.stop();
    }
  }

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
    _sessionEpoch += 1;
    _resetStallTracking();
    _tearDownNativeErrorListener();
    _bindings.uvc_close_device();
    await _usbChannel.invokeMethod<void>('closeUsbDevice');
  }

  @override
  int openFd(int fd) {
    final int result = _bindings.uvc_open_fd(fd);
    if (result == 0) {
      _setupNativeErrorListener();
    }
    return result;
  }

  @override
  int openPreview(UvcCameraMode mode) {
    _resetPreviewState();
    // Record the mode so stall detection can report and restart previews
    // started through openPreview directly, using default verification.
    // Requests recorded by startPreview for the same mode are kept so their
    // policy/timeout parameters survive.
    final _PreviewRequest? existing = _lastPreviewRequest;
    final bool sameMode = existing != null &&
        existing.mode.frameFormat == mode.frameFormat &&
        existing.mode.width == mode.width &&
        existing.mode.height == mode.height &&
        existing.mode.fps == mode.fps;
    if (!sameMode) {
      _lastPreviewRequest = _PreviewRequest(
        mode: mode,
        policy: UvcPreviewPolicy.stableFrames,
        consecutiveValidFrames: 3,
        timeout: const Duration(seconds: 2),
      );
    }
    return _bindings.uvc_start_preview(
      mode.frameFormat,
      mode.width,
      mode.height,
      mode.fps,
    );
  }

  @override
  Future<UvcPreviewStartResult> startPreview(
    UvcCameraMode mode, {
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration timeout = const Duration(seconds: 2),
  }) {
    _sessionEpoch += 1;
    _lastPreviewRequest = _PreviewRequest(
      mode: mode,
      policy: policy,
      consecutiveValidFrames: consecutiveValidFrames,
      timeout: timeout,
    );
    _resetStallTracking();
    return _startPreviewInternal(
      mode,
      policy: policy,
      requiredConsecutiveValidFrames: consecutiveValidFrames,
      timeout: timeout,
    );
  }

  @override
  Future<UvcAutoPreviewResult> startPreviewAuto({
    List<UvcCameraMode>? candidates,
    UvcAutoPreviewPreference preference = UvcAutoPreviewPreference.reliability,
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration perModeTimeout = const Duration(seconds: 2),
    int maxCandidates = 8,
  }) async {
    if (maxCandidates <= 0) {
      throw ArgumentError.value(
        maxCandidates,
        'maxCandidates',
        'Must be greater than 0.',
      );
    }
    final List<UvcCameraMode> modes = (candidates ??
            _defaultAutoCandidates(preference))
        .take(maxCandidates)
        .toList();
    final List<UvcPreviewStartResult> attempts = <UvcPreviewStartResult>[];
    for (final UvcCameraMode mode in modes) {
      final UvcPreviewStartResult result = await startPreview(
        mode,
        policy: policy,
        consecutiveValidFrames: consecutiveValidFrames,
        timeout: perModeTimeout,
      );
      attempts.add(result);
      if (result.success) break;
    }
    return UvcAutoPreviewResult(attempts: attempts);
  }

  /// Orders descriptor-reported modes MJPEG before uncompressed formats, then
  /// by resolution and frame rate — ascending for
  /// [UvcAutoPreviewPreference.reliability], descending for
  /// [UvcAutoPreviewPreference.quality].
  List<UvcCameraMode> _defaultAutoCandidates(
    UvcAutoPreviewPreference preference,
  ) {
    int formatRank(UvcCameraMode mode) => mode.formatName == 'MJPEG' ? 0 : 1;
    final int direction =
        preference == UvcAutoPreviewPreference.reliability ? 1 : -1;
    final List<UvcCameraMode> modes = supportedModes();
    modes.sort((UvcCameraMode a, UvcCameraMode b) {
      final int byFormat = formatRank(a).compareTo(formatRank(b));
      if (byFormat != 0) return byFormat;
      final int byArea =
          direction * (a.width * a.height).compareTo(b.width * b.height);
      if (byArea != 0) return byArea;
      return direction * a.fps.compareTo(b.fps);
    });
    return modes;
  }

  void _stopPreviewNative() {
    _bindings.uvc_stop_preview();
    _resetPreviewState();
  }

  @override
  void stopPreview() {
    _sessionEpoch += 1;
    _resetStallTracking();
    _stopPreviewNative();
  }

  @override
  void closeFd() {
    _sessionEpoch += 1;
    _resetStallTracking();
    _tearDownNativeErrorListener();
    _bindings.uvc_close_device();
    _resetPreviewState();
  }

  @override
  void closeDevice() => closeFd();

  @override
  bool get isPreviewing => _bindings.uvc_is_previewing() != 0;

  @override
  Stream<UvcStreamError> get streamErrors {
    if (_errorCallable == null) {
      _setupNativeErrorListener();
    }
    return _streamErrorController.stream;
  }

  @override
  Stream<UvcDeviceEvent> get deviceEvents {
    _ensureAndroid();
    return _deviceEventStream ??= _deviceEventChannel
        .receiveBroadcastStream()
        .map(
          (dynamic event) => UvcDeviceEvent.fromMap(
            (event as Map<Object?, Object?>?) ?? <Object?, Object?>{},
          ),
        );
  }

  @override
  Stream<UvcStallEvent> get stallEvents => _stallEventController.stream;

  @override
  void enableStallDetection([
    UvcStallDetectionConfig config = const UvcStallDetectionConfig(),
  ]) {
    _stallConfig = config;
    _resetStallTracking();
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(config.checkInterval, (_) => _stallTick());
  }

  @override
  void disableStallDetection() {
    _stallConfig = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _resetStallTracking();
  }

  void _resetStallTracking() {
    _stallLastSequence = latestFrameSequence();
    _stallLastProgress = _stallClock.elapsed;
    _inStallEpisode = false;
    _restartAttempts = 0;
  }

  void _stallTick() {
    final UvcStallDetectionConfig? config = _stallConfig;
    if (config == null || _restartInProgress) return;
    if (!isPreviewing) {
      _resetStallTracking();
      return;
    }

    final int sequence = latestFrameSequence();
    final Duration now = _stallClock.elapsed;
    if (sequence != _stallLastSequence) {
      _stallLastSequence = sequence;
      _stallLastProgress = now;
      _inStallEpisode = false;
      _restartAttempts = 0;
      return;
    }

    if (_inStallEpisode) return;
    final Duration silence = now - _stallLastProgress;
    if (silence < config.stallTimeout) return;

    final _PreviewRequest? request = _lastPreviewRequest;
    if (request == null) return;
    _inStallEpisode = true;
    _stallEventController.add(
      UvcStallEvent(
        type: UvcStallEventType.stalled,
        mode: request.mode,
        silence: silence,
      ),
    );
    if (config.autoRestart) {
      unawaited(_attemptStallRestart(config, request, silence));
    }
  }

  Future<void> _attemptStallRestart(
    UvcStallDetectionConfig config,
    _PreviewRequest request,
    Duration silence,
  ) async {
    _restartInProgress = true;
    final int epoch = _sessionEpoch;
    try {
      while (_restartAttempts < config.maxRestartAttempts) {
        _restartAttempts += 1;
        final int attempt = _restartAttempts;
        _stopPreviewNative();
        final UvcPreviewStartResult result = await _startPreviewInternal(
          request.mode,
          policy: request.policy,
          requiredConsecutiveValidFrames: request.consecutiveValidFrames,
          timeout: request.timeout,
        );
        // The user started/stopped/closed the session while the restart was
        // in flight; their call supersedes this recovery attempt.
        if (_sessionEpoch != epoch || _stallConfig == null) return;
        if (result.success) {
          _stallLastSequence = latestFrameSequence();
          _stallLastProgress = _stallClock.elapsed;
          _inStallEpisode = false;
          _restartAttempts = 0;
          _stallEventController.add(
            UvcStallEvent(
              type: UvcStallEventType.restartSucceeded,
              mode: request.mode,
              silence: silence,
              restartAttempt: attempt,
              restartResult: result,
            ),
          );
          return;
        }
        _stallEventController.add(
          UvcStallEvent(
            type: UvcStallEventType.restartFailed,
            mode: request.mode,
            silence: silence,
            restartAttempt: attempt,
            restartResult: result,
          ),
        );
      }
    } finally {
      _restartInProgress = false;
    }
  }

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
  UvcPreviewFrame? copyLatestFrameTransformed(UvcPreviewTransform transform) {
    if (transform == UvcPreviewTransform.identity) {
      return _copyLatestFrameInternal();
    }
    final int srcWidth = _bindings.uvc_frame_width();
    final int srcHeight = _bindings.uvc_frame_height();
    if (srcWidth <= 0 || srcHeight <= 0) return null;

    final int expectedBytes = srcWidth * srcHeight * 4;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(expectedBytes);
    final Pointer<Int> nativeWidth = calloc<Int>();
    final Pointer<Int> nativeHeight = calloc<Int>();
    final Pointer<Int64> nativeSequence = calloc<Int64>();
    try {
      final int copiedBytes = _bindings.uvc_copy_latest_frame_rgba_transformed(
        nativeBuffer,
        expectedBytes,
        transform.rotation,
        transform.flipHorizontal ? 1 : 0,
        transform.flipVertical ? 1 : 0,
        nativeWidth,
        nativeHeight,
        nativeSequence,
      );
      if (copiedBytes <= 0) return null;
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

  @override
  int latestFrameSequence() => _bindings.uvc_latest_frame_sequence();

  @override
  UvcStreamStats getStreamStats() => _readJsonObject(
    _bindings.uvc_get_stream_stats_json,
    UvcStreamStats.fromJson,
  ) ?? const UvcStreamStats.zero();

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
  UvcPreviewTransform get previewTransform => _previewTransform;

  @override
  void setPreviewTransform(UvcPreviewTransform transform) {
    _previewTransform = transform;
    _bindings.uvc_set_preview_transform(
      transform.rotation,
      transform.flipHorizontal ? 1 : 0,
      transform.flipVertical ? 1 : 0,
    );
  }

  @override
  void rotatePreviewClockwise() {
    setPreviewTransform(
      _previewTransform.copyWith(
        rotation: (_previewTransform.rotation + 90) % 360,
      ),
    );
  }

  @override
  void rotatePreviewCounterClockwise() {
    setPreviewTransform(
      _previewTransform.copyWith(
        rotation: (_previewTransform.rotation + 270) % 360,
      ),
    );
  }

  @override
  void togglePreviewFlipHorizontal() {
    setPreviewTransform(
      _previewTransform.copyWith(
        flipHorizontal: !_previewTransform.flipHorizontal,
      ),
    );
  }

  @override
  void togglePreviewFlipVertical() {
    setPreviewTransform(
      _previewTransform.copyWith(
        flipVertical: !_previewTransform.flipVertical,
      ),
    );
  }

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
