import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';

const List<String> kPadIconNames = [
  'tune',
  'keyboard_voice',
  'keyboard',
  'pinch',
  'mouse',
  'touch_app',
  'gesture',
  'message',
  'tv',
  'close',
  'more_vert',
  'fit_screen',
  'content_paste',
  'refresh',
  'lock',
  'lock_open',
  'password',
  'security',
  'fingerprint',
  'back_hand',
  'front_hand',
  'videocam',
  'pause',
  'highlight_mouse',
  'volume_up',
  'volume_off',
  'visibility',
  'visibility_off',
];

IconData padIconData(String name) {
  switch (name) {
    case 'tune':
      return Icons.tune;
    case 'keyboard_voice':
      return Icons.keyboard_voice;
    case 'keyboard':
      return Icons.keyboard;
    case 'pinch':
      return Icons.pinch;
    case 'mouse':
      return Icons.mouse;
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
    case 'fit_screen':
      return Icons.fit_screen;
    case 'content_paste':
      return Icons.content_paste;
    case 'refresh':
      return Icons.refresh;
    case 'lock':
      return Icons.lock;
    case 'lock_open':
      return Icons.lock_open;
    case 'password':
      return Icons.password;
    case 'security':
      return Icons.security;
    case 'fingerprint':
      return Icons.fingerprint;
    case 'back_hand':
      return Icons.back_hand;
    case 'front_hand':
      return Icons.front_hand;
    case 'videocam':
      return Icons.videocam;
    case 'pause':
      return Icons.pause;
    case 'highlight_mouse':
      return Icons.highlight_alt;
    case 'volume_up':
      return Icons.volume_up;
    case 'volume_off':
      return Icons.volume_off;
    case 'visibility':
      return Icons.visibility;
    case 'visibility_off':
      return Icons.visibility_off;
    default:
      return Icons.circle;
  }
}

enum _Step { home, kind, action, keystroke, face }

class PadEditor extends StatefulWidget {
  final List<PadButton> buttons;
  final String Function(String key) labelOf;
  final void Function(PadButton button) onAdd;
  final void Function(PadButton button) onRemove;
  final void Function(PadButton button) onUpdate;
  final void Function(PadAppAction action)? onQuick;

  /// Newest first. Shown above the grouped actions.
  final List<PadAppAction> recent;

  const PadEditor({
    Key? key,
    required this.buttons,
    required this.labelOf,
    required this.onAdd,
    required this.onRemove,
    required this.onUpdate,
    this.onQuick,
    this.recent = const [],
  }) : super(key: key);

  @override
  State<PadEditor> createState() => _PadEditorState();
}

class _PadEditorState extends State<PadEditor> {
  late final List<PadButton> _buttons = List<PadButton>.from(widget.buttons);
  _Step _step = _Step.home;
  PadButton? _draft;
  bool _editing = false;
  final _keyCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _textOnCtrl = TextEditingController();
  final _mods = <String>{};
  String _icon = 'keyboard';
  String _iconOn = 'mouse';

  static const _groups = <String, List<PadAppAction>>{
    'Canvas': [
      PadAppAction.resetCanvas,
      PadAppAction.lockCanvas,
      PadAppAction.toggleTwoFinger,
      PadAppAction.displays,
      PadAppAction.gestureHelp,
    ],
    'Input': [
      PadAppAction.sendText,
      PadAppAction.sendClipboard,
      PadAppAction.keyboard,
      PadAppAction.toggleTouchMode,
      PadAppAction.ctrlAltDel,
      PadAppAction.lock,
      PadAppAction.osPassword,
    ],
    'Session': [
      PadAppAction.disconnect,
      PadAppAction.chat,
      PadAppAction.refresh,
      PadAppAction.more,
      PadAppAction.elevation,
      PadAppAction.fingerprint,
      PadAppAction.blockInput,
      PadAppAction.recording,
      PadAppAction.showRemoteCursor,
      PadAppAction.mute,
      PadAppAction.privacyMode,
    ],
  };

  @override
  void dispose() {
    _keyCtrl.dispose();
    _textCtrl.dispose();
    _textOnCtrl.dispose();
    super.dispose();
  }

