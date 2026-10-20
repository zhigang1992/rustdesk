import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';

void main() {
  test('default pad round-trips through JSON', () {
    final decoded = PadConfig.tryDecode(PadConfig.defaults().encode());
    expect(decoded, isNotNull);
    expect(decoded!.buttons.map((b) => b.appAction), [
      PadAppAction.menu,
      PadAppAction.sendText,
      PadAppAction.toggleTwoFinger
    ]);
    expect(decoded.buttons.every((b) => b.edge == PadEdge.right), isTrue);
  });

  test('custom edges, combo and bad input', () {
    final cfg = PadConfig(buttons: [
      const PadButton(
          id: 'a',
          actionKind: PadActionKind.combo,
          payload: 'ctrl+alt+delete',
          label: 'CAD',
          edge: PadEdge.bottom,
          along: 0.2,
          inset: 8),
    ]);
    final back = PadConfig.tryDecode(cfg.encode())!;
    expect(back.buttons.single.edge, PadEdge.bottom);
    expect(back.buttons.single.comboParts, ['ctrl', 'alt', 'delete']);
    expect(PadConfig.tryDecode('not json'), isNull);
    expect(PadConfig.tryDecode(''), isNull);
  });
}
