import UIKit
import WebKit
import Network
import CryptoKit

@available(iOS 17.0, *)
final class RemoteBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private final class Tab {
        let webView: WKWebView
        var observations: [NSKeyValueObservation] = []
        init(_ webView: WKWebView) { self.webView = webView }
    }

    private struct SavedTabs: Codable {
        let urls: [String]
        let selected: Int
    }

    var onClose: (() -> Void)?
    private let store: WKWebsiteDataStore
    private let storageKey: String
    private let initialURL: URL?
    private var tabs: [Tab] = []
    private var selected = 0
    private var finished = false
    private let tabStrip = UIStackView()
    private let address = UITextField()
    private let content = UIView()
    private let status = UILabel()
    private var backButton: UIBarButtonItem!
    private var forwardButton: UIBarButtonItem!
    private var reloadButton: UIBarButtonItem!

    static func profileID(for identity: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(("rustdesk.remote-browser.v1\0" + identity).utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    init(peer: String, identity: String, port: UInt16, username: String, password: String, initialURL: URL?) {
        let profileID = Self.profileID(for: identity)
        store = WKWebsiteDataStore(forIdentifier: profileID)
        storageKey = "remote-browser.tabs." + profileID.uuidString
        self.initialURL = initialURL
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.allowFailover = false
        proxy.matchDomains = []
        proxy.excludedDomains = []
        proxy.applyCredential(username: username, password: password)
        store.proxyConfigurations = [proxy]
        super.init(nibName: nil, bundle: nil)
        title = "Browser · " + peer
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finish))
        let layout = UIStackView()
        layout.axis = .vertical
        layout.spacing = 6
        layout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        tabStrip.axis = .horizontal
        tabStrip.spacing = 5
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 42),
            tabStrip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            tabStrip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            tabStrip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            tabStrip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        layout.addArrangedSubview(scroll)
        address.borderStyle = .roundedRect
        address.keyboardType = .URL
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.returnKeyType = .go
        address.clearButtonMode = .whileEditing
        address.placeholder = "URL on remote Mac"
        address.accessibilityLabel = "Address"
        address.delegate = self
        address.heightAnchor.constraint(equalToConstant: 42).isActive = true
        layout.addArrangedSubview(address)
        layout.addArrangedSubview(content)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        status.font = .preferredFont(forTextStyle: .caption1)
        status.textColor = .secondaryLabel
        status.text = "Web traffic via remote Mac"
        layout.addArrangedSubview(status)
        let toolbar = UIToolbar()
        backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(goBack))
        backButton.accessibilityLabel = "Back"
        forwardButton = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: self, action: #selector(goForward))
        forwardButton.accessibilityLabel = "Forward"
        reloadButton = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload))
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addBlankTab))
        add.accessibilityLabel = "New tab"
        toolbar.items = [backButton, .flexibleSpace(), forwardButton, .flexibleSpace(), reloadButton, .flexibleSpace(), add]
        layout.addArrangedSubview(toolbar)

        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) {
            for text in saved.urls.prefix(32) {
                _ = addTab(url: Self.webURL(text))
            }
            if !tabs.isEmpty { selectTab(min(max(saved.selected, 0), tabs.count - 1)) }
        }
        if let url = initialURL { _ = addTab(url: url) }
        if tabs.isEmpty { _ = addTab() }
    }

    private var current: WKWebView? { tabs.indices.contains(selected) ? tabs[selected].webView : nil }

    @discardableResult
    private func addTab(configuration: WKWebViewConfiguration? = nil, url: URL? = nil) -> WKWebView? {
        guard tabs.count < 32 else {
            status.text = "Close a tab before opening another (32 tab limit)."
            return nil
        }
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        let tab = Tab(web)
        tab.observations = [
            web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.refresh() },
            web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.refresh() },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.refresh() },
        ]
        tabs.append(tab)
        selectTab(tabs.count - 1)
        if let url = url { web.load(URLRequest(url: url)) }
        return web
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = index
        content.subviews.forEach { $0.removeFromSuperview() }
        let web = tabs[index].webView
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor), web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        refresh()
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].webView.stopLoading()
        tabs[index].webView.removeFromSuperview()
        tabs.remove(at: index)
        if index < selected { selected -= 1 }
        selected = min(selected, max(tabs.count - 1, 0))
        saveTabs()
        if tabs.isEmpty { finish() } else { selectTab(selected) }
    }

    private func saveTabs() {
        let state = SavedTabs(urls: tabs.map { $0.webView.url?.absoluteString ?? "about:blank" }, selected: selected)
        do { UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: storageKey) }
        catch { status.text = "Could not save browser tabs: " + error.localizedDescription }
    }

    private func refresh() {
        guard isViewLoaded, !finished else { return }
        if !address.isFirstResponder { address.text = current?.url?.absoluteString }
        backButton.isEnabled = current?.canGoBack == true
        forwardButton.isEnabled = current?.canGoForward == true
        tabStrip.arrangedSubviews.forEach { tabStrip.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let row = UIStackView()
            row.layer.cornerRadius = 7
            row.backgroundColor = index == selected ? .tertiarySystemFill : .secondarySystemBackground
            let button = UIButton(type: .system)
            button.setTitle(tab.webView.title?.isEmpty == false ? tab.webView.title : (tab.webView.url?.host ?? "New tab"), for: .normal)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.widthAnchor.constraint(equalToConstant: 145).isActive = true
            button.accessibilityLabel = "Select tab \(index + 1)"
            button.addAction(UIAction { [weak self] _ in self?.selectTab(index) }, for: .touchUpInside)
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.widthAnchor.constraint(equalToConstant: 32).isActive = true
            close.accessibilityLabel = "Close tab \(index + 1)"
            close.addAction(UIAction { [weak self] _ in self?.closeTab(index) }, for: .touchUpInside)
            row.addArrangedSubview(button)
            row.addArrangedSubview(close)
            tabStrip.addArrangedSubview(row)
        }
        saveTabs()
    }

    @objc private func addBlankTab() { _ = addTab(); address.becomeFirstResponder() }
    @objc private func goBack() { current?.goBack() }
    @objc private func goForward() { current?.goForward() }
    @objc private func reload() { current?.reload() }

    @objc func finish() {
        guard !finished else { return }
        finished = true
        saveTabs()
        for tab in tabs { tab.webView.stopLoading() }
        let completion = onClose
        dismiss(animated: true) { completion?() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        var text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.contains("://") {
            let local = text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = Self.webURL(text) else { status.text = "Enter an HTTP or HTTPS URL without credentials."; return false }
        textField.resignFirstResponder()
        status.text = "Web traffic via remote Mac"
        current?.load(URLRequest(url: url))
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.webURL(url.absoluteString) != nil || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            status.text = "This browser supports HTTP and HTTPS navigation."
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return addTab(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) { closeTab(index) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    private func show(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.text = error.localizedDescription }
    }
}