  String _title(PadButton b) {
    if (b.face == PadFace.text && b.label != null && b.label!.isNotEmpty) {
      return b.label!;
    }
    final action = b.appAction;
    if (action != null) return widget.labelOf(padAppActionLabel(action));
    return b.label ?? b.payload;
  }

  void _startFace(PadButton draft, {required bool editing}) {
    _draft = draft;
    _editing = editing;
    _icon = draft.icon ?? 'keyboard';
    _iconOn = draft.iconOn ?? 'mouse';
    _textCtrl.text = draft.label ?? '';
    _textOnCtrl.text = draft.labelOn ?? '';
    setState(() => _step = _Step.face);
  }

  void _pickAction(PadAppAction action) {
    final base = PadButton.appAction(action);
    final taken = _buttons.any((b) => b.id == base.id);
    _startFace(
      taken
          ? PadButton(
              id: '${action.name}-${DateTime.now().microsecondsSinceEpoch}',
              actionKind: PadActionKind.appAction,
              payload: action.name,
              icon: base.icon,
              iconOn: base.iconOn,
            )
          : base,
      editing: false,
    );
  }

  void _pickKeystroke() {
    final raw = _keyCtrl.text.trim();
    if (raw.isEmpty) return;
    final combo = _mods.isNotEmpty;
    final payload = combo ? '${_mods.join('+')}+$raw' : raw;
    _startFace(
      PadButton(
        id: '${combo ? 'combo' : 'key'}-${DateTime.now().microsecondsSinceEpoch}',
        actionKind: combo ? PadActionKind.combo : PadActionKind.key,
        payload: payload,
        label: payload,
        face: PadFace.text,
      ),
      editing: false,
    );
  }

