import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/control_pad_editor.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/control_pad_store.dart';

const double _kPadSize = 56;
const double _kDragSlop = 12;

/// Mount above the remote canvas. Only the buttons take hits.
///
/// Every button can be dragged; the position is stored as a fraction of the
/// canvas. The menu button opens the shortcut editor and cannot be removed.
class ControlPadOverlay extends StatefulWidget {
  final void Function(PadButton button, bool down)? onPress;

  /// When set, used instead of [loadControlPad].
  final List<PadButton>? initialButtons;

  /// Tests pass false so a drag does not touch the native option store.
  final bool persist;

  /// Tests pass an identity function. The app uses [translate].
  final String Function(String key)? strings;

  /// Live on/off for toggle actions. Read during build so the face updates.
  final bool Function(PadButton button)? isOn;

  const ControlPadOverlay({
    Key? key,
    this.onPress,
    this.initialButtons,
    this.persist = true,
    this.strings,
    this.isOn,
  }) : super(key: key);

  @override
  State<ControlPadOverlay> createState() => _ControlPadOverlayState();
}

class _ControlPadOverlayState extends State<ControlPadOverlay> {
  late final List<PadButton> _buttons = List<PadButton>.from(
      (widget.initialButtons ?? loadControlPad().buttons));
  String? _dragId;
  Offset _dragCenter = Offset.zero;
  Offset? _panOrigin;
  Offset _panTotal = Offset.zero;
  bool _moved = false;
  Future<void> _saveChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    if (!_buttons.any((b) => b.appAction == PadAppAction.menu)) {
      _buttons.insert(
          0, PadButton.appAction(PadAppAction.menu, x: 0.92, y: 0.50));
    }
  }

  String _t(String key) => widget.strings?.call(key) ?? translate(key);

  Offset _centerOf(PadButton b, Size size) =>
      Offset(b.x * size.width, b.y * size.height);

  void _save() {
    if (!widget.persist) return;
    final snapshot = List<PadButton>.from(_buttons);
    _saveChain =
        _saveChain.then((_) => saveControlPad(PadConfig(buttons: snapshot)));
  }

  void _place(PadButton b) {
    final n = _buttons.length;
    setState(() => _buttons.add(b.copyWith(
          x: 0.78,
          y: (0.28 + 0.12 * n).clamp(0.12, 0.88),
        )));
    _save();
  }

  Future<void> _openEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => PadEditor(
        buttons: List<PadButton>.from(_buttons),
        labelOf: _t,
        onAdd: _place,
        onRemove: (b) {
          if (b.appAction == PadAppAction.menu) return;
          setState(() => _buttons.removeWhere((e) => e.id == b.id));
          _save();
        },
        onUpdate: (b) {
          setState(() {
            final i = _buttons.indexWhere((e) => e.id == b.id);
            if (i < 0) return;
            _buttons[i] = b.copyWith(x: _buttons[i].x, y: _buttons[i].y);
          });
          _save();
        },
      ),
    );
  }

  void _activate(PadButton b) {
    if (b.appAction == PadAppAction.menu) {
      _openEditor();
      return;
    }
    widget.onPress?.call(b, true);
  }

  Widget _chip(PadButton b, Size size) {
    final dragging = _dragId == b.id;
    final center = dragging ? _dragCenter : _centerOf(b, size);
    final r = _kPadSize / 2;
    return Positioned(
      key: ValueKey(b.id),
      left: center.dx - r,
      top: center.dy - r,
      width: _kPadSize,
      height: _kPadSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_moved) return;
          _activate(b);
        },
        onPanStart: (_) {
          _panOrigin = _centerOf(b, size);
          _panTotal = Offset.zero;
          _moved = false;
        },
        onPanUpdate: (d) {
          final origin = _panOrigin;
          if (origin == null) return;
          _panTotal += d.delta;
          if (_panTotal.distance < _kDragSlop) return;
          setState(() {
            _moved = true;
            _dragId = b.id;
            _dragCenter = Offset(
              (origin.dx + _panTotal.dx).clamp(r, size.width - r),
              (origin.dy + _panTotal.dy).clamp(r, size.height - r),
            );
          });
        },
        onPanEnd: (_) => _endDrag(b, size),
        onPanCancel: () => _endDrag(b, size),
        child: Tooltip(
          message: _faceLabel(b),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: MyTheme.accent.withOpacity(dragging ? 1 : 0.92),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x47000000),
                  blurRadius: 6,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: _face(b),
          ),
        ),
      ),
    );
  }

  void _endDrag(PadButton b, Size size) {
    if (_moved && _dragId == b.id) {
      final i = _buttons.indexWhere((e) => e.id == b.id);
      if (i >= 0) {
        final w = size.width <= 0 ? 1.0 : size.width;
        final h = size.height <= 0 ? 1.0 : size.height;
        _buttons[i] = b.copyWith(x: _dragCenter.dx / w, y: _dragCenter.dy / h);
      }
      _save();
    }
    setState(() {
      _dragId = null;
      _moved = false;
      _panOrigin = null;
    });
  }

  String _faceLabel(PadButton b) {
    final on = _isOn(b);
    if (on && b.labelOn != null && b.labelOn!.isNotEmpty) return b.labelOn!;
    if (b.label != null && b.label!.isNotEmpty) return b.label!;
    final action = b.appAction;
    if (action != null) return _t(padAppActionLabel(action));
    return b.payload;
  }

  bool _isOn(PadButton b) {
    final action = b.appAction;
    if (action == null || !padAppActionIsToggle(action)) return false;
    return widget.isOn?.call(b) == true;
  }

  Widget _face(PadButton b) {
    final on = _isOn(b);
    if (b.face == PadFace.text) {
      final raw = on && b.labelOn != null && b.labelOn!.isNotEmpty
          ? b.labelOn!
          : (b.label ?? _faceLabel(b));
      final text = raw.length > 4 ? raw.substring(0, 4) : raw;
      return Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      );
    }
    return Icon(padIconData(_iconName(b, on)), color: Colors.white, size: 26);
  }

  String _iconName(PadButton b, bool on) {
    if (on && b.iconOn != null && b.iconOn!.isNotEmpty) return b.iconOn!;
    if (b.icon != null && b.icon!.isNotEmpty) return b.icon!;
    final action = b.appAction;
    if (action == null) return '';
    if (on) return padAppActionIconOn(action) ?? padAppActionIcon(action);
    return padAppActionIcon(action);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      return Stack(
        clipBehavior: Clip.none,
        children: [for (final b in _buttons) _chip(b, size)],
      );
    });
  }
}
