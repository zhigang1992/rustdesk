import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

PadConfig loadControlPad() {
  final decoded =
      PadConfig.tryDecode(bind.getLocalFlutterOption(k: kOptionControlPad));
  // v1 was edge-snapped text chips; reset those to the FAB stack.
  // v3 gains the mouse/touch toggle without moving the buttons already placed.
  if (decoded == null || decoded.version < 3) {
    return PadConfig.defaults();
  }
  final cfg = decoded.withMenu();
  if (decoded.version < kControlPadVersion) {
    final next = cfg.withTouchToggle();
    if (next.version >= kControlPadVersion) return next;
    return PadConfig(version: kControlPadVersion, buttons: next.buttons);
  }
  return cfg;
}

Future<void> saveControlPad(PadConfig config) =>
    bind.setLocalFlutterOption(k: kOptionControlPad, v: config.encode());

Future<PadConfig> resetControlPadDefault() async {
  final config = PadConfig.defaults();
  await saveControlPad(config);
  return config;
}

TwoFingerMode getTwoFingerMode() => enumByName(TwoFingerMode.values,
    bind.getLocalFlutterOption(k: kOptionTwoFingerMode), TwoFingerMode.canvas);

Future<void> setTwoFingerMode(TwoFingerMode mode) =>
    bind.setLocalFlutterOption(k: kOptionTwoFingerMode, v: mode.name);
