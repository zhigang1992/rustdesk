import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

PadConfig loadControlPad() =>
    PadConfig.tryDecode(bind.getLocalFlutterOption(k: kOptionControlPad)) ??
    PadConfig.defaults();

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
