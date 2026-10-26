import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/autocomplete.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/models/browser_workspace.dart';
import '../browser/browser_workspace_controller.dart';
import 'remote_page.dart';
import 'settings_page.dart';

Future<bool> browserWorkspaceEnabled() async {
  await browserWorkspaces.initialize();
  return browserWorkspaces.enabled;
}

Future<void> openBrowserWorkspace({String? peer, String? url}) async {
  await browserWorkspaces.initialize();
  if (!browserWorkspaces.enabled) return;
  if (peer != null) browserWorkspaces.select(peer, url: url);
  if (browserWorkspaces.presented) return;
  browserWorkspaces.presented = true;
  try {
    await globalKey.currentState?.push<void>(
        MaterialPageRoute(builder: (_) => const BrowserWorkspacePage()));
  } finally {
    browserWorkspaces.presented = false;
  }
}

Future<void> openBrowserWorkspaceDesktop(String peer,
    {String? password, bool? isSharedPassword, bool? forceRelay}) async {
  await browserWorkspaces.initialize();
  browserWorkspaces.desktopRequest = BrowserDesktopRequest(peer,
      password: password,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay);
  await openBrowserWorkspace(peer: peer);
}

class BrowserWorkspacePage extends StatefulWidget {
  const BrowserWorkspacePage({super.key});
  @override
  State<BrowserWorkspacePage> createState() => _BrowserWorkspacePageState();
}

class _BrowserWorkspacePageState extends State<BrowserWorkspacePage> {
  final owner = browserWorkspaces;
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  final _peers = AllPeersLoader();
  bool _covered = false;
  bool _endingDesktop = false;
  bool _openingDesktop = false;
  Completer<void>? _desktopDisposed;
  String? _addressTab;
  String? _visibleWebPeer;

  BrowserWorkspace? get workspace => owner.model.current;
  bool get desktopVisible =>
      !_covered &&
      !_addressFocus.hasFocus &&
      workspace?.desktopSelected == true &&
      owner.model.desktopPeer == workspace?.peer;

  @override
  void initState() {
    super.initState();
    owner.addListener(_changed);
    _addressFocus.addListener(_changed);
    _peers.init((callback) {
      if (mounted) setState(callback);
    });
    _peers.getAllPeers();
    mobileWorkspaceCloseHandler = _sessionClosed;
    _drainDesktopRequest();
    _syncWebVisibility();
  }

  void _changed() {
    if (mounted) setState(() {});
    _drainDesktopRequest();
    _syncWebVisibility();
  }

  void _syncWebVisibility() {
    final peer = !_covered &&
            !_addressFocus.hasFocus &&
            workspace?.desktopSelected != true
        ? workspace?.peer
        : null;
    if (peer == _visibleWebPeer) return;
    for (final id in [_visibleWebPeer, peer]) {
      if (id == null) continue;
      unawaited(browserWorkspaceChannel.invokeMethod('workspaceCommand', {
        'workspace': id,
        'command': 'visibility',
        'value': (id == peer).toString(),
      }).catchError((Object error) {
        debugPrint('Could not update browser focus: $error');
      }));
    }
    _visibleWebPeer = peer;
  }

