import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
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

  const ControlPadOverlay({
    Key? key,
    this.onPress,
    this.initialButtons,
    this.persist = true,
    this.strings,
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
      builder: (ctx) => _PadEditor(
        buttons: List<PadButton>.from(_buttons),
        labelOf: _t,
        onAdd: (b) {
          _place(b);
          Navigator.pop(ctx);
        },
        onRemove: (b) {
          if (b.appAction == PadAppAction.menu) return;
          setState(() => _buttons.removeWhere((e) => e.id == b.id));
          _save();
          Navigator.pop(ctx);
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
    if (b.label != null && b.label!.isNotEmpty) return b.label!;
    final action = b.appAction;
    if (action != null) return _t(padAppActionLabel(action));
    return b.payload;
  }

  Widget _face(PadButton b) {
    final showText = b.actionKind != PadActionKind.appAction &&
        b.label != null &&
        b.label!.isNotEmpty;
    if (showText) {
      final text = b.label!.length > 4 ? b.label!.substring(0, 4) : b.label!;
      return Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      );
    }
    return Icon(_iconOf(b), color: Colors.white, size: 26);
  }

  IconData _iconOf(PadButton b) {
    final name = (b.icon != null && b.icon!.isNotEmpty)
        ? b.icon!
        : (b.appAction == null ? '' : _defaultIconFor(b.appAction!));
    return _iconData(name);
  }

  String _defaultIconFor(PadAppAction a) {
    switch (a) {
      case PadAppAction.menu:
        return 'tune';
      case PadAppAction.sendText:
        return 'keyboard_voice';
      case PadAppAction.keyboard:
        return 'keyboard';
      case PadAppAction.toggleTwoFinger:
        return 'touch_app';
      case PadAppAction.gestureHelp:
        return 'gesture';
      case PadAppAction.chat:
        return 'message';
      case PadAppAction.displays:
        return 'tv';
      case PadAppAction.disconnect:
        return 'close';
      case PadAppAction.more:
        return 'more_vert';
    }
  }

  IconData _iconData(String name) {
    switch (name) {
      case 'tune':
        return Icons.tune;
      case 'keyboard_voice':
        return Icons.keyboard_voice;
      case 'keyboard':
        return Icons.keyboard;
      case 'touch_app':
        return Icons.touch_app;
      case 'gesture':
        return Icons.gesture;
      case 'message':
        return Icons.message;
      case 'tv':
        return Icons.tv;
      case 'close':
        return Icons.close;
      case 'more_vert':
        return Icons.more_vert;
      case 'text_fields':
        return Icons.text_fields;
      default:
        return Icons.circle;
    }
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

class _PadEditor extends StatefulWidget {
  final List<PadButton> buttons;
  final String Function(String key) labelOf;
  final void Function(PadButton button) onAdd;
  final void Function(PadButton button) onRemove;

  const _PadEditor({
    required this.buttons,
    required this.labelOf,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<_PadEditor> createState() => _PadEditorState();
}

class _PadEditorState extends State<_PadEditor> {
  final _keyCtrl = TextEditingController();
  final _comboKeyCtrl = TextEditingController();
  final _mods = <String>{};

  static const _catalog = <PadAppAction>[
    PadAppAction.sendText,
    PadAppAction.keyboard,
    PadAppAction.gestureHelp,
    PadAppAction.chat,
    PadAppAction.displays,
    PadAppAction.disconnect,
    PadAppAction.more,
    PadAppAction.toggleTwoFinger,
  ];

  @override
  void dispose() {
    _keyCtrl.dispose();
    _comboKeyCtrl.dispose();
    super.dispose();
  }

  bool _has(PadAppAction a) => widget.buttons.any((b) => b.appAction == a);

  String _title(PadButton b) {
    if (b.label != null && b.label!.isNotEmpty) return b.label!;
    final action = b.appAction;
    if (action != null) return widget.labelOf(padAppActionLabel(action));
    return b.payload;
  }

  void _addKey() {
    final raw = _keyCtrl.text.trim();
    if (raw.isEmpty) return;
    widget.onAdd(PadButton(
      id: 'key-${DateTime.now().microsecondsSinceEpoch}',
      actionKind: PadActionKind.key,
      payload: raw,
      label: raw,
    ));
  }

  void _addCombo() {
    final raw = _comboKeyCtrl.text.trim();
    if (raw.isEmpty || _mods.isEmpty) return;
    final payload = '${_mods.join('+')}+$raw';
    widget.onAdd(PadButton(
      id: 'combo-${DateTime.now().microsecondsSinceEpoch}',
      actionKind: PadActionKind.combo,
      payload: payload,
      label: payload,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final missing = [for (final a in _catalog) if (!_has(a)) a];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(widget.labelOf('Menu'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(widget.labelOf('Edit shortcuts')),
          ),
          for (final b in widget.buttons)
            if (b.appAction != PadAppAction.menu)
              ListTile(
                title: Text(_title(b)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => widget.onRemove(b),
                ),
              ),
          if (missing.isNotEmpty) const Divider(),
          for (final a in missing)
            ListTile(
              leading: Icon(_catalogIcon(a)),
              title: Text(widget.labelOf(padAppActionLabel(a))),
              trailing: const Icon(Icons.add),
              onTap: () => widget.onAdd(PadButton.appAction(a)),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(widget.labelOf('Key')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _keyCtrl,
                  decoration: InputDecoration(
                    hintText: 'Esc, F5, Enter',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: _addKey, child: Text(widget.labelOf('Add'))),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(widget.labelOf('Combo')),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final m in const ['ctrl', 'alt', 'shift', 'command'])
                  FilterChip(
                    label: Text(m),
                    selected: _mods.contains(m),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _mods.add(m);
                      } else {
                        _mods.remove(m);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _comboKeyCtrl,
                  decoration: const InputDecoration(
                    hintText: 'delete',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: _addCombo, child: Text(widget.labelOf('Add'))),
            ]),
          ),
        ],
      ),
    );
  }

  IconData _catalogIcon(PadAppAction a) {
    switch (a) {
      case PadAppAction.sendText:
        return Icons.keyboard_voice;
      case PadAppAction.keyboard:
        return Icons.keyboard;
      case PadAppAction.gestureHelp:
        return Icons.gesture;
      case PadAppAction.chat:
        return Icons.message;
      case PadAppAction.displays:
        return Icons.tv;
      case PadAppAction.disconnect:
        return Icons.close;
      case PadAppAction.more:
        return Icons.more_vert;
      case PadAppAction.toggleTwoFinger:
        return Icons.touch_app;
      case PadAppAction.menu:
        return Icons.tune;
    }
  }
}
