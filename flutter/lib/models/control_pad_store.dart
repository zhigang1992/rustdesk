import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

PadConfig loadControlPad() {
  final decoded =
      PadConfig.tryDecode(bind.getLocalFlutterOption(k: kOptionControlPad));
  // v1 was edge-snapped text chips; reset to the FAB stack defaults on bump.
  if (decoded == null || decoded.version < kControlPadVersion) {
    return PadConfig.defaults();
  }
  return decoded.withMenu();
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
