import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/common.dart';

enum SystemWindowTheme { light, dark }

/// The platform channel for RustDesk.
class RdPlatformChannel {
  RdPlatformChannel._();

  static final RdPlatformChannel _windowUtil = RdPlatformChannel._();

  static RdPlatformChannel get instance => _windowUtil;

  final MethodChannel _hostMethodChannel =
      MethodChannel("org.rustdesk.rustdesk/host");

  /// Bump the position of the mouse cursor, if applicable
  Future<bool> bumpMouse({required int dx, required int dy}) async {
    // No debug output; this call is too chatty.

    bool? result = await _hostMethodChannel
      .invokeMethod("bumpMouse", {"dx": dx, "dy": dy});

    return result ?? false;
  }

  /// Change the theme of the system window
  Future<void> changeSystemWindowTheme(SystemWindowTheme theme) {
    assert(isMacOS);
    if (kDebugMode) {
      print(
          "[Window ${kWindowId ?? 'Main'}] change system window theme to ${theme.name}");
    }
    return _hostMethodChannel
        .invokeMethod("setWindowTheme", {"themeName": theme.name});
  }

  /// Terminate .app manually.
  Future<void> terminate() {
    assert(isMacOS);
    return _hostMethodChannel.invokeMethod("terminate");
  }

  /// Native macOS text box so dictation / IME stay on the host.
  /// Returns the typed text and append-Enter flag, or null if cancelled.
  Future<({String text, bool appendEnter})?> showKeystrokeInput({
    required String title,
    required String send,
    required String cancel,
    required String hint,
    required String appendEnterLabel,
    required bool appendEnter,
  }) async {
    if (!isMacOS) return null;
    final result = await _hostMethodChannel.invokeMethod(
      "showKeystrokeInput",
      {
        "title": title,
        "send": send,
        "cancel": cancel,
        "hint": hint,
        "appendEnterLabel": appendEnterLabel,
        "appendEnter": appendEnter,
      },
    );
    if (result is! Map) return null;
    final text = result['text'];
    if (text is! String) return null;
    return (text: text, appendEnter: result['appendEnter'] == true);
  }
}
