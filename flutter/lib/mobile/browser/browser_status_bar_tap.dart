import 'package:flutter/gestures.dart';

bool rejectBrowserPanelStatusBarTap(PointerEvent event) {
  if (event is! PointerDownEvent ||
      event.kind != PointerDeviceKind.touch ||
      event.device != 0 ||
      event.position != Offset.zero) return false;
  // Flutter 3.24 turns iOS scroll-to-top requests into device-0 taps at (0, 0).
  // iPadOS can send these after a toolbar tap, hitting a new modal's barrier.
  GestureBinding.instance.gestureArena
      .add(event.pointer, const _StatusBarTap())
      .resolve(GestureDisposition.accepted);
  return true;
}

class _StatusBarTap implements GestureArenaMember {
  const _StatusBarTap();

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {}
}
