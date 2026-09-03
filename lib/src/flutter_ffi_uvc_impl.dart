import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

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

/// Package implementation of [UvcCamera]. Construct through `UvcCamera()`.
class FfiUvcCamera implements UvcCamera, Finalizable {
  FfiUvcCamera();
  static const MethodChannel _textureChannel = MethodChannel(
    'flutter_ffi_uvc/texture',
  );
  static const MethodChannel _usbChannel = MethodChannel('flutter_ffi_uvc/usb');
  static const EventChannel _deviceEventChannel = EventChannel(
    'flutter_ffi_uvc/device_events',
  );

  // Device events are process-wide. All instances share one subscription.
  static Stream<UvcDeviceEvent>? _sharedDeviceEventStream;

  // Devices open or being opened in this process, so two instances never
  // open the same one. Weak so an undisposed instance can still be collected.
  static final Map<int, WeakReference<FfiUvcCamera>> _openDevices =
      <int, WeakReference<FfiUvcCamera>>{};
  int? _openedDeviceId;

  static FfiUvcCamera? _deviceHolder(int deviceId) {
    final FfiUvcCamera? holder = _openDevices[deviceId]?.target;
    if (holder == null) _openDevices.remove(deviceId);
    return holder;
  }

  void _releaseDeviceClaim(int deviceId) {
    if (_openDevices[deviceId]?.target == this) _openDevices.remove(deviceId);
  }

  // Set when a call is rejected before reaching the native layer.
  String? _dartLastError;

  // Closes the session when its own device is unplugged.
  StreamSubscription<UvcDeviceEvent>? _ownDeviceSub;

  @override
  int? get openedDeviceId => _openedDeviceId;

  void _forgetOpenedDevice() {
    final int? deviceId = _openedDeviceId;
    if (deviceId != null) _releaseDeviceClaim(deviceId);
    _openedDeviceId = null;
    _ownDeviceSub?.cancel();
    _ownDeviceSub = null;
  }

  void _rememberOpenedDevice(int deviceId) {
    _openDevices[deviceId] = WeakReference<FfiUvcCamera>(this);
    _openedDeviceId = deviceId;
    _ownDeviceSub ??= deviceEvents.listen((UvcDeviceEvent event) {
      if (event.type == UvcDeviceEventType.detached &&
          event.device.deviceId == _openedDeviceId) {
        // The transport is gone, so the session cannot be used again.
        stopPreview();
        unawaited(closeUsbDevice());
      }
    });
  }

  // Created on first native use so construction never loads the library.
  Pointer<uvc_session_t>? _session;
  bool _disposed = false;

  Pointer<uvc_session_t> get _s {
    if (_disposed) {
      throw StateError('This UvcCamera has been disposed.');
    }
    return _session ??= _createSession();
  }

