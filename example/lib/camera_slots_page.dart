import 'package:flutter/material.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import 'main.dart';

/// Hosts one [UvcPreviewPage] per camera so several cameras stream at once.
///
/// The first slot uses the shared [uvcCamera]. Every added slot creates its
/// own [UvcCamera] and disposes it when removed. Wide windows show all slots
/// side by side. Narrow screens show one slot at a time, and the others keep
/// streaming in the background.
class CameraSlotsPage extends StatefulWidget {
  const CameraSlotsPage({super.key});

  static const int maxSlots = 4;

  @override
  State<CameraSlotsPage> createState() => _CameraSlotsPageState();
}

class _CameraSlot {
  _CameraSlot({
    required this.camera,
    required this.ownsCamera,
    required this.id,
  });

  final UvcCamera camera;
  final bool ownsCamera;
  final int id;
  // Keeps the page state alive when the layout switches between the
  // side-by-side row and the stacked view.
  final GlobalKey key = GlobalKey();
}

class _CameraSlotsPageState extends State<CameraSlotsPage> {
  static const double _sideBySideMinWidth = 1100;

  // Bumped whenever a slot opens or closes a device so every slot rebuilds
  // its device list. Which device each slot holds comes from the package.
  final ValueNotifier<int> _openRevision = ValueNotifier<int>(0);
  bool _disposed = false;

  // A removed page reports its close after its own teardown, which may be
  // after this host is gone.
  void _bumpOpenRevision() {
    if (!_disposed) _openRevision.value += 1;
  }

  bool _isOpenElsewhere(UvcCamera self, int deviceId) => _slots.any(
    (_CameraSlot slot) =>
        slot.camera != self && slot.camera.openedDeviceId == deviceId,
  );

  final List<_CameraSlot> _slots = <_CameraSlot>[
    _CameraSlot(camera: uvcCamera, ownsCamera: false, id: 1),
  ];
  int _nextId = 2;
  int _current = 0;

  void _addSlot() {
    if (_slots.length >= CameraSlotsPage.maxSlots) return;
    setState(() {
      _slots.add(
        _CameraSlot(camera: UvcCamera(), ownsCamera: true, id: _nextId++),
      );
      _current = _slots.length - 1;
    });
  }

  void _removeSlot(int index) {
    // The page disposes the camera itself once its teardown has finished.
    setState(() {
      _slots.removeAt(index);
      if (_current >= _slots.length) _current = _slots.length - 1;
    });
  }

  Widget _page(_CameraSlot slot) => UvcPreviewPage(
    key: slot.key,
    camera: slot.camera,
    ownsCamera: slot.ownsCamera,
    title: 'Camera ${slot.id}',
    isOpenElsewhere: (int deviceId) => _isOpenElsewhere(slot.camera, deviceId),
    openRevision: _openRevision,
    onOpenChanged: _bumpOpenRevision,
  );

  @override
  void dispose() {
    _disposed = true;
    _openRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool sideBySide =
            constraints.maxWidth >= _sideBySideMinWidth && _slots.length > 1;
        final Widget body = sideBySide
            ? Row(
                children: <Widget>[
                  for (final _CameraSlot slot in _slots)
                    Expanded(child: _page(slot)),
                ],
              )
            : IndexedStack(
                index: _current,
                children: <Widget>[
                  for (final _CameraSlot slot in _slots) _page(slot),
                ],
              );
        return Scaffold(
          body: body,
          bottomNavigationBar: _SlotBar(
            slots: _slots,
            current: _current,
            sideBySide: sideBySide,
            onSelect: (int index) => setState(() => _current = index),
            onAdd: _slots.length < CameraSlotsPage.maxSlots ? _addSlot : null,
            onRemove: _removeSlot,
          ),
        );
      },
    );
  }
}

class _SlotBar extends StatelessWidget {
  const _SlotBar({
    required this.slots,
    required this.current,
    required this.sideBySide,
    required this.onSelect,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_CameraSlot> slots;
  final int current;
  final bool sideBySide;
  final ValueChanged<int> onSelect;
  final VoidCallback? onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < slots.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InputChip(
                            label: Text('Camera ${slots[i].id}'),
                            selected: !sideBySide && i == current,
                            onSelected: sideBySide ? null : (_) => onSelect(i),
                            // The first slot is the shared instance and stays.
                            onDeleted: slots[i].ownsCamera
                                ? () => onRemove(i)
                                : null,
                            deleteIcon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                tooltip: 'Add camera',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
