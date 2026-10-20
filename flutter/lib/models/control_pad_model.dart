import 'dart:convert';

enum PadActionKind { appAction, key, combo }

enum PadAppAction { menu, sendText, toggleTwoFinger, keyboard }

enum PadEdge { left, right, top, bottom }

enum TwoFingerMode { canvas, rightDrag }

const int kControlPadVersion = 1;

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
  final PadEdge edge;
  final double along;
  final double inset;

  const PadButton({
    required this.id,
    required this.actionKind,
    required this.payload,
    this.label,
    this.icon,
    this.edge = PadEdge.right,
    this.along = 0.5,
    this.inset = 0,
  });

  factory PadButton.appAction(
    PadAppAction action, {
    String? id,
    PadEdge edge = PadEdge.right,
    double along = 0.5,
    double inset = 0,
  }) =>
      PadButton(
        id: id ?? action.name,
        actionKind: PadActionKind.appAction,
        payload: action.name,
        edge: edge,
        along: _clamp01(along),
        inset: inset,
      );

  PadAppAction? get appAction => actionKind == PadActionKind.appAction
      ? PadAppAction.values.where((a) => a.name == payload).firstOrNull
      : null;

  List<String> get comboParts => payload.split('+');

  PadButton copyWith({PadEdge? edge, double? along, double? inset}) =>
      PadButton(
        id: id,
        actionKind: actionKind,
        payload: payload,
        label: label,
        icon: icon,
        edge: edge ?? this.edge,
        along: along == null ? this.along : _clamp01(along),
        inset: inset ?? this.inset,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'actionKind': actionKind.name,
        'payload': payload,
        if (label != null) 'label': label,
        if (icon != null) 'icon': icon,
        'edge': edge.name,
        'along': along,
        'inset': inset,
      };

  static PadButton? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final payload = json['payload'];
    if (id is! String || payload is! String) return null;
    final kind = json['actionKind'];
    if (!PadActionKind.values.any((k) => k.name == kind)) return null;
    final along = json['along'];
    final inset = json['inset'];
    return PadButton(
      id: id,
      actionKind: enumByName(PadActionKind.values, kind, PadActionKind.key),
      payload: payload,
      label: json['label'] is String ? json['label'] : null,
      icon: json['icon'] is String ? json['icon'] : null,
      edge: enumByName(PadEdge.values, json['edge'], PadEdge.right),
      along: along is num ? _clamp01(along) : 0.5,
      inset: inset is num ? inset.toDouble() : 0,
    );
  }
}

class PadConfig {
  final int version;
  final List<PadButton> buttons;

  const PadConfig({this.version = kControlPadVersion, required this.buttons});

  factory PadConfig.defaults() => PadConfig(buttons: [
        PadButton.appAction(PadAppAction.menu, along: 0.3),
        PadButton.appAction(PadAppAction.sendText, along: 0.5),
        PadButton.appAction(PadAppAction.toggleTwoFinger, along: 0.7),
      ]);

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
