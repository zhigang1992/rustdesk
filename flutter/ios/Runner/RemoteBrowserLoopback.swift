import WebKit

@available(iOS 17.0, *)
enum RemoteBrowserLoopback {
    private static let hosts = [
        "localhost": "localhost.rustdesk.localhost",
        "127.0.0.1": "ipv4.rustdesk.localhost",
        "[::1]": "ipv6.rustdesk.localhost",
    ]

    static func url(_ url: URL, remote: Bool) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), ["http", "https", "ws", "wss"].contains(parts.scheme?.lowercased() ?? "") else { return url }
        let names = remote ? hosts : Dictionary(uniqueKeysWithValues: hosts.map { ($1, $0) })
        guard let replacement = names[host == "localhost." ? "localhost" : host] else { return url }
        parts.host = replacement
        return parts.url ?? url
    }

    // Rewrite before the browser computes same-origin credentials; engine rules also cover worker fetches and subresources.
    static let script = #"""
    (() => {
      const names = {'localhost':'localhost.rustdesk.localhost', 'localhost.':'localhost.rustdesk.localhost',
        '127.0.0.1':'ipv4.rustdesk.localhost', '[::1]':'ipv6.rustdesk.localhost'};
      const map = value => {
        const text = String(value);
        let url;
        try { url = new URL(text, location.href); } catch (_) { return text; }
        if (/^(https?|wss?):$/.test(url.protocol) && names[url.hostname]) {
          url.hostname = names[url.hostname]; return url.href;
        }
        return text;
      };
      const fetch = globalThis.fetch;
      globalThis.fetch = function(input, init) {
        if (input instanceof Request) {
          const url = map(input.url);
          // Rebuilding a Request exposes its body as a stream, which WebKit cannot upload.
          if (url !== input.url && new URL(url).origin === location.origin &&
              (init?.credentials ?? input.credentials) === 'same-origin') {
            init = {...init, credentials: 'include'};
          }
        } else input = map(input);
        return Reflect.apply(fetch, this, [input, init]);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        return Reflect.apply(open, this, [method, map(url), ...rest]);
      };
      for (const name of ['WebSocket', 'EventSource', 'Worker', 'SharedWorker']) {
        const Original = globalThis[name];
        if (Original) globalThis[name] = new Proxy(Original, {
          construct(target, args, newTarget) {
            if (args.length) args[0] = map(args[0]);
            return Reflect.construct(target, args, newTarget);
          }
        });
      }
    })();
    """#
}

@available(iOS 18.4, *)
final class RemoteBrowserRouting: NSObject, WKWebExtensionControllerDelegate {
    private final class Tab: NSObject, WKWebExtensionTab {
        weak var view: WKWebView?
        init(_ view: WKWebView) { self.view = view }
        func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    }

    private let controller: WKWebExtensionController
    private var context: WKWebExtensionContext?
    private var completion: ((Error?) -> Void)?

    init(store: WKWebsiteDataStore) {
        let config = WKWebExtensionController.Configuration.nonPersistent()
        config.defaultWebsiteDataStore = store
        controller = WKWebExtensionController(configuration: config)
        super.init()
        controller.delegate = self
    }

    func prepare(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                guard let base = Bundle.main.resourceURL?.appendingPathComponent("RemoteBrowserExtension") else {
                    throw NSError(domain: "RemoteBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Remote browser routing resources are missing."])
                }
                let webExtension = try await WKWebExtension(resourceBaseURL: base)
                let context = WKWebExtensionContext(for: webExtension)
                context.uniqueIdentifier = "rustdesk-remote-loopback-v1"
                context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
                context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
                self.context = context
                try controller.load(context)
                try await context.loadBackgroundContent()
            } catch { complete(error) }
        }
    }

    func configure(_ config: WKWebViewConfiguration) {
        config.webExtensionController = controller
        config.userContentController.addUserScript(WKUserScript(source: RemoteBrowserLoopback.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func opened(_ web: WKWebView) -> NSObject {
        let tab = Tab(web)
        controller.didOpenTab(tab)
        return tab
    }

    func closed(_ object: NSObject?) {
        if let tab = object as? Tab { controller.didCloseTab(tab, windowIsClosing: false) }
    }

    private func complete(_ error: Error?) {
        let callback = completion
        completion = nil
        callback?(error)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for context: WKWebExtensionContext, replyHandler: @escaping (Any?, Error?) -> Void) {
        guard context === self.context, let message = message as? [String: Any] else { replyHandler(nil, nil); return }
        replyHandler(nil, nil)
        if let error = message["error"] as? String {
            complete(NSError(domain: "RemoteBrowser", code: 2, userInfo: [NSLocalizedDescriptionKey: error]))
        } else if message["ready"] as? Bool == true { complete(nil) }
    }
}
