import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/control_pad_store.dart';
import 'package:flutter_hbb/models/model.dart';

const double _kPadSize = 48;
const double _kVerticalEdgePenalty = 32;

/// Mount as a child of the remote page's Stack/Overlay:
/// `Positioned.fill(child: ControlPadOverlay(ffi: gFFI))`.
/// Only the buttons take hits; the rest of the canvas stays interactive.
class ControlPadOverlay extends StatefulWidget {
  final FFI ffi;
  final void Function(PadButton button, bool down)? onPress;
  final void Function(PadButton? editing)? onAddOrEdit;

  const ControlPadOverlay({
    Key? key,
    required this.ffi,
    this.onPress,
    this.onAddOrEdit,
  }) : super(key: key);

  @override
  State<ControlPadOverlay> createState() => _ControlPadOverlayState();
}

class _ControlPadOverlayState extends State<ControlPadOverlay> {
  late final List<PadButton> _buttons = loadControlPad().buttons;
  bool _editing = false;
  String? _pressedId;
  String? _dragId;
  Offset _dragCenter = Offset.zero;
  Future<void> _saveChain = Future<void>.value();

  Offset _centerOf(PadButton b, Size size) {
    final r = _kPadSize / 2;
    switch (b.edge) {
      case PadEdge.left:
        return Offset(b.inset + r, _alongPos(b.along, size.height));
      case PadEdge.right:
        return Offset(
            size.width - b.inset - r, _alongPos(b.along, size.height));
      case PadEdge.top:
        return Offset(_alongPos(b.along, size.width), b.inset + r);
      case PadEdge.bottom:
        return Offset(
            _alongPos(b.along, size.width), size.height - b.inset - r);
    }
  }

  double _alongPos(double along, double length) {
    final r = _kPadSize / 2;
    final span = (length - _kPadSize).clamp(0.0, double.infinity);
    return r + along * span;
  }

  PadButton _snap(PadButton b, Offset c, Size size) {
    final dists = {
      PadEdge.left: c.dx,
      PadEdge.right: size.width - c.dx,
      PadEdge.top: c.dy + _kVerticalEdgePenalty,
      PadEdge.bottom: size.height - c.dy + _kVerticalEdgePenalty,
    };
    final edge = dists.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    final horizontal = edge == PadEdge.top || edge == PadEdge.bottom;
    final length = horizontal ? size.width : size.height;
    final span = (length - _kPadSize).clamp(1.0, double.infinity);
    final pos = horizontal ? c.dx : c.dy;
    return b.copyWith(
        edge: edge,
        along: ((pos - _kPadSize / 2) / span).clamp(0.0, 1.0),
        inset: 8);
  }

  void _save() {
    final snapshot = List<PadButton>.from(_buttons);
    _saveChain = _saveChain.then((_) => saveControlPad(PadConfig(buttons: snapshot)));
  }

