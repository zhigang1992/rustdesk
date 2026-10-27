import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'package:flutter_hbb/models/browser_workspace.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uuid/uuid.dart';

const browserWorkspaceChannel = MethodChannel('rustdesk/remote-browser');
final browserWorkspaces = BrowserWorkspaceController();

class BrowserWorkspaceController extends ChangeNotifier {
  final model = BrowserWorkspaces();
  final connections = <String, BrowserWorkspaceConnection>{};
  final _starting = <String>{};
  Future<void>? _initializing;
  bool dev = false;
  bool enabled = false;
  bool presented = false;
  BrowserDesktopRequest? desktopRequest;
  BrowserDesktopRequest? desktopConfiguration;
  final pendingNavigation = <String, BrowserNavigation>{};
  String? authenticationPeer;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (!isIOS) return;
    try {
      final settings = await browserWorkspaceChannel
          .invokeMapMethod<String, dynamic>('workspaceSettings');
      dev = settings?['dev'] == true;
      enabled = settings?['enabled'] == true;
      final saved = settings?['saved'] as String? ?? '';
      if (saved.isNotEmpty) model.restore(jsonDecode(saved));
      browserWorkspaceChannel.setMethodCallHandler((call) async {
        if (call.method != 'workspaceState') return;
        final args = Map<String, dynamic>.from(call.arguments);
        final peer = args['workspace'] as String;
        final state = Map<String, dynamic>.from(args['state']);
        final workspace =
            model.items.where((item) => item.peer == peer).firstOrNull;
        if (workspace == null) return;
        workspace.applyNative(state);
        if ((state['error'] as String? ?? '').isNotEmpty) {
          connections[peer]?.failed(state['error'] as String);
        }
        if (state['ready'] == true) {
          connections[peer]?.nativeReady = true;
          unawaited(flushNavigation(workspace));
        }
        changed();
      });
    } on MissingPluginException {
      dev = false;
    } catch (error) {
      debugPrint('Could not restore browser workspaces: $error');
    }
  }

  Future<void> optIn(bool value) async {
    await initialize();
    if (!dev) return;
    await browserWorkspaceChannel
        .invokeMethod('workspaceSettings', {'enabled': value});
    enabled = value;
    if (!value) {
      for (final connection in connections.values) {
        await connection.close();
      }
    }
    notifyListeners();
  }

  BrowserWorkspace select(String peer, {String? label, String? url}) {
    peer = peer.replaceAll(' ', '');
    final workspace = model.select(peer, label: label);
    if (url != null) {
      workspace.desktopSelected = false;
      pendingNavigation[peer] = BrowserNavigation(url, newTab: true);
      unawaited(connect(workspace));
    }
    changed();
    return workspace;
  }

  Future<void> connect(BrowserWorkspace workspace) async {
    if (!_starting.add(workspace.peer)) return;
    try {
      final existing = connections[workspace.peer];
      if (existing?.connecting == true) return;
      if (existing?.connected == true) {
        await flushNavigation(workspace);
        return;
      }
      await existing?.close();
      if (authenticationPeer != null && authenticationPeer != workspace.peer) {
        final previous = connections[authenticationPeer];
        await previous?.close();
      }
      authenticationPeer = workspace.peer;
      final connection = BrowserWorkspaceConnection(this, workspace)
        ..nativeReady = existing?.nativeReady ?? false;
      connections[workspace.peer] = connection;
      notifyListeners();
      await connection.start();
    } finally {
      _starting.remove(workspace.peer);
    }
  }

  Future<void> flushNavigation(BrowserWorkspace workspace) async {
    final connection = connections[workspace.peer];
    if (connection?.connected != true || connection?.nativeReady != true)
      return;
    final navigation = pendingNavigation.remove(workspace.peer);
    if (navigation != null) {
      await command(workspace, navigation.newTab ? 'new' : 'navigate',
          value: navigation.url);
    }
  }

  Future<void> command(BrowserWorkspace workspace, String command,
      {String? tab, String? value}) async {
    try {
      final state = await browserWorkspaceChannel
          .invokeMapMethod<String, dynamic>('workspaceCommand', {
        'workspace': workspace.peer,
        'command': command,
        if (tab != null) 'tab': tab,
        if (value != null) 'value': value
      });
      if (state != null) workspace.applyNative(state);
      changed();
    } catch (error) {
      connections[workspace.peer]?.message = error.toString();
      notifyListeners();
    }
  }

  Future<void> disconnect(BrowserWorkspace workspace) async {
    await connections[workspace.peer]?.close();
    notifyListeners();
  }

  Future<void> saveOfflineTabs(BrowserWorkspace workspace) async {
    if (workspace.identity != null) {
      await browserWorkspaceChannel.invokeMethod('workspaceSaveTabs', {
        'workspace': workspace.peer,
        'peerIdentity': workspace.identity,
        'urls': workspace.tabs.map((tab) => tab.url).toList(),
        'selected':
            workspace.tabs.indexWhere((tab) => tab.id == workspace.selected),
      });
    }
    changed();
  }

  void signal() => notifyListeners();

  void changed() {
    notifyListeners();
    unawaited(browserWorkspaceChannel
        .invokeMethod('saveWorkspaces', jsonEncode(model.toJson()))
        .catchError((Object error) {
      debugPrint('Could not save browser workspaces: $error');
    }));
  }
}

