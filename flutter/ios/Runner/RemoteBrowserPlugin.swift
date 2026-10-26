import Flutter
import UIKit

final class RemoteBrowserPlugin: NSObject, FlutterPlugin {
    private var closeBrowser: (() -> Void)?
    private var channel: FlutterMethodChannel?
    private var workspaces: [String: AnyObject] = [:]
    private var identities: [String: String] = [:]

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RemoteBrowserPlugin()
        let channel = FlutterMethodChannel(name: "rustdesk/remote-browser", binaryMessenger: registrar.messenger())
        plugin.channel = channel
        registrar.addMethodCallDelegate(plugin, channel: channel)
        registrar.register(BrowserWorkspaceFactory(plugin: plugin), withId: "rustdesk/browser-content")
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "workspaceSettings" {
            var supported = false
            if #available(iOS 17.0, *) { supported = true }
            let dev = supported && Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            if dev, let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: "remote-browser.workspace.enabled")
            }
            result(["dev": dev, "enabled": dev && UserDefaults.standard.bool(forKey: "remote-browser.workspace.enabled"),
                    "saved": UserDefaults.standard.string(forKey: "remote-browser.workspaces.v1") ?? ""])
            return
        }
        if call.method == "saveWorkspaces", let saved = call.arguments as? String {
            UserDefaults.standard.set(saved, forKey: "remote-browser.workspaces.v1"); result(nil); return
        }
        if call.method.hasPrefix("workspace") && call.method != "workspaceSettings" {
            guard #available(iOS 17.0, *), Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
                  let args = call.arguments as? [String: Any], let id = args["workspace"] as? String else {
                result(FlutterError(code: "unavailable", message: "Browser workspace is available in iOS Dev builds only.", details: nil)); return
            }
            if call.method == "workspaceSaveTabs", let identity = args["peerIdentity"] as? String,
               let urls = args["urls"] as? [String], workspaces[id] == nil {
                RemoteBrowserViewController.saveOfflineTabs(identity: identity, urls: urls, selected: args["selected"] as? Int ?? 0)
                result(nil); return
            }
            if call.method == "workspacePrepare" {
                guard let port = args["port"] as? Int, port > 0, port <= 65535,
                      let identity = args["peerIdentity"] as? String, !identity.isEmpty,
                      let username = args["username"] as? String, let password = args["password"] as? String, !password.isEmpty else {
                    result(FlutterError(code: "invalid", message: "Invalid browser endpoint.", details: nil)); return
                }
                guard identities[id] == nil || identities[id] == identity else {
                    result(FlutterError(code: "identity_changed", message: "Computer identity changed. Existing tabs were not rerouted.", details: nil)); return
                }
                identities[id] = identity
                if let existing = workspaces[id] as? RemoteBrowserViewController {
                    existing.reconnect(port: UInt16(port), username: username, password: password)
                    result(existing.workspaceState())
                } else {
                    let browser = RemoteBrowserViewController(peer: id, identity: identity, port: UInt16(port), username: username, password: password, initialURL: nil, embedded: true)
                    browser.onState = { [weak self] state in self?.channel?.invokeMethod("workspaceState", arguments: ["workspace": id, "state": state]) }
                    workspaces[id] = browser
                    browser.loadViewIfNeeded()
                    result(browser.workspaceState())
                }
                return
            }
            guard let browser = workspaces[id] as? RemoteBrowserViewController else { result(nil); return }
            browser.workspaceCommand(args["command"] as? String ?? "", tabID: args["tab"] as? String, value: args["value"] as? String)
            result(browser.workspaceState()); return
        }
        if call.method == "available" {
            if #available(iOS 17.0, *) { result(true) } else { result(false) }
            return
        }
        if call.method == "close" { closeBrowser?(); result(nil); return }
        guard call.method == "open" else { result(FlutterMethodNotImplemented); return }
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "unavailable", message: "Remote browser requires iOS 17 or later.", details: nil)); return
        }
        guard closeBrowser == nil, let presenter = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController, presenter.presentedViewController == nil,
              let args = call.arguments as? [String: Any],
              let port = args["port"] as? Int, port > 0, port <= 65535,
              let identity = args["peerIdentity"] as? String, !identity.isEmpty,
              let peer = args["peer"] as? String,
              let username = args["username"] as? String,
              let password = args["password"] as? String, !password.isEmpty else {
            result(FlutterError(code: "invalid", message: "Cannot open remote browser.", details: nil)); return
        }
        let url = (args["url"] as? String).flatMap(RemoteBrowserViewController.webURL)
        let browser = RemoteBrowserViewController(peer: peer, identity: identity, port: UInt16(port), username: username, password: password, initialURL: url)
        let navigation = UINavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .fullScreen
        closeBrowser = { [weak browser] in browser?.finish() }
        browser.onClose = { [weak self] in self?.closeBrowser = nil; result(nil) }
        presenter.present(navigation, animated: true)
    }
}


private final class BrowserWorkspaceFactory: NSObject, FlutterPlatformViewFactory {
    private let plugin: RemoteBrowserPlugin
    init(plugin: RemoteBrowserPlugin) { self.plugin = plugin }
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        if #available(iOS 17.0, *), let id = (args as? [String: Any])?["workspace"] as? String,
           let browser = plugin.workspace(id) {
            browser.workspaceCommand("visibility", tabID: nil, value: (args as? [String: Any])?["visible"] as? Bool == true ? "true" : "false")
            return BrowserWorkspaceView(frame: frame, browser: browser, presenter: UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController)
        }
        return BrowserEmptyView()
    }
}

extension RemoteBrowserPlugin {
    @available(iOS 17.0, *)
    fileprivate func workspace(_ id: String) -> RemoteBrowserViewController? { workspaces[id] as? RemoteBrowserViewController }
}

private final class BrowserEmptyView: NSObject, FlutterPlatformView {
    private let content = UIView()
    func view() -> UIView { content }
}

@available(iOS 17.0, *)
private final class BrowserWorkspaceView: NSObject, FlutterPlatformView {
    private let content: UIView
    private let browser: RemoteBrowserViewController
    init(frame: CGRect, browser: RemoteBrowserViewController, presenter: UIViewController?) {
        content = UIView(frame: frame)
        self.browser = browser
        super.init()
        browser.willMove(toParent: nil)
        browser.view.removeFromSuperview()
        browser.removeFromParent()
        presenter?.addChild(browser)
        browser.view.frame = content.bounds
        browser.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(browser.view)
        browser.didMove(toParent: presenter)
    }
    func view() -> UIView { content }
    deinit {
        if browser.view.superview === content {
            browser.view.endEditing(true)
            browser.willMove(toParent: nil)
            browser.view.removeFromSuperview()
            browser.removeFromParent()
        }
    }
}
