import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';

import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';

bool _keystrokePromptOpen = false;

String sendTextAsKeystrokesShortcutLabel() {
  return isMacOS ? '⌘⇧K' : 'Ctrl+Shift+K';
}

String sendTextAsKeystrokesSubmitLabel() {
  return isMacOS ? '⌘↩' : 'Ctrl+Enter';
}

/// Host text box, then send the result as remote keystrokes.
Future<void> promptAndSendKeystrokes({
  required SessionID sessionId,
  required OverlayDialogManager dialogManager,
}) async {
  if (_keystrokePromptOpen) return;
  _keystrokePromptOpen = true;
  try {
    final text = await _promptKeystrokeText(dialogManager);
    if (text == null) return;
    final value = text.trimRight();
    if (value.isEmpty) return;
    bind.sessionInputString(sessionId: sessionId, value: value);
  } finally {
    _keystrokePromptOpen = false;
  }
}

Future<String?> _promptKeystrokeText(OverlayDialogManager dialogManager) async {
  final title = translate('Send text as keystrokes');
  final send = translate('Send');
  final cancel = translate('Cancel');
  final hint = isMobile
      ? translate('send-text-as-keystrokes-mobile-tip')
      : translate('send-text-as-keystrokes-tip')
          .replaceAll('{}', sendTextAsKeystrokesSubmitLabel());

  if (isMacOS) {
    try {
      return await RdPlatformChannel.instance.showKeystrokeInput(
        title: title,
        send: send,
        cancel: cancel,
        hint: hint,
      );
    } catch (e) {
      debugPrint('Native keystroke input unavailable: $e');
    }
  }

  return dialogManager.show<String>((setState, close, context) {
    final controller = TextEditingController();
    void submit() => close(controller.text);
    return CustomAlertDialog(
      title: Text(title),
      content: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter;
          final mod = isMacOS
              ? HardwareKeyboard.instance.isMetaPressed
              : HardwareKeyboard.instance.isControlPressed;
          if (isEnter && mod) {
            submit();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(hintText: hint),
        ),
      ),
      actions: [
        dialogButton('Cancel', onPressed: () => close(null), isOutline: true),
        dialogButton('Send', onPressed: submit),
      ],
      onCancel: () => close(null),
    );
  }, clickMaskDismiss: false, backDismiss: true);
}
