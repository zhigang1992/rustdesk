/// Presentation metadata only. WebKit owns navigation and website data.
class BrowserTab {
  BrowserTab(this.id,
      {this.url = 'about:blank',
      this.title = 'New tab',
      this.loading = false,
      this.back = false,
      this.forward = false});
  final String id;
  final String url;
  final String title;
  final bool loading;
  final bool back;
  final bool forward;
  bool get blank => url.isEmpty || url == 'about:blank';
  factory BrowserTab.fromJson(Map<String, dynamic> value) =>
      BrowserTab(value['id'] as String,
          url: value['url'] as String? ?? 'about:blank',
          title: value['title'] as String? ?? 'New tab',
          loading: value['loading'] == true,
          back: value['back'] == true,
          forward: value['forward'] == true);
  Map<String, dynamic> toJson() => {'id': id, 'url': url, 'title': title};
}

class BrowserWorkspace {
  BrowserWorkspace(this.peer, {String? label}) : label = label ?? peer;
  final String peer;
  String label;
  String? identity;
  List<BrowserTab> tabs = [BrowserTab('blank')];
  String selected = 'blank';
  List<Map<String, dynamic>> bookmarks = [];
  List<Map<String, dynamic>> recents = [];
  bool desktopSelected = false;
  BrowserTab get current =>
      tabs.firstWhere((tab) => tab.id == selected, orElse: () => tabs.first);

  void applyNative(Map<String, dynamic> value) {
    final received = (value['tabs'] as List? ?? [])
        .map((tab) => BrowserTab.fromJson(Map<String, dynamic>.from(tab)))
        .toList();
    if (received.isEmpty) return;
    tabs = received;
    selected = value['selected'] as String? ?? tabs.first.id;
    bookmarks = (value['bookmarks'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    recents = (value['recents'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, dynamic> toJson() => {
        'peer': peer,
        'label': label,
        'identity': identity,
        'tabs': tabs.map((tab) => tab.toJson()).toList(),
        'selected': selected,
        'bookmarks': bookmarks,
        'recents': recents
      };
  factory BrowserWorkspace.fromJson(Map<String, dynamic> value) {
    final workspace = BrowserWorkspace(value['peer'] as String,
        label: value['label'] as String?);
    workspace.identity = value['identity'] as String?;
    workspace.applyNative(value);
    return workspace;
  }
}

class BrowserWorkspaces {
  final List<BrowserWorkspace> items = [];
  String? selectedPeer;
  String? desktopPeer;
  BrowserWorkspace? get current {
    for (final workspace in items) {
      if (workspace.peer == selectedPeer) return workspace;
    }
    return items.isEmpty ? null : items.first;
  }

  BrowserWorkspace select(String peer, {String? label}) {
    final workspace = items.firstWhere((item) => item.peer == peer, orElse: () {
      final item = BrowserWorkspace(peer, label: label);
      items.add(item);
      return item;
    });
    selectedPeer = peer;
    return workspace;
  }

  bool canOpenDesktop(String peer) =>
      desktopPeer == null || desktopPeer == peer;
  void openDesktop(String peer) {
    if (!canOpenDesktop(peer)) throw StateError('End the other desktop first.');
    desktopPeer = peer;
    select(peer).desktopSelected = true;
  }

  void closeDesktop() {
    for (final workspace in items) {
      workspace.desktopSelected = false;
    }
    desktopPeer = null;
  }

  void closeOfflineTab(BrowserWorkspace workspace, String id) {
    final index = workspace.tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    workspace.tabs.removeAt(index);
    if (workspace.tabs.isEmpty) workspace.tabs.add(BrowserTab('blank'));
    if (workspace.selected == id) {
      workspace.selected =
          workspace.tabs[index.clamp(0, workspace.tabs.length - 1)].id;
    }
  }

  Map<String, dynamic> toJson() => {
        'selectedPeer': selectedPeer,
        'workspaces': items.map((workspace) => workspace.toJson()).toList()
      };
  void restore(Map<String, dynamic> value) {
    items.clear();
    items.addAll((value['workspaces'] as List? ?? []).map(
        (item) => BrowserWorkspace.fromJson(Map<String, dynamic>.from(item))));
    selectedPeer = value['selectedPeer'] as String?;
    desktopPeer = null;
  }
}
