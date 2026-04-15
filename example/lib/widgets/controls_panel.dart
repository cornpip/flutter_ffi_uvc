import 'package:flutter/material.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

class CameraControlsPanel extends StatefulWidget {
  const CameraControlsPanel({
    super.key,
    required this.controls,
    required this.onChanged,
    required this.onReset,
  });

  final List<UvcCameraControl> controls;
  final void Function(UvcControlId id, int value) onChanged;
  final VoidCallback onReset;

  @override
  State<CameraControlsPanel> createState() => _CameraControlsPanelState();
}

class _CameraControlsPanelState extends State<CameraControlsPanel> {
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
              if (v != null) {
                onChanged(v);
              }
            },
          ),
        ],
      ),
    );
  }
}

class FocusButton extends StatelessWidget {
  const FocusButton({
    super.key,
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
