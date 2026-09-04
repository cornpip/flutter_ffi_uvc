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
  // instance and the app-facing stream. The stream is synchronous so an app
  // handler runs before the holding instance closes the detached device and
  // still sees it in openedDeviceId.
  static StreamController<UvcDeviceEvent>? _deviceEventController;
  static StreamSubscription<dynamic>? _channelDeviceEvents;

  static StreamController<UvcDeviceEvent> _deviceEvents() {
    return _deviceEventController ??=
        StreamController<UvcDeviceEvent>.broadcast(
          onListen: _ensureChannelDeviceEvents,
          onCancel: _releaseChannelDeviceEvents,
          sync: true,
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
            final FfiUvcCamera? holder =
                event.type == UvcDeviceEventType.detached
                ? _deviceHolder(event.device.deviceId)
                : null;
            try {
              _deviceEventController?.add(event);
            } finally {
              holder?._onOwnDeviceDetached(event.device.deviceId);
            }
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
    // An earlier open of this instance may have completed meanwhile. The
    // native open just closed its device, so its claim ends here.
    _forgetOpenedDevice();
    _openedDeviceId = deviceId;
    _ensureChannelDeviceEvents();
  }

  // The transport is gone, so the session cannot be used again. An app
  // handler for the same event may already have queued an open of another
  // device, so the close only runs while the detached one is still open.
  void _onOwnDeviceDetached(int deviceId) {
    if (_disposed || _openedDeviceId != deviceId) return;
    _dartLastError = null;
    _forgetOpenedDevice();
    unawaited(
      _awaitRequest(_bindings.uvc_request_close(_s)).then((_) {
        if (!_disposed) _afterClosed();
      }),
    );
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
  // lost to a hot restart without dispose(). The session releases the
  // camera and, through the platform listener, its platform connection.
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
    _setupRequestListener(session);
    return session;
  }

  /// Registry id of the native session, passed to the platform channels.
  /// Never reused within the process, unlike the address.
  int get nativeSessionHandle => _bindings.uvc_session_id(_s);

  /// Native session address, for test-only backend entry points.
  int get nativeSessionAddress => _s.address;

  UvcPreviewTransform _previewTransform = UvcPreviewTransform.identity;

  final StreamController<UvcStreamError> _streamErrorController =
      StreamController<UvcStreamError>.broadcast();
  NativeCallable<Void Function(Pointer<Void>, Pointer<Char>)>? _errorCallable;

  // Stall detection state.
  final StreamController<UvcStallEvent> _stallEventController =
      StreamController<UvcStallEvent>.broadcast();
  UvcStallDetectionConfig? _stallConfig;
  Timer? _stallTimer;
  // Completers for queued requests, keyed by native request id. Completed
  // from the request listener in completion order.
  final Map<int, Completer<int>> _pending = <int, Completer<int>>{};
  NativeCallable<Void Function(Pointer<Void>, Int64, Int, Int)>?
  _requestCallable;

  void _setupRequestListener(Pointer<uvc_session_t> session) {
    // Weak so an undisposed instance can still be collected and finalized.
    final WeakReference<FfiUvcCamera> weak = WeakReference<FfiUvcCamera>(this);
    _requestCallable =
        NativeCallable<Void Function(Pointer<Void>, Int64, Int, Int)>.listener(
          (Pointer<Void> _, int requestId, int op, int result) =>
              weak.target?._onRequestDone(requestId, result),
        );
    _bindings.uvc_set_request_listener(
      session,
      _requestCallable!.nativeFunction,
      nullptr,
    );
  }

  void _onRequestDone(int requestId, int result) {
    _pending.remove(requestId)?.complete(result);
  }

  // Resolves with the request's result code. A negative id is a request
  // the native layer refused to queue and resolves with that code at once.
  Future<int> _awaitRequest(int requestId) {
    if (requestId <= 0) return Future<int>.value(requestId);
    final Completer<int> completer = Completer<int>();
    _pending[requestId] = completer;
    return completer.future;
  }

  // After the session is destroyed nothing completes the rest.
  void _failPendingRequests() {
    final List<Completer<int>> waiting = _pending.values.toList();
    _pending.clear();
    for (final Completer<int> completer in waiting) {
      completer.complete(UvcErrorCode.noDevice.nativeValue);
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw _fail(UvcErrorCode.noDevice, 'UvcCamera has been disposed');
    }
  }

  // Throws for a failed request. [cancelMessage] names the noDevice error
  // for a request that a later close or dispose interrupted.
  Never _throwRequestFailure(int result, String? cancelMessage) {
    _throwIfDisposed();
    if (result == UvcErrorCode.interrupted.nativeValue &&
        cancelMessage != null) {
      throw _fail(UvcErrorCode.noDevice, cancelMessage);
    }
    _dartLastError = null;
    throw UvcException.fromNativeCode(result, message: _nativeLastError());
  }

  static int _nativePolicy(UvcPreviewPolicy policy) => switch (policy) {
    UvcPreviewPolicy.stableFrames => UVC_VERIFY_STABLE_FRAMES,
    UvcPreviewPolicy.sequenceOnly => UVC_VERIFY_SEQUENCE_ONLY,
  };

  static void _fillNativeMode(uvc_mode_t target, UvcCameraMode mode) {
    target.frame_format = mode.frameFormat;
    target.width = mode.width;
    target.height = mode.height;
    target.fps = mode.fps;
  }

  static uvc_mode_t _nativeMode(UvcCameraMode mode) {
    final uvc_mode_t native = Struct.create<uvc_mode_t>();
    _fillNativeMode(native, mode);
    return native;
  }

  static const Map<int, String> _formatNames = <int, String>{
    3: 'YUYV',
    4: 'UYVY',
    5: 'RGB',
    6: 'BGR',
    7: 'MJPEG',
    8: 'H264',
    9: 'GRAY8',
  };

  // The mode object for a native attempt: the caller's own when it was one
  // of the candidates, else one built from the numbers.
  UvcCameraMode _modeFromJson(
    Map<String, dynamic> json,
    List<UvcCameraMode>? candidates,
  ) {
    final int format = json['frameFormat'] as int;
    final int width = json['width'] as int;
    final int height = json['height'] as int;
    final int fps = json['fps'] as int;
    for (final UvcCameraMode mode in candidates ?? const <UvcCameraMode>[]) {
      if (mode.frameFormat == format &&
          mode.width == width &&
          mode.height == height &&
          mode.fps == fps) {
        return mode;
      }
    }
    return UvcCameraMode(
      frameFormat: format,
      formatName: _formatNames[format] ?? 'UNKNOWN',
      width: width,
      height: height,
      fps: fps,
    );
  }

  Map<String, dynamic>? _takeResultJson(int requestId) {
    if (_disposed || requestId <= 0) return null;
    // Room for an auto result with every candidate failing verbosely.
    const int bufferLength = 128 * 1024;
    final Pointer<Uint8> nativeBuffer = calloc<Uint8>(bufferLength);
    try {
      final int copiedBytes = _bindings.uvc_take_request_result_json(
        _s,
        requestId,
        nativeBuffer,
        bufferLength,
      );
      if (copiedBytes <= 0) return null;
      return jsonDecode(
            nativeBuffer.cast<Utf8>().toDartString(length: copiedBytes),
          )
          as Map<String, dynamic>;
    } finally {
      calloc.free(nativeBuffer);
    }
  }

  UvcPreviewStartResult _startResultFromJson(
    Map<String, dynamic> json,
    UvcCameraMode mode,
  ) => UvcPreviewStartResult(
    mode: mode,
    success: json['success'] as bool,
    validFrameCount: json['validFrameCount'] as int,
    consecutiveValidFrames: json['consecutiveValidFrames'] as int,
    errorCount: json['errorCount'] as int,
    elapsed: Duration(milliseconds: json['elapsedMs'] as int),
    lastError: json['lastError'] as String?,
    nativeErrorCode: json['nativeErrorCode'] as int,
  );

  // The result of a start request. Without a result JSON (the session was
  // destroyed meanwhile, or the request was refused) the code decides.
  UvcPreviewStartResult _takeStartResult(
    int requestId,
    int result,
    UvcCameraMode mode,
  ) {
    final Map<String, dynamic>? json = _takeResultJson(requestId);
    if (json != null) return _startResultFromJson(json, mode);
    if (result == UvcErrorCode.interrupted.nativeValue) {
      return _interrupted(mode);
    }
    return _noDeviceResult(
      mode,
      _disposed ? 'UvcCamera has been disposed' : 'Camera is not open',
      code: result,
    );
  }

  List<UvcPreviewStartResult> _takeAutoResult(
    int requestId,
    int result,
    List<UvcCameraMode>? candidates,
  ) {
    final Map<String, dynamic>? json = _takeResultJson(requestId);
    if (json == null) {
      if (result == UvcErrorCode.interrupted.nativeValue ||
          candidates == null) {
        return const <UvcPreviewStartResult>[];
      }
      return <UvcPreviewStartResult>[
        if (candidates.isNotEmpty)
          _noDeviceResult(
            candidates.first,
            _disposed ? 'UvcCamera has been disposed' : 'Camera is not open',
            code: result,
          ),
      ];
    }
    final List<UvcCameraMode>? known =
        candidates ?? (_disposed ? null : supportedModes());
    return (json['attempts'] as List<dynamic>)
        .map(
          (dynamic item) => _startResultFromJson(
            item as Map<String, dynamic>,
            _modeFromJson(item, known),
          ),
        )
        .toList();
  }

  UvcPreviewStartResult _noDeviceResult(
    UvcCameraMode mode,
    String message, {
    int? code,
  }) {
    _dartLastError = message;
    return UvcPreviewStartResult(
      mode: mode,
      success: false,
      validFrameCount: 0,
      consecutiveValidFrames: 0,
      errorCount: 0,
      elapsed: Duration.zero,
      lastError: message,
      nativeErrorCode: code == null || code == 0
          ? UvcErrorCode.noDevice.nativeValue
          : code,
    );
  }

  UvcPreviewStartResult _interrupted(UvcCameraMode mode) =>
      UvcPreviewStartResult(
        mode: mode,
        success: false,
        validFrameCount: 0,
        consecutiveValidFrames: 0,
        errorCount: 0,
        elapsed: Duration.zero,
        lastError: 'Preview start interrupted by a later lifecycle call',
        nativeErrorCode: UvcErrorCode.interrupted.nativeValue,
      );

  String _nativeLastError() {
    final Pointer<Char> pointer = _bindings.uvc_last_error(_s).cast<Char>();
    return pointer == nullptr ? '' : pointer.cast<Utf8>().toDartString();
  }

  // Builds the exception for a failed call and mirrors it in lastError.
  UvcException _fail(UvcErrorCode code, String message) {
    _dartLastError = message;
    return UvcException.fromNativeCode(code.nativeValue, message: message);
  }

  // Throws for a non-zero native code, with the native message. lastError
  // then reads that message too.
  void _check(int code) {
    if (code == 0) return;
    _dartLastError = null;
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

  // Registers the Dart callable on the native session. The slot survives a
  // close, so re-registering on the next open only rewrites the same
  // pointer. The session clears it as part of its teardown.
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

  void _onNativeError(Pointer<Void> _, Pointer<Char> messagePtr) {
    final String message = messagePtr.cast<Utf8>().toDartString();
    if (message.isNotEmpty) {
      _streamErrorController.add(UvcStreamError(message: message));
    }
  }

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
    int width = _bindings.uvc_frame_width(_s);
    int height = _bindings.uvc_frame_height(_s);
    // A mode switch on the session worker can change the frame size between
    // the size query and the copy. A copy that does not match the size it
    // reports is retried once with that size.
    for (int attempt = 0; attempt < 2; attempt++) {
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
        final int copiedWidth = nativeWidth.value;
        final int copiedHeight = nativeHeight.value;
        if (copiedBytes == copiedWidth * copiedHeight * 4) {
          return UvcPreviewFrame(
            width: copiedWidth,
            height: copiedHeight,
            rgbaBytes: Uint8List.fromList(
              nativeBuffer.asTypedList(copiedBytes),
            ),
            sequence: nativeSequence.value,
          );
        }
        width = copiedWidth;
        height = copiedHeight;
      } finally {
        calloc.free(nativeBuffer);
        calloc.free(nativeWidth);
        calloc.free(nativeHeight);
        calloc.free(nativeSequence);
      }
    }
    return null;
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
  Future<void> openUsbDevice(int deviceId) async {
    _ensureSupportedPlatform();
    _throwIfDisposed();
    _dartLastError = null;
    final FfiUvcCamera? holder = _deviceHolder(deviceId);
    if (holder != null && holder != this) {
      throw _fail(
        UvcErrorCode.busy,
        'Device $deviceId is open in another UvcCamera instance',
      );
    }
    // The queued open closes this instance's device first, so its claim
    // ends here. The new one is claimed now so a concurrent open on another
    // instance sees it as busy. Released again on failure.
    _forgetOpenedDevice();
    _openDevices[deviceId] = WeakReference<FfiUvcCamera>(this);
    _resetStallTracking();
    final int requestId = _bindings.uvc_request_open(_s);
    final Future<int> done = _awaitRequest(requestId);
    Object? platformError;
    StackTrace? platformStack;
    if (requestId > 0) {
      // The platform hands the fd straight to the queued open. Its failure
      // fails the open, and its answer after a cancelled open is refused
      // there, so this call is never waited on.
      unawaited(
        _usbChannel
            .invokeMethod<void>('openUsbDevice', <String, Object?>{
              'sessionHandle': nativeSessionHandle,
              'deviceId': deviceId,
              'requestId': requestId,
            })
            .then(
              (_) {},
              onError: (Object error, StackTrace stack) {
                platformError = error;
                platformStack = stack;
                if (!_disposed) _bindings.uvc_supply_fd(_s, requestId, -1);
              },
            ),
      );
    }
    final int result = await done;
    if (result == 0 && !_disposed) {
      _setupNativeErrorListener();
      _rememberOpenedDevice(deviceId);
      return;
    }
    // The native open closed whatever this instance held before it failed,
    // and a close queued by dispose() takes the device back either way, so
    // an earlier open's claim ends here too.
    _forgetOpenedDevice();
    _releaseDeviceClaim(deviceId);
    if (platformError != null && !_disposed) {
      Error.throwWithStackTrace(platformError!, platformStack!);
    }
    _throwRequestFailure(result, 'Open cancelled: the instance was closed');
  }

  @override
  Future<void> openFd(int fd) async {
    _ensureAndroidOnlyApi('openFd');
    if (fd < 0) {
      throw _fail(UvcErrorCode.invalidParam, 'Invalid file descriptor: $fd');
    }
    _throwIfDisposed();
    _dartLastError = null;
    // A device opened through openUsbDevice is replaced by the raw
    // descriptor. The queued open closes it and its connection.
    _forgetOpenedDevice();
    _resetStallTracking();
    final int requestId = _bindings.uvc_request_open(_s);
    final Future<int> done = _awaitRequest(requestId);
    if (requestId > 0) _bindings.uvc_supply_fd(_s, requestId, fd);
    final int result = await done;
    if (result != 0 || _disposed) {
      _throwRequestFailure(result, 'Open cancelled: the instance was closed');
    }
    _setupNativeErrorListener();
  }

  @override
  Future<void> closeUsbDevice() {
    _ensureSupportedPlatform();
    return _closeDevice();
  }

  @override
  Future<void> closeFd() {
    _ensureAndroidOnlyApi('closeFd');
    return _closeDevice();
  }

  Future<void> _closeDevice() async {
    if (_disposed) return;
    _dartLastError = null;
    _forgetOpenedDevice();
    _resetStallTracking();
    final int result = await _awaitRequest(_bindings.uvc_request_close(_s));
    if (_disposed) return;
    if (result != 0) _throwRequestFailure(result, null);
    _afterClosed();
  }

  // Runs when a close request has completed, from a call or a detach. An
  // open queued before the close may have set the device meanwhile, and
  // the close took it back.
  void _afterClosed() {
    _forgetOpenedDevice();
    _resetPreviewState();
  }

  Future<void>? _disposing;

  @override
  Future<void> dispose() => _disposing ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    // Mark disposed before the first await so a re-entrant dispose() or a
    // concurrent open cannot see the session.
    _disposed = true;
    _forgetOpenedDevice();
    final Pointer<uvc_session_t>? session = _session;
    _session = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _stallConfig = null;
    if (session == null) {
      await _streamErrorController.close();
      await _stallEventController.close();
      return;
    }
    _finalizer.detach(this);
    // Teardown is a request like any other. It interrupts a start in
    // progress, reports the requests it drains, and completes once the
    // device is closed. Waiting for it never blocks this isolate, so the
    // native threads reporting into it stay free to finish.
    await _awaitRequest(_bindings.uvc_request_destroy(session));
    try {
      _requestCallable?.close();
      _requestCallable = null;
      // The session cleared its listener slots before completing, so no
      // callback can reach these any more.
      _errorCallable?.close();
      _errorCallable = null;
    } finally {
      _failPendingRequests();
      await _streamErrorController.close();
      await _stallEventController.close();
    }
  }

  @override
  Future<void> openPreview(UvcCameraMode mode) async {
    _throwIfDisposed();
    _recordPreviewRequest(mode);
    final int result = await _awaitStart(
      _bindings.uvc_request_start(_s, _nativeMode(mode), UVC_VERIFY_NONE, 0, 0),
    );
    if (result != 0) {
      _throwIfDisposed();
      _throwRequestFailure(result, null);
    }
  }

  void _recordPreviewRequest(UvcCameraMode mode) {
    _dartLastError = null;
    _resetPreviewState();
    _resetStallTracking();
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
  }) async {
    _checkConsecutiveValidFrames(policy, consecutiveValidFrames);
    if (_disposed) return _noDeviceResult(mode, 'UvcCamera has been disposed');
    _dartLastError = null;
    _resetPreviewState();
    _resetStallTracking();
    _lastPreviewRequest = _PreviewRequest(
      mode: mode,
      policy: policy,
      consecutiveValidFrames: consecutiveValidFrames,
      timeout: timeout,
    );
    final int requestId = _bindings.uvc_request_start(
      _s,
      _nativeMode(mode),
      _nativePolicy(policy),
      consecutiveValidFrames,
      timeout.inMilliseconds,
    );
    return _finishStart(requestId, mode);
  }

  static void _checkConsecutiveValidFrames(UvcPreviewPolicy policy, int count) {
    if (policy == UvcPreviewPolicy.stableFrames && count <= 0) {
      throw ArgumentError.value(
        count,
        'consecutiveValidFrames',
        'Must be greater than 0.',
      );
    }
  }

  // Start and auto requests of this instance still queued or running. The
  // stall timer stays quiet meanwhile, so it never cuts an auto short.
  int _startsInFlight = 0;

  Future<int> _awaitStart(int requestId) async {
    _startsInFlight += 1;
    try {
      return await _awaitRequest(requestId);
    } finally {
      _startsInFlight -= 1;
    }
  }

  // Waits for a queued start and reads its result. Updates the state the
  // way the native outcome left it.
  Future<UvcPreviewStartResult> _finishStart(
    int requestId,
    UvcCameraMode mode,
  ) async {
    final int result = await _awaitStart(requestId);
    final UvcPreviewStartResult parsed = _takeStartResult(
      requestId,
      result,
      mode,
    );
    return parsed;
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
    _checkConsecutiveValidFrames(policy, consecutiveValidFrames);
    if (_disposed) return const UvcAutoPreviewResult(attempts: []);
    _dartLastError = null;
    _resetPreviewState();
    _resetStallTracking();
    final List<UvcCameraMode>? given = candidates?.take(maxCandidates).toList();
    final int count = given?.length ?? 0;
    final Pointer<uvc_mode_t> modes = given == null
        ? nullptr
        : calloc<uvc_mode_t>(count == 0 ? 1 : count);
    final int requestId;
    try {
      for (int i = 0; i < count; i++) {
        _fillNativeMode(modes[i], given![i]);
      }
      requestId = _bindings.uvc_request_start_auto(
        _s,
        modes,
        count,
        preference == UvcAutoPreviewPreference.quality ? 1 : 0,
        maxCandidates,
        _nativePolicy(policy),
        consecutiveValidFrames,
        perModeTimeout.inMilliseconds,
      );
    } finally {
      if (modes != nullptr) calloc.free(modes);
    }
    final int result = await _awaitStart(requestId);
    final List<UvcPreviewStartResult> attempts = _takeAutoResult(
      requestId,
      result,
      given,
    );
    if (attempts.isNotEmpty) {
      final UvcPreviewStartResult last = attempts.last;
      if (last.success) {
        _lastPreviewRequest = _PreviewRequest(
          mode: last.mode,
          policy: policy,
          consecutiveValidFrames: consecutiveValidFrames,
          timeout: perModeTimeout,
        );
      }
    }
    return UvcAutoPreviewResult(attempts: attempts);
  }

  @override
  Future<void> stopPreview() async {
    if (_disposed) return;
    _dartLastError = null;
    _resetStallTracking();
    await _awaitRequest(_bindings.uvc_request_stop(_s));
    if (_disposed) return;
    _resetPreviewState();
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
    if (_disposed) return;
    _stallLastSequence = latestFrameSequence();
    _stallLastProgress = _stallClock.elapsed;
    _inStallEpisode = false;
    _restartAttempts = 0;
  }

  void _stallTick() {
    final UvcStallDetectionConfig? config = _stallConfig;
    if (config == null || _restartInProgress || _startsInFlight > 0) return;
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
      unawaited(
        _attemptStallRestart(
          config,
          request,
          silence,
          _bindings.uvc_latest_request_id(_s),
        ),
      );
    }
  }

  Future<void> _attemptStallRestart(
    UvcStallDetectionConfig config,
    _PreviewRequest request,
    Duration silence,
    int latestRequest,
  ) async {
    _restartInProgress = true;
    // Each attempt runs only when nothing was requested since the stall was
    // seen, or since our own previous attempt. `expected` carries that, and
    // the native side rejects the request when it no longer holds, so an app
    // lifecycle call in between always wins.
    int expected = latestRequest;
    try {
      while (_restartAttempts < config.maxRestartAttempts) {
        if (_disposed) return;
        // The stream the stall was seen on must still be the running one.
        // Later attempts follow our own failed ones, which the native start
        // reports on, so only the first needs this.
        if (_restartAttempts == 0 && !isPreviewing) return;
        _restartAttempts += 1;
        final int attempt = _restartAttempts;
        final int requestId = _bindings.uvc_request_start_if(
          _s,
          expected,
          _nativeMode(request.mode),
          _nativePolicy(request.policy),
          request.consecutiveValidFrames,
          request.timeout.inMilliseconds,
        );
        if (requestId == UvcErrorCode.interrupted.nativeValue) return;
        if (requestId > 0) expected = requestId;
        final UvcPreviewStartResult result = await _finishStart(
          requestId,
          request.mode,
        );
        if (result.nativeErrorCode == UvcErrorCode.interrupted.nativeValue ||
            result.nativeErrorCode == UvcErrorCode.noDevice.nativeValue ||
            _disposed ||
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
      // tuples. Dedupe so consumers never see duplicates.
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
