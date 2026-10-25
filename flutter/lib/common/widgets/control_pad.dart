import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' hide Dialog;
import 'package:flutter_hbb/common/widgets/control_pad_editor.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/control_pad_store.dart';
import 'package:path_provider/path_provider.dart';

File? _padLogFile;
Future<void>? _padLogReady;

void _padLog(String message) {
  final line = '${DateTime.now().toIso8601String()} $message';
  debugPrint('PADPANEL $line');
  _padLogReady ??= () async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _padLogFile = File('${dir.path}/pad_panel.log');
      debugPrint('PADPANEL file ${_padLogFile!.path}');
    } catch (e) {
      debugPrint('PADPANEL file unavailable $e');
    }
  }();
  _padLogReady!.then((_) {
    try {
      _padLogFile?.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  });
}

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

  /// Tests pass this so a recent row does not touch the native option store.
  final List<String>? initialRecent;

  const ControlPadOverlay({
    Key? key,
    this.onPress,
    this.initialButtons,
    this.persist = true,
    this.strings,
    this.isOn,
    this.initialRecent,
  }) : super(key: key);

  @override
  State<ControlPadOverlay> createState() => _ControlPadOverlayState();
}

class _ControlPadOverlayState extends State<ControlPadOverlay> {
  late final List<PadButton> _buttons = List<PadButton>.from(
      (widget.initialButtons ?? loadControlPad().buttons));
  late final List<String> _recent = List<String>.from(widget.initialRecent ??
      (widget.initialButtons != null || !widget.persist
          ? const <String>[]
          : loadControlPad().recent));
  String? _dragId;
  Offset _dragCenter = Offset.zero;
  Offset? _panOrigin;
  Offset _panTotal = Offset.zero;
  bool _moved = false;
  Future<void> _saveChain = Future<void>.value();
  bool _panelOpen = false;
  DateTime? _panelOpenedAt;

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
    final recent = List<String>.from(_recent);
    _saveChain = _saveChain.then((_) =>
        saveControlPad(PadConfig(buttons: snapshot, recent: recent)));
  }

  void _remember(PadAppAction? action) {
    if (action == null || action == PadAppAction.menu) return;
    setState(() {
      _recent.remove(action.name);
      _recent.insert(0, action.name);
      if (_recent.length > 10) {
        _recent.removeRange(10, _recent.length);
      }
    });
    _save();
  }

  void _place(PadButton b) {
    final n = _buttons.length;
    setState(() => _buttons.add(b.copyWith(
          x: 0.78,
          y: (0.28 + 0.12 * n).clamp(0.12, 0.88),
        )));
    _save();
  }

  Widget _editor() {
    return PadEditor(
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
      recent: [
        for (final name in _recent)
          if (PadAppAction.values.any((a) => a.name == name))
            PadAppAction.values.firstWhere((a) => a.name == name),
      ],
      onQuick: (action) {
        _remember(action);
        widget.onPress?.call(PadButton.appAction(action), true);
      },
    );
  }

  bool get _largeScreen => MediaQuery.sizeOf(context).shortestSide >= 600;

  void _dismissPanel(BuildContext ctx) {
    final opened = _panelOpenedAt;
    final age = opened == null
        ? -1
        : DateTime.now().difference(opened).inMilliseconds;
    // The tap that opens the panel can arrive again on the scrim a moment
    // later and close it. Ignore that. A real tap outside still closes it.
    if (age >= 0 && age < 800) {
      _padLog('scrim ignored age=$age');
      return;
    }
    _padLog('scrim dismiss age=$age');
    Navigator.of(ctx).pop();
  }

  Future<void> _openEditor() async {
    final mq = MediaQuery.of(context);
    _panelOpen = true;
    _panelOpenedAt = DateTime.now();
    _padLog(
        'open large=$_largeScreen size=${mq.size} insets=${mq.viewInsets} padding=${mq.padding}');
    try {
      if (_largeScreen) {
        final height = mq.size.height;
        await showGeneralDialog<void>(
          context: context,
          barrierDismissible: false,
          barrierLabel:
              MaterialLocalizations.of(context).modalBarrierDismissLabel,
          barrierColor: Colors.black54,
          pageBuilder: (ctx, _, __) => _PanelTrace(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _dismissPanel(ctx),
                  ),
                ),
                Center(
                  child: Dialog(
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 520,
                        maxHeight: height * 0.7,
                      ),
                      child: _editor(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        // A size change while the sheet is opening was being read as a drag
        // and closing it.
        enableDrag: false,
        builder: (ctx) => _PanelTrace(child: _editor()),
      );
    } finally {
      _panelOpen = false;
      _padLog('closed mounted=$mounted');
    }
  }

  @override
  void deactivate() {
    if (_panelOpen) {
      _padLog('overlay deactivate while panel open\n${StackTrace.current}');
    }
    super.deactivate();
  }

  void _delete(PadButton b) {
    if (b.appAction == PadAppAction.menu) return;
    setState(() => _buttons.removeWhere((e) => e.id == b.id));
    _save();
  }

  Future<void> _showButtonMenu(PadButton b, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(global.dx, global.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final value = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          enabled: false,
          child: Text(_faceLabel(b)),
        ),
        if (b.appAction != PadAppAction.menu)
          PopupMenuItem(value: 'delete', child: Text(_t('Delete'))),
      ],
    );
    if (!mounted || value != 'delete') return;
    _delete(b);
  }

  void _activate(PadButton b) {
    if (b.appAction == PadAppAction.menu) {
      // The tap that opens the sheet can also land on the new barrier and
      // dismiss it. Wait until that gesture has finished.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openEditor();
      });
      return;
    }
    _remember(b.appAction);
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
        onLongPressStart: (d) {
          if (_moved) return;
          _showButtonMenu(b, d.globalPosition);
        },
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

class _PanelTrace extends StatefulWidget {
  final Widget child;

  const _PanelTrace({required this.child});

  @override
  State<_PanelTrace> createState() => _PanelTraceState();
}

class _PanelTraceState extends State<_PanelTrace> {
  @override
  void initState() {
    super.initState();
    _padLog('panel mount');
  }

  @override
  void dispose() {
    _padLog('panel dispose\n${StackTrace.current}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        _padLog('panel pop didPop=$didPop result=$result\n${StackTrace.current}');
      },
      child: widget.child,
    );
  }
}