class BrowserWorkspaceConnection {
  BrowserWorkspaceConnection(this.owner, this.workspace);
  final BrowserWorkspaceController owner;
  final BrowserWorkspace workspace;
  final ffi = FFI(Uuid().v4obj());
  final overlay = BlockableOverlayState();
  StreamSubscription<EventToUI>? _events;
  Map<String, dynamic>? _endpoint;
  bool _added = false;
  bool _closed = false;
  bool connecting = true;
  bool connected = false;
  bool nativeReady = false;
  String message = 'Authenticating with remote computer…';

  Future<void> start() async {
    overlay.applyFfi(ffi);
    try {
      ffi.id = workspace.peer;
      ffi.connType = ConnType.portForward;
      final error = bind.sessionAddSync(
          sessionId: ffi.sessionId,
          id: workspace.peer,
          isFileTransfer: false,
          isViewCamera: false,
          isPortForward: true,
          isRdp: false,
          isTerminal: false,
          switchUuid: '',
          forceRelay: false,
          password: '',
          isSharedPassword: false);
      if (error.isNotEmpty) throw StateError(error);
      _added = true;
      final configuration = bind.sessionGetCommonSync(
          sessionId: ffi.sessionId, key: 'remote-browser-prepare', param: '');
      if (configuration == null || configuration.isEmpty) {
        throw StateError('Remote browser is unavailable in this build.');
      }
      _endpoint = jsonDecode(configuration);
      if (_endpoint!['error'] != null) throw StateError(_endpoint!['error']);
      final handleEvent =
          ffi.ffiModel.startEventListener(ffi.sessionId, workspace.peer);
      _events = bind
          .sessionStart(sessionId: ffi.sessionId, id: workspace.peer)
          .listen((event) async {
        if (_closed || event is! EventToUI_Event) return;
        if (event.field0 == 'close') {
          _disconnected('Connection closed.');
          return;
        }
        try {
          final value = jsonDecode(event.field0) as Map<String, dynamic>;
          if (value['name'] == 'browser_ready') {
            ffi.dialogManager.dismissAll();
            final identity = _endpoint!['peerIdentity'] as String;
            if (workspace.identity != null && workspace.identity != identity) {
              throw StateError(
                  'Computer identity changed. Re-add this computer before browsing.');
            }
            workspace.identity = identity;
            final state = await browserWorkspaceChannel
                .invokeMapMethod<String, dynamic>('workspacePrepare',
                    {..._endpoint!, 'workspace': workspace.peer});
            if (_closed) return;
            if (owner.authenticationPeer == workspace.peer)
              owner.authenticationPeer = null;
            connected = true;
            connecting = false;
            if ((state?['error'] as String? ?? '').isNotEmpty) {
              throw StateError(state!['error']);
            }
            if (state != null) {
              workspace.applyNative(state);
              nativeReady = state['ready'] == true;
            }
            await owner.command(workspace, 'resume');
            await owner.flushNavigation(workspace);
            owner.changed();
          } else if (value['name'] == 'browser_closed') {
            _disconnected(
                'Connection closed. Your tabs and website data are saved.');
          } else {
            if (value['name'] == 'msgbox')
              owner.authenticationPeer = workspace.peer;
            if (value['name'] == 'cancel_msgbox' &&
                owner.authenticationPeer == workspace.peer) {
              owner.authenticationPeer = null;
            }
            await handleEvent(value);
          }
        } catch (error) {
          _disconnected(error.toString());
        }
      }, onError: (Object error) => _disconnected(error.toString()));
    } catch (error) {
      _disconnected(error.toString());
    }
  }

  void failed(String reason) => _disconnected(reason);

  void _disconnected(String reason) {
    if (_closed) return;
    connecting = false;
    connected = false;
    message = reason;
    ffi.dialogManager.dismissAll();
    if (owner.authenticationPeer == workspace.peer)
      owner.authenticationPeer = null;
    unawaited(owner.command(workspace, 'suspend'));
    owner.signal();
  }

  Future<void> close() async {
    _closed = true;
    if (owner.authenticationPeer == workspace.peer)
      owner.authenticationPeer = null;
    await owner.command(workspace, 'suspend');
    connecting = false;
    connected = false;
    message = 'Disconnected. Your tabs and website data are saved.';
    await _events?.cancel();
    ffi.dialogManager.dismissAll();
    if (_added) {
      _added = false;
      await ffi.close();
    }
    _endpoint = null;
  }
}

class BrowserDesktopRequest {
  BrowserDesktopRequest(this.peer,
      {this.password, this.isSharedPassword, this.forceRelay});
  final String peer;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
}

class BrowserNavigation {
  BrowserNavigation(this.url, {this.newTab = false});
  final String url;
  final bool newTab;
}