  void _drainDesktopRequest() {
    final request = owner.desktopRequest;
    if (request == null || _openingDesktop) return;
    owner.desktopRequest = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openDesktop(request: request);
    });
  }

  void _sessionClosed() {
    final authenticating = owner.authenticationPeer;
    if (authenticating != null) {
      final item =
          owner.model.items.firstWhere((item) => item.peer == authenticating);
      unawaited(owner.disconnect(item));
    } else if (owner.model.desktopPeer != null) {
      unawaited(_closeDesktop());
    } else if (workspace != null) {
      unawaited(owner.disconnect(workspace!));
    }
  }

  @override
  void dispose() {
    mobileWorkspaceCloseHandler = null;
    owner.removeListener(_changed);
    _addressFocus.removeListener(_changed);
    _addressFocus.dispose();
    _address.dispose();
    _peers.clear();
    owner.model.closeDesktop();
    for (final item in owner.model.items) {
      unawaited(owner.command(item, 'blur'));
    }
    super.dispose();
  }

  void _setCovered(bool value) {
    if (!mounted) return;
    setState(() => _covered = value);
    _syncWebVisibility();
  }

  Future<T?> _cover<T>(Future<T?> Function() action) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return null;
    _setCovered(true);
    if (workspace != null) await owner.command(workspace!, 'blur');
    try {
      return await action();
    } finally {
      if (mounted) _setCovered(false);
    }
  }

  Future<void> _closeDesktop() async {
    if (_endingDesktop || owner.model.desktopPeer == null) return;
    _endingDesktop = true;
    final disposed = _desktopDisposed;
    owner.model.closeDesktop();
    owner.changed();
    await disposed?.future;
    _desktopDisposed = null;
    owner.desktopConfiguration = null;
    _endingDesktop = false;
  }

  Future<void> _openDesktop({BrowserDesktopRequest? request}) async {
    final selected =
        request == null ? workspace : owner.model.select(request.peer);
    if (selected == null || _endingDesktop || _openingDesktop) return;
    _openingDesktop = true;
    _addressFocus.unfocus();
    final authenticating = owner.authenticationPeer;
    if (authenticating != null) {
      await owner.connections[authenticating]?.close();
    }
    if (!owner.model.canOpenDesktop(selected.peer)) {
      final end = await _cover(() => showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('End the other desktop?'),
                  content: Text(
                      'Desktop is connected to ${owner.model.desktopPeer}. End screen sharing there and open ${selected.label}? Website tabs stay open.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('End and open'))
                  ])));
      if (end != true || !mounted) {
        _openingDesktop = false;
        return;
      }
      await _closeDesktop();
    }
    if (!mounted) {
      _openingDesktop = false;
      return;
    }
    owner.desktopConfiguration = request;
    _desktopDisposed ??= Completer<void>();
    await owner.command(selected, 'blur');
    owner.model.openDesktop(selected.peer);
    _openingDesktop = false;
    owner.changed();
  }

  Future<void> _selectTab(BrowserWorkspace item, BrowserTab tab) async {
    _addressFocus.unfocus();
    item.desktopSelected = false;
    item.selected = tab.id;
    if (owner.connections[item.peer]?.nativeReady == true) {
      await owner.command(item, 'select', tab: tab.id);
    }
    await owner.saveOfflineTabs(item);
    if (!tab.blank && owner.connections[item.peer]?.connected != true) {
      unawaited(owner.connect(item));
    }
  }

  Future<void> _newTab() async {
    final item = workspace;
    if (item == null) {
      await _computerPicker();
      return;
    }
    if (item.tabs.length >= 32) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Close a tab before opening another (32 tab limit).')));
      return;
    }
    item.desktopSelected = false;
    if (owner.connections[item.peer]?.nativeReady == true) {
      await owner.command(item, 'new');
    } else {
      final tab = BrowserTab('blank-${DateTime.now().microsecondsSinceEpoch}');
      item.tabs.add(tab);
      item.selected = tab.id;
      await owner.saveOfflineTabs(item);
    }
    _addressFocus.requestFocus();
  }

  Future<void> _navigate(String text) async {
    final item = workspace;
    if (item == null) return;
    final value = text.trim();
    final local = value == 'localhost' ||
        value.startsWith('localhost:') ||
        value.startsWith('127.0.0.1') ||
        value.startsWith('[::1]');
    final uri = Uri.tryParse(
        value.contains('://') ? value : '${local ? 'http' : 'https'}://$value');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter an HTTP or HTTPS URL without credentials.')));
      return;
    }
    item.desktopSelected = false;
    _addressFocus.unfocus();
    owner.changed();
    if (owner.connections[item.peer]?.connected == true &&
        owner.connections[item.peer]?.nativeReady == true) {
      await owner.command(item, 'navigate',
          tab: item.selected, value: uri.toString());
    } else {
      owner.pendingNavigation[item.peer] = BrowserNavigation(uri.toString());
      await owner.connect(item);
    }
  }

  Future<void> _closeTab(BrowserWorkspace item, BrowserTab tab) async {
    if (owner.connections[item.peer]?.nativeReady == true) {
      await owner.command(item, 'close', tab: tab.id);
    } else {
      owner.model.closeOfflineTab(item, tab.id);
      await owner.saveOfflineTabs(item);
    }
  }

  Future<void> _computerPicker() => _cover(() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final controller = TextEditingController();
        final known = <String, String>{
          for (final item in _peers.peers) item.id: item.getId(),
          for (final item in owner.model.items) item.peer: item.label
        };
        return SafeArea(
            child: Padding(
                padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: 16,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Computers',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: ListView(
                              shrinkWrap: true,
                              children: known.entries
                                  .map((entry) => ListTile(
                                      leading: const Icon(Icons.computer),
                                      title: Text(entry.value),
                                      subtitle: Text(entry.key),
                                      selected: workspace?.peer == entry.key,
                                      onTap: () {
                                        owner.select(entry.key,
                                            label: entry.value);
                                        Navigator.pop(context);
                                      }))
                                  .toList())),
                      TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                              labelText: 'Add computer ID',
                              hintText: 'RustDesk ID or IP address'),
                          onSubmitted: (value) {
                            if (value.trim().isNotEmpty) {
                              owner.select(value.trim());
                              Navigator.pop(context);
                            }
                          }),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: () {
                            if (controller.text.trim().isNotEmpty) {
                              owner.select(controller.text.trim());
                              Navigator.pop(context);
                            }
                          },
                          child: const Text('Add computer')),
                    ])));
      }));

  Future<void> _overview() => _cover(() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final item = workspace;
        if (item == null) return const SizedBox.shrink();
        return SafeArea(
            child: SizedBox(
                height: MediaQuery.of(context).size.height * .7,
                child: StatefulBuilder(
                    builder: (context, update) => Column(children: [
                          ListTile(
                              title: Text('Tabs · ${item.label}'),
                              trailing: IconButton(
                                  tooltip: 'New tab',
                                  icon: const Icon(Icons.add),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _newTab();
                                  })),
                          Expanded(
                              child: ListView(children: [
                            if (owner.model.desktopPeer == item.peer)
                              ListTile(
                                  leading: const Icon(Icons.desktop_windows),
                                  title: const Text('Desktop'),
                                  selected: item.desktopSelected,
                                  onTap: () {
                                    Navigator.pop(context);
                                    _openDesktop();
                                  },
                                  trailing: IconButton(
                                      tooltip: 'Close Desktop',
                                      icon: const Icon(Icons.close),
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _closeDesktop();
                                      })),
                            ...item.tabs.map((tab) => ListTile(
                                leading: Icon(tab.blank
                                    ? Icons.add_box_outlined
                                    : Icons.public),
                                title: Text(tab.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: tab.blank
                                    ? null
                                    : Text(tab.url,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                selected: !item.desktopSelected &&
                                    item.selected == tab.id,
                                onTap: () {
                                  Navigator.pop(context);
                                  _selectTab(item, tab);
                                },
                                trailing: IconButton(
                                    tooltip: 'Close tab',
                                    icon: const Icon(Icons.close),
                                    onPressed: () async {
                                      await _closeTab(item, tab);
                                      update(() {});
                                    }))),
                          ])),
                        ]))));
      }));

  Future<void> _bookmarks() => _cover(() => showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
              child: Column(children: [
            ListTile(
                title: const Text('Bookmarks'),
                trailing: IconButton(
                    tooltip: 'Bookmark this page',
                    icon: const Icon(Icons.bookmark_add_outlined),
                    onPressed: workspace?.desktopSelected == true ||
                            owner.connections[workspace?.peer]?.connected !=
                                true ||
                            workspace?.current.blank != false
                        ? null
                        : () {
                            Navigator.pop(context);
                            owner.command(workspace!, 'bookmark');
                          })),
            Expanded(
                child: ListView(children: [
              for (var index = 0;
                  index < (workspace?.bookmarks.length ?? 0);
                  index++)
                ListTile(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text(workspace!.bookmarks[index]['title']),
                    subtitle: Text(workspace!.bookmarks[index]['url'],
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      final url = workspace!.bookmarks[index]['url'] as String;
                      Navigator.pop(context);
                      _navigate(url);
                    },
                    trailing: PopupMenuButton<String>(
                        enabled:
                            owner.connections[workspace?.peer]?.connected ==
                                    true &&
                                workspace?.desktopSelected != true,
                        onSelected: (action) {
                          Navigator.pop(context);
                          owner.command(workspace!, action,
                              value: index.toString());
                        },
                        itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'editBookmark', child: Text('Edit')),
                              PopupMenuItem(
                                  value: 'deleteBookmark',
                                  child: Text('Delete'))
                            ]))
            ])),
          ]))));

  Widget _button(IconData icon, String label, VoidCallback? action) =>
      IconButton(
          iconSize: 20,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
          padding: const EdgeInsets.all(8),
          tooltip: label,
          onPressed: action,
          icon: Icon(icon));

  Widget _selectedTab(BrowserWorkspace? item) {
    final tab = item?.current;
    final token =
        '${item?.peer}/${item?.desktopSelected == true ? 'desktop' : tab?.id}';
    if (!_addressFocus.hasFocus &&
        (_addressTab != token ||
            _address.text != (tab?.blank == false ? tab!.url : ''))) {
      _address.text = tab?.blank == false ? tab!.url : '';
      _addressTab = token;
    }
    return Container(
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Theme.of(context).dividerColor)),
        child: Row(children: [
          InkWell(
              onTap: _computerPicker,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        item?.desktopSelected == true
                            ? Icons.desktop_windows
                            : Icons.computer,
                        size: 17),
                    if (MediaQuery.of(context).size.width >= 600) ...[
                      const SizedBox(width: 5),
                      ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 100),
                          child: Text(item?.label ?? 'Add computer',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)))
                    ],
                    const Icon(Icons.expand_more, size: 15)
                  ]))),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8),
          Expanded(
              child: item?.desktopSelected == true
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text('Desktop'))
                  : TextField(
                      controller: _address,
                      focusNode: _addressFocus,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                          hintText: 'Enter website address',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10)),
                      onTap: () => _address.selection = TextSelection(
                          baseOffset: 0, extentOffset: _address.text.length),
                      onSubmitted: _navigate)),
          if (item != null && MediaQuery.of(context).size.width >= 600)
            _button(Icons.close,
                item.desktopSelected ? 'Close Desktop' : 'Close tab', () {
              if (item.desktopSelected) {
                _closeDesktop();
              } else {
                _closeTab(item, item.current);
              }
            }),
        ]));
  }

  Widget _toolbar(double width) {
    final item = workspace;
    final desktop = item?.desktopSelected == true;
    final connected = owner.connections[item?.peer]?.connected == true;
    final compact = width < 700;
    final backgroundDesktop =
        !desktop && item != null && owner.model.desktopPeer == item.peer;
    final inactiveCount = ((width - 600 - (backgroundDesktop ? 110 : 0)) /
            (width > 1100 ? 140 : 105))
        .floor()
        .clamp(0, 3);
    return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox(
            height: 52,
            child: Row(children: [
              _button(
                  Icons.chevron_left,
                  'Back',
                  !desktop && connected && item?.current.back == true
                      ? () => owner.command(item!, 'back')
                      : null),
              if (!compact) ...[
                _button(
                    Icons.chevron_right,
                    'Forward',
                    !desktop && connected && item?.current.forward == true
                        ? () => owner.command(item!, 'forward')
                        : null),
                _button(
                    item?.current.loading == true ? Icons.close : Icons.refresh,
                    item?.current.loading == true ? 'Stop loading' : 'Reload',
                    desktop || item == null
                        ? null
                        : () {
                            if (connected) {
                              owner.command(item, 'reload');
                            } else {
                              owner.connect(item);
                            }
                          }),
                if (item != null)
                  ...item.tabs
                      .where((tab) => desktop || tab.id != item.selected)
                      .take(inactiveCount)
                      .map((tab) => SizedBox(
                          width: width > 1100 ? 140 : 105,
                          child: Row(children: [
                            Expanded(
                                child: TextButton(
                                    onPressed: () => _selectTab(item, tab),
                                    child: Text(tab.title,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1))),
                            SizedBox(
                                width: 28,
                                child: _button(
                                    Icons.close,
                                    'Close ${tab.title}',
                                    () => _closeTab(item, tab)))
                          ]))),
                if (!desktop &&
                    item != null &&
                    owner.model.desktopPeer == item.peer)
                  SizedBox(
                      width: 110,
                      child: TextButton.icon(
                          onPressed: _openDesktop,
                          icon: const Icon(Icons.desktop_windows, size: 17),
                          label: const Text('Desktop'))),
              ],
              Expanded(child: _selectedTab(item)),
              if (!compact) _button(Icons.add, 'New tab', _newTab),
              _button(
                  Icons.tab_outlined,
                  'Tabs (${(item?.tabs.length ?? 0) + (item != null && owner.model.desktopPeer == item.peer ? 1 : 0)})',
                  _overview),
              if (!compact)
                _button(Icons.bookmark_outline, 'Bookmarks', _bookmarks),
              PopupMenuButton<String>(
                  tooltip: 'Workspace menu',
                  icon: const Icon(Icons.more_horiz),
                  onOpened: () {
                    _setCovered(true);
                    if (item != null) owner.command(item, 'blur');
                  },
                  onCanceled: () => _setCovered(false),
                  onSelected: (action) async {
                    _setCovered(false);
                    switch (action) {
                      case 'new':
                        await _newTab();
                        break;
                      case 'computers':
                        await _computerPicker();
                        break;
                      case 'desktop':
                        await _openDesktop();
                        break;
                      case 'close':
                        if (item != null) {
                          if (desktop) {
                            await _closeDesktop();
                          } else {
                            await _closeTab(item, item.current);
                          }
                        }
                        break;
                      case 'bookmarks':
                        await _bookmarks();
                        break;
                      case 'bookmark':
                        if (item != null) await owner.command(item, 'bookmark');
                        break;
                      case 'back':
                      case 'forward':
                      case 'reload':
                      case 'find':
                      case 'desktopWebsite':
                        if (item != null) await owner.command(item, action);
                        break;
                      case 'disconnect':
                        if (item != null) await owner.disconnect(item);
                        break;
                      case 'settings':
                        await _cover(() => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                                builder: (_) => Scaffold(
                                    appBar:
                                        AppBar(title: const Text('Settings')),
                                    body: SettingsPage()))));
                        break;
                      case 'exit':
                        await _closeDesktop();
                        if (mounted) Navigator.pop(context);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'new', child: Text('New tab')),
                        const PopupMenuItem(
                            value: 'computers',
                            child: Text('Switch or add computer')),
                        if (item != null)
                          const PopupMenuItem(
                              value: 'desktop', child: Text('Open desktop')),
                        if (compact) ...[
                          PopupMenuItem(
                              value: 'forward',
                              enabled: !desktop &&
                                  connected &&
                                  item?.current.forward == true,
                              child: const Text('Forward')),
                          PopupMenuItem(
                              value: 'reload',
                              enabled: !desktop && connected,
                              child: Text(item?.current.loading == true
                                  ? 'Stop loading'
                                  : 'Reload')),
                          const PopupMenuItem(
                              value: 'bookmarks', child: Text('Bookmarks')),
                        ],
                        PopupMenuItem(
                            value: 'bookmark',
                            enabled: !desktop &&
                                connected &&
                                item?.current.blank == false,
                            child: const Text('Bookmark this page')),
                        PopupMenuItem(
                            value: 'desktopWebsite',
                            enabled: !desktop && connected,
                            child: const Text('Toggle desktop website')),
                        PopupMenuItem(
                            value: 'find',
                            enabled: !desktop && connected,
                            child: const Text('Find on page')),
                        if (item != null)
                          PopupMenuItem(
                              value: 'close',
                              child: Text(
                                  desktop ? 'Close Desktop' : 'Close tab')),
                        if (connected)
                          const PopupMenuItem(
                              value: 'disconnect',
                              child: Text('Disconnect browser')),
                        const PopupMenuItem(
                            value: 'settings', child: Text('Settings')),
                        const PopupMenuItem(
                            value: 'exit', child: Text('Connections')),
                      ]),
            ])));
  }

  Widget _newTabPage(BrowserWorkspace? item) => ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
          children: [
            Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 700),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('New tab',
                              style: TextStyle(
                                  fontSize: 30, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Text(
                              item == null
                                  ? 'Add a computer to browse through it.'
                                  : 'Browsing through ${item.label}',
                              style: Theme.of(context).textTheme.bodyLarge),
                          if (item != null &&
                              owner.connections[item.peer] != null &&
                              owner.connections[item.peer]?.connected != true &&
                              owner.connections[item.peer]?.connecting != true)
                            Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                    owner.connections[item.peer]!.message,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))),
                          const SizedBox(height: 20),
                          Wrap(spacing: 12, runSpacing: 8, children: [
                            OutlinedButton.icon(
                                onPressed: _computerPicker,
                                icon: const Icon(Icons.computer),
                                label: Text(item == null
                                    ? 'Add computer'
                                    : 'Switch computer')),
                            if (item != null)
                              OutlinedButton.icon(
                                  onPressed: _openDesktop,
                                  icon: const Icon(Icons.desktop_windows),
                                  label: const Text('Open desktop')),
                            if (item != null)
                              OutlinedButton.icon(
                                  onPressed: () => owner.connect(item),
                                  icon: const Icon(Icons.link),
                                  label: Text(
                                      owner.connections[item.peer]?.connected ==
                                              true
                                          ? 'Connected'
                                          : owner.connections[item.peer] == null
                                              ? 'Connect browser'
                                              : 'Reconnect browser')),
                          ]),
                          if (item != null) ...[
                            const SizedBox(height: 30),
                            const Text('Favorites',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600)),
                            if (item.bookmarks.isEmpty)
                              const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child:
                                      Text('Bookmark a page to keep it here.')),
                            ...item.bookmarks.map((entry) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.bookmark_outline),
                                title: Text(entry['title']),
                                subtitle: Text(entry['url'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onTap: () => _navigate(entry['url']))),
                            const SizedBox(height: 24),
                            const Text('Recent pages',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600)),
                            ...item.recents.take(12).map((entry) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.history),
                                title: Text(entry['title']),
                                subtitle: Text(entry['url'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onTap: () => _navigate(entry['url']))),
                          ],
                        ]))),
          ]));

  Widget _webContent(BrowserWorkspace? item) {
    if (item == null) return _newTabPage(null);
    final connection = owner.connections[item.peer];
    if (connection == null) return _webBody(item);
    return BlockableOverlay(
        state: connection.overlay,
        underlying: AnimatedBuilder(
            animation: owner, builder: (context, _) => _webBody(item)));
  }

  Widget _webBody(BrowserWorkspace item) {
    final connection = owner.connections[item.peer];
    final connected =
        connection?.connected == true && connection?.nativeReady == true;
    return Stack(children: [
      if (connected)
        Positioned.fill(
            child: UiKitView(
                key: ValueKey('web-${item.peer}'),
                viewType: 'rustdesk/browser-content',
                creationParams: {
                  'workspace': item.peer,
                  'visible': _visibleWebPeer == item.peer
                },
                creationParamsCodec: const StandardMessageCodec())),
      if (item.current.blank && connection?.connecting != true)
        Positioned.fill(child: _newTabPage(item)),
      if (!connected && (!item.current.blank || connection?.connecting == true))
        Center(
            child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.computer, size: 36),
                  const SizedBox(height: 16),
                  Text(
                      connection?.message ??
                          'Connect to ${item.label} to open your saved page.',
                      textAlign: TextAlign.center),
                  if (!item.current.blank)
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(item.current.url,
                            maxLines: 2, overflow: TextOverflow.ellipsis)),
                  const SizedBox(height: 16),
                  if (connection?.connecting == true) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: () => owner.disconnect(item),
                        child: const Text('Cancel'))
                  ] else
                    FilledButton(
                        onPressed: () => owner.connect(item),
                        child:
                            Text(connection == null ? 'Connect' : 'Reconnect')),
                ]))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final item = workspace;
    final desktopPeer = owner.model.desktopPeer;
    return WillPopScope(
        onWillPop: () async {
          if (item?.desktopSelected == true) {
            item!.desktopSelected = false;
            owner.changed();
            return false;
          }
          await _closeDesktop();
          return true;
        },
        child: Scaffold(
            body: SafeArea(
                child: Column(children: [
          LayoutBuilder(
              builder: (context, constraints) =>
                  _toolbar(constraints.maxWidth)),
          Expanded(
              child: Stack(fit: StackFit.expand, children: [
            if (desktopPeer != null)
              Offstage(
                  offstage: !desktopVisible,
                  child: ExcludeFocus(
                      excluding: !desktopVisible,
                      child: RemotePage(
                          key: ValueKey('desktop-$desktopPeer'),
                          id: desktopPeer,
                          password: owner.desktopConfiguration?.password,
                          isSharedPassword:
                              owner.desktopConfiguration?.isSharedPassword,
                          forceRelay: owner.desktopConfiguration?.forceRelay,
                          embedded: true,
                          inputEnabled: desktopVisible,
                          onEmbeddedClose: () => unawaited(_closeDesktop()),
                          onEmbeddedDisposed: () {
                            if (_desktopDisposed?.isCompleted == false)
                              _desktopDisposed!.complete();
                          }))),
            if (item?.desktopSelected != true) _webContent(item),
          ])),
        ]))));
  }
}
