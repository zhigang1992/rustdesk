import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/browser_workspace.dart';
import 'package:flutter_hbb/models/remote_browser_link.dart';

void main() {
  test('switching computers keeps each selected website and its metadata', () {
    final workspaces = BrowserWorkspaces();
    final first = workspaces.select('mac-a');
    first.applyNative({
      'tabs': [
        {'id': 'a1', 'url': 'http://localhost:50100/a', 'title': 'A'},
        {'id': 'a2', 'url': 'https://example.com', 'title': 'Example'},
      ],
      'selected': 'a2',
      'bookmarks': [
        {'title': 'Local A', 'url': 'http://localhost:50100/a'}
      ]
    });
    final second = workspaces.select('mac-b');
    second.applyNative({
      'tabs': [
        {'id': 'b1', 'url': 'http://localhost:50100/a', 'title': 'B'}
      ],
      'selected': 'b1'
    });
    expect(workspaces.current?.current.title, 'B');
    workspaces.select('mac-a');
    expect(workspaces.current?.current.url, 'https://example.com');
    expect(first.bookmarks.single['title'], 'Local A');
    expect(second.bookmarks, isEmpty);
  });

  test(
      'closing an inactive website preserves selection; last close leaves blank',
      () {
    final workspaces = BrowserWorkspaces();
    final workspace = workspaces.select('mac-a');
    workspace.tabs = [BrowserTab('a'), BrowserTab('b')];
    workspace.selected = 'b';
    workspaces.openDesktop('mac-a');
    workspaces.closeOfflineTab(workspace, 'a');
    expect(workspace.selected, 'b');
    expect(workspaces.desktopPeer, 'mac-a');
    workspaces.closeOfflineTab(workspace, 'b');
    expect(workspace.current.blank, isTrue);
    workspaces.closeDesktop();
    expect(workspace.tabs.length, 1);
    expect(workspace.desktopSelected, isFalse);
  });

  test('another desktop requires ending the live desktop first', () {
    final workspaces = BrowserWorkspaces();
    final first = workspaces.select('mac-a');
    workspaces.openDesktop('mac-a');
    workspaces.select('mac-b');
    expect(workspaces.canOpenDesktop('mac-b'), isFalse);
    expect(() => workspaces.openDesktop('mac-b'), throwsStateError);
    expect(workspaces.desktopPeer, 'mac-a');
    expect(first.desktopSelected, isTrue);
    workspaces.closeDesktop();
    workspaces.openDesktop('mac-b');
    expect(workspaces.desktopPeer, 'mac-b');
    expect(first.desktopSelected, isFalse);
  });

  test(
      'restart restores URLs, selected workspace and bookmarks without desktop or credentials',
      () {
    final workspaces = BrowserWorkspaces();
    workspaces.select('mac-a');
    final selected = workspaces.select('mac-b');
    selected.identity = 'existing-peer-identity';
    selected.applyNative({
      'tabs': [
        {'id': 'tab-b', 'url': 'https://example.com', 'title': 'Example'}
      ],
      'selected': 'tab-b',
      'bookmarks': [
        {'title': 'Example', 'url': 'https://example.com'}
      ]
    });
    workspaces.openDesktop('mac-b');
    final serialized = jsonEncode(workspaces.toJson());
    final restored = BrowserWorkspaces()..restore(jsonDecode(serialized));
    expect(restored.current?.peer, 'mac-b');
    expect(restored.current?.current.url, 'https://example.com');
    expect(restored.current?.identity, 'existing-peer-identity');
    expect(restored.current?.bookmarks.single['title'], 'Example');
    expect(restored.desktopPeer, isNull);
    expect(restored.current?.desktopSelected, isFalse);
    expect(serialized, isNot(contains('password')));
  });

  test(
      'browser deep link selects its own computer without rerouting existing tabs',
      () {
    final workspaces = BrowserWorkspaces();
    final first = workspaces.select('mac-a');
    first.tabs = [BrowserTab('a', url: 'http://localhost:50100')];
    final link = RemoteBrowserLink.parse(Uri.parse(
        'rustdesk://browser/mac-b?url=http%3A%2F%2Flocalhost%3A50100'))!;
    final target = workspaces.select(link.peer);
    expect(target.peer, 'mac-b');
    expect(first.tabs.single.url, 'http://localhost:50100');
    expect(first.peer, 'mac-a');
    expect(workspaces.items.length, 2);
  });
}