  Future<void> _add() async {
    if (widget.onAddOrEdit != null) {
      widget.onAddOrEdit!(null);
      return;
    }
    final used = _buttons.map((b) => '${b.actionKind.name}:${b.payload}').toSet();
    final choices = <PadButton>[
      for (final a in PadAppAction.values)
        if (!used.contains('${PadActionKind.appAction.name}:${a.name}'))
          PadButton.appAction(a, inset: 8),
      for (final e in const [
        ('VK_ESCAPE', 'Esc'),
        ('VK_TAB', 'Tab'),
        ('VK_RETURN', 'Enter'),
        ('VK_F5', 'F5'),
        ('VK_F11', 'F11'),
        ('VK_DELETE', 'Del'),
      ])
        if (!used.contains('${PadActionKind.key.name}:${e.$1}'))
          PadButton(
            id: e.$1,
            actionKind: PadActionKind.key,
            payload: e.$1,
            label: e.$2,
            inset: 8,
          ),
    ];
    if (choices.isEmpty || !mounted) return;
    final picked = await showModalBottomSheet<PadButton>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in choices)
              ListTile(
                title: Text(_labelOf(c)),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _buttons.add(picked.copyWith(
          along: (_buttons.length + 1) / (_buttons.length + 2),
        )));
    _save();
  }

  void _remove(PadButton b) {
    setState(() => _buttons.removeWhere((e) => e.id == b.id));
    _save();
  }

  Widget _chip(PadButton b, Size size) {
    final dragging = _dragId == b.id;
    final pressed = _pressedId == b.id || dragging;
    final center = dragging ? _dragCenter : _centerOf(b, size);
    return Positioned(
      left: center.dx - _kPadSize / 2,
      top: center.dy - _kPadSize / 2,
      width: _kPadSize,
      height: _kPadSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Fire on accepted tap only so long-press → edit does not run the action.
        onTapDown: (_) {
          if (_editing) return;
          setState(() => _pressedId = b.id);
        },
        onTapUp: (_) {
          if (_pressedId == b.id) setState(() => _pressedId = null);
        },
        onTapCancel: () {
          if (_pressedId == b.id) setState(() => _pressedId = null);
        },
        onTap: () {
          if (_editing) return;
          widget.onPress?.call(b, true);
        },
        onLongPress: () => setState(() => _editing = true),
        onPanStart: (_) {
          if (!_editing) return;
          setState(() {
            _dragId = b.id;
            _dragCenter = _centerOf(b, size);
          });
        },
        onPanUpdate: (d) {
          if (_dragId != b.id) return;
          setState(() => _dragCenter = Offset(
                (_dragCenter.dx + d.delta.dx)
                    .clamp(_kPadSize / 2, size.width - _kPadSize / 2),
                (_dragCenter.dy + d.delta.dy)
                    .clamp(_kPadSize / 2, size.height - _kPadSize / 2),
              ));
        },
        onPanEnd: (_) {
          if (_dragId != b.id) return;
          setState(() {
            final i = _buttons.indexWhere((e) => e.id == b.id);
            if (i >= 0) _buttons[i] = _snap(b, _dragCenter, size);
            _dragId = null;
          });
          _save();
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MyTheme.accent.withOpacity(pressed ? 0.75 : 0.25),
                border: Border.all(
                    color: Colors.white.withOpacity(pressed ? 0.9 : 0.35),
                    width: _editing ? 2 : 1),
              ),
              alignment: Alignment.center,
              child: _editing
                  ? const Icon(Icons.open_with, color: Colors.white70, size: 20)
                  : Text(_labelOf(b),
                      style: TextStyle(
                          color: Colors.white.withOpacity(pressed ? 1 : 0.7),
                          fontWeight: FontWeight.w600)),
            ),
            if (_editing)
              Positioned(
                right: -8,
                top: -8,
                child: GestureDetector(
                  onTap: () => _remove(b),
                  child: const CircleAvatar(
                    radius: 10,
                    backgroundColor: Colors.red,
                    child: Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _labelOf(PadButton b) {
    if (b.label != null && b.label!.isNotEmpty) return b.label!;
    final a = b.appAction;
    switch (a) {
      case PadAppAction.menu:
        return 'Menu';
      case PadAppAction.sendText:
        return 'Txt';
      case PadAppAction.toggleTwoFinger:
        return '2F';
      case PadAppAction.keyboard:
        return 'Kbd';
      case null:
        return b.payload;
    }
  }

  Widget _actionChip(IconData icon, Offset at, VoidCallback onTap) {
    return Positioned(
      left: at.dx,
      top: at.dy,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: Colors.black.withOpacity(0.45)),
          child: Icon(icon, color: Colors.white70, size: 20),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          ..._buttons.map((b) => _chip(b, size)),
          if (_editing || _buttons.isEmpty) ...[
            _actionChip(Icons.add, Offset(size.width / 2 - 44, 8), _add),
            _actionChip(Icons.check, Offset(size.width / 2 + 8, 8),
                () => setState(() => _editing = false)),
          ],
        ],
      );
    });
  }
}
