import 'dart:convert';

enum PadActionKind { appAction, key, combo }

enum PadAppAction {
  menu,
  sendText,
  keyboard,
  toggleTwoFinger,
  gestureHelp,
  chat,
  displays,
  disconnect,
  more,
  resetCanvas,
  sendClipboard,
  refresh,
  ctrlAltDel,
  lock,
  osPassword,
  elevation,
  fingerprint,
  blockInput,
  recording,
  showRemoteCursor,
  mute,
  privacyMode,
  lockCanvas,
}

enum PadFace { icon, text }

/// Legacy edge enum kept only so v1 configs can migrate to free x/y.
enum PadEdge { left, right, top, bottom }

enum TwoFingerMode { canvas, rightDrag }

const int kControlPadVersion = 3;

T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

double _clamp01(num v) => v.clamp(0.0, 1.0).toDouble();

class PadButton {
  final String id;
  final PadActionKind actionKind;

  /// appAction: [PadAppAction] name; key: logical key name;
  /// combo: modifiers followed by the key, joined with '+' (e.g. "ctrl+alt+delete").
  final String payload;
  final String? label;
  final String? icon;

  /// Shown while a toggle action is on. Ignored for one-shot actions.
  final String? labelOn;
  final String? iconOn;
  final PadFace face;

  /// Center X as a fraction of the canvas width (0..1).
  final double x;

  /// Center Y as a fraction of the canvas height (0..1).
  final double y;

  const PadButton({
    required this.id,
    required this.actionKind,
    required this.payload,
    this.label,
    this.icon,
    this.labelOn,
    this.iconOn,
    this.face = PadFace.icon,
    this.x = 0.92,
    this.y = 0.5,
  });

  factory PadButton.appAction(
    PadAppAction action, {
    String? id,
    String? label,
    String? icon,
    String? labelOn,
    String? iconOn,
    PadFace face = PadFace.icon,
    double x = 0.92,
    double y = 0.5,
  }) =>
      PadButton(
        id: id ?? action.name,
        actionKind: PadActionKind.appAction,
        payload: action.name,
        label: label,
        icon: icon ?? padAppActionIcon(action),
        labelOn: labelOn,
        iconOn: iconOn ?? padAppActionIconOn(action),
        face: face,
        x: _clamp01(x),
        y: _clamp01(y),
      );

  PadAppAction? get appAction => actionKind == PadActionKind.appAction
      ? PadAppAction.values.where((a) => a.name == payload).firstOrNull
      : null;

  List<String> get comboParts => payload.split('+');

  PadButton copyWith({
    String? label,
    String? icon,
    String? labelOn,
    String? iconOn,
    PadFace? face,
    double? x,
    double? y,
  }) =>
      PadButton(
        id: id,
        actionKind: actionKind,
        payload: payload,
        label: label ?? this.label,
        icon: icon ?? this.icon,
        labelOn: labelOn ?? this.labelOn,
        iconOn: iconOn ?? this.iconOn,
        face: face ?? this.face,
        x: x == null ? this.x : _clamp01(x),
        y: y == null ? this.y : _clamp01(y),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'actionKind': actionKind.name,
        'payload': payload,
        if (label != null) 'label': label,
        if (icon != null) 'icon': icon,
        if (labelOn != null) 'labelOn': labelOn,
        if (iconOn != null) 'iconOn': iconOn,
        if (face != PadFace.icon) 'face': face.name,
        'x': x,
        'y': y,
      };

  static PadButton? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final payload = json['payload'];
    if (id is! String || payload is! String) return null;
    final kind = json['actionKind'];
    if (!PadActionKind.values.any((k) => k.name == kind)) return null;

    final xy = _xyFromJson(json);
    return PadButton(
      id: id,
      actionKind: enumByName(PadActionKind.values, kind, PadActionKind.key),
      payload: payload,
      label: json['label'] is String ? json['label'] : null,
      icon: json['icon'] is String ? json['icon'] : null,
      labelOn: json['labelOn'] is String ? json['labelOn'] : null,
      iconOn: json['iconOn'] is String ? json['iconOn'] : null,
      face: enumByName(PadFace.values, json['face'], PadFace.icon),
      x: xy.$1,
      y: xy.$2,
    );
  }

  /// Prefer free x/y; migrate legacy edge/along/inset configs.
  static (double, double) _xyFromJson(Map json) {
    final x = json['x'];
    final y = json['y'];
    if (x is num && y is num) return (_clamp01(x), _clamp01(y));

    final edge = enumByName(PadEdge.values, json['edge'], PadEdge.right);
    final along = json['along'] is num ? _clamp01(json['along'] as num) : 0.5;
    // Fixed margin so v1 edge configs migrate without needing canvas size.
    const margin = 0.08;
    switch (edge) {
      case PadEdge.left:
        return (margin, along);
      case PadEdge.right:
        return (1.0 - margin, along);
      case PadEdge.top:
        return (along, margin);
      case PadEdge.bottom:
        return (along, 1.0 - margin);
    }
  }
}