  // Destroys the native session of an instance that is garbage collected or
  // lost to a hot restart without dispose().
  static final NativeFinalizer _finalizer = NativeFinalizer(
    _dylib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'uvc_session_destroy',
    ),
  );

  Pointer<uvc_session_t> _createSession() {
    final Pointer<uvc_session_t> session = _bindings.uvc_session_create();
    if (session == nullptr) {
      throw StateError('Native session allocation failed.');
    }
    _finalizer.attach(this, session.cast<Void>(), detach: this);
    return session;
  }

  /// Native session address, passed to the platform channels.
  int get nativeSessionHandle => _s.address;

  UvcPreviewTransform _previewTransform = UvcPreviewTransform.identity;

  final StreamController<UvcStreamError> _streamErrorController =
      StreamController<UvcStreamError>.broadcast();
  NativeCallable<Void Function(Pointer<Void>, Pointer<Char>)>? _errorCallable;

  // Stall detection state. The session epoch increments whenever the user
  // starts/stops/closes the preview session so an in-flight automatic restart
  // can detect it has been superseded and abort.
  final StreamController<UvcStallEvent> _stallEventController =
      StreamController<UvcStallEvent>.broadcast();
  UvcStallDetectionConfig? _stallConfig;
  Timer? _stallTimer;
  // Every stop, close, dispose, and start bumps the epoch. An async native
  // operation belongs to the epoch it started in and undoes itself when a
  // later call has moved on.
  int _sessionEpoch = 0;

  // Bumped only by closeUsbDevice, closeFd, and dispose. An open in flight
  // when it changes undoes itself.
  int _deviceEpoch = 0;

  // Every call that changes the session goes through here. A new lifecycle
  // method must call it, or in-flight work will not notice the call.
  void _supersede({bool device = false}) {
    _sessionEpoch += 1;
    if (device) _deviceEpoch += 1;
  }

  // Async native operations of one instance run one at a time.
  Future<void> _nativeQueue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final Future<T> result = _nativeQueue.then((_) => operation());
    _nativeQueue = result.then((_) {}, onError: (_) {});
    return result;
  }
  int _stallLastSequence = 0;
  // Monotonic clock for stall timing so wall-clock adjustments (NTP, manual
  // time changes) can neither fake nor mask a stall.
  final Stopwatch _stallClock = Stopwatch()..start();
  Duration _stallLastProgress = Duration.zero;
  bool _inStallEpisode = false;
  bool _restartInProgress = false;
  int _restartAttempts = 0;
  _PreviewRequest? _lastPreviewRequest;

  // Registers the Dart callable on the native session. Always re-registers
  // because the native layer clears the slot when a device closes.
  void _setupNativeErrorListener() {
    if (_disposed) return;
    _errorCallable ??=
        NativeCallable<Void Function(Pointer<Void>, Pointer<Char>)>.listener(
          _onNativeError,
        );
    _bindings.uvc_set_error_listener(_s, _errorCallable!.nativeFunction, nullptr);
  }

  void _tearDownNativeErrorListener([Pointer<uvc_session_t>? session]) {
    session ??= _disposed ? null : _session;
    if (session != null) {
      _bindings.uvc_set_error_listener(session, nullptr, nullptr);
    }
    _errorCallable?.close();
    _errorCallable = null;
  }

  void _onNativeError(Pointer<Void> _, Pointer<Char> messagePtr) {
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
      final int epoch = _sessionEpoch;
      int startResult;
      try {
        startResult = await _serialized(() => _openPreviewOffThread(mode));
      } on StateError {
        // dispose() ran before the queued start reached the native layer.
        if (!_disposed) rethrow;
        startResult = UvcErrorCode.noDevice.nativeValue;
      }
      if (_disposed || _sessionEpoch != epoch) {
        // stopPreview(), closeUsbDevice(), dispose(), or a later start ran
        // while this start was in flight and wins.
        if (startResult == 0 && !_disposed) _stopPreviewNative();
        return UvcPreviewStartResult(
          mode: mode,
          success: false,
          validFrameCount: 0,
          consecutiveValidFrames: 0,
          errorCount: 0,
          elapsed: stopwatch.elapsed,
          lastError: 'Preview start superseded by a later call',
        );
      }
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
        if (_disposed || _sessionEpoch != epoch) {
          // A later call owns the stream now. Leave it running.
          return UvcPreviewStartResult(
            mode: mode,
            success: false,
            validFrameCount: totalValidFrames,
            consecutiveValidFrames: consecutiveValidFrames,
            errorCount: errorCount,
            elapsed: stopwatch.elapsed,
            lastError: 'Preview start superseded by a later call',
          );
        }
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

      if (_disposed || _sessionEpoch != epoch) {
        return UvcPreviewStartResult(
          mode: mode,
          success: false,
          validFrameCount: totalValidFrames,
          consecutiveValidFrames: consecutiveValidFrames,
          errorCount: errorCount,
          elapsed: stopwatch.elapsed,
          lastError: 'Preview start superseded by a later call',
        );
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
    final int width = _bindings.uvc_frame_width(_s);
    final int height = _bindings.uvc_frame_height(_s);
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
    (buffer, bufferLength, width, height, sequence) =>
        _bindings.uvc_copy_latest_frame_rgba_with_metadata(
          _s,
          buffer,
          bufferLength,
          width,
          height,
          sequence,
        ),
  );

  @override
  void setLogLevel(UvcLogLevel level) {
    _bindings.uvc_set_log_level(level.nativeValue);
  }

  T? _readJsonObject<T>(
    int Function(
      Pointer<uvc_session_t> session,
      Pointer<Uint8> buffer,
      int bufferLength,
    )
    nativeCall,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    const int bufferLength = 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = nativeCall(_s, nativeBuffer, bufferLength);
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
    _ensureSupportedPlatform();
    return await _usbChannel.invokeMethod<bool>('ensureCameraPermission') ??
        false;
  }

  @override
  Future<List<UvcUsbDevice>> listUsbDevices() async {
    _ensureSupportedPlatform();
    final List<Object?>? raw =
        await _usbChannel.invokeListMethod<Object?>('listUsbDevices');
    return (raw ?? <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(UvcUsbDevice.fromMap)
        .toList();
  }

  @override
  Future<int> openUsbDevice(int deviceId) {
    _ensureSupportedPlatform();
    // Epochs are taken now, at call time. An open supersedes an earlier
    // start, and a close or dispose called after this open supersedes it,
    // even while it still waits in the queue.
    _supersede();
    final int deviceEpoch = _deviceEpoch;
    // The whole open runs as one queued transaction, so two opens on the
    // same instance follow each other instead of closing each other's
    // connection, and a start issued after an open waits for it.
    return _serialized(() => _openUsbDeviceTransaction(deviceId, deviceEpoch));
  }

  Future<int> _openUsbDeviceTransaction(int deviceId, int epoch) async {
    if (_disposed || _deviceEpoch != epoch) {
      _dartLastError = 'Open cancelled: the instance was closed';
      return UvcErrorCode.noDevice.nativeValue;
    }
    _dartLastError = null;
    // An instance holds one device. Close this instance's device first.
    // Internal close: the epochs stay, so a start queued behind this open
    // still runs.
    _stopPreviewNative();
    await _closeUsbDeviceInternal();
    final FfiUvcCamera? holder = _deviceHolder(deviceId);
    if (holder != null && holder != this) {
      _dartLastError = 'Device $deviceId is open in another UvcCamera instance';
      return UvcErrorCode.busy.nativeValue;
    }
    // Claim the device before the first await so a concurrent open on
    // another instance sees it as busy. Released again on failure.
    _openDevices[deviceId] = WeakReference<FfiUvcCamera>(this);
    final int handle = nativeSessionHandle;
    final Map<Object?, Object?>? result;
    try {
      result = await _usbChannel.invokeMapMethod<Object?, Object?>(
        'openUsbDevice',
        <String, Object?>{'sessionHandle': handle, 'deviceId': deviceId},
      );
    } on PlatformException catch (error) {
      _releaseDeviceClaim(deviceId);
      if (error.code == 'closed') {
        // closeUsbDevice() or dispose() cancelled this open.
        _dartLastError = 'Open cancelled: the instance was closed';
        return UvcErrorCode.noDevice.nativeValue;
      }
      rethrow;
    }
    if (_disposed || _deviceEpoch != epoch) {
      // closeUsbDevice() or dispose() ran during the platform open. Release
      // the connection it opened.
      _releaseDeviceClaim(deviceId);
      try {
        await _usbChannel.invokeMethod<void>(
          'closeUsbDevice',
          <String, Object?>{'sessionHandle': handle},
        );
      } catch (_) {
        // Nothing left to release.
      }
      _dartLastError = 'Open cancelled: the instance was closed';
      return UvcErrorCode.noDevice.nativeValue;
    }
    final int fd = result?['fileDescriptor'] as int? ?? -1;
    // Opening can block for seconds while the OS finishes initialising a
    // freshly plugged camera, so it runs on a worker isolate.
    final int openResult = await Isolate.run(
      () => _bindings.uvc_open_fd(Pointer<uvc_session_t>.fromAddress(handle), fd),
    );
    if (_disposed || _deviceEpoch != epoch) {
      // closeUsbDevice() or dispose() ran while the open was in flight and
      // wins. Undo what the worker opened.
      _releaseDeviceClaim(deviceId);
      if (openResult == 0 && !_disposed) {
        _bindings.uvc_close_device(_s);
      }
      try {
        await _usbChannel.invokeMethod<void>(
          'closeUsbDevice',
          <String, Object?>{'sessionHandle': handle},
        );
      } catch (_) {
        // Nothing left to release.
      }
      _dartLastError = 'Open cancelled: the instance was closed';
      return UvcErrorCode.noDevice.nativeValue;
    }
    if (openResult == 0) {
      _setupNativeErrorListener();
      _rememberOpenedDevice(deviceId);
    } else {
      _releaseDeviceClaim(deviceId);
    }
    if (openResult != 0) {
      // The platform-side open succeeded but the native session failed to
      // attach; close it so any failure leaves nothing open.
      try {
        await _closeUsbDeviceInternal();
      } catch (_) {
        // Cleanup failure must not mask the original open error.
      }
    }
    return openResult;
  }

  @override
  Future<void> closeUsbDevice() {
    _ensureSupportedPlatform();
    _supersede(device: true);
    return _closeUsbDeviceInternal();
  }

  Future<void> _closeUsbDeviceInternal() async {
    _dartLastError = null;
    _forgetOpenedDevice();
    _resetStallTracking();
    // Closing joins the stream thread, so do it before the callable goes away.
    _bindings.uvc_close_device(_s);
    _tearDownNativeErrorListener();
    await _usbChannel.invokeMethod<void>(
      'closeUsbDevice',
      <String, Object?>{'sessionHandle': nativeSessionHandle},
    );
  }

  Future<void>? _disposing;

  @override
  Future<void> dispose() => _disposing ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    if (_disposed) return;
    // Mark disposed before the first await so a re-entrant dispose() or a
    // concurrent open cannot see the session.
    _disposed = true;
    _forgetOpenedDevice();
    final Pointer<uvc_session_t>? session = _session;
    _session = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _stallConfig = null;
    if (session != null) {
      _supersede(device: true);
      _finalizer.detach(this);
      // A worker may still be inside a native open or start. Let the queue
      // drain before the session goes away.
      try {
        await _nativeQueue;
      } catch (_) {
        // The queued operation reported its own failure.
      }
      try {
        _bindings.uvc_stop_preview(session);
        _bindings.uvc_close_device(session);
        _tearDownNativeErrorListener(session);
        // The platform side holds the handle. Release it before the session.
        await _usbChannel.invokeMethod<void>(
          'closeUsbDevice',
          <String, Object?>{'sessionHandle': session.address},
        );
        await _textureChannel.invokeMethod<void>(
          'detachPreviewSession',
          <String, Object?>{'sessionHandle': session.address},
        );
      } finally {
        _bindings.uvc_session_destroy(session);
        await _streamErrorController.close();
        await _stallEventController.close();
      }
      return;
    }
    await _streamErrorController.close();
    await _stallEventController.close();
  }

  @override
  int openFd(int fd) {
    _ensureAndroidOnlyApi('openFd');
    return _openFdNative(fd);
  }

  /// Shared native-open step. On Android the value is a real file descriptor;
  /// on Windows the native layer interprets it as the enumeration device id
  /// handed back by the openUsbDevice platform channel. That mapping is an
  /// internal detail — the public [openFd] stays Android-only.
  int _openFdNative(int fd) {
    _dartLastError = null;
    final int result = _bindings.uvc_open_fd(_s, fd);
    if (result == 0) {
      _setupNativeErrorListener();
    }
    return result;
  }

  @override
  int openPreview(UvcCameraMode mode) {
    // Replaces the stream like startPreview does, so it supersedes a start
    // still verifying frames.
    _supersede();
    _recordPreviewRequest(mode);
    return _bindings.uvc_start_preview(
      _s,
      mode.frameFormat,
      mode.width,
      mode.height,
      mode.fps,
    );
  }

  // Same as openPreview, with the native call on a worker isolate so the
  // device negotiation does not block the UI.
  Future<int> _openPreviewOffThread(UvcCameraMode mode) {
    _recordPreviewRequest(mode);
    final int session = _s.address;
    final int format = mode.frameFormat;
    final int width = mode.width;
    final int height = mode.height;
    final int fps = mode.fps;
    return Isolate.run(
      () => _bindings.uvc_start_preview(
        Pointer<uvc_session_t>.fromAddress(session),
        format,
        width,
        height,
        fps,
      ),
    );
  }

  void _recordPreviewRequest(UvcCameraMode mode) {
    _dartLastError = null;
    _resetPreviewState();
    // Record the mode so stall detection can report and restart previews
    // started through openPreview directly, using default verification.
    // Requests recorded by startPreview for the same mode are kept so their
    // policy/timeout parameters survive.
    final _PreviewRequest? existing = _lastPreviewRequest;
    final bool sameMode = existing != null && existing.mode == mode;
    if (!sameMode) {
      _lastPreviewRequest = _PreviewRequest(
        mode: mode,
        policy: UvcPreviewPolicy.stableFrames,
        consecutiveValidFrames: 3,
        timeout: const Duration(seconds: 2),
      );
    }
  }

  @override
  Future<UvcPreviewStartResult> startPreview(
    UvcCameraMode mode, {
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
    int consecutiveValidFrames = 3,
    Duration timeout = const Duration(seconds: 2),
  }) {
    _supersede();
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
      if (_disposed) break;
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
    // H264 modes are opt-in via an explicit startPreview: keyframe timing and
    // decoder behavior vary too much per device for the auto sequence.
    final List<UvcCameraMode> modes = supportedModes()
        .where((UvcCameraMode mode) => mode.formatName != 'H264')
        .toList();
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
    _bindings.uvc_stop_preview(_s);
    _resetPreviewState();
  }

  @override
  void stopPreview() {
    _supersede();
    _dartLastError = null;
    _resetStallTracking();
    _stopPreviewNative();
  }

  @override
  void closeFd() {
    _ensureAndroidOnlyApi('closeFd');
    _supersede(device: true);
    _dartLastError = null;
    _forgetOpenedDevice();
    _resetStallTracking();
    _bindings.uvc_close_device(_s);
    _tearDownNativeErrorListener();
    _resetPreviewState();
  }

  @override
  void closeDevice() => closeFd();

  @override
  bool get isPreviewing => _bindings.uvc_is_previewing(_s) != 0;

  @override
  Stream<UvcStreamError> get streamErrors {
    if (_errorCallable == null && !_disposed) {
      _setupNativeErrorListener();
    }
    return _streamErrorController.stream;
  }

  @override
  Stream<UvcDeviceEvent> get deviceEvents {
    _ensureSupportedPlatform();
    return _sharedDeviceEventStream ??= _deviceEventChannel
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
        if (_disposed) return;
        _restartAttempts += 1;
        if (_disposed) return;
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
    } on StateError {
      // dispose() ran while the restart was in flight.
      if (!_disposed) rethrow;
    } finally {
      _restartInProgress = false;
    }
  }

  @override
  String get lastError {
    final String? dartError = _dartLastError;
    if (dartError != null) return dartError;
    final Pointer<Char> pointer = _bindings.uvc_last_error(_s).cast<Char>();
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
    final int srcWidth = _bindings.uvc_frame_width(_s);
    final int srcHeight = _bindings.uvc_frame_height(_s);
    if (srcWidth <= 0 || srcHeight <= 0) return null;

    final int expectedBytes = srcWidth * srcHeight * 4;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(expectedBytes);
    final Pointer<Int> nativeWidth = calloc<Int>();
    final Pointer<Int> nativeHeight = calloc<Int>();
    final Pointer<Int64> nativeSequence = calloc<Int64>();
    try {
      final int copiedBytes = _bindings.uvc_copy_latest_frame_rgba_transformed(
        _s,
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
  UvcStillPicture? takePicture({
    int quality = 90,
    UvcPreviewTransform? transform,
  }) {
    final UvcPreviewTransform effective = transform ?? _previewTransform;
    final int srcWidth = _bindings.uvc_frame_width(_s);
    final int srcHeight = _bindings.uvc_frame_height(_s);
    if (srcWidth <= 0 || srcHeight <= 0) return null;

    // RGBA size is a generous upper bound for JPEG output at any quality.
    final int bufferLength = srcWidth * srcHeight * 4;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    final Pointer<Int> nativeWidth = calloc<Int>();
    final Pointer<Int> nativeHeight = calloc<Int>();
    final Pointer<Int64> nativeSequence = calloc<Int64>();
    try {
      final int encodedBytes = _bindings.uvc_take_picture_jpeg(
        _s,
        nativeBuffer,
        bufferLength,
        quality,
        effective.rotation,
        effective.flipHorizontal ? 1 : 0,
        effective.flipVertical ? 1 : 0,
        nativeWidth,
        nativeHeight,
        nativeSequence,
      );
      if (encodedBytes <= 0) return null;
      return UvcStillPicture(
        width: nativeWidth.value,
        height: nativeHeight.value,
        jpegBytes: Uint8List.fromList(
          nativeBuffer.asTypedList(encodedBytes),
        ),
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
  int startVideoRecording(
    String path, {
    int bitrateBps = 0,
    UvcPreviewTransform? transform,
  }) {
    final UvcPreviewTransform effective = transform ?? _previewTransform;
    // The mode fps seeds encoder rate control; 0 lets the native layer pick.
    final int fpsHint = _lastPreviewRequest?.mode.fps ?? 0;
    final Pointer<Utf8> nativePath = path.toNativeUtf8(allocator: calloc);
    try {
      return _bindings.uvc_start_recording(
        _s,
        nativePath.cast(),
        bitrateBps,
        fpsHint,
        effective.rotation,
        effective.flipHorizontal ? 1 : 0,
        effective.flipVertical ? 1 : 0,
      );
    } finally {
      calloc.free(nativePath);
    }
  }

  @override
  int stopVideoRecording() => _bindings.uvc_stop_recording(_s);

  @override
  bool get isRecording => _bindings.uvc_is_recording(_s) != 0;

  @override
  int latestFrameSequence() => _bindings.uvc_latest_frame_sequence(_s);

  @override
  UvcStreamStats getStreamStats() => _readJsonObject(
    _bindings.uvc_get_stream_stats_json,
    UvcStreamStats.fromJson,
  ) ?? const UvcStreamStats.zero();

  @override
  Future<int> createPreviewTexture() async {
    _ensureSupportedPlatform();
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
    _ensureSupportedPlatform();
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
    _ensureSupportedPlatform();
    await _textureChannel.invokeMethod<void>(
      'attachPreviewTexture',
      <String, Object?>{
        'sessionHandle': nativeSessionHandle,
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
        _s,
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
        _s,
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
    final int result = _bindings.uvc_ctrl_get(_s, controlId.nativeValue);
    // INT32_MIN == -2147483648 signals an error from the native layer
    if (result == -2147483648) {
      return null;
    }
    return result;
  }

  /// Sets [controlId] to [value]. Returns 0 on success, negative on error.
  @override
  int setControl(UvcControlId controlId, int value) =>
      _bindings.uvc_ctrl_set(_s, controlId.nativeValue, value);

  @override
  UvcWhiteBalanceComponent? getWhiteBalanceComponent() => _readJsonObject(
    _bindings.uvc_get_white_balance_component_json,
    UvcWhiteBalanceComponent.fromJson,
  );

  @override
  int setWhiteBalanceComponent(UvcWhiteBalanceComponent value) =>
      _bindings.uvc_set_white_balance_component_values(_s, value.blue, value.red);

  @override
  UvcFocusRelativeControl? getFocusRelativeControl() => _readJsonObject(
    _bindings.uvc_get_focus_rel_json,
    UvcFocusRelativeControl.fromJson,
  );

  @override
  int setFocusRelativeControl(UvcFocusRelativeControl value) =>
      _bindings.uvc_set_focus_rel_values(_s, value.focusRel, value.speed);

  @override
  UvcZoomRelativeControl? getZoomRelativeControl() => _readJsonObject(
    _bindings.uvc_get_zoom_rel_json,
    UvcZoomRelativeControl.fromJson,
  );

  @override
  int setZoomRelativeControl(UvcZoomRelativeControl value) => _bindings
      .uvc_set_zoom_rel_values(_s, value.zoomRel, value.digitalZoom, value.speed);

  @override
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_abs_json,
    UvcPanTiltAbsoluteControl.fromJson,
  );

  @override
  int setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value) =>
      _bindings.uvc_set_pantilt_abs_values(_s, value.pan, value.tilt);

  @override
  UvcPanTiltRelativeControl? getPanTiltRelativeControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_rel_json,
    UvcPanTiltRelativeControl.fromJson,
  );

  @override
  int setPanTiltRelativeControl(UvcPanTiltRelativeControl value) =>
      _bindings.uvc_set_pantilt_rel_values(
        _s,
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
      _bindings.uvc_set_roll_rel_values(_s, value.rollRel, value.speed);

  @override
  UvcDigitalWindowControl? getDigitalWindowControl() => _readJsonObject(
    _bindings.uvc_get_digital_window_json,
    UvcDigitalWindowControl.fromJson,
  );

  @override
  int setDigitalWindowControl(UvcDigitalWindowControl value) =>
      _bindings.uvc_set_digital_window_values(
        _s,
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
        _s,
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
      _s,
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
        _s,
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
      // The native layer emits one entry per descriptor interval, and integer
      // fps truncation can collapse distinct intervals into identical mode
      // tuples — dedupe so consumers never see duplicates.
      return decoded
          .map(
            (dynamic item) =>
                UvcCameraMode.fromJson(item as Map<String, dynamic>),
          )
          .toSet()
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
  _ensureSupportedPlatform();
  // On Windows and Linux the FFI symbols are exported from the plugin
  // library, which also hosts the native backend and the platform channels.
  final String libraryName;
  if (Platform.isWindows) {
    libraryName = '${_libName}_plugin.dll';
  } else if (Platform.isLinux) {
    libraryName = 'lib${_libName}_plugin.so';
  } else {
    libraryName = 'lib$_libName.so';
  }
  return _cachedDylib ??= DynamicLibrary.open(libraryName);
}

void _ensureSupportedPlatform() {
  if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) {
    throw UnsupportedError(
      'flutter_ffi_uvc is supported only on Android, Windows, and Linux.',
    );
  }
}

/// Guard for fd-based APIs, which only mean something on Android. Failing
/// fast here keeps callers from depending on what the native layer happens to
/// do with the value elsewhere.
void _ensureAndroidOnlyApi(String apiName) {
  _ensureSupportedPlatform();
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      '$apiName is Android-only. Use openUsbDevice/closeUsbDevice on Windows '
      'and Linux.',
    );
  }
}

FlutterFfiUvcBindings get _bindings =>
    _cachedBindings ??= FlutterFfiUvcBindings(_dylib);

/// Shared default camera instance. Create more with `UvcCamera()`.
final UvcCamera uvcCamera = FfiUvcCamera();
