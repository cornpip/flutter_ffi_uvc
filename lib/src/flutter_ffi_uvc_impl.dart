import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'flutter_ffi_uvc_bindings_generated.dart';
import 'uvc_camera_api.dart';

enum _State { closed, open, previewing, disposed }

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

  // Device events are process-wide. One channel subscription feeds every
  // instance and the app-facing stream. The instance that holds a detached
  // device is told first, so an app handler that reacts to the same event
  // already finds the device closed.
  static StreamController<UvcDeviceEvent>? _deviceEventController;
  static StreamSubscription<dynamic>? _channelDeviceEvents;

  static StreamController<UvcDeviceEvent> _deviceEvents() {
    return _deviceEventController ??=
        StreamController<UvcDeviceEvent>.broadcast(
          onListen: _ensureChannelDeviceEvents,
          onCancel: _releaseChannelDeviceEvents,
        );
  }

  static void _ensureChannelDeviceEvents() {
    _channelDeviceEvents ??= _deviceEventChannel
        .receiveBroadcastStream()
        .listen(
          (dynamic raw) {
            final UvcDeviceEvent event = UvcDeviceEvent.fromMap(
              (raw as Map<Object?, Object?>?) ?? <Object?, Object?>{},
            );
            if (event.type == UvcDeviceEventType.detached) {
              _deviceHolder(event.device.deviceId)?._onOwnDeviceDetached();
            }
            _deviceEventController?.add(event);
          },
          onError: (Object error, StackTrace stack) {
            _deviceEventController?.addError(error, stack);
          },
        );
  }

  // Keeps the platform receiver only while someone needs it.
  static void _releaseChannelDeviceEvents() {
    final bool appListening = _deviceEventController?.hasListener ?? false;
    _openDevices.removeWhere(
      (_, WeakReference<FfiUvcCamera> claim) => claim.target == null,
    );
    if (appListening || _openDevices.isNotEmpty) return;
    _channelDeviceEvents?.cancel();
    _channelDeviceEvents = null;
  }

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
    if (_openDevices[deviceId]?.target == this) {
      _openDevices.remove(deviceId);
      _releaseChannelDeviceEvents();
    }
  }

  // Set when a call is rejected before reaching the native layer.
  String? _dartLastError;

  @override
  int? get openedDeviceId => _openedDeviceId;

  void _forgetOpenedDevice() {
    final int? deviceId = _openedDeviceId;
    _openedDeviceId = null;
    if (deviceId != null) _releaseDeviceClaim(deviceId);
  }

  void _rememberOpenedDevice(int deviceId) {
    _openedDeviceId = deviceId;
    _ensureChannelDeviceEvents();
  }

  // The transport is gone, so the session cannot be used again.
  void _onOwnDeviceDetached() {
    if (_disposed) return;
    unawaited(closeUsbDevice());
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

  // Releases the platform connection and texture binding of an instance
  // that is garbage collected without dispose(). The platform close also
  // closes the native device first, so it is safe in any order with
  // _finalizer.
  static final Finalizer<int> _platformFinalizer = Finalizer<int>((int handle) {
    final Map<String, Object?> args = <String, Object?>{
      'sessionHandle': handle,
    };
    unawaited(
      _textureChannel
          .invokeMethod<void>('detachPreviewSession', args)
          .catchError((_) {}),
    );
    unawaited(
      _usbChannel.invokeMethod<void>('closeUsbDevice', args).catchError((_) {}),
    );
  });

  Pointer<uvc_session_t> _createSession() {
    final Pointer<uvc_session_t> session = _bindings.uvc_session_create();
    if (session == nullptr) {
      throw StateError('Native session allocation failed.');
    }
    _finalizer.attach(this, session.cast<Void>(), detach: this);
    _platformFinalizer.attach(this, session.address, detach: this);
    return session;
  }

  /// Native session address, passed to the platform channels.
  int get nativeSessionHandle => _s.address;

  UvcPreviewTransform _previewTransform = UvcPreviewTransform.identity;

  final StreamController<UvcStreamError> _streamErrorController =
      StreamController<UvcStreamError>.broadcast();
  NativeCallable<Void Function(Pointer<Void>, Pointer<Char>)>? _errorCallable;

  // Stall detection state.
  final StreamController<UvcStallEvent> _stallEventController =
      StreamController<UvcStallEvent>.broadcast();
  UvcStallDetectionConfig? _stallConfig;
  Timer? _stallTimer;
  // Lifecycle state. Every call that changes it runs as a command on one
  // queue per instance, in call order, so the state and the native session
  // move together. Between commands the state is one of these.
  _State _state = _State.closed;

  Future<void> _nativeQueue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() command) {
    final Future<T> result = _nativeQueue.then((_) => command());
    _nativeQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  // Bumped by stop, close, and dispose at call time. A preview verification
  // in progress ends early with interrupted when it sees a newer value. The
  // queued command that bumped it then runs and stops the stream.
  int _cancelRequests = 0;

  // Bumped by every app lifecycle call at call time. A stall auto-restart
  // stops retrying when the app has moved on.
  int _lifecycleCalls = 0;

  // True while an open command waits on the platform (Android permission
  // dialog). close and dispose cancel that immediately instead of waiting.
  bool _openWaitingOnPlatform = false;

  String _nativeLastError() {
    final Pointer<Char> pointer = _bindings.uvc_last_error(_s).cast<Char>();
    return pointer == nullptr ? '' : pointer.cast<Utf8>().toDartString();
  }

  // Builds the exception for a failed call and mirrors it in lastError.
  UvcException _fail(UvcErrorCode code, String message) {
    _dartLastError = message;
    return UvcException.fromNativeCode(code.nativeValue, message: message);
  }

  // Throws for a non-zero native code, with the native message.
  void _check(int code) {
    if (code == 0) return;
    throw UvcException.fromNativeCode(code, message: _nativeLastError());
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
    if (_errorCallable == null) {
      // Weak so an undisposed instance can still be collected and finalized.
      final WeakReference<FfiUvcCamera> weak = WeakReference<FfiUvcCamera>(
        this,
      );
      _errorCallable =
          NativeCallable<Void Function(Pointer<Void>, Pointer<Char>)>.listener(
            (Pointer<Void> data, Pointer<Char> message) =>
                weak.target?._onNativeError(data, message),
          );
    }
    _bindings.uvc_set_error_listener(
      _s,
      _errorCallable!.nativeFunction,
      nullptr,
    );
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

  // Runs inside a queued command.
  Future<UvcPreviewStartResult> _startPreviewInternal(
    UvcCameraMode mode, {
    required UvcPreviewPolicy policy,
    required int requiredConsecutiveValidFrames,
    required Duration timeout,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    if (_disposed || _state == _State.closed) {
      final String message = _disposed
          ? 'UvcCamera has been disposed'
          : 'Camera is not open';
      _dartLastError = message;
      return UvcPreviewStartResult(
        mode: mode,
        success: false,
        validFrameCount: 0,
        consecutiveValidFrames: 0,
        errorCount: 0,
        elapsed: stopwatch.elapsed,
        lastError: message,
        nativeErrorCode: UvcErrorCode.noDevice.nativeValue,
      );
    }
    final int cancelGeneration = _cancelRequests;
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
      final int startResult = await _openPreviewOffThread(mode);
      if (_disposed) {
        // The dispose command queued behind this one stops the stream.
        return _interrupted(mode, stopwatch, 0, 0, errorCount);
      }
      if (startResult != 0) {
        _state = _afterFailedStart();
        final String error = _nativeLastError();
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
      // The stream runs from here. A stop, close, or dispose queued behind
      // this command will stop it, so an interrupted verification only
      // returns early.
      _state = _State.previewing;

      while (stopwatch.elapsed < timeout) {
        if (_cancelRequests != cancelGeneration) {
          return _interrupted(
            mode,
            stopwatch,
            totalValidFrames,
            consecutiveValidFrames,
            errorCount,
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

      if (_cancelRequests != cancelGeneration) {
        return _interrupted(
          mode,
          stopwatch,
          totalValidFrames,
          consecutiveValidFrames,
          errorCount,
        );
      }
      final String error = lastError ?? _nativeLastError();
      _stopPreviewNative();
      _state = _State.open;
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

  UvcPreviewStartResult _interrupted(
    UvcCameraMode mode,
    Stopwatch stopwatch,
    int validFrames,
    int consecutive,
    int errors,
  ) => UvcPreviewStartResult(
    mode: mode,
    success: false,
    validFrameCount: validFrames,
    consecutiveValidFrames: consecutive,
    errorCount: errors,
    elapsed: stopwatch.elapsed,
    lastError: 'Preview start interrupted by stop, close, or dispose',
    nativeErrorCode: UvcErrorCode.interrupted.nativeValue,
  );

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
    final List<Object?>? raw = await _usbChannel.invokeListMethod<Object?>(
      'listUsbDevices',
    );
    return (raw ?? <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(UvcUsbDevice.fromMap)
        .toList();
  }

  @override
  Future<void> openUsbDevice(int deviceId) {
    _ensureSupportedPlatform();
    _lifecycleCalls += 1;
    return _serialized(() => _openUsbDeviceCommand(deviceId));
  }

  Future<void> _openUsbDeviceCommand(int deviceId) async {
    if (_disposed)
      throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
    _dartLastError = null;
    // An instance holds one device. Close this instance's device first.
    _stopPreviewNative();
    await _closeUsbDeviceInternal();
    final FfiUvcCamera? holder = _deviceHolder(deviceId);
    if (holder != null && holder != this) {
      throw _fail(
        UvcErrorCode.busy,
        'Device $deviceId is open in another UvcCamera instance',
      );
    }
    // Claim the device before the first await so a concurrent open on
    // another instance sees it as busy. Released again on failure.
    _openDevices[deviceId] = WeakReference<FfiUvcCamera>(this);
    final int handle = nativeSessionHandle;
    final Map<Object?, Object?>? result;
    _openWaitingOnPlatform = true;
    try {
      result = await _usbChannel.invokeMapMethod<Object?, Object?>(
        'openUsbDevice',
        <String, Object?>{'sessionHandle': handle, 'deviceId': deviceId},
      );
    } on PlatformException catch (error) {
      _releaseDeviceClaim(deviceId);
      if (error.code == 'closed') {
        // closeUsbDevice() or dispose() cancelled this open.
        throw _fail(
          UvcErrorCode.noDevice,
          'Open cancelled: the instance was closed',
        );
      }
      rethrow;
    } finally {
      _openWaitingOnPlatform = false;
    }
    if (_disposed) {
      _releaseDeviceClaim(deviceId);
      await _platformClose(handle);
      throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
    }
    final int fd = result?['fileDescriptor'] as int? ?? -1;
    // Opening can block for seconds while the OS finishes initialising a
    // freshly plugged camera, so it runs on a worker isolate.
    final int openResult = await Isolate.run(
      () =>
          _bindings.uvc_open_fd(Pointer<uvc_session_t>.fromAddress(handle), fd),
    );
    if (_disposed) {
      // The dispose command queued behind this one closes the device.
      _releaseDeviceClaim(deviceId);
      throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
    }
    if (openResult == 0) {
      _setupNativeErrorListener();
      _rememberOpenedDevice(deviceId);
      _state = _State.open;
      return;
    }
    // The platform-side open succeeded but the native session failed to
    // attach. Close it so a failure leaves nothing open.
    _releaseDeviceClaim(deviceId);
    final String message = _nativeLastError();
    try {
      await _closeUsbDeviceInternal();
    } catch (_) {
      // The original error is the one to report.
    }
    throw UvcException.fromNativeCode(openResult, message: message);
  }

  Future<void> _platformClose(int handle) async {
    try {
      await _usbChannel.invokeMethod<void>('closeUsbDevice', <String, Object?>{
        'sessionHandle': handle,
      });
    } catch (_) {
      // Nothing left to release.
    }
  }

  @override
  Future<void> closeUsbDevice() {
    _ensureSupportedPlatform();
    _lifecycleCalls += 1;
    _cancelRequests += 1;
    // An open waiting on the platform is cancelled now instead of after it.
    if (_openWaitingOnPlatform) unawaited(_platformClose(nativeSessionHandle));
    return _serialized(() async {
      if (_disposed) return;
      _dartLastError = null;
      _stopPreviewNative();
      await _closeUsbDeviceInternal();
    });
  }

  // Runs inside a queued command.
  Future<void> _closeUsbDeviceInternal() async {
    _forgetOpenedDevice();
    _resetStallTracking();
    _state = _State.closed;
    // Closing joins the stream thread, so do it before the callable goes away.
    _bindings.uvc_close_device(_s);
    _tearDownNativeErrorListener();
    await _usbChannel.invokeMethod<void>('closeUsbDevice', <String, Object?>{
      'sessionHandle': nativeSessionHandle,
    });
  }

  Future<void>? _disposing;

  @override
  Future<void> dispose() => _disposing ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    // Mark disposed before the first await so a re-entrant dispose() or a
    // concurrent open cannot see the session.
    _disposed = true;
    _lifecycleCalls += 1;
    _cancelRequests += 1;
    _forgetOpenedDevice();
    final Pointer<uvc_session_t>? session = _session;
    _session = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _stallConfig = null;
    if (session == null) {
      _state = _State.disposed;
      await _streamErrorController.close();
      await _stallEventController.close();
      return;
    }
    _finalizer.detach(this);
    _platformFinalizer.detach(this);
    // An open waiting on the platform is cancelled now instead of after it.
    if (_openWaitingOnPlatform) await _platformClose(session.address);
    // Queued commands run first and skip themselves. The session goes away
    // only after them.
    await _serialized(() async {
      _state = _State.disposed;
      try {
        _bindings.uvc_stop_preview(session);
        _bindings.uvc_close_device(session);
        _tearDownNativeErrorListener(session);
        await _platformClose(session.address);
        await _textureChannel.invokeMethod<void>(
          'detachPreviewSession',
          <String, Object?>{'sessionHandle': session.address},
        );
      } finally {
        _bindings.uvc_session_destroy(session);
        await _streamErrorController.close();
        await _stallEventController.close();
      }
    });
  }

  @override
  Future<void> openFd(int fd) {
    _ensureAndroidOnlyApi('openFd');
    if (fd < 0) {
      throw _fail(UvcErrorCode.invalidParam, 'Invalid file descriptor: $fd');
    }
    _lifecycleCalls += 1;
    return _serialized(() async {
      if (_disposed)
        throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
      _dartLastError = null;
      _resetStallTracking();
      // A device opened through openUsbDevice is replaced by the raw
      // descriptor. Close it natively first, then release its platform
      // connection.
      if (_openedDeviceId != null) {
        _stopPreviewNative();
        _bindings.uvc_close_device(_s);
        _tearDownNativeErrorListener();
        _state = _State.closed;
        _forgetOpenedDevice();
        await _platformClose(nativeSessionHandle);
      }
      final int result = _bindings.uvc_open_fd(_s, fd);
      if (result != 0) {
        _state = _State.closed;
        _check(result);
      }
      _setupNativeErrorListener();
      _state = _State.open;
    });
  }

  @override
  Future<void> openPreview(UvcCameraMode mode) {
    _lifecycleCalls += 1;
    return _serialized(() async {
      if (_disposed)
        throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
      if (_state == _State.closed) {
        throw _fail(UvcErrorCode.noDevice, 'Camera is not open');
      }
      final int result = await _openPreviewOffThread(mode);
      if (_disposed) {
        throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
      }
      if (result != 0) {
        _state = _afterFailedStart();
        _check(result);
      }
      _state = _State.previewing;
    });
  }

  // The state a failed start leaves behind. A native start that fails
  // before it stops the running stream leaves that stream running.
  _State _afterFailedStart() =>
      _bindings.uvc_is_previewing(_s) != 0 ? _State.previewing : _State.open;

  // Native start on a worker isolate so the device negotiation does not
  // block the UI.
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
    if (policy == UvcPreviewPolicy.stableFrames &&
        consecutiveValidFrames <= 0) {
      throw ArgumentError.value(
        consecutiveValidFrames,
        'consecutiveValidFrames',
        'Must be greater than 0.',
      );
    }
    _lifecycleCalls += 1;
    _lastPreviewRequest = _PreviewRequest(
      mode: mode,
      policy: policy,
      consecutiveValidFrames: consecutiveValidFrames,
      timeout: timeout,
    );
    return _serialized(() async {
      _resetStallTracking();
      return _startPreviewInternal(
        mode,
        policy: policy,
        requiredConsecutiveValidFrames: consecutiveValidFrames,
        timeout: timeout,
      );
    });
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
    final List<UvcCameraMode> modes =
        (candidates ?? _defaultAutoCandidates(preference))
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
      // A failed attempt leaves the device open for the next candidate.
      // Interrupted or no device means the app moved on.
      final int code = result.nativeErrorCode;
      if (code == UvcErrorCode.interrupted.nativeValue ||
          code == UvcErrorCode.noDevice.nativeValue) {
        break;
      }
    }
    return UvcAutoPreviewResult(attempts: attempts);
  }

  /// Orders descriptor-reported modes MJPEG before uncompressed formats, then
  /// by resolution and frame rate. Ascending for
  /// [UvcAutoPreviewPreference.reliability], descending for
  /// [UvcAutoPreviewPreference.quality].
  List<UvcCameraMode> _defaultAutoCandidates(
    UvcAutoPreviewPreference preference,
  ) {
    int formatRank(UvcCameraMode mode) => mode.formatName == 'MJPEG' ? 0 : 1;
    final int direction = preference == UvcAutoPreviewPreference.reliability
        ? 1
        : -1;
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
    if (_state == _State.previewing) _state = _State.open;
  }

  @override
  Future<void> stopPreview() {
    _lifecycleCalls += 1;
    _cancelRequests += 1;
    return _serialized(() async {
      if (_disposed) return;
      _dartLastError = null;
      _resetStallTracking();
      _stopPreviewNative();
    });
  }

  @override
  Future<void> closeFd() {
    _ensureAndroidOnlyApi('closeFd');
    _lifecycleCalls += 1;
    _cancelRequests += 1;
    if (_openWaitingOnPlatform) unawaited(_platformClose(nativeSessionHandle));
    return _serialized(() async {
      if (_disposed) return;
      _dartLastError = null;
      _stopPreviewNative();
      final bool platformHeld = _openedDeviceId != null;
      _forgetOpenedDevice();
      _resetStallTracking();
      _state = _State.closed;
      _bindings.uvc_close_device(_s);
      _tearDownNativeErrorListener();
      _resetPreviewState();
      if (platformHeld) await _platformClose(nativeSessionHandle);
    });
  }

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
    return _deviceEvents().stream;
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
    // Weak so an undisposed instance can still be collected and finalized.
    final WeakReference<FfiUvcCamera> weak = WeakReference<FfiUvcCamera>(this);
    _stallTimer = Timer.periodic(config.checkInterval, (Timer timer) {
      final FfiUvcCamera? self = weak.target;
      if (self == null) {
        timer.cancel();
        return;
      }
      self._stallTick();
    });
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
    final int calls = _lifecycleCalls;
    try {
      while (_restartAttempts < config.maxRestartAttempts) {
        // The first attempt restarts a stalled preview. Later attempts follow
        // our own failed ones, which leave the device open. Any app
        // lifecycle call in between means the app moved on.
        final _State required = _restartAttempts == 0
            ? _State.previewing
            : _State.open;
        if (_state != required || _lifecycleCalls != calls) return;
        _restartAttempts += 1;
        final int attempt = _restartAttempts;
        final UvcPreviewStartResult result = await _serialized(() async {
          if (_disposed || _lifecycleCalls != calls) {
            return _interrupted(request.mode, Stopwatch(), 0, 0, 0);
          }
          _stopPreviewNative();
          return _startPreviewInternal(
            request.mode,
            policy: request.policy,
            requiredConsecutiveValidFrames: request.consecutiveValidFrames,
            timeout: request.timeout,
          );
        });
        if (result.nativeErrorCode == UvcErrorCode.interrupted.nativeValue ||
            _lifecycleCalls != calls ||
            _stallConfig == null) {
          return;
        }
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
  String get lastError => _dartLastError ?? _nativeLastError();

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
        jpegBytes: Uint8List.fromList(nativeBuffer.asTypedList(encodedBytes)),
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
  void startVideoRecording(
    String path, {
    int bitrateBps = 0,
    UvcPreviewTransform? transform,
  }) {
    final UvcPreviewTransform effective = transform ?? _previewTransform;
    // The mode fps seeds encoder rate control; 0 lets the native layer pick.
    final int fpsHint = _lastPreviewRequest?.mode.fps ?? 0;
    final Pointer<Utf8> nativePath = path.toNativeUtf8(allocator: calloc);
    try {
      _check(
        _bindings.uvc_start_recording(
          _s,
          nativePath.cast(),
          bitrateBps,
          fpsHint,
          effective.rotation,
          effective.flipHorizontal ? 1 : 0,
          effective.flipVertical ? 1 : 0,
        ),
      );
    } finally {
      calloc.free(nativePath);
    }
  }

  @override
  void stopVideoRecording() => _check(_bindings.uvc_stop_recording(_s));

  @override
  bool get isRecording => _bindings.uvc_is_recording(_s) != 0;

  @override
  int latestFrameSequence() => _bindings.uvc_latest_frame_sequence(_s);

  @override
  UvcStreamStats getStreamStats() =>
      _readJsonObject(
        _bindings.uvc_get_stream_stats_json,
        UvcStreamStats.fromJson,
      ) ??
      const UvcStreamStats.zero();

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
  void setControl(UvcControlId controlId, int value) =>
      _check(_bindings.uvc_ctrl_set(_s, controlId.nativeValue, value));

  @override
  UvcWhiteBalanceComponent? getWhiteBalanceComponent() => _readJsonObject(
    _bindings.uvc_get_white_balance_component_json,
    UvcWhiteBalanceComponent.fromJson,
  );

  @override
  void setWhiteBalanceComponent(UvcWhiteBalanceComponent value) => _check(
    _bindings.uvc_set_white_balance_component_values(_s, value.blue, value.red),
  );

  @override
  UvcFocusRelativeControl? getFocusRelativeControl() => _readJsonObject(
    _bindings.uvc_get_focus_rel_json,
    UvcFocusRelativeControl.fromJson,
  );

  @override
  void setFocusRelativeControl(UvcFocusRelativeControl value) => _check(
    _bindings.uvc_set_focus_rel_values(_s, value.focusRel, value.speed),
  );

  @override
  UvcZoomRelativeControl? getZoomRelativeControl() => _readJsonObject(
    _bindings.uvc_get_zoom_rel_json,
    UvcZoomRelativeControl.fromJson,
  );

  @override
  void setZoomRelativeControl(UvcZoomRelativeControl value) => _check(
    _bindings.uvc_set_zoom_rel_values(
      _s,
      value.zoomRel,
      value.digitalZoom,
      value.speed,
    ),
  );

  @override
  UvcPanTiltAbsoluteControl? getPanTiltAbsoluteControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_abs_json,
    UvcPanTiltAbsoluteControl.fromJson,
  );

  @override
  void setPanTiltAbsoluteControl(UvcPanTiltAbsoluteControl value) =>
      _check(_bindings.uvc_set_pantilt_abs_values(_s, value.pan, value.tilt));

  @override
  UvcPanTiltRelativeControl? getPanTiltRelativeControl() => _readJsonObject(
    _bindings.uvc_get_pantilt_rel_json,
    UvcPanTiltRelativeControl.fromJson,
  );

  @override
  void setPanTiltRelativeControl(UvcPanTiltRelativeControl value) => _check(
    _bindings.uvc_set_pantilt_rel_values(
      _s,
      value.panRel,
      value.panSpeed,
      value.tiltRel,
      value.tiltSpeed,
    ),
  );

  @override
  UvcRollRelativeControl? getRollRelativeControl() => _readJsonObject(
    _bindings.uvc_get_roll_rel_json,
    UvcRollRelativeControl.fromJson,
  );

  @override
  void setRollRelativeControl(UvcRollRelativeControl value) =>
      _check(_bindings.uvc_set_roll_rel_values(_s, value.rollRel, value.speed));

  @override
  UvcDigitalWindowControl? getDigitalWindowControl() => _readJsonObject(
    _bindings.uvc_get_digital_window_json,
    UvcDigitalWindowControl.fromJson,
  );

  @override
  void setDigitalWindowControl(UvcDigitalWindowControl value) => _check(
    _bindings.uvc_set_digital_window_values(
      _s,
      value.windowTop,
      value.windowLeft,
      value.windowBottom,
      value.windowRight,
      value.numSteps,
      value.numStepsUnits,
    ),
  );

  @override
  UvcRegionOfInterestControl? getRegionOfInterestControl() => _readJsonObject(
    _bindings.uvc_get_region_of_interest_json,
    UvcRegionOfInterestControl.fromJson,
  );

  @override
  void setRegionOfInterestControl(UvcRegionOfInterestControl value) => _check(
    _bindings.uvc_set_region_of_interest_values(
      _s,
      value.roiTop,
      value.roiLeft,
      value.roiBottom,
      value.roiRight,
      value.autoControls,
    ),
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
      _previewTransform.copyWith(flipVertical: !_previewTransform.flipVertical),
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