  void _saveFace() {
    final draft = _draft;
    if (draft == null) return;
    final toggle =
        draft.appAction != null && padAppActionIsToggle(draft.appAction!);
    final face = draft.face;
    final next = PadButton(
      id: draft.id,
      actionKind: draft.actionKind,
      payload: draft.payload,
      label: face == PadFace.text ? _textCtrl.text.trim() : draft.label,
      labelOn: face == PadFace.text && toggle ? _textOnCtrl.text.trim() : null,
      icon: face == PadFace.icon ? _icon : draft.icon,
      iconOn: face == PadFace.icon && toggle ? _iconOn : draft.iconOn,
      face: face,
      x: draft.x,
      y: draft.y,
    );
    if (_editing) {
      final i = _buttons.indexWhere((e) => e.id == next.id);
      if (i >= 0) _buttons[i] = next;
      widget.onUpdate(next);
    } else {
      _buttons.add(next);
      widget.onAdd(next);
    }
    setState(() => _step = _Step.home);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        child: switch (_step) {
          _Step.home => _home(),
          _Step.kind => _kind(),
          _Step.action => _actions(),
          _Step.keystroke => _keystroke(),
          _Step.face => _face(),
        },
      ),
    );
  }

  Widget _home() {
    return ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          title: Text(widget.labelOf('Menu'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(widget.labelOf('Edit shortcuts')),
        ),
        for (final b in _buttons)
          if (b.appAction != PadAppAction.menu)
            ListTile(
              leading: Icon(b.face == PadFace.text
                  ? Icons.text_fields
                  : padIconData(b.icon ?? '')),
              title: Text(_title(b)),
              onTap: () => _startFace(b, editing: true),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() => _buttons.removeWhere((e) => e.id == b.id));
                  widget.onRemove(b);
                },
              ),
            ),
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(widget.labelOf('Add')),
          onTap: () => setState(() => _step = _Step.kind),
        ),
        if (widget.onQuick != null) ..._quickSections(),
      ],
    );
  }

  List<Widget> _quickSections() {
    return [
      if (widget.recent.isNotEmpty)
        ..._quickSection('Recently used', widget.recent),
      for (final group in _groups.entries)
        ..._quickSection(group.key, group.value),
    ];
  }

  List<Widget> _quickSection(String title, List<PadAppAction> actions) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(widget.labelOf(title),
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Wrap(
          children: [for (final action in actions) _quickButton(action)],
        ),
      ),
    ];
  }

  Widget _quickButton(PadAppAction action) {
    final label = widget.labelOf(padAppActionLabel(action));
    return Builder(
      builder: (ctx) => GestureDetector(
        onTap: () {
          Navigator.of(context).pop();
          widget.onQuick!(action);
        },
        onLongPress: () => _showQuickLabel(ctx, label),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(padIconData(padAppActionIcon(action)), size: 22),
        ),
      ),
    );
  }

  void _showQuickLabel(BuildContext ctx, String label) {
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero);
    showMenu<void>(
      context: ctx,
      position: RelativeRect.fromRect(
        origin & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<void>(enabled: false, child: Text(label)),
      ],
    );
  }

  Widget _kind() {
    return ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: BackButton(
              onPressed: () => setState(() => _step = _Step.home)),
          title: Text(widget.labelOf('Add')),
        ),
        ListTile(
          leading: const Icon(Icons.bolt),
          title: Text(widget.labelOf('Action')),
          subtitle: Text(widget.labelOf('Reset canvas')),
          onTap: () => setState(() => _step = _Step.action),
        ),
        ListTile(
          leading: const Icon(Icons.keyboard),
          title: Text(widget.labelOf('Key')),
          subtitle: Text(widget.labelOf('Combo')),
          onTap: () => setState(() => _step = _Step.keystroke),
        ),
      ],
    );
  }

  Widget _actions() {
    return ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: BackButton(
              onPressed: () => setState(() => _step = _Step.kind)),
          title: Text(widget.labelOf('Action')),
        ),
        for (final group in _groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(group.key,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          for (final action in group.value)
            ListTile(
              leading: Icon(padIconData(padAppActionIcon(action))),
              title: Text(widget.labelOf(padAppActionLabel(action))),
              subtitle: padAppActionIsToggle(action)
                  ? Text(widget.labelOf('On'))
                  : null,
              onTap: () => _pickAction(action),
            ),
        ],
      ],
    );
  }

  Widget _keystroke() {
    return ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: BackButton(
              onPressed: () => setState(() => _step = _Step.kind)),
          title: Text(widget.labelOf('Key')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _keyCtrl,
            decoration: const InputDecoration(
              hintText: 'Esc, F5, delete',
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
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
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _pickKeystroke,
            child: Text(widget.labelOf('Next')),
          ),
        ),
      ],
    );
  }

  Widget _face() {
    final draft = _draft;
    final toggle = draft?.appAction != null &&
        padAppActionIsToggle(draft!.appAction!);
    return ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          leading: BackButton(onPressed: () => setState(() {
            _step = _editing ? _Step.home : _Step.kind;
          })),
          title: Text(widget.labelOf('Icon')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<PadFace>(
            segments: [
              ButtonSegment(value: PadFace.icon, label: Text(widget.labelOf('Icon'))),
              ButtonSegment(
                  value: PadFace.text, label: Text(widget.labelOf('Text'))),
            ],
            selected: {draft?.face ?? PadFace.icon},
            onSelectionChanged: (v) {
              setState(() {
                _draft = PadButton(
                  id: draft!.id,
                  actionKind: draft.actionKind,
                  payload: draft.payload,
                  label: draft.label,
                  icon: draft.icon,
                  labelOn: draft.labelOn,
                  iconOn: draft.iconOn,
                  face: v.first,
                  x: draft.x,
                  y: draft.y,
                );
              });
            },
          ),
        ),
        if ((draft?.face ?? PadFace.icon) == PadFace.icon) ...[
          _iconGrid(widget.labelOf(toggle ? 'Off' : 'Icon'), _icon,
              (name) => setState(() => _icon = name)),
          if (toggle)
            _iconGrid(widget.labelOf('On'), _iconOn,
                (name) => setState(() => _iconOn = name)),
        ] else ...[
          _textField(widget.labelOf(toggle ? 'Off' : 'Text'), _textCtrl),
          if (toggle) _textField(widget.labelOf('On'), _textOnCtrl),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextButton(
              onPressed: _saveFace,
              child: Text(widget.labelOf('OK')),
            ),
          ),
        ),
      ],
    );
  }

  Widget _iconGrid(String title, String selected, void Function(String) onPick) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in kPadIconNames)
                InkWell(
                  onTap: () => onPick(name),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor:
                        selected == name ? Colors.blue : Colors.black26,
                    child: Icon(padIconData(name), color: Colors.white, size: 18),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(String title, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: controller,
        maxLength: 4,
        decoration: InputDecoration(labelText: title, isDense: true),
      ),
    );
  }
}
