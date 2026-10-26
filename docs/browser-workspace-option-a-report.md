# Option A iOS browser workspace implementation

Current review state: the workspace implementation and follow-up UI fixes are complete through `e1a82bea8`. Physical iPad Air testing confirmed that the host picker, tabs, bookmarks and workspace menu stay open after the synthetic status-bar tap fix. The clean signed Dev build was installed; its automatic relaunch timed out. The sections below preserve the original implementation and installation checkpoints; their pending-acceptance statements are superseded only by the specific results in the final validation section.

Application source commit: `17997209f252801368e5ed9256d5a62ad5d7ff2e`, based on `bb1a75cb1` on the Remote-Browser branch. This report records implementation and local validation; physical-device acceptance remains with the coordinator.

## Delivered behavior

- Dev-only, persisted iOS/iPadOS opt-in on Connections: **Browser workspace preview**. Opted-in startup enters the last selected computer workspace. Release and unsupported iOS versions retain the existing paths.
- One responsive toolbar with the selected website address and computer picker, inactive title/close tabs when space permits, Back/Forward, reload/stop, New tab, bookmarks, overview and secondary menu actions. Compact phones use the overview for other tabs.
- New tab page with per-computer favorites/bookmarks, recent pages, Add/Switch computer, Connect/Reconnect and Open desktop. Connection failures remain visible even on blank tabs.
- Dedicated browser FFI/tunnel owner retained outside route lifetime. Explicit disconnect stops WebKit loads and the browser tunnel while retaining website views, saved metadata and cookies. Reconnect updates the existing profile's SOCKS endpoint without direct-network failover.
- Native WKWebViews embedded through the existing Flutter engine's platform-view registrar. WebKit owns navigation and popup configurations. Website views and live Back/Forward survive workspace/tab switches; Flutter receives presentation state, not a second navigation stack.
- A retained Flutter RemotePage Desktop tab using the existing Control Pad, keyboard and touch implementation. Hiding it releases keys/modifiers/mouse buttons, mouse listening and focus, unmounts input/gesture widgets, and gates deferred touch actions. Closing Desktop ends only screen sharing. Closing websites preserves Desktop; the last website close leaves a blank tab.
- One live Desktop across the app. Existing iOS desktop entry routes enter this shell when opted in. A second host requires an explicit End and open confirmation and waits for the old gFFI teardown before constructing the replacement.
- Existing browser deep links select their requested computer and open a website there. Address submission navigates the selected website, including after reconnect. Desktop entry retains its requested peer and authentication options.
- Browser authentication/error close actions use an explicit browser operation owner; they do not end an unrelated retained Desktop or pop the shell.

## Persistence and migration

`profileID(for: peerIdentity)` is unchanged, including its `rustdesk.remote-browser.v1\0` SHA256 input. Existing `remote-browser.tabs.<profile UUID>`, `remote-browser.bookmarks.<profile UUID>` and `remote-browser.desktop.<profile UUID>` mappings and `SavedTabs {urls, selected}` encoding remain unchanged. The original reader restores old saved tabs/bookmarks into embedded workspaces on first authenticated connection; no cookie store is reset or replaced.

New metadata is additive: `remote-browser.workspaces.v1` stores saved computers, last workspace, website selection/URLs/titles, bookmarks and recents for presentation before connection; recents also use the existing native tab key plus `.recents`. Offline tab close/selection/new-blank changes write the original native SavedTabs encoding under the saved peer identity. Native tab IDs identify live views only and do not replace profile IDs. Native commands reject stale tab IDs and an existing workspace's identity change, rather than rerouting another host's views.

No SOCKS credentials, browser endpoint credentials or desktop passwords are serialized. Desktop sessions and live loading/navigation state are not restored after process termination. Restart restores website URLs/selection/bookmarks/data, with explicit connection when needed; it does not promise a full Back/Forward stack or reconnect Desktop automatically.

## Validation

All commands ran in this child workspace, using the installed `/Volumes/Users/kylefang/flutter-3.24.5` SDK. No bridge code generation, Rust rebuild, device install, host stop, GitHub push/PR, release bundle/version edit or TestFlight upload occurred.

### Flutter tests

From `flutter/`:

