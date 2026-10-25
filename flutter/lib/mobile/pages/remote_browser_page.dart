import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uuid/uuid.dart';

const _browserChannel = MethodChannel('rustdesk/remote-browser');
bool _browserOpening = false;

Future<bool> remoteBrowserAvailable() async {
  if (!isIOS) return false;
  try {
    return await _browserChannel.invokeMethod<bool>('available') ?? false;
  } on MissingPluginException {
    return false;
  }
}

Future<void> openRemoteBrowser(String peer, {String? url}) async {
  if (_browserOpening || peer.trim().isEmpty) return;
  _browserOpening = true;
  try {
    if (!await remoteBrowserAvailable()) {
      showToast('Remote browser requires iOS or iPadOS 17 or later.');
      return;
    }
    await globalKey.currentState?.push<void>(MaterialPageRoute(
        builder: (_) => RemoteBrowserPage(peer: peer.trim(), url: url)));
  } finally {
    _browserOpening = false;
  }
}

class RemoteBrowserPage extends StatefulWidget {
  const RemoteBrowserPage({super.key, required this.peer, this.url});
  final String peer;
  final String? url;

  @override
  State<RemoteBrowserPage> createState() => _RemoteBrowserPageState();
}

class _RemoteBrowserPageState extends State<RemoteBrowserPage> {
  final _ffi = FFI(Uuid().v4obj());
  final _overlay = BlockableOverlayState();
  StreamSubscription<EventToUI>? _events;
  Map<String, dynamic>? _endpoint;
  bool _added = false;
  bool _transportClosed = false;
  bool _nativeOpen = false;
  String _message =
      'Authenticating with remote Mac…\nRequires the accompanying Mac preview.';

  @override
  void initState() {
    super.initState();
    _overlay.applyFfi(_ffi);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    try {
      _ffi.id = widget.peer;
      _ffi.connType = ConnType.portForward;
      final error = bind.sessionAddSync(
          sessionId: _ffi.sessionId,
          id: widget.peer,
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
          sessionId: _ffi.sessionId, key: 'remote-browser-prepare', param: '');
      if (configuration == null || configuration.isEmpty) {
        throw StateError('Remote browser is unavailable in this build.');
      }
      _endpoint = jsonDecode(configuration) as Map<String, dynamic>;
      if (_endpoint!['error'] != null) throw StateError(_endpoint!['error']);
      final handleEvent =
          _ffi.ffiModel.startEventListener(_ffi.sessionId, widget.peer);
      _events = bind
          .sessionStart(sessionId: _ffi.sessionId, id: widget.peer)
          .listen((event) async {
        if (!mounted || event is! EventToUI_Event || event.field0 == 'close') {
          return;
        }
        final value = jsonDecode(event.field0) as Map<String, dynamic>;
        if (value['name'] == 'browser_ready') {
          _ffi.dialogManager.dismissAll();
          _present();
        } else if (value['name'] == 'browser_closed') {
          _transportClosed = true;
          if (_nativeOpen) await _browserChannel.invokeMethod<void>('close');
          if (mounted) {
            setState(() => _message =
                'Connection closed. Reopen the browser to reconnect.');
          }
        } else {
          await handleEvent(value);
        }
      }, onError: (Object error) {
        if (mounted) setState(() => _message = error.toString());
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _present() async {
    if (_nativeOpen || _transportClosed || !mounted) return;
    _nativeOpen = true;
    try {
      await _browserChannel.invokeMethod<void>('open', {
        ..._endpoint!,
        'peer': widget.peer,
        if (widget.url != null) 'url': widget.url,
      });
      if (mounted && !_transportClosed) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      _nativeOpen = false;
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    if (_nativeOpen) _browserChannel.invokeMethod<void>('close');
    _ffi.dialogManager.dismissAll();
    if (_added) _ffi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('Browser · ${widget.peer}')),
      body: BlockableOverlay(
          state: _overlay,
          underlying: Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_message, textAlign: TextAlign.center)))));
}
