import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';

import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';

/// Per-peer: after typing text as keystrokes, also press Enter on the remote.
const String kPeerOptionAllowSendEnterAfterKeystrokes =
    'allow-send-enter-after-keystrokes';

bool _keystrokePromptOpen = false;

String sendTextAsKeystrokesShortcutLabel() {
  return isMacOS ? '⌘⇧K' : 'Ctrl+Shift+K';
}

class _KeystrokePromptResult {
  final String text;
  final bool appendEnter;

  const _KeystrokePromptResult({required this.text, required this.appendEnter});
}

/// Host text box, then send the result as remote keystrokes.
Future<void> promptAndSendKeystrokes({
  required String peerId,
  required FFI ffi,
}) async {
  if (_keystrokePromptOpen) return;
  _keystrokePromptOpen = true;
  try {
    final result = await _promptKeystrokeText(peerId, ffi.dialogManager);
    if (result == null) return;
    _setAppendEnter(peerId, result.appendEnter);
    final value = result.text.trimRight();
    if (value.isEmpty) return;
    await bind.sessionInputString(sessionId: ffi.sessionId, value: value);
    if (result.appendEnter) {
      ffi.inputModel.inputKey('VK_ENTER');
    }
  } finally {
    _keystrokePromptOpen = false;
  }
}

bool _getAppendEnter(String peerId) {
  return mainGetPeerBoolOptionSync(
      peerId, kPeerOptionAllowSendEnterAfterKeystrokes);
}

void _setAppendEnter(String peerId, bool value) {
  bind.mainSetPeerOptionSync(
    id: peerId,
    key: kPeerOptionAllowSendEnterAfterKeystrokes,
    value: bool2option(kPeerOptionAllowSendEnterAfterKeystrokes, value),
  );
}

Future<_KeystrokePromptResult?> _promptKeystrokeText(
  String peerId,
  OverlayDialogManager dialogManager,
) async {
  final title = translate('Send text as keystrokes');
  final send = translate('Send');
  final cancel = translate('Cancel');
  final appendEnterLabel = translate('Also send Enter key');
  final hint = isMobile
      ? translate('send-text-as-keystrokes-mobile-tip')
      : translate('send-text-as-keystrokes-tip');
  final appendEnter = _getAppendEnter(peerId);

  if (isMacOS) {
    try {
      final native = await RdPlatformChannel.instance.showKeystrokeInput(
        title: title,
        send: send,
        cancel: cancel,
        hint: hint,
        appendEnterLabel: appendEnterLabel,
        appendEnter: appendEnter,
      );
      if (native == null) return null;
      return _KeystrokePromptResult(
        text: native.text,
        appendEnter: native.appendEnter,
      );
    } catch (e) {
      debugPrint('Native keystroke input unavailable: $e');
    }
  }

  return dialogManager.show<_KeystrokePromptResult>((setState, close, context) {
    final controller = TextEditingController();
    var appendEnterValue = appendEnter;
    void submit() => close(_KeystrokePromptResult(
          text: controller.text,
          appendEnter: appendEnterValue,
        ));
    return CustomAlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 1,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(hintText: hint),
          ),
          CheckboxListTile(
            contentPadding: const EdgeInsets.all(0),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(appendEnterLabel),
            value: appendEnterValue,
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                appendEnterValue = v;
                _setAppendEnter(peerId, v);
              });
            },
          ),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: () => close(null), isOutline: true),
        dialogButton('Send', onPressed: submit),
      ],
      onCancel: () => close(null),
    );
  }, clickMaskDismiss: false, backDismiss: true);
}
