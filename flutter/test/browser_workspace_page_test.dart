import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/browser/browser_workspace_controller.dart';
import 'package:flutter_hbb/mobile/pages/browser_workspace_page.dart';
import 'package:flutter_hbb/models/browser_workspace.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';
  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';
  @override
  bool isDisableAb({dynamic hint}) => false;
  @override
  bool isDisableAccount({dynamic hint}) => false;
  @override
  bool isDisableGroupPanel({dynamic hint}) => false;
  @override
  Future<void> mainLoadRecentPeers({dynamic hint}) async {}
  @override
  Future<void> mainLoadLanPeers({dynamic hint}) async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final owner = browserWorkspaces;
  late BrowserWorkspace item;
  final nativeCalls = <MethodCall>[];
  setUpAll(() async {
    isTest = true;
    platformFFI.setBindingForTesting(_Binding());
    await initGlobalFFI();
  });
  setUp(() {
    owner.model.items.clear();
    owner.connections.clear();
    owner.model.desktopPeer = null;
    item = owner.model.select('mac-a', label: 'Mac A');
    item.tabs = [
      BrowserTab('a', url: 'https://a.example', title: 'Site A'),
      BrowserTab('b', url: 'https://b.example', title: 'Site B'),
      BrowserTab('c', url: 'https://c.example', title: 'Site C'),
    ];
    item.selected = 'a';
    owner.connections[item.peer] = BrowserWorkspaceConnection(owner, item)
      ..connecting = false
      ..connected = true
      ..nativeReady = true;
    nativeCalls.clear();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      nativeCalls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(browserWorkspaceChannel, (call) async {
      if (call.method == 'workspaceCommand') return item.toJson();
      return null;
    });
  });

  Future<void> showPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const GetMaterialApp(home: BrowserWorkspacePage()));
    await tester.pumpAndSettle();
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
      'panels retain their routes across native updates and restore the retained web surface',
      (tester) async {
    await showPage(tester);
    final web = tester.element(find.byType(UiKitView));
    for (final panel in [
      'Computers',
      'Tabs · Mac A',
      'Bookmarks',
      'Switch or add computer'
    ]) {
      if (panel == 'Computers') {
        await tester.tap(find.byIcon(Icons.expand_more));
      } else {
        await tester.tap(find.byTooltip(panel == 'Tabs · Mac A'
            ? 'Tabs (3)'
            : panel == 'Bookmarks'
                ? 'Bookmarks'
                : 'Workspace menu'));
      }
      await tester.pumpAndSettle();
      expect(find.text(panel), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(UiKitView, skipOffstage: false).evaluate().single,
          same(web));
      item.tabs = [
        BrowserTab('a',
            url: 'https://a.example/updated',
            title: 'Updated A',
            loading: true),
        BrowserTab('b', url: 'https://b.example', title: 'Background B'),
        item.tabs[2],
      ];
      await owner.command(item, 'blur');
      await owner.command(item, 'visibility', value: 'false');
      await tester.pumpAndSettle();
      expect(find.text(panel), findsOneWidget);
      if (panel != 'Switch or add computer') {
        await tester.tap(find.text(panel));
        await tester.pumpAndSettle();
        expect(find.text(panel), findsOneWidget);
      }
      await tester.tapAt(const Offset(4, 200));
      await tester.pumpAndSettle();
      expect(find.text(panel), findsNothing);
      expect(tester.element(find.byType(UiKitView)), same(web));
    }
    expect(nativeCalls.where((call) => call.method == 'create'), hasLength(1));
    expect(nativeCalls.where((call) => call.method == 'dispose'), isEmpty);
    await closePage(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'website slots keep order and identity while selection expands in place and edits survive background metadata',
      (tester) async {
    await showPage(tester);
    Finder slot(String id) => find.byKey(ValueKey('tab-mac-a-$id'));
    List<String> order() => tester
        .widgetList<SizedBox>(find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(SizedBox)))
        .map((widget) => widget.key)
        .whereType<ValueKey<String>>()
        .map((key) => key.value)
        .where((key) => key.startsWith('tab-'))
        .toList();
    expect(tester.getCenter(find.byType(TextField)).dx,
        lessThan(tester.getCenter(find.text('Site B')).dx));
    final elements = [
      for (final id in ['a', 'b', 'c']) tester.element(slot(id))
    ];
    expect(order(), ['tab-mac-a-a', 'tab-mac-a-b', 'tab-mac-a-c']);
    await tester.tap(find.text('Site B'));
    await tester.pumpAndSettle();
    expect(order(), ['tab-mac-a-a', 'tab-mac-a-b', 'tab-mac-a-c']);
    expect(tester.getCenter(find.text('Site A')).dx,
        lessThan(tester.getCenter(find.byType(TextField)).dx));
    expect(tester.getCenter(find.byType(TextField)).dx,
        lessThan(tester.getCenter(find.text('Site C')).dx));
    expect(find.descendant(of: slot('a'), matching: find.text('Site A')),
        findsOneWidget);
    expect(find.descendant(of: slot('b'), matching: find.byType(TextField)),
        findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://b.example');
    expect([
      for (final id in ['a', 'b', 'c']) tester.element(slot(id))
    ], elements);
    await tester.enterText(
        find.byType(TextField), 'https://draft.example/typing');
    item.applyNative({
      'tabs': [
        {'id': 'a', 'url': 'https://a.example/new', 'title': 'Background A'},
        {'id': 'b', 'url': 'https://b.example/redirect', 'title': 'Selected B'},
        item.tabs[2].toJson(),
      ],
      'selected': 'b',
    });
    owner.signal();
    await tester.pumpAndSettle();
    expect(item.current.id, 'b');
    expect(find.descendant(of: slot('a'), matching: find.text('Background A')),
        findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://draft.example/typing');
    await closePage(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'web viewport reaches the bottom while sheets and keyboard keep their safe space',
      (tester) async {
    await showPage(tester);
    expect(tester.getRect(find.byType(UiKitView)).bottom, 900);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(
        tester
            .getRect(find.widgetWithText(FilledButton, 'Add computer'))
            .bottom,
        lessThanOrEqualTo(866));
    await tester.tapAt(const Offset(4, 200));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(UiKitView)).bottom, 650);
    await closePage(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
