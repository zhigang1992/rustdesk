import Flutter
import UIKit

final class RemoteBrowserPlugin: NSObject, FlutterPlugin {
    private var closeBrowser: (() -> Void)?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = RemoteBrowserPlugin()
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "rustdesk/remote-browser", binaryMessenger: registrar.messenger()))
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
