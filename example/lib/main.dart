import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_ffi_uvc_example/android_bridge.dart';

import 'app_theme.dart';
import 'widgets/controls_panel.dart';

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
  static const Duration _fpsSampleInterval = Duration(milliseconds: 400);
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
  Timer? _focusRepeatTimer;
  Timer? _focusValueHideTimer;
  bool _focusValueVisible = false;
  String? _status;
  double _previewFps = 0;
  int _lastPreviewSequence = 0;
  DateTime? _lastPreviewSequenceSampleAt;

  @override
  void initState() {
    super.initState();
    _camera.setLogLevel(UvcLogLevel.trace);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializePermissionsAndDevices());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_disconnectSelectedDevice());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      await _stopCurrentPreview();
      await _camera.closeUsbDevice();
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
      UvcCameraMode? startedMode;
      String? lastStartError;
      for (final UvcCameraMode candidate in sortedModes) {
        final String? probeError = await _startModeWithProbe(candidate);
        if (probeError == null) {
          startedMode = candidate;
          break;
        }
        lastStartError = probeError;
      }

      if (startedMode == null) {
        throw Exception(
          'Failed to start any supported mode: ${lastStartError ?? "unknown error"}',
        );
      }

      setState(() {
        _selectedDevice = device;
        _cameraModes = libuvcModes;
        _cameraControls = controls;
        _selectedMode = startedMode;
        _openingDevice = false;
        _previewFrozen = false;
        _manualFocusControlsVisible = false;
        _status = 'Preview running: ${startedMode!.label} / Texture';
      });
      _log('Preview running: ${device.displayName} / ${startedMode.label} / Texture');
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

    final String? startError = await _startModeWithProbe(mode);
    if (startError != null) {
      _setStatus('Failed to switch mode: $startError', openingDevice: false);
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

  void _resetPreviewFps() {
    _previewFps = 0;
    _lastPreviewSequence = 0;
    _lastPreviewSequenceSampleAt = null;
  }

  bool get _hasLivePreview => _previewTextureId != null && _camera.isPreviewing;

  double? get _previewAspectRatio {
    final UvcCameraMode? mode = _selectedMode;
    if (mode == null || mode.width <= 0 || mode.height <= 0) {
      return null;
    }
    return mode.width / mode.height;
  }

  void _samplePreviewFps() {
    final DateTime now = DateTime.now();
    final DateTime? previousAt = _lastPreviewSequenceSampleAt;
    final int latestSequence = _camera.latestFrameSequence();
    if (previousAt == null) {
      _lastPreviewSequence = latestSequence;
      _lastPreviewSequenceSampleAt = now;
      return;
    }

    final double seconds =
        now.difference(previousAt).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (seconds <= 0) {
      return;
    }

    final int frameDelta = latestSequence - _lastPreviewSequence;
    _lastPreviewSequence = latestSequence;
    _lastPreviewSequenceSampleAt = now;
    if (!mounted) {
      _previewFps = frameDelta <= 0 ? 0 : frameDelta / seconds;
      return;
    }
    setState(() {
      _previewFps = frameDelta <= 0 ? 0 : frameDelta / seconds;
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

  Future<String?> _beginPreviewConsumption(UvcCameraMode mode) async {
    _previewStatsTimer?.cancel();
    _resetPreviewFps();
    _lastPreviewSequence = 0;
    _lastPreviewSequenceSampleAt = DateTime.now();

    try {
      final DateTime deadline = DateTime.now().add(_startupProbeTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final int latestSequence = _camera.latestFrameSequence();
        if (latestSequence > 0) {
          _lastPreviewSequence = latestSequence;
          _lastPreviewSequenceSampleAt = DateTime.now();
          _previewStatsTimer = Timer.periodic(
            _fpsSampleInterval,
            (_) => _samplePreviewFps(),
          );
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _samplePreviewFps();
      final String error = _camera.lastError;
      if (error.isNotEmpty) {
        return error;
      }
      return 'libuvc startup probe timed out for ${mode.label} (Texture)';
    } finally {
      if (_camera.latestFrameSequence() <= 0) {
        _previewStatsTimer?.cancel();
        _previewStatsTimer = null;
      }
    }
  }

  Future<String?> _startModeWithProbe(UvcCameraMode mode) async {
    _log('libuvc preview start attempt: ${mode.label} / Texture');
    final int? textureId = _previewTextureId;
    if (textureId != null) {
      await _camera.attachPreviewTexture(
        textureId,
        width: mode.width,
        height: mode.height,
      );
    }
    final int startResult = _camera.startPreview(mode);
    if (startResult != 0) {
      return _camera.lastError;
    }

    final String? probeError = await _beginPreviewConsumption(mode);
    if (probeError == null) {
      return null;
    }

    await _stopCurrentPreview(clearPreviewImage: true);
    return probeError;
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
      final UvcPreviewFrame? frame = _camera.copyLatestFrame();
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
    final String? startError = await _startModeWithProbe(mode);
    if (startError != null) {
      _previewImage = previousImage;
      _setStatus('Failed to resume preview: $startError', openingDevice: false);
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
                                          if (mode == null ||
                                              mode == _selectedMode) {
                                            return;
                                          }
                                          unawaited(_switchMode(mode));
                                        },
                                ),
                              ),
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