```sh
/Volumes/Users/kylefang/flutter-3.24.5/bin/flutter test --no-pub \
  test/browser_workspace_test.dart test/remote_browser_link_test.dart \
  test/control_pad_model_test.dart test/control_pad_overlay_test.dart \
  test/input_modifier_utils_test.dart test/keyboard_shortcuts_test.dart
```

Result: **53 passed**, exit 0. Log: `/tmp/browser-workspace-tests.log`. The existing Control Pad tests log mock/plugin callback errors, but the suite reports all tests passed. Five added model tests cover workspace isolation/selection, website/Desktop close independence, one-Desktop enforcement, restart metadata without Desktop/credentials, and deep-link computer ownership.

### Analyzer

```sh
/Volumes/Users/kylefang/flutter-3.24.5/bin/dart analyze \
  flutter/lib/models/browser_workspace.dart \
  flutter/lib/mobile/browser/browser_workspace_controller.dart \
  flutter/lib/mobile/pages/browser_workspace_page.dart \
  flutter/lib/mobile/pages/remote_browser_page.dart \
  flutter/lib/mobile/pages/remote_page.dart \
  flutter/lib/mobile/pages/home_page.dart \
  flutter/lib/mobile/pages/connection_page.dart \
  flutter/lib/common/widgets/remote_input.dart
```

Result: exit 0, no errors or warnings; deprecation/style info remains. Log: `/tmp/browser-workspace-focused-analyzer.log`. Including `flutter/lib/common.dart` returns exit 2 solely for its pre-existing unused `dart:math` import, plus info diagnostics; no errors. Full log: `/tmp/browser-workspace-analyzer.log`. The import is untouched to avoid unrelated cleanup.

### Swift typecheck

```sh
xcrun swiftc -typecheck -target arm64-apple-ios13.0 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -F /Volumes/Users/kylefang/flutter-3.24.5/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64 \
  flutter/ios/Runner/RemoteBrowserPlugin.swift \
  flutter/ios/Runner/RemoteBrowserViewController.swift \
  flutter/ios/Runner/RemoteBrowserLoopback.swift
```

Result: exit 0, no diagnostics. Log: `/tmp/browser-workspace-swift.log`. The platform-view composition API compiles with the pinned Flutter framework and the project's iOS 13 target. This is compile evidence, not a physical-device composition/input result.

### iOS Dev builds and signed artifact

Unsigned Debug build succeeded, then the signed standalone Profile Dev build succeeded from application source commit `17997209f252801368e5ed9256d5a62ad5d7ff2e`:

```sh
xcodebuild -workspace flutter/ios/Runner.xcworkspace -scheme Runner \
  -configuration Profile -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/browser-workspace-profile \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 DEVELOPMENT_TEAM=7CRYNR44B3 \
  CODE_SIGN_STYLE=Automatic \
  PODS_ROOT=/Volumes/Users/kylefang/orca/workspaces/rustdesk/Browser-Workspace-A/flutter/ios/Pods
```

The installed Xcode 27.1 rejects the existing app iOS 13/Pods iOS 11 build targets, so the local build uses a command-line minimum override only. No project/Podfile minimum or signing change is committed. The pinned native code also typechecks at iOS 13, as shown above. A nonfatal Flutter `NSBonjourServices` plist query diagnostic appears in the successful build log.

- Final build log: `/tmp/browser-workspace-profile-build.log` (`BUILD SUCCEEDED`).
- App: `/tmp/browser-workspace-profile/Build/Products/Profile-iphoneos/Runner.app`.
- Signing time: **2026-10-26 18:20:56 Asia/Singapore**.
- Verified bundle: `app.reily.rustdesk.dev`; display name: `RustDesk Dev`; team: `7CRYNR44B3`; version/build unchanged: `1.5.1 (72)`.
- `codesign --verify --deep --strict` passed.
- Runner SHA256: `4e7f2c949af89f84a9e39db468ff2f13b6b605cde45ff9bbfeb671d487ab56a5`.
- `Frameworks/App.framework/App` SHA256: `df33a2436190ce33902c61f4bab027e6b516f24665ed5019c90dc4ef4269af0d`.

Ignored build dependencies were reused from the parent (generated Dart bridges, plugin headers, CocoaPods dependencies and prebuilt Rust static library); Pods were copied locally for builds and build-only lock/workspace edits were reverted. The parent's generated Pods manifest was left matching its original Podfile.lock. No generated bridge or build artifacts are committed.

