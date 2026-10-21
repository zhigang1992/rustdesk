import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';

void main() {
  test('default pad round-trips through JSON with free x/y', () {
    final decoded = PadConfig.tryDecode(PadConfig.defaults().encode());
    expect(decoded, isNotNull);
    expect(decoded!.version, kControlPadVersion);
    expect(decoded.buttons.map((b) => b.appAction), [
      PadAppAction.menu,
      PadAppAction.sendText,
      PadAppAction.keyboard,
    ]);
    expect(decoded.buttons.every((b) => b.x == 0.92), isTrue);
    expect(decoded.buttons.map((b) => b.icon), [
      'tune',
      'keyboard_voice',
      'keyboard',
    ]);
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

  test('withMenu inserts the editor button without moving the others', () {
    final cfg = PadConfig(buttons: [
      PadButton.appAction(PadAppAction.keyboard, x: 0.2, y: 0.3),
    ]).withMenu();
    expect(cfg.buttons.first.appAction, PadAppAction.menu);
    expect(cfg.buttons.last.x, 0.2);
    expect(cfg.withMenu().buttons.length, 2);
  });
}
