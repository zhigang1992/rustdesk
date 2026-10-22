import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';

void main() {
  test('default pad round-trips through JSON with free x/y', () {
    final decoded = PadConfig.tryDecode(PadConfig.defaults().encode());
    expect(decoded, isNotNull);
    expect(decoded!.version, kControlPadVersion);
    expect(decoded.buttons.map((b) => b.appAction), [
      PadAppAction.toggleTouchMode,
      PadAppAction.menu,
      PadAppAction.sendText,
      PadAppAction.keyboard,
    ]);
    expect(decoded.buttons.every((b) => b.x == 0.92), isTrue);
    expect(decoded.buttons.map((b) => b.icon), [
      'mouse',
      'tune',
      'keyboard_voice',
      'keyboard',
    ]);
    expect(decoded.buttons.first.iconOn, 'touch_app');
    final twoFinger = PadButton.appAction(PadAppAction.toggleTwoFinger);
    expect(twoFinger.icon, 'pinch');
    expect(twoFinger.iconOn, 'mouse');
    expect(padAppActionIsToggle(PadAppAction.toggleTwoFinger), isTrue);
    expect(padAppActionIsToggle(PadAppAction.toggleTouchMode), isTrue);
    expect(padAppActionIsToggle(PadAppAction.resetCanvas), isFalse);
  });

  test('migrates legacy edge/along configs to x/y', () {
    const legacy = '{"version":1,"buttons":[{"id":"a","actionKind":"combo",'
        '"payload":"ctrl+alt+delete","label":"CAD","edge":"bottom",'
        '"along":0.2,"inset":8}]}';
    final back = PadConfig.tryDecode(legacy)!;
    expect(back.version, 1);
    expect(back.buttons.single.y, closeTo(0.92, 0.001));
    expect(back.buttons.single.x, closeTo(0.2, 0.001));
    expect(back.buttons.single.comboParts, ['ctrl', 'alt', 'delete']);
    expect(PadConfig.tryDecode('not json'), isNull);
    expect(PadConfig.tryDecode(''), isNull);
  });

  test('a version 3 pad gains the touch toggle without moving the others', () {
    final next = PadConfig(version: 3, buttons: [
      PadButton.appAction(PadAppAction.keyboard, x: 0.2, y: 0.3),
    ]).withTouchToggle();
    expect(next.version, kControlPadVersion);
    expect(next.buttons.first.appAction, PadAppAction.toggleTouchMode);
    expect(next.buttons.last.x, 0.2);
    expect(next.withTouchToggle().buttons.length, 2);
  });

  test('withMenu inserts the editor button without moving the others', () {
    final cfg = PadConfig(buttons: [
      PadButton.appAction(PadAppAction.keyboard, x: 0.2, y: 0.3),
    ]).withMenu();
    expect(cfg.buttons.first.appAction, PadAppAction.menu);
    expect(cfg.buttons.last.x, 0.2);
    expect(cfg.withMenu().buttons.length, 2);
  });
}