String padAppActionLabel(PadAppAction a) {
  switch (a) {
    case PadAppAction.menu:
      return 'Menu';
    case PadAppAction.sendText:
      return 'Send text as keystrokes';
    case PadAppAction.keyboard:
      return 'Keyboard';
    case PadAppAction.toggleTwoFinger:
      return 'Two-finger mode';
    case PadAppAction.gestureHelp:
      return 'Touch mode';
    case PadAppAction.chat:
      return 'Text chat';
    case PadAppAction.displays:
      return 'Display';
    case PadAppAction.disconnect:
      return 'Disconnect';
    case PadAppAction.more:
      return 'More';
    case PadAppAction.resetCanvas:
      return 'Reset canvas';
    case PadAppAction.sendClipboard:
      return 'Send clipboard keystrokes';
    case PadAppAction.refresh:
      return 'Refresh';
    case PadAppAction.ctrlAltDel:
      return 'Insert Ctrl + Alt + Del';
    case PadAppAction.lock:
      return 'Insert Lock';
    case PadAppAction.osPassword:
      return 'OS Password';
    case PadAppAction.elevation:
      return 'Request Elevation';
    case PadAppAction.fingerprint:
      return 'Copy Fingerprint';
    case PadAppAction.blockInput:
      return 'Block user input';
    case PadAppAction.recording:
      return 'Start session recording';
    case PadAppAction.showRemoteCursor:
      return 'Show remote cursor';
    case PadAppAction.mute:
      return 'Mute';
    case PadAppAction.privacyMode:
      return 'Privacy mode';
    case PadAppAction.lockCanvas:
      return 'Lock canvas';
  }
}

bool padAppActionIsToggle(PadAppAction a) {
  switch (a) {
    case PadAppAction.toggleTwoFinger:
    case PadAppAction.blockInput:
    case PadAppAction.recording:
    case PadAppAction.showRemoteCursor:
    case PadAppAction.mute:
    case PadAppAction.privacyMode:
    case PadAppAction.lockCanvas:
      return true;
    default:
      return false;
  }
}

String padAppActionIcon(PadAppAction a) {
  switch (a) {
    case PadAppAction.menu:
      return 'tune';
    case PadAppAction.sendText:
      return 'keyboard_voice';
    case PadAppAction.keyboard:
      return 'keyboard';
    case PadAppAction.toggleTwoFinger:
      return 'pinch';
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
    case PadAppAction.resetCanvas:
      return 'fit_screen';
    case PadAppAction.sendClipboard:
      return 'content_paste';
    case PadAppAction.refresh:
      return 'refresh';
    case PadAppAction.ctrlAltDel:
      return 'keyboard';
    case PadAppAction.lock:
      return 'lock';
    case PadAppAction.osPassword:
      return 'password';
    case PadAppAction.elevation:
      return 'security';
    case PadAppAction.fingerprint:
      return 'fingerprint';
    case PadAppAction.blockInput:
      return 'back_hand';
    case PadAppAction.recording:
      return 'videocam';
    case PadAppAction.showRemoteCursor:
      return 'mouse';
    case PadAppAction.mute:
      return 'volume_up';
    case PadAppAction.privacyMode:
      return 'visibility';
    case PadAppAction.lockCanvas:
      return 'lock_open';
  }
}

String? padAppActionIconOn(PadAppAction a) {
  switch (a) {
    case PadAppAction.toggleTwoFinger:
      return 'mouse';
    case PadAppAction.blockInput:
      return 'front_hand';
    case PadAppAction.recording:
      return 'pause';
    case PadAppAction.showRemoteCursor:
      return 'highlight_mouse';
    case PadAppAction.mute:
      return 'volume_off';
    case PadAppAction.privacyMode:
      return 'visibility_off';
    case PadAppAction.lockCanvas:
      return 'lock';
    default:
      return null;
  }
}

class PadConfig {
  final int version;
  final List<PadButton> buttons;

  const PadConfig({this.version = kControlPadVersion, required this.buttons});

  /// Menu stays so shortcuts can be edited. The other two match the
  /// actions people used the voice button and the keyboard key for.
  factory PadConfig.defaults() => PadConfig(buttons: [
        PadButton.appAction(PadAppAction.menu, x: 0.92, y: 0.50),
        PadButton.appAction(PadAppAction.sendText, x: 0.92, y: 0.64),
        PadButton.appAction(PadAppAction.keyboard, x: 0.92, y: 0.78),
      ]);

  PadConfig withMenu() {
    if (buttons.any((b) => b.appAction == PadAppAction.menu)) return this;
    return PadConfig(
      version: version,
      buttons: [
        PadButton.appAction(PadAppAction.menu, x: 0.92, y: 0.50),
        ...buttons,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'buttons': buttons.map((b) => b.toJson()).toList(),
      };

  /// Returns null when [json] is not a usable config.
  static PadConfig? tryFromJson(Object? json) {
    if (json is! Map || json['buttons'] is! List) return null;
    final version = json['version'];
    return PadConfig(
      version: version is int ? version : kControlPadVersion,
      buttons: (json['buttons'] as List)
          .map(PadButton.tryFromJson)
          .whereType<PadButton>()
          .toList(),
    );
  }

  String encode() => jsonEncode(toJson());

  static PadConfig? tryDecode(String s) {
    if (s.isEmpty) return null;
    try {
      return tryFromJson(jsonDecode(s));
    } on FormatException {
      return null;
    }
  }
}
