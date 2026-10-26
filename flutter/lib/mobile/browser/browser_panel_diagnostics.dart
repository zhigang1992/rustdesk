import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const browserPanelDiagnosticsEnabled =
    bool.fromEnvironment('BROWSER_PANEL_DIAGNOSTICS') && !kIsWeb;

void browserPanelTrace(String event, {bool stack = false}) {
  if (!browserPanelDiagnosticsEnabled) return;
  try {
    File('${Directory.systemTemp.path}/rustdesk-browser-panels.log')
        .writeAsStringSync(
            '${DateTime.now().toUtc().toIso8601String()} $event\n'
            '${stack ? '${StackTrace.current}\n' : ''}',
            mode: FileMode.append,
            flush: true);
  } catch (error) {
    debugPrint('Browser panel diagnostic write failed: $error');
  }
}

final browserPanelNavigatorObserver = BrowserPanelNavigatorObserver();

class BrowserPanelNavigatorObserver extends NavigatorObserver
    with WidgetsBindingObserver {
  void start() {
    browserPanelTrace('diagnostic start pid=$pid');
    WidgetsBinding.instance.addObserver(this);
  }

  String _route(Route<dynamic>? route) => route == null
      ? 'null'
      : '${route.runtimeType}#${identityHashCode(route)}';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    browserPanelTrace(
        'navigator push ${_route(route)} previous=${_route(previousRoute)}');
    if (route is PopupRoute<dynamic>) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!route.isActive) return;
        route.addScopedWillPopCallback(() {
          browserPanelTrace('navigator willPop ${_route(route)}', stack: true);
          return Future.value(true);
        });
      });
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    browserPanelTrace(
        'navigator pop ${_route(route)} previous=${_route(previousRoute)}',
        stack: true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    browserPanelTrace(
        'navigator remove ${_route(route)} previous=${_route(previousRoute)}',
        stack: true);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    browserPanelTrace(
        'navigator replace ${_route(oldRoute)} new=${_route(newRoute)}',
        stack: true);
  }

  @override
  void didStartUserGesture(
      Route<dynamic> route, Route<dynamic>? previousRoute) {
    browserPanelTrace('navigator gesture ${_route(route)}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    browserPanelTrace('lifecycle ${state.name}');
  }

  @override
  void didChangeMetrics() {
    browserPanelTrace('metrics changed');
  }

  @override
  Future<bool> didPopRoute() {
    browserPanelTrace('platform didPopRoute', stack: true);
    return Future.value(false);
  }
}
