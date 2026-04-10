import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

const Color _brandGreen = Color(0xFF2F6B3F);
const Color _brandGreenLight = Color(0xFFE4F0E7);
const Color _brandGreenBorder = Color(0xFF9EBDA6);
const Color _surfaceNeutral = Color(0xFFF8FAF8);
const Color _surfaceNeutralBorder = Color(0xFFD7E1D7);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class UsbCameraDevice {
  const UsbCameraDevice({
    required this.deviceId,
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.productName,
    required this.manufacturerName,
    required this.serialNumber,
    required this.hasPermission,
  });

  factory UsbCameraDevice.fromMap(Map<Object?, Object?> map) {
    return UsbCameraDevice(
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

  String get title {
    final String label = productName.isNotEmpty ? productName : deviceName;
    return '$label (${vendorId.toRadixString(16)}:${productId.toRadixString(16)})';
  }

  String get subtitle {
    final List<String> parts = <String>[
      if (manufacturerName.isNotEmpty) manufacturerName,
      if (serialNumber.isNotEmpty) 'S/N $serialNumber',
      hasPermission ? 'permission granted' : 'permission required',
    ];
    return parts.join(' • ');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UVC Preview Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandGreen,
          surface: _surfaceNeutral,
        ),
        scaffoldBackgroundColor: _surfaceNeutral,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      home: const UvcPreviewPage(),
    );
  }
}

class UvcPreviewPage extends StatefulWidget {
  const UvcPreviewPage({super.key, this.camera = uvcCamera});

  final UvcCamera camera;

  @override
  State<UvcPreviewPage> createState() => _UvcPreviewPageState();
}