## Mandatory regression-surface/minimization review

Reviewed every modified existing file and path; only the following existing paths change:

| Existing file | Required behavior change and boundary |
| --- | --- |
| `flutter/ios/Runner/RemoteBrowserPlugin.swift` | Register platform-view factory on the same engine and route explicit workspace commands/events/settings. Existing `available`, modal `open` and `close` paths remain. |
| `flutter/ios/Runner/RemoteBrowserViewController.swift` | Optional embedded layout, live tab IDs/state, native workspace commands/reconnect, recents and embedded visibility/dialog gating. Original profile mapping, SavedTabs/bookmark readers, routing, popup configuration, native navigation and modal chrome remain. Additional history KVO and state emission are embedded-only. |
| `flutter/lib/common.dart` | Thin opted-in iOS desktop-entry hook and a nullable shell close hook for existing shared mobile session dialogs. Feature-off/other-platform routing and close behavior use the original implementation. |
| `flutter/lib/common/widgets/remote_input.dart` | Optional callback on the touch region and checks at callback/queued/post-await boundaries, preventing hidden embedded gestures from sending delayed presses/moves. Null callback preserves existing behavior; no gesture algorithm/state was rewritten. |
| `flutter/lib/mobile/pages/remote_page.dart` | Optional embedded/input visibility/close/disposal hooks. The new path retains the session state while its input subtree is hidden; teardown remains the existing gFFI teardown. Standalone constructor defaults and Control Pad/keyboard/touch behavior remain. |
| `flutter/lib/mobile/pages/remote_browser_page.dart` | Opted-in entry delegates to the new shell. Original transient modal route/transport implementation remains feature-off. |
| `flutter/lib/mobile/pages/home_page.dart` | Post-frame startup entry only when the supported Dev opt-in is enabled. Original Home page stays underneath for Connections/settings. |
| `flutter/lib/mobile/pages/connection_page.dart` | Visible Dev-only preview toggle/entry. Original peer connection and remote-browser entry remain. |

New shell, transport ownership and metadata logic live in browser-specific files. No Rust, host SOCKS/loopback/protocol, native loopback script/extension, AppDelegate/engine, release identity/version, localization, dependency or submodule changes are included. Existing shared paths were not refactored to share implementation. `git diff --check` passes.

## Remaining acceptance and limits

The coordinator owns physical iPad Air/iPhone install and acceptance. I did not run native UI automation, take device screenshots, test real Google/localhost WebCrypto/cookies, verify hardware keyboard/Control Pad on the device, test two real hosts, orientation/backgrounding, or WebKit memory pressure. The signed Profile app above is ready for that work; no simulator/device run is claimed.

Expected first-delivery limits remain: iOS/iPadOS only (remote browser iOS 17+, localhost routing iOS 18.4+), one live Desktop, 32 websites per native workspace, no full Back/Forward persistence across restart, and explicit reload if WebKit terminates a content process. Bookmark management requires a connected website surface; saved bookmarks/favorites remain readable and openable while disconnected. Existing cookie/profile migration is implemented but still needs the coordinator's before/after device-storage and login check. No new Mac browser client or production release is included.

## Coordinator integration and iPad installation

Reviewed the implementation diff and validation report, verified the signed app's bundle identifier and both executable hashes above, and fast-forwarded the current `Remote-Browser` workspace through `ef127c709`. `git diff bb1a75cb1 HEAD --check` passed. The supervised worker reported success and was released; its child workspace and commits remain available. The pre-existing untracked `design/` mockups were preserved.

Installed the final signed Profile app on the physical iPad Air (`00008122-001C38680CE1801C`) using `xcrun devicectl device install app`. Independent installed-app queries confirm that both `app.reily.rustdesk.dev` (RustDesk Dev) and `app.reily.rustdesk` (RustDesk/TestFlight), each version `1.5.1 (72)`, remain installed separately. No GitHub push, TestFlight upload, production bundle replacement, or Mac host restart occurred. The existing Mac host remained listening on port 21118.

Compared the Dev app's browser preferences before and after installation: its existing native saved-tab key and value were preserved byte-for-byte (one saved website tab). This proves preservation through installation, not a completed browser login/cookie or live-tab restoration test.

