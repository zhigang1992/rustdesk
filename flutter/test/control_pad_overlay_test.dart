import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/control_pad.dart';
import 'package:flutter_hbb/models/control_pad_model.dart';

Widget _host(List<PadButton> buttons, void Function(PadButton, bool) onPress) {
  return MaterialApp(
    home: Scaffold(
      body: ControlPadOverlay(
        persist: false,
        strings: (s) => s,
        initialButtons: buttons,
        onPress: onPress,
      ),
    ),
  );
}

void main() {
  testWidgets('dragging a button moves it and does not fire the action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    PadButton? pressed;
    await tester.pumpWidget(_host(
      [
        PadButton.appAction(PadAppAction.sendText, x: 0.5, y: 0.5),
      ],
      (b, down) => pressed = b,
    ));
    await tester.pump();

    final icon = find.byIcon(Icons.keyboard_voice);
    final before = tester.getCenter(icon);
    await tester.drag(icon, const Offset(-100, 40));
    await tester.pump();
    final after = tester.getCenter(icon);

    expect(after.dx, lessThan(before.dx - 50));
    expect(after.dy, greaterThan(before.dy + 20));
    expect(pressed, isNull);
  });

  testWidgets('tap runs the action and menu opens the editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    PadButton? pressed;
    await tester.pumpWidget(_host(
      [
        PadButton.appAction(PadAppAction.sendText, x: 0.5, y: 0.5),
        PadButton.appAction(PadAppAction.menu, x: 0.9, y: 0.2),
      ],
      (b, down) => pressed = b,
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.keyboard_voice));
    await tester.pump();
    expect(pressed?.appAction, PadAppAction.sendText);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Send text as keystrokes'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Key'), findsOneWidget);
    expect(pressed?.appAction, PadAppAction.sendText);
  });

  testWidgets('a toggle button shows its on icon while the setting is on',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ControlPadOverlay(
          persist: false,
          strings: (s) => s,
          isOn: (_) => true,
          initialButtons: [
            PadButton.appAction(PadAppAction.toggleTwoFinger, x: 0.5, y: 0.5),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.mouse), findsOneWidget);
    expect(find.byIcon(Icons.pinch), findsNothing);
  });
}