class _UvcPreviewPageState extends State<UvcPreviewPage>
    with WidgetsBindingObserver {
  static const MethodChannel _usbChannel = MethodChannel(
    'flutter_ffi_uvc_example/usb',
  );
  static const String _logPrefix = '@@@@UVC_EXAMPLE';
  static const Duration _startupProbeTimeout = Duration(seconds: 2);
  static const Duration _startupProbeInterval = Duration(milliseconds: 120);

  UvcCamera get _camera => widget.camera;

  List<UsbCameraDevice> _devices = const <UsbCameraDevice>[];
  List<UvcCameraMode> _cameraModes = const <UvcCameraMode>[];
  List<UvcCameraControl> _cameraControls = const <UvcCameraControl>[];
  UsbCameraDevice? _selectedDevice;
  UvcCameraMode? _selectedMode;
  ui.Image? _previewImage;
  Timer? _frameTimer;
  bool _loadingDevices = true;
  bool _openingDevice = false;
  bool _decodingFrame = false;
  bool _afTriggering = false;
  bool _previewFrozen = false;
  bool _savingPhoto = false;
  bool _manualFocusControlsVisible = false;
  Timer? _focusRepeatTimer;
  Timer? _focusValueHideTimer;
  bool _focusValueVisible = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _camera.setLogLevel(UvcLogLevel.debug);
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
    _frameTimer?.cancel();
    _focusRepeatTimer?.cancel();
    _focusValueHideTimer?.cancel();
    _previewImage?.dispose();
    unawaited(_stopCurrentPreview(closeDevice: true));
    unawaited(_usbChannel.invokeMethod<void>('closeUsbDevice'));
    super.dispose();
  }

  Future<void> _initializePermissionsAndDevices() async {
    try {
      final bool granted =
          await _usbChannel.invokeMethod<bool>('ensureCameraPermission') ??
          false;
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
      final List<Object?>? rawDevices = await _usbChannel
          .invokeListMethod<Object?>('listUsbDevices');
      final List<UsbCameraDevice> devices = (rawDevices ?? <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(UsbCameraDevice.fromMap)
          .toList();

      setState(() {
        _devices = devices;
        _selectedDevice =
            devices.any(
              (UsbCameraDevice device) =>
                  device.deviceId == _selectedDevice?.deviceId,
            )
            ? devices.firstWhere(
                (UsbCameraDevice device) =>
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

  Future<void> _openSelectedDevice(UsbCameraDevice device) async {
    _setStatus('Opening device...', openingDevice: true);
    _log('Open device requested: ${device.title}');

    _frameTimer?.cancel();
    _previewImage?.dispose();
    _previewImage = null;

    try {
      await _stopCurrentPreview(closeDevice: true);
      await _usbChannel.invokeMethod<void>('closeUsbDevice');
      final Map<Object?, Object?>? result = await _usbChannel
          .invokeMapMethod<Object?, Object?>('openUsbDevice', <String, Object?>{
            'deviceId': device.deviceId,
          });

      final int fd = result?['fileDescriptor'] as int? ?? -1;
      final int openResult = _camera.openFd(fd);
      if (openResult != 0) {
        throw Exception('uvc_open_fd failed: ${_camera.lastError}');
      }

      final List<UvcCameraMode> libuvcModes = _camera.supportedModes();
      final List<UvcCameraControl> controls = _camera.supportedControls();
      _log('Controls: ${controls.map((UvcCameraControl c) => '${c.name}(id=${c.id.nativeValue},cur=${c.cur})').join(', ')}');

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

      _frameTimer = Timer.periodic(
        const Duration(milliseconds: 66),
        (_) => unawaited(_pollLatestFrame()),
      );

      setState(() {
        _selectedDevice = device;
        _cameraModes = libuvcModes;
        _cameraControls = controls;
        _selectedMode = startedMode;
        _openingDevice = false;
        _previewFrozen = false;
        _manualFocusControlsVisible = false;
        _status = 'Preview running: ${startedMode!.label}';
      });
      _log('Preview running: ${device.title} / ${startedMode.label}');
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

    final String deviceTitle = _selectedDevice?.title ?? 'Connected device';
    _setStatus('Disconnecting device...', openingDevice: true);
    _log('Disconnect requested: $deviceTitle');

    try {
      await _stopCurrentPreview(closeDevice: true, clearPreviewImage: true);
      await _usbChannel.invokeMethod<void>('closeUsbDevice');
      setState(() {
        _selectedDevice = null;
        _selectedMode = null;
        _cameraModes = const <UvcCameraMode>[];
        _cameraControls = const <UvcCameraControl>[];
        _previewFrozen = false;
        _manualFocusControlsVisible = false;
        _openingDevice = false;
        _status = 'Device disconnected.';
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
    _setStatus('Switching mode: ${mode.label}', openingDevice: true);
    await _stopCurrentPreview(closeDevice: false, clearPreviewImage: true);

    final String? startError = await _startModeWithProbe(mode);
    if (startError != null) {
      _setStatus('Failed to switch mode: $startError', openingDevice: false);
      return;
    }

    _frameTimer = Timer.periodic(
      const Duration(milliseconds: 66),
      (_) => unawaited(_pollLatestFrame()),
    );

    setState(() {
      _selectedMode = mode;
      _openingDevice = false;
      _previewFrozen = false;
      _manualFocusControlsVisible = false;
      _status = 'Preview running: ${mode.label}';
    });
    _log('Preview mode changed: ${mode.label}');
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

  Future<void> _pollLatestFrame() async {
    if (_decodingFrame || _previewFrozen) {
      return;
    }

    _decodingFrame = true;
    try {
      final ui.Image? image = await _decodeLibuvcFrame();
      if (image == null) {
        return;
      }
      if (!mounted) {
        image.dispose();
        return;
      }

      final ui.Image? previousImage = _previewImage;
      setState(() {
        _previewImage = image;
      });
      previousImage?.dispose();
    } finally {
      _decodingFrame = false;
    }
  }

  Future<ui.Image?> _decodeLibuvcFrame() async {
    if (!_camera.isPreviewing) {
      return null;
    }

    final UvcPreviewFrame? frame = _camera.copyLatestFrame();
    if (frame == null) {
      return null;
    }
    return _decodeRgbaFrame(frame);
  }

  Future<String?> _startModeWithProbe(UvcCameraMode mode) async {
    _log('libuvc preview start attempt: ${mode.label}');
    final int startResult = _camera.startPreview(mode);
    if (startResult != 0) {
      return _camera.lastError;
    }

    final String? probeError = await _probeActivePreview(mode);
    if (probeError == null) {
      return null;
    }

    await _stopCurrentPreview(closeDevice: false, clearPreviewImage: true);
    return probeError;
  }

  Future<String?> _probeActivePreview(UvcCameraMode mode) async {
    final DateTime deadline = DateTime.now().add(_startupProbeTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final String error = _camera.lastError;
      if (error.isNotEmpty) {
        return error;
      }
      final UvcPreviewFrame? frame = _camera.copyLatestFrame();
      if (frame != null) {
        return null;
      }
      await Future<void>.delayed(_startupProbeInterval);
    }

    final String error = _camera.lastError;
    if (error.isNotEmpty) {
      return error;
    }
    return 'libuvc startup probe timed out for ${mode.label}';
  }

  Future<ui.Image> _decodeRgbaFrame(UvcPreviewFrame frame) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgbaBytes,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  Future<void> _stopCurrentPreview({
    required bool closeDevice,
    bool clearPreviewImage = false,
  }) async {
    _frameTimer?.cancel();
    _frameTimer = null;

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
    if (closeDevice) {
      _camera.closeDevice();
    }
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
    final ui.Image? image = _previewImage;
    if (image == null || _savingPhoto || _previewFrozen) {
      return;
    }

    setState(() => _savingPhoto = true);
    try {
      final ByteData? pngData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (pngData == null) {
        throw Exception('Failed to encode PNG from the current preview frame.');
      }

      final Uint8List pngBytes = pngData.buffer.asUint8List();
      final String timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final String? savedUri = await _usbChannel
          .invokeMethod<String>('saveImageToGallery', <String, Object?>{
            'bytes': pngBytes,
            'displayName': 'uvc_capture_$timestamp.png',
            'mimeType': 'image/png',
          });

      _setStatus(
        savedUri == null || savedUri.isEmpty
            ? 'Saved capture to gallery.'
            : 'Saved capture to gallery: $savedUri',
      );
      await _stopCurrentPreview(closeDevice: false, clearPreviewImage: false);
      if (mounted) {
        setState(() => _previewFrozen = true);
      } else {
        _previewFrozen = true;
      }
      _setStatus('Preview paused on captured frame.');
    } on PlatformException catch (error) {
      _setStatus(
        'Failed to save capture: ${error.message ?? error.code}',
        error: error,
      );
    } catch (error) {
      _setStatus('Failed to save capture.', error: error);
    } finally {
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

    _setStatus('Resuming preview...', openingDevice: true);
    final String? startError = await _startModeWithProbe(mode);
    if (startError != null) {
      _setStatus('Failed to resume preview: $startError', openingDevice: false);
      return;
    }

    _frameTimer = Timer.periodic(
      const Duration(milliseconds: 66),
      (_) => unawaited(_pollLatestFrame()),
    );

    if (!mounted) {
      _previewFrozen = false;
      _openingDevice = false;
      _status = 'Preview running: ${mode.label}';
      return;
    }

    setState(() {
      _previewFrozen = false;
      _openingDevice = false;
      _status = 'Preview running: ${mode.label}';
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
        return _ControlsPanel(
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
                      child: _previewImage == null
                          ? const Text(
                              'No preview',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 18,
                              ),
                            )
                          : RawImage(image: _previewImage, fit: BoxFit.contain),
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
                    if (_focusAbsControl != null)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
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
                            if (_manualFocusControlsVisible) ...<Widget>[
                              _FocusButton(
                                icon: Icons.add,
                                onPressStart: () => _startFocusRepeat(1),
                                onPressEnd: _stopFocusRepeat,
                              ),
                              const SizedBox(height: 8),
                              _FocusButton(
                                icon: Icons.remove,
                                onPressStart: () => _startFocusRepeat(-1),
                                onPressEnd: _stopFocusRepeat,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                  if (mode == null || mode == _selectedMode) {
                                    return;
                                  }
                                  unawaited(_switchMode(mode));
                                },
                        ),
                      ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 96),
                        child: _loadingDevices
                            ? const Center(child: CircularProgressIndicator())
                            : ListView.separated(
                                itemCount: _devices.length,
                                separatorBuilder:
                                    (BuildContext context, int index) =>
                                        const Divider(height: 1),
                                itemBuilder: (BuildContext context, int index) {
                                  final UsbCameraDevice device =
                                      _devices[index];
                                  final bool selected =
                                      _selectedDevice?.deviceId ==
                                      device.deviceId;
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? _brandGreenLight
                                          : Colors.white,
                                      border: Border.all(
                                        color: selected
                                            ? _brandGreenBorder
                                            : _surfaceNeutralBorder,
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
                                          device.title,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          device.subtitle,
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
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: Center(
              child: FilledButton.icon(
                onPressed: _savingPhoto
                    ? null
                    : _previewFrozen
                    ? () => unawaited(_resumePreview())
                    : _previewImage == null
                    ? null
                    : () => unawaited(_capturePhoto()),
                style: FilledButton.styleFrom(
                  backgroundColor: _previewFrozen ? Colors.white : _brandGreen,
                  foregroundColor: _previewFrozen ? _brandGreen : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  side: _previewFrozen
                      ? const BorderSide(color: _brandGreenBorder)
                      : BorderSide.none,
                ),
                icon: _savingPhoto
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _previewFrozen ? Icons.play_arrow : Icons.camera_alt,
                      ),
                label: Text(
                  _savingPhoto
                      ? 'Saving...'
                      : _previewFrozen
                      ? 'Resume preview'
                      : 'Capture',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Camera controls bottom sheet
// ---------------------------------------------------------------------------

class _ControlsPanel extends StatefulWidget {
  const _ControlsPanel({
    required this.controls,
    required this.onChanged,
    required this.onReset,
  });

  final List<UvcCameraControl> controls;
  final void Function(UvcControlId id, int value) onChanged;
  final VoidCallback onReset;

  @override
  State<_ControlsPanel> createState() => _ControlsPanelState();
}

class _ControlsPanelState extends State<_ControlsPanel> {
  late List<UvcCameraControl> _controls;
  UvcControlId? _draggingId;

  @override
  void initState() {
    super.initState();
    _controls = List<UvcCameraControl>.from(widget.controls);
  }

  void _update(UvcControlId id, int value) {
    setState(() {
      _controls = _controls
          .map((UvcCameraControl c) => c.id == id ? c.copyWithCur(value) : c)
          .toList();
    });
    widget.onChanged(id, value);
  }

  void _onDragStart(UvcControlId id) => setState(() => _draggingId = id);
  void _onDragEnd() => setState(() => _draggingId = null);

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          color: _draggingId != null
              ? Colors.transparent
              : Theme.of(context).colorScheme.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _draggingId != null ? 0 : 1,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // Handle bar
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: <Widget>[
                          const Text(
                            'Camera controls',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: widget.onReset,
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('Restore defaults'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _controls.length,
                  itemBuilder: (BuildContext context, int index) {
                    final UvcCameraControl ctrl = _controls[index];
                    final bool isActive = _draggingId == ctrl.id;
                    final bool hide = _draggingId != null && !isActive;
                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: hide ? 0 : 1,
                      child: switch (ctrl.kind) {
                        UvcControlKind.boolean => _BoolControlTile(
                          ctrl: ctrl,
                          onChanged: (int v) => _update(ctrl.id, v),
                        ),
                        UvcControlKind.enumLike => _EnumControlTile(
                          ctrl: ctrl,
                          onChanged: (int v) => _update(ctrl.id, v),
                        ),
                        _ => _SliderControlTile(
                          ctrl: ctrl,
                          onChanged: (int v) => _update(ctrl.id, v),
                          onDragStart: _onDragStart,
                          onDragEnd: _onDragEnd,
                        ),
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderControlTile extends StatelessWidget {
  const _SliderControlTile({
    required this.ctrl,
    required this.onChanged,
    required this.onDragStart,
    required this.onDragEnd,
  });

  final UvcCameraControl ctrl;
  final ValueChanged<int> onChanged;
  final ValueChanged<UvcControlId> onDragStart;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final double range = (ctrl.max - ctrl.min).toDouble();
    final int divisions = range > 0 && ctrl.res > 0
        ? (range / ctrl.res).round().clamp(1, 500)
        : null as int? ?? 100;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                ctrl.label,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              Text(
                '${ctrl.cur}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Text(
                '${ctrl.min}',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
              Expanded(
                child: Slider(
                  value: ctrl.cur.toDouble().clamp(
                    ctrl.min.toDouble(),
                    ctrl.max.toDouble(),
                  ),
                  min: ctrl.min.toDouble(),
                  max: ctrl.max.toDouble(),
                  divisions: divisions,
                  onChangeStart: (_) => onDragStart(ctrl.id),
                  onChangeEnd: (_) => onDragEnd(),
                  onChanged: (double v) => onChanged(v.round()),
                ),
              ),
              Text(
                '${ctrl.max}',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BoolControlTile extends StatelessWidget {
  const _BoolControlTile({required this.ctrl, required this.onChanged});

  final UvcCameraControl ctrl;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(ctrl.label),
      value: ctrl.cur != 0,
      onChanged: (bool v) => onChanged(v ? 1 : 0),
    );
  }
}

// Power line frequency and AE mode use named options where known.
class _EnumControlTile extends StatelessWidget {
  const _EnumControlTile({required this.ctrl, required this.onChanged});

  final UvcCameraControl ctrl;
  final ValueChanged<int> onChanged;

  static const Map<String, Map<int, String>> _enumLabels =
      <String, Map<int, String>>{
        'power_line_frequency': <int, String>{
          0: 'Disabled',
          1: '50 Hz',
          2: '60 Hz',
        },
        'ae_mode': <int, String>{
          1: 'Manual',
          2: 'Auto',
          4: 'Shutter priority',
          8: 'Aperture priority',
        },
      };

  @override
  Widget build(BuildContext context) {
    final Map<int, String>? labels = _enumLabels[ctrl.name];
    // Build list of valid values from min..max by res steps
    final List<int> values = <int>[];
    if (labels != null) {
      values.addAll(labels.keys);
    } else {
      for (int v = ctrl.min; v <= ctrl.max; v += ctrl.res > 0 ? ctrl.res : 1) {
        values.add(v);
      }
    }

    final int currentValue = values.contains(ctrl.cur)
        ? ctrl.cur
        : values.first;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: <Widget>[
          Text(ctrl.label, style: const TextStyle(fontWeight: FontWeight.w500)),
          const Spacer(),
          DropdownButton<int>(
            value: currentValue,
            items: values
                .map(
                  (int v) => DropdownMenuItem<int>(
                    value: v,
                    child: Text(labels?[v] ?? '$v'),
                  ),
                )
                .toList(),
            onChanged: (int? v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _FocusButton extends StatelessWidget {
  const _FocusButton({
    required this.icon,
    required this.onPressStart,
    required this.onPressEnd,
  });

  final IconData icon;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onPressStart(),
      onPointerUp: (_) => onPressEnd(),
      onPointerCancel: (_) => onPressEnd(),
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
