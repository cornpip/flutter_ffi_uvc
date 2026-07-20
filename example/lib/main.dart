import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_ffi_uvc_example/android_bridge.dart';

import 'app_theme.dart';
import 'widgets/controls_panel.dart';
import 'widgets/stream_stats_card.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UVC Preview Demo',
      theme: buildExampleTheme(),
      home: UvcPreviewPage(),
    );
  }
}

class UvcPreviewPage extends StatefulWidget {
  UvcPreviewPage({super.key, UvcCamera? camera}) : camera = camera ?? uvcCamera;

  final UvcCamera camera;

  @override
  State<UvcPreviewPage> createState() => _UvcPreviewPageState();
}

class _UvcPreviewPageState extends State<UvcPreviewPage>
    with WidgetsBindingObserver {
  static const AndroidBridge _androidBridge = AndroidBridge();
  static const String _logPrefix = '@@@@UVC_EXAMPLE';
  static const Duration _startupProbeTimeout = Duration(seconds: 2);
  static const Duration _fpsSampleInterval = Duration(milliseconds: 1000);
  static const Duration _streamErrorSnackbarCooldown = Duration(seconds: 3);
  UvcCamera get _camera => widget.camera;

  List<UvcUsbDevice> _devices = const <UvcUsbDevice>[];
  List<UvcCameraMode> _cameraModes = const <UvcCameraMode>[];
  List<UvcCameraControl> _cameraControls = const <UvcCameraControl>[];
  UvcUsbDevice? _selectedDevice;
  UvcCameraMode? _selectedMode;
  int? _previewTextureId;
  ui.Image? _previewImage;
  Timer? _previewStatsTimer;
  bool _loadingDevices = true;
  bool _openingDevice = false;
  bool _afTriggering = false;
  bool _previewFrozen = false;
  bool _savingPhoto = false;
  bool _saveToGallery = false;
  bool _transformControlsExpanded = false;
  bool _manualFocusControlsVisible = false;
  StreamSubscription<UvcStreamError>? _streamErrorSub;
  StreamSubscription<UvcDeviceEvent>? _deviceEventSub;
  StreamSubscription<UvcStallEvent>? _stallEventSub;
  bool _stallAutoRecover = true;
  Timer? _focusRepeatTimer;
  Timer? _focusValueHideTimer;
  bool _focusValueVisible = false;
  String? _status;
  String? _lastSnackBarErrorKey;
  Duration? _lastSnackBarErrorAt;
  double _previewFps = 0;
  int _lastPreviewSequence = 0;
  Duration? _lastPreviewSequenceSampleAt;

  // Monotonic clock for FPS sampling and snackbar cooldowns; unlike
  // DateTime.now() it is immune to wall-clock adjustments.
  final Stopwatch _monotonicClock = Stopwatch()..start();
  UvcStreamStats _streamStats = const UvcStreamStats.zero();

  @override
  void initState() {
    super.initState();
    _camera.setLogLevel(UvcLogLevel.debug);
    WidgetsBinding.instance.addObserver(this);
    _streamErrorSub = _camera.streamErrors.listen(_onStreamError);
    // USB hot-plug notifications: attach refreshes the list, detach of the
    // active device tears the session down. Android only.
    _deviceEventSub = _camera.deviceEvents.listen(_onDeviceEvent);
    // Watchdog: report (and, when enabled, auto-recover from) silent stalls.
    _stallEventSub = _camera.stallEvents.listen(_onStallEvent);
    _camera.enableStallDetection(_stallDetectionConfig());
    unawaited(_initializePermissionsAndDevices());
  }

  // Library defaults (2s stall timeout, 500ms checks, 3 restart attempts)
  // are fine for the demo; only the auto-restart switch is ours.
  UvcStallDetectionConfig _stallDetectionConfig() =>
      UvcStallDetectionConfig(autoRestart: _stallAutoRecover);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_disconnectSelectedDevice());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamErrorSub?.cancel();
    _deviceEventSub?.cancel();
    _stallEventSub?.cancel();
    _camera.disableStallDetection();
    _previewStatsTimer?.cancel();
    _focusRepeatTimer?.cancel();
    _focusValueHideTimer?.cancel();
    _previewImage?.dispose();
    unawaited(_stopCurrentPreview());
    unawaited(_disposePreviewTexture());
    unawaited(_camera.closeUsbDevice());
    super.dispose();
  }

  Future<void> _initializePermissionsAndDevices() async {
    try {
      final bool granted = await _camera.ensureCameraPermission();
      if (!granted) {
        _setStatus('Camera permission is required.', loadingDevices: false);
        return;
      }
      await _refreshDevices();
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to request camera permission: ${error.message ?? error.code}',
        loadingDevices: false,
        error: error,
      );
    }
  }

  Future<void> _refreshDevices() async {
    _log('Refreshing device list');
    setState(() {
      _loadingDevices = true;
      _status = null;
    });

    try {
      final List<UvcUsbDevice> devices = await _camera.listUsbDevices();

      setState(() {
        _devices = devices;
        _selectedDevice =
            devices.any(
              (UvcUsbDevice device) =>
                  device.deviceId == _selectedDevice?.deviceId,
            )
            ? devices.firstWhere(
                (UvcUsbDevice device) =>
                    device.deviceId == _selectedDevice?.deviceId,
              )
            : null;
        _loadingDevices = false;
        if (devices.isEmpty) {
          _status = 'No USB camera found.';
        }
      });
      _log('Loaded ${devices.length} device(s)');
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to load device list: ${error.message ?? error.code}',
        loadingDevices: false,
        error: error,
      );
    }
  }

  Future<void> _openSelectedDevice(UvcUsbDevice device) async {
    _setStatus('Opening device...', openingDevice: true);
    _log('Open device requested: ${device.displayName}');

    _previewImage?.dispose();
    _previewImage = null;

    try {
      await _ensurePreviewTexture();
      // _stopCurrentPreview() does app-level UI teardown (stats timer, FPS,
      // image); openUsbDevice() tears down the native session itself before
      // opening. Both are needed — they clean up different layers.
      await _stopCurrentPreview();
      final int openResult = await _camera.openUsbDevice(device.deviceId);
      if (openResult != 0) {
        throw Exception('uvc_open_fd failed: ${_camera.lastError}');
      }

      final List<UvcCameraMode> libuvcModes = _camera.supportedModes();
      final List<UvcCameraControl> controls = _camera.supportedControls();
      _log(
        'Controls: ${controls.map((UvcCameraControl c) => '${c.name}(id=${c.id.nativeValue},cur=${c.cur})').join(', ')}',
      );

      // Debug-only: logs controls that are advertised in bmControls but fail GET_CUR probing.
      final List<UvcBmControlInfo> bmControls = _camera.debugBmControls();
      final Set<int> controlIds = controls
          .map((UvcCameraControl c) => c.id.nativeValue)
          .toSet();
      final List<UvcBmControlInfo> bmOnlyControls = bmControls
          .where((UvcBmControlInfo c) => !controlIds.contains(c.id.nativeValue))
          .toList();
      if (controls.length != bmControls.length && bmOnlyControls.isNotEmpty) {
        _log(
          'bmControls-only: ${bmOnlyControls.map((UvcBmControlInfo c) => '${c.name}(id=${c.id.nativeValue})').join(', ')}',
        );
      }

      if (libuvcModes.isEmpty) {
        throw Exception('No supported camera modes were found.');
      }

      final List<UvcCameraMode> sortedModes = _sortModesByPreference(
        libuvcModes,
      );
      _setStatus(
        'Opening device... Auto-selecting a working mode...',
        openingDevice: true,
      );
      // startPreviewAuto() runs the MJPEG-first fallback loop this example
      // used to implement by hand: each candidate is verified like
      // startPreview and rejected on failure, keeping the first mode that
      // actually delivers frames. The default reliability preference probes
      // smaller, safer modes first; pass
      // preference: UvcAutoPreviewPreference.quality to try larger
      // resolutions first instead.
      final UvcAutoPreviewResult autoResult = await _camera.startPreviewAuto(
        perModeTimeout: _startupProbeTimeout,
        maxCandidates: 3,
      );
      final UvcCameraMode? startedMode = autoResult.mode;
      if (startedMode != null) {
        await _onPreviewStarted(startedMode);
      }
      final UvcPreviewStartResult? lastProbeResult =
          autoResult.attempts.isEmpty ? null : autoResult.attempts.last;

      final String statusMessage;
      if (startedMode != null) {
        statusMessage = 'Preview running: ${startedMode.label} / Texture';
      } else if (autoResult.attempts.isEmpty) {
        statusMessage =
            'Opened device. No modes were available for automatic probe.';
      } else {
        statusMessage =
            'Opened device. Automatic probe tried ${autoResult.attempts.length} mode(s) and found no working preview. Try a mode manually.';
      }

      setState(() {
        _selectedDevice = device;
        _cameraModes = libuvcModes;
        _cameraControls = controls;
        _selectedMode = startedMode ?? sortedModes.first;
        _openingDevice = false;
        _previewFrozen = false;
        _manualFocusControlsVisible = false;
        _status = statusMessage;
      });
      if (startedMode != null) {
        _log(
          'Preview running: ${device.displayName} / ${startedMode.label} / Texture',
        );
      } else {
        _log(
          'Device opened without working preview mode: ${device.displayName} / ${lastProbeResult == null ? "no probe result" : _startFailureMessage(lastProbeResult)}',
        );
      }
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to open device: ${error.message ?? error.code}',
        openingDevice: false,
        error: error,
      );
    } catch (error) {
      _setStatus(error.toString(), openingDevice: false, error: error);
    }
  }

  Future<void> _disconnectSelectedDevice() async {
    if (_openingDevice) {
      return;
    }

    final String deviceTitle = _selectedDevice?.displayName ?? 'Connected device';
    _setStatus('Disconnecting device...', openingDevice: true);
    _log('Disconnect requested: $deviceTitle');

    try {
      await _stopCurrentPreview(clearPreviewImage: true);
      await _camera.closeUsbDevice();
      await _disposePreviewTexture();
      setState(() {
        _selectedDevice = null;
        _selectedMode = null;
        _cameraModes = const <UvcCameraMode>[];
        _cameraControls = const <UvcCameraControl>[];
        _previewFrozen = false;
        _transformControlsExpanded = false;
        _manualFocusControlsVisible = false;
        _openingDevice = false;
        _status = 'Device disconnected.';
        _previewFps = 0;
      });
      _log('Device disconnected: $deviceTitle');
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to disconnect device: ${error.message ?? error.code}',
        openingDevice: false,
        error: error,
      );
    } catch (error) {
      _setStatus(
        'Failed to disconnect device.',
        openingDevice: false,
        error: error,
      );
    }
  }

  Future<void> _switchMode(UvcCameraMode mode) async {
    if (_openingDevice) {
      return;
    }
    _previewFrozen = false;
    _setStatus('Switching mode: ${mode.label}', openingDevice: true);
    await _stopCurrentPreview(clearPreviewImage: true);

    final UvcPreviewStartResult probeResult = await _startPreview(mode, policy: UvcPreviewPolicy.sequenceOnly);
    if (!probeResult.success) {
      _setStatus(
        'Failed to switch mode: ${_startFailureMessage(probeResult)}',
        openingDevice: false,
      );
      return;
    }

    setState(() {
      _selectedMode = mode;
      _openingDevice = false;
      _previewFrozen = false;
      _manualFocusControlsVisible = false;
      _status = 'Preview running: ${mode.label} / Texture';
    });
    _log('Preview mode changed: ${mode.label} / Texture');
  }

  List<UvcCameraMode> _sortModesByPreference(List<UvcCameraMode> modes) {
    final List<UvcCameraMode> sorted = List<UvcCameraMode>.from(modes);
    sorted.sort((UvcCameraMode a, UvcCameraMode b) {
      final int aIsMjpeg = a.formatName == 'MJPEG' ? 1 : 0;
      final int bIsMjpeg = b.formatName == 'MJPEG' ? 1 : 0;
      if (aIsMjpeg != bIsMjpeg) {
        return bIsMjpeg - aIsMjpeg;
      }

      final int areaCompare = (a.width * a.height).compareTo(
        b.width * b.height,
      );
      if (areaCompare != 0) {
        return areaCompare;
      }

      return b.fps.compareTo(a.fps);
    });
    return sorted;
  }

  String _startFailureMessage(UvcPreviewStartResult result) {
    // When the native stream failed to start, startPreview now reports a typed
    // error code (e.g. noDevice on mid-session disconnect, notSupported for an
    // unusable mode). Surface it so failures are actionable.
    final UvcErrorCode? code = result.errorCode;
    final String codeSuffix = code == null
        ? ''
        : ' [${code.name} (${result.nativeErrorCode})]';
    final String? error = result.lastError;
    if (error != null && error.isNotEmpty) {
      return '$error$codeSuffix';
    }
    return 'No valid frame sequence was observed for this mode within '
        '${_startupProbeTimeout.inSeconds}s.$codeSuffix';
  }

  void _onDeviceEvent(UvcDeviceEvent event) {
    _log('Device event: $event');
    final bool isActiveDevice =
        _selectedDevice != null &&
        event.device.deviceId == _selectedDevice!.deviceId;
    switch (event.type) {
      case UvcDeviceEventType.attached:
        _setStatus('USB camera attached: ${event.device.displayName}');
        unawaited(_refreshDevices());
      case UvcDeviceEventType.detached:
        if (isActiveDevice) {
          // The active device lost its transport; the native session is dead.
          _setStatus('Active camera detached: ${event.device.displayName}');
          unawaited(_disconnectSelectedDevice());
        } else {
          _setStatus('USB camera detached: ${event.device.displayName}');
          unawaited(_refreshDevices());
        }
    }
  }

  void _onStallEvent(UvcStallEvent event) {
    _log('Stall event: $event');
    final String message;
    final Color background;
    switch (event.type) {
      case UvcStallEventType.stalled:
        message =
            'Preview stalled: no frames for ${event.silence.inMilliseconds}ms'
            '${_stallAutoRecover ? ' — recovering...' : '.'}';
        background = Colors.orange.shade900;
      case UvcStallEventType.restartSucceeded:
        message =
            'Preview recovered after ${event.restartAttempt} restart '
            'attempt(s).';
        background = Colors.green.shade800;
      case UvcStallEventType.restartFailed:
        final UvcPreviewStartResult? restart = event.restartResult;
        message =
            'Preview restart attempt ${event.restartAttempt} failed'
            '${restart == null ? '' : ': ${_startFailureMessage(restart)}'}.';
        background = Colors.red.shade800;
    }
    if (!mounted) {
      _status = message;
      return;
    }
    setState(() => _status = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: background,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _setStallAutoRecover(bool value) {
    setState(() => _stallAutoRecover = value);
    // Reconfigure the watchdog in place: detection stays on either way, only
    // the automatic stop/restart behaviour is toggled.
    _camera.enableStallDetection(_stallDetectionConfig());
  }

  void _resetPreviewFps() {
    _previewFps = 0;
    _lastPreviewSequence = 0;
    _lastPreviewSequenceSampleAt = null;
  }

  void _resetStreamStats() {
    _streamStats = const UvcStreamStats.zero();
  }

  bool get _hasLivePreview => _previewTextureId != null && _camera.isPreviewing;

  double? get _previewAspectRatio {
    final UvcCameraMode? mode = _selectedMode;
    if (mode == null || mode.width <= 0 || mode.height <= 0) {
      return null;
    }
    final (int w, int h) =
        _camera.previewTransform.applyToSize(mode.width, mode.height);
    return w / h;
  }

  void _samplePreviewFps() {
    final Duration now = _monotonicClock.elapsed;
    final Duration? previousAt = _lastPreviewSequenceSampleAt;
    final int latestSequence = _camera.latestFrameSequence();
    final UvcStreamStats streamStats = _camera.getStreamStats();
    if (previousAt == null) {
      _lastPreviewSequence = latestSequence;
      _lastPreviewSequenceSampleAt = now;
      _streamStats = streamStats;
      return;
    }

    final double seconds =
        (now - previousAt).inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) {
      return;
    }

    final int frameDelta = latestSequence - _lastPreviewSequence;
    _lastPreviewSequence = latestSequence;
    _lastPreviewSequenceSampleAt = now;
    if (!mounted) {
      _previewFps = frameDelta <= 0 ? 0 : frameDelta / seconds;
      _streamStats = streamStats;
      return;
    }
    setState(() {
      _previewFps = frameDelta <= 0 ? 0 : frameDelta / seconds;
      _streamStats = streamStats;
    });
  }

  Future<void> _ensurePreviewTexture() async {
    if (_previewTextureId != null) {
      return;
    }

    final int textureId = await _camera.createPreviewTexture();
    if (!mounted) {
      _previewTextureId = textureId;
      return;
    }
    setState(() {
      _previewTextureId = textureId;
    });
  }

  Future<void> _disposePreviewTexture() async {
    final int? textureId = _previewTextureId;
    if (textureId == null) {
      return;
    }

    _previewTextureId = null;
    await _camera.disposePreviewTexture(textureId);
  }

  Future<UvcPreviewStartResult> _startPreview(
    UvcCameraMode mode, {
    UvcPreviewPolicy policy = UvcPreviewPolicy.stableFrames,
  }) async {
    _log('libuvc preview start attempt: ${mode.label} / Texture');
    final UvcPreviewStartResult result = await _camera.startPreview(
      mode,
      policy: policy,
      consecutiveValidFrames: 3,
      timeout: _startupProbeTimeout,
    );
    if (result.success) {
      await _onPreviewStarted(mode);
      return result;
    }
    _previewStatsTimer?.cancel();
    _previewStatsTimer = null;
    return result;
  }

  /// Attaches the preview texture and (re)starts FPS/stats sampling after any
  /// successful preview start, whether via [_startPreview] or the library's
  /// [UvcCamera.startPreviewAuto].
  Future<void> _onPreviewStarted(UvcCameraMode mode) async {
    final int? textureId = _previewTextureId;
    if (textureId != null) {
      await _camera.attachPreviewTexture(
        textureId,
        width: mode.width,
        height: mode.height,
      );
    }
    _previewStatsTimer?.cancel();
    _resetPreviewFps();
    _resetStreamStats();
    _lastPreviewSequence = _camera.latestFrameSequence();
    _lastPreviewSequenceSampleAt = _monotonicClock.elapsed;
    _previewStatsTimer = Timer.periodic(
      _fpsSampleInterval,
      (_) => _samplePreviewFps(),
    );
  }

  Future<ui.Image> _decodeRgbaFrame(UvcPreviewFrame frame) {
    return _decodeRgbaFrameWithDescriptor(frame);
  }

  Future<ui.Image> _decodeRgbaFrameWithDescriptor(UvcPreviewFrame frame) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      frame.rgbaBytes,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.rgba8888,
      rowBytes: frame.width * 4,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    try {
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<void> _stopCurrentPreview({bool clearPreviewImage = false}) async {
    _previewStatsTimer?.cancel();
    _previewStatsTimer = null;
    _resetPreviewFps();

    if (clearPreviewImage) {
      final ui.Image? previousImage = _previewImage;
      if (mounted) {
        setState(() {
          _previewImage = null;
        });
      } else {
        _previewImage = null;
      }
      previousImage?.dispose();
    }

    _camera.stopPreview();
  }

  void _setStatus(
    String status, {
    bool? loadingDevices,
    bool? openingDevice,
    Object? error,
  }) {
    _log(status, error: error);
    setState(() {
      _status = status;
      if (loadingDevices != null) {
        _loadingDevices = loadingDevices;
      }
      if (openingDevice != null) {
        _openingDevice = openingDevice;
      }
    });
  }

  bool get _hasFocusAuto =>
      _cameraControls.any((UvcCameraControl c) => c.name == 'focus_auto');

  UvcCameraControl? get _focusAbsControl => _cameraControls
      .where((UvcCameraControl c) => c.name == 'focus_abs')
      .firstOrNull;

  void _stepFocus(int direction) {
    final UvcCameraControl? ctrl = _focusAbsControl;
    if (ctrl == null) return;
    final int step = ctrl.res > 0 ? ctrl.res : 1;
    final int next = (ctrl.cur + direction * step).clamp(ctrl.min, ctrl.max);
    if (next == ctrl.cur) return;
    _camera.setControl(ctrl.id, next);
    _focusValueHideTimer?.cancel();
    _focusValueHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusValueVisible = false);
    });
    setState(() {
      _focusValueVisible = true;
      _cameraControls = _cameraControls
          .map(
            (UvcCameraControl c) =>
                c.name == 'focus_abs' ? c.copyWithCur(next) : c,
          )
          .toList();
    });
  }

  Future<void> _toggleManualFocusControls() async {
    if (_manualFocusControlsVisible) {
      setState(() {
        _manualFocusControlsVisible = false;
        _focusValueVisible = false;
      });
      return;
    }

    final UvcCameraControl? ctrl = _focusAbsControl;
    if (ctrl == null) {
      return;
    }

    final int? currentValue = _camera.getControl(ctrl.id);
    if (currentValue != null) {
      setState(() {
        _cameraControls = _cameraControls
            .map(
              (UvcCameraControl c) =>
                  c.id == ctrl.id ? c.copyWithCur(currentValue) : c,
            )
            .toList();
        _focusValueVisible = true;
        _manualFocusControlsVisible = true;
      });
      _focusValueHideTimer?.cancel();
      _focusValueHideTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _focusValueVisible = false);
      });
      return;
    }

    setState(() {
      _manualFocusControlsVisible = true;
    });
  }

  void _startFocusRepeat(int direction) {
    _stepFocus(direction);
    _focusRepeatTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _stepFocus(direction),
    );
  }

  void _stopFocusRepeat() {
    _focusRepeatTimer?.cancel();
    _focusRepeatTimer = null;
  }

  Future<void> _triggerOneShutAF() async {
    setState(() => _afTriggering = true);
    try {
      _camera.setControl(UvcControlId.focusAuto, 1);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _camera.setControl(UvcControlId.focusAuto, 0);
    } finally {
      if (mounted) setState(() => _afTriggering = false);
    }
  }

  Future<void> _capturePhoto() async {
    if (_savingPhoto || _previewFrozen) {
      return;
    }

    setState(() => _savingPhoto = true);
    ui.Image? capturedImage;
    try {
      final UvcPreviewFrame? frame = _camera.copyLatestFrameTransformed(
        _camera.previewTransform,
      );
      if (frame == null) {
        throw Exception('No preview frame available to capture.');
      }
      capturedImage = await _decodeRgbaFrame(frame);
      final ByteData? pngData = await capturedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (pngData == null) {
        throw Exception('Failed to encode PNG from the current preview frame.');
      }

      final Uint8List pngBytes = pngData.buffer.asUint8List();
      if (_saveToGallery) {
        final String timestamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '-');
        final String? savedUri = await _androidBridge.saveImageToGallery(
          pngBytes,
          displayName: 'uvc_capture_$timestamp.png',
        );
        _setStatus(
          savedUri == null || savedUri.isEmpty
              ? 'Saved capture to gallery.'
              : 'Saved capture to gallery: $savedUri',
        );
      }
      await _stopCurrentPreview();
      final ui.Image? previousImage = _previewImage;
      if (mounted) {
        setState(() {
          _previewImage = capturedImage;
          _previewFrozen = true;
        });
      } else {
        _previewImage = capturedImage;
        _previewFrozen = true;
      }
      previousImage?.dispose();
      capturedImage = null;
      _setStatus('Preview paused on captured frame.');
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to save capture: ${error.message ?? error.code}',
        error: error,
      );
    } catch (error) {
      _setStatus('Failed to save capture.', error: error);
    } finally {
      capturedImage?.dispose();
      if (mounted) {
        setState(() => _savingPhoto = false);
      } else {
        _savingPhoto = false;
      }
    }
  }

  Future<void> _resumePreview() async {
    final UvcCameraMode? mode = _selectedMode;
    if (mode == null || _openingDevice) {
      return;
    }

    _previewFrozen = false;
    _setStatus('Resuming preview...', openingDevice: true);
    final ui.Image? previousImage = _previewImage;
    _previewImage = null;
    final UvcPreviewStartResult probeResult = await _startPreview(mode, policy: UvcPreviewPolicy.sequenceOnly);
    if (!probeResult.success) {
      _previewImage = previousImage;
      _setStatus(
        'Failed to resume preview: ${_startFailureMessage(probeResult)}',
        openingDevice: false,
      );
      return;
    }
    previousImage?.dispose();

    if (!mounted) {
      _previewFrozen = false;
      _openingDevice = false;
      _status = 'Preview running: ${mode.label} / Texture';
      return;
    }

    setState(() {
      _previewFrozen = false;
      _openingDevice = false;
      _status = 'Preview running: ${mode.label} / Texture';
    });
  }

  void _showControlsPanel() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return CameraControlsPanel(
          controls: _cameraControls,
          onChanged: (UvcControlId id, int value) {
            final int result = _camera.setControl(id, value);
            if (result == 0) {
              setState(() {
                _cameraControls = _cameraControls
                    .map(
                      (UvcCameraControl c) =>
                          c.id == id ? c.copyWithCur(value) : c,
                    )
                    .toList();
              });
            } else {
              _log(
                'setControl failed id=${id.nativeValue} value=$value err=$result',
              );
            }
          },
          onReset: () {
            for (final UvcCameraControl ctrl in _cameraControls) {
              if (ctrl.id == UvcControlId.focusAbs ||
                  ctrl.id == UvcControlId.focusAuto ||
                  ctrl.id == UvcControlId.focusSimple) {
                continue;
              }
              _camera.setControl(ctrl.id, ctrl.def);
            }
            final List<UvcCameraControl> refreshed = _camera
                .supportedControls();
            setState(() {
              _cameraControls = refreshed;
            });
            Navigator.of(context).pop();
            _showControlsPanel();
          },
        );
      },
    );
  }

  void _onStreamError(UvcStreamError error) {
    _log('Stream error: ${error.message}');
    _status = 'Stream error: ${error.message}';
    if (!mounted) {
      return;
    }

    final Duration now = _monotonicClock.elapsed;
    final String errorKey = _normaliseStreamErrorKey(error.message);
    final bool isRepeatedMessage = _lastSnackBarErrorKey == errorKey;
    final bool withinCooldown =
        _lastSnackBarErrorAt != null &&
        now - _lastSnackBarErrorAt! < _streamErrorSnackbarCooldown;

    if (isRepeatedMessage && withinCooldown) {
      setState(() {
        _status = 'Stream error: ${error.message}';
      });
      return;
    }

    _lastSnackBarErrorKey = errorKey;
    _lastSnackBarErrorAt = now;
    setState(() {
      _status = 'Stream error: ${error.message}';
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
      SnackBar(
        content: Text(error.message),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () =>
              ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  String _normaliseStreamErrorKey(String message) {
    String normalized = message.trim();
    normalized = normalized.replaceAll(RegExp(r'width=\d+'), 'width=*');
    normalized = normalized.replaceAll(RegExp(r'height=\d+'), 'height=*');
    normalized = normalized.replaceAll(RegExp(r'bytes=\d+'), 'bytes=*');
    normalized = normalized.replaceAll(RegExp(r'expected>=\d+'), 'expected>=*');
    normalized = normalized.replaceAll(RegExp(r'actual=\d+'), 'actual=*');
    normalized = normalized.replaceAll(RegExp(r'callback=\d+'), 'callback=*');
    normalized = normalized.replaceAll(RegExp(r'format=\d+'), 'format=*');
    normalized = normalized.replaceAll(RegExp(r'err=[^,\s]+'), 'err=*');
    return normalized;
  }

  void _log(String message, {Object? error}) {
    debugPrint('$_logPrefix $message');
    if (error != null) {
      debugPrint('$_logPrefix error=$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Color(0xFF000000),
          systemNavigationBarIconBrightness: Brightness.light,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: const Text('UVC Camera Preview'),
        actions: <Widget>[
          if (_cameraControls.isNotEmpty)
            IconButton(
              onPressed: () => _showControlsPanel(),
              icon: const Icon(Icons.tune),
              tooltip: 'Camera controls',
            ),
          IconButton(
            onPressed: _loadingDevices
                ? null
                : () => unawaited(_refreshDevices()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: Stack(
                  children: <Widget>[
                    Container(
                      width: double.infinity,
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: _previewFrozen && _previewImage != null
                          ? RawImage(image: _previewImage, fit: BoxFit.contain)
                          : !_hasLivePreview
                          ? const Text(
                              'No preview',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 18,
                              ),
                            )
                          : _previewAspectRatio == null
                          ? Texture(
                              textureId: _previewTextureId!,
                              filterQuality: FilterQuality.none,
                            )
                          : Center(
                              child: AspectRatio(
                                aspectRatio: _previewAspectRatio!,
                                child: Texture(
                                  textureId: _previewTextureId!,
                                  filterQuality: FilterQuality.none,
                                ),
                              ),
                            ),
                    ),
                    if (_focusValueVisible && _focusAbsControl != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 16,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: _focusValueVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 300),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Focus: ${_focusAbsControl!.cur}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_hasLivePreview || _previewFrozen)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${_previewFps.toStringAsFixed(0)} fps',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Center(
                        child: FilledButton(
                          onPressed: _savingPhoto
                              ? null
                              : _previewFrozen
                              ? () => unawaited(_resumePreview())
                              : !_hasLivePreview
                              ? null
                              : () => unawaited(_capturePhoto()),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.85,
                            ),
                            foregroundColor: Colors.black87,
                            minimumSize: const Size(44, 44),
                            padding: const EdgeInsets.all(10),
                            shape: const CircleBorder(),
                          ),
                          child: Tooltip(
                            message: _savingPhoto
                                ? 'Saving'
                                : _previewFrozen
                                ? 'Resume preview'
                                : 'Capture',
                            child: _savingPhoto
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    _previewFrozen
                                        ? Icons.play_arrow
                                        : Icons.camera_alt,
                                    size: 24,
                                  ),
                          ),
                        ),
                      ),
                    ),
                    if (_hasLivePreview)
                      Positioned(
                        left: 12,
                        bottom: 16,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                              alignment: Alignment.bottomLeft,
                              child: _transformControlsExpanded
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        _TransformIconButton(
                                          icon: Icons.rotate_90_degrees_cw,
                                          tooltip: 'Rotate 90° CW',
                                          active: false,
                                          onTap: () {
                                            _camera.rotatePreviewClockwise();
                                            setState(() {});
                                          },
                                        ),
                                        const SizedBox(height: 8),
                                        _TransformIconButton(
                                          icon: Icons.flip,
                                          tooltip: 'Flip horizontal',
                                          active: _camera
                                              .previewTransform.flipHorizontal,
                                          onTap: () {
                                            _camera
                                                .togglePreviewFlipHorizontal();
                                            setState(() {});
                                          },
                                        ),
                                        const SizedBox(height: 8),
                                        _TransformIconButton(
                                          icon: Icons.flip,
                                          iconAngle: 90,
                                          tooltip: 'Flip vertical',
                                          active: _camera
                                              .previewTransform.flipVertical,
                                          onTap: () {
                                            _camera.togglePreviewFlipVertical();
                                            setState(() {});
                                          },
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            _TransformIconButton(
                              icon: Icons.screen_rotation,
                              tooltip: _transformControlsExpanded
                                  ? 'Close transform controls'
                                  : 'Transform controls',
                              active: _transformControlsExpanded ||
                                  _camera.previewTransform !=
                                      UvcPreviewTransform.identity,
                              onTap: () => setState(
                                () => _transformControlsExpanded =
                                    !_transformControlsExpanded,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_focusAbsControl != null)
                      Positioned(
                        right: 12,
                        bottom: 16,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            if (_hasFocusAuto)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: FilledButton.icon(
                                  onPressed: _afTriggering
                                      ? null
                                      : () => unawaited(_triggerOneShutAF()),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.black54,
                                  ),
                                  icon: _afTriggering
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.center_focus_strong),
                                  label: const Text('AF'),
                                ),
                              ),
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: _manualFocusControlsVisible ? 8 : 0,
                              ),
                              child: FilledButton.icon(
                                onPressed: () =>
                                    unawaited(_toggleManualFocusControls()),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.black54,
                                ),
                                icon: Icon(
                                  _manualFocusControlsVisible
                                      ? Icons.expand_more
                                      : Icons.tune,
                                ),
                                label: Text(
                                  _manualFocusControlsVisible
                                      ? 'Hide focus'
                                      : 'Manual focus',
                                ),
                              ),
                            ),
                            if (_manualFocusControlsVisible)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  FocusButton(
                                    icon: Icons.remove,
                                    onPressStart: () => _startFocusRepeat(-1),
                                    onPressEnd: _stopFocusRepeat,
                                  ),
                                  const SizedBox(width: 8),
                                  FocusButton(
                                    icon: Icons.add,
                                    onPressStart: () => _startFocusRepeat(1),
                                    onPressEnd: _stopFocusRepeat,
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 96),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (_status != null)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  _status!,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            if (_cameraModes.isNotEmpty)
                              SwitchListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                title: const Text('Save capture to gallery'),
                                value: _saveToGallery,
                                onChanged: (bool value) =>
                                    setState(() => _saveToGallery = value),
                              ),
                            if (_cameraModes.isNotEmpty)
                              SwitchListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                title: const Text('Auto-recover on stall'),
                                subtitle: const Text(
                                  'Watchdog restarts the preview if frame '
                                  'delivery silently stops',
                                ),
                                value: _stallAutoRecover,
                                onChanged: _setStallAutoRecover,
                              ),
                            if (_cameraModes.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  0,
                                ),
                                child: DropdownButton<UvcCameraMode>(
                                  isExpanded: true,
                                  value: _selectedMode,
                                  hint: const Text('Select preview mode'),
                                  items: _cameraModes
                                      .map(
                                        (UvcCameraMode mode) =>
                                            DropdownMenuItem<UvcCameraMode>(
                                              value: mode,
                                              child: Text(mode.label),
                                            ),
                                      )
                                      .toList(),
                                  onChanged: _openingDevice
                                      ? null
                                      : (UvcCameraMode? mode) {
                                          if (mode == null) {
                                            return;
                                          }
                                          unawaited(_switchMode(mode));
                                        },
                                ),
                              ),
                            if (_selectedDevice != null &&
                                (_selectedMode != null ||
                                    _streamStats.elapsed > Duration.zero))
                              StreamStatsCard(stats: _streamStats),
                            if (_loadingDevices)
                              const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _devices.length,
                                separatorBuilder:
                                    (BuildContext context, int index) =>
                                        const Divider(height: 1),
                                itemBuilder: (BuildContext context, int index) {
                                  final UvcUsbDevice device =
                                      _devices[index];
                                  final bool selected =
                                      _selectedDevice?.deviceId ==
                                      device.deviceId;
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? brandGreenLight
                                          : Colors.white,
                                      border: Border.all(
                                        color: selected
                                            ? brandGreenBorder
                                            : surfaceNeutralBorder,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          device.displayName,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          device.details,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                        const SizedBox(height: 12),
                                        _openingDevice && selected
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: <Widget>[
                                                  ElevatedButton(
                                                    onPressed: _openingDevice
                                                        ? null
                                                        : () => unawaited(
                                                            _openSelectedDevice(
                                                              device,
                                                            ),
                                                          ),
                                                    child: Text(
                                                      selected
                                                          ? 'Reconnect'
                                                          : 'Open',
                                                    ),
                                                  ),
                                                  if (selected) ...<Widget>[
                                                    const SizedBox(width: 8),
                                                    ElevatedButton(
                                                      onPressed: _openingDevice
                                                          ? null
                                                          : () => unawaited(
                                                              _disconnectSelectedDevice(),
                                                            ),
                                                      child: const Text(
                                                        'Disconnect',
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransformIconButton extends StatelessWidget {

  const _TransformIconButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.iconAngle = 0,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  /// Rotation in degrees applied to the icon (0 or 90).
  final double iconAngle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Material(
          color: active
              ? Colors.white.withValues(alpha: 0.9)
              : Colors.black54,
          shape: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Transform.rotate(
              angle: iconAngle * 3.141592653589793 / 180,
              child: Icon(
                icon,
                color: active ? Colors.black87 : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
