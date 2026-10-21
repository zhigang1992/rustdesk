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
}

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
    this.x = 0.92,
    this.y = 0.5,
  });

  factory PadButton.appAction(
    PadAppAction action, {
    String? id,
    String? label,
    String? icon,
    double x = 0.92,
    double y = 0.5,
  }) =>
      PadButton(
        id: id ?? action.name,
        actionKind: PadActionKind.appAction,
        payload: action.name,
        label: label,
        icon: icon ?? _defaultIconForAppAction(action),
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
    double? x,
    double? y,
  }) =>
      PadButton(
        id: id,
        actionKind: actionKind,
        payload: payload,
        label: label ?? this.label,
        icon: icon ?? this.icon,
        x: x == null ? this.x : _clamp01(x),
        y: y == null ? this.y : _clamp01(y),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'actionKind': actionKind.name,
        'payload': payload,
        if (label != null) 'label': label,
        if (icon != null) 'icon': icon,
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
  }
}

String _defaultIconForAppAction(PadAppAction a) {
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