Device launch succeeded, and a subsequent process query confirmed the installed executable running as PID 23273. The test launch used Apple's temporary argument-domain preference override `-remote-browser.workspace.enabled YES` and the existing browser deep-link entry for the Mac's localhost page. This does not persist the preview opt-in; the normal persistent control is **Connections → Browser workspace preview**.

Physical visual acceptance is still pending. The iPad subsequently reported `passcodeRequired: true`; a developer screenshot was entirely black and is not evidence of a rendered screen or of an application crash. The device debug transports were also intermittently unavailable. No successful on-device Google/localhost/WebCrypto, touch, keyboard, Desktop switching, or two-host test is claimed. An app launch console remains in Orca terminal `term_144a153b-ecc3-413e-92c7-67be62850c1f` for the pending awake-device check.

Coordinator evidence is local in `/tmp/rd-option-a-validation/`: `install.json`, `launch.json`, `process-after-launch.json`, `dev-app-installed.json`, `release-app-installed.json`, and `storage-preservation-after-install.json`. Raw preference snapshots remain private local debugging files and were not published. The Mac's localhost page responded in the coordinator's desktop-browser baseline; that is not a substitute for the pending iPad network check.

## Final UI fixes and device acceptance

Website tabs now keep their keyed position when selected, so the selected address editor replaces its own tab in place instead of moving other titles between slots. The browser viewport fills the bottom safe area; the embedded Desktop keeps safe insets for its controls. Page regressions cover tab ordering, address edits, viewport size and keyboard insets.

The disappearing panels were actual Navigator pops. Flutter 3.24.5's iOS engine converts status-bar scroll-to-top requests into touch Down/Up events at `(0, 0)` with device ID zero. iPadOS generated that event about 350 milliseconds after opening the host picker, causing its modal barrier to dismiss it. The browser workspace now consumes only that exact event while a panel is open, using its existing panel-coverage flag and a stateless gesture-arena member. Normal outside taps, sheet drags and Escape still dismiss panels. The ineffective web-content Offstage workaround and all temporary diagnostics were removed.

Primary sources: [pinned engine implementation](https://github.com/flutter-team-archive/engine/blob/3.24.5/shell/platform/darwin/ios/framework/Source/FlutterViewController.mm#L516), [upstream issue](https://github.com/flutter/flutter/issues/177992), and [upstream fix](https://github.com/flutter/flutter/pull/182391). Intentional status-bar scroll-to-top is ignored while a workspace panel is open; without a panel, the filter does nothing.

The regression fails on the old implementation and passes with the fix for all four panel types. Physical iPad testing explicitly confirmed that the host picker, tabs, bookmarks and workspace menu stay open. The device trace also recorded the exact synthetic event being rejected, followed by ordinary outside-tap dismissal.

The final code passed 24 focused Flutter tests, analyzer checks with no errors or warnings (three existing informational lints), a signed Profile iOS build and deep strict signature verification. The clean `app.reily.rustdesk.dev` build was installed alongside the existing production app; automatic relaunch timed out, so foreground launch of that clean artifact is unconfirmed. Device acceptance used the same fix with temporary tracing enabled. No TestFlight release or production bundle/version change was made.

PR preparation reran the complete selected browser/input suite on the integrated branch: **56 passed**, exit 0. This includes `browser_workspace_page_test.dart`, `browser_workspace_test.dart`, `remote_browser_link_test.dart`, `control_pad_model_test.dart`, `control_pad_overlay_test.dart`, `input_modifier_utils_test.dart` and `keyboard_shortcuts_test.dart`, using `flutter test --no-pub` from `flutter/`. Existing Control Pad mock/plugin callback diagnostics remain in the passing test output.

The final panel fix changes runtime behavior only in `browser_workspace_page.dart`, with a new `browser_status_bar_tap.dart` helper and an updated page regression. Its callback exists only while the browser workspace is mounted. The broader feature's shared-file regression surface is listed above; existing native proxy/localhost/WebCrypto logic and feature-off routing remain unchanged. Real two-host operation, cookie/login migration, hardware-keyboard and Control Pad interaction, background/orientation changes and WebKit memory pressure remain broader acceptance limits.
