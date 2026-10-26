import UIKit
import WebKit
import Network
import CryptoKit

@available(iOS 17.0, *)
final class RemoteBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private final class Tab {
        let webView: WKWebView
        let id = UUID().uuidString
        let row = UIStackView()
        let button = UIButton(type: .system)
        let address = UITextField()
        let close = UIButton(type: .system)
        var width: NSLayoutConstraint?
        var observations: [NSKeyValueObservation] = []
        var routingTab: NSObject?
        init(_ webView: WKWebView) { self.webView = webView }
    }

    private struct SavedTabs: Codable {
        let urls: [String]
        let selected: Int
    }

    private struct Bookmark: Codable {
        var title: String
        var url: String
    }

    var onClose: (() -> Void)?
    var onState: (([String: Any]) -> Void)?
    private let embedded: Bool
    private var recents: [Bookmark] = []
    private var restored = false
    private var workspaceVisible = true
    private let store: WKWebsiteDataStore
    private let storageKey: String
    private let bookmarksKey: String
    private let desktopKey: String
    private let peer: String
    private let initialURL: URL?
    private var tabs: [Tab] = []
    private var bookmarks: [Bookmark] = []
    private var selected = 0
    private var finished = false
    private var desktopMode: Bool
    private var routing: NSObject?
    private let bar = UIStackView()
    private let tabScroll = UIScrollView()
    private let tabStrip = UIStackView()
    private let content = UIView()
    private let message = UILabel()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let bookmarksButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

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

    static func addressURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") { return webURL(text) }
        let local = text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]")
        return webURL((local ? "http://" : "https://") + text)
    }

    static func allowsNavigation(_ url: URL, mainFrame: Bool) -> Bool {
        if webURL(url.absoluteString) != nil { return true }
        switch url.scheme?.lowercased() {
        case "about":
            let page = url.absoluteString.lowercased().split(separator: "#", maxSplits: 1).first
            return page == "about:blank" || page == "about:srcdoc"
        case "blob": return true
        case "data": return !mainFrame
        default: return false
        }
    }

    init(peer: String, identity: String, port: UInt16, username: String, password: String, initialURL: URL?, embedded: Bool = false) {
        let profileID = Self.profileID(for: identity)
        store = WKWebsiteDataStore(forIdentifier: profileID)
        storageKey = "remote-browser.tabs." + profileID.uuidString
        bookmarksKey = "remote-browser.bookmarks." + profileID.uuidString
        desktopKey = "remote-browser.desktop." + profileID.uuidString
        self.embedded = embedded
        self.peer = peer
        self.initialURL = initialURL
        desktopMode = UserDefaults.standard.object(forKey: desktopKey) as? Bool ?? (UIDevice.current.userInterfaceIdiom == .pad)
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) { bookmarks = saved }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.allowFailover = false
        proxy.matchDomains = []
        proxy.excludedDomains = []
        proxy.applyCredential(username: username, password: password)
        store.proxyConfigurations = [proxy]
        super.init(nibName: nil, bundle: nil)
        if let data = UserDefaults.standard.data(forKey: storageKey + ".recents"),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) { recents = saved }
    }

    required init?(coder: NSCoder) { return nil }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
        view.backgroundColor = .systemBackground
        bar.spacing = 2
        bar.alignment = .center
        bar.accessibilityIdentifier = "Browser bar"
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        configure(backButton, symbol: "chevron.left", label: "Back", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.right", label: "Forward", action: #selector(goForward))
        configure(reloadButton, symbol: "arrow.clockwise", label: "Reload", action: #selector(reload))
        bar.addArrangedSubview(backButton)
        bar.addArrangedSubview(forwardButton)
        bar.addArrangedSubview(reloadButton)
        tabScroll.showsHorizontalScrollIndicator = false
        tabStrip.axis = .horizontal
        tabStrip.spacing = 4
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.heightAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 44),
        ])
        tabScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(tabScroll)
        let add = UIButton(type: .system)
        configure(add, symbol: "plus", label: "New tab", action: #selector(addBlankTab))
        bar.addArrangedSubview(add)
        configure(bookmarksButton, symbol: "book", label: "Bookmarks")
        bookmarksButton.showsMenuAsPrimaryAction = true
        bar.addArrangedSubview(bookmarksButton)
        configure(moreButton, symbol: "ellipsis.circle", label: "Browser menu")
        moreButton.showsMenuAsPrimaryAction = true
        bar.addArrangedSubview(moreButton)
        let done = UIButton(type: .system)
        configure(done, symbol: "xmark.circle", label: "Close browser", action: #selector(finish))
        bar.addArrangedSubview(done)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 44),
            content.topAnchor.constraint(equalTo: embedded ? view.topAnchor : bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bar.isHidden = embedded
        message.font = .preferredFont(forTextStyle: .body)
        message.textColor = .secondaryLabel
        message.backgroundColor = .secondarySystemBackground
        message.numberOfLines = 0
        message.textAlignment = .center
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])

        if #available(iOS 18.4, *) {
            let routing = RemoteBrowserRouting(store: store)
            self.routing = routing
            showMessage("Preparing remote browser…")
            routing.prepare { [weak self] error in
                guard let self = self, !self.finished else { return }
                if let error = error { self.showMessage("Could not prepare remote browsing: " + error.localizedDescription) }
                else { self.restoreTabs() }
            }
        } else { restoreTabs() }
    }

    private func restoreTabs() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) {
            for text in saved.urls.prefix(32) { _ = addTab(url: Self.webURL(text)) }
            if !tabs.isEmpty { selectTab(min(max(saved.selected, 0), tabs.count - 1)) }
        }
        if let url = initialURL { _ = addTab(url: url) }
        if tabs.isEmpty { _ = addTab() }
        restored = true
        if embedded { refresh() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.bounds.width < 600
        forwardButton.isHidden = compact
        reloadButton.isHidden = compact
        for (index, tab) in tabs.enumerated() {
            let available = max(140, tabScroll.bounds.width)
            let width = tabs.count == 1 ? available : min(index == selected ? 380 : 240, available)
            if tab.width?.constant != width { tab.width?.constant = width }
        }
    }

    private func configure(_ button: UIButton, symbol: String, label: String, action: Selector? = nil) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if let action = action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    private var current: WKWebView? { tabs.indices.contains(selected) ? tabs[selected].webView : nil }

    @discardableResult
    private func addTab(configuration: WKWebViewConfiguration? = nil, url: URL? = nil) -> WKWebView? {
        guard tabs.count < 32 else {
            showMessage("Close a tab before opening another (32 tab limit).")
            return nil
        }
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            config.websiteDataStore = store
            let version = ProcessInfo.processInfo.operatingSystemVersion
            // Bare WKWebView omits the browser version tokens used by sites for browser layouts.
            let safariVersion = desktopMode ? "605.1.15" : "604.1"
            config.applicationNameForUserAgent = "Version/\(version.majorVersion).\(version.minorVersion) Safari/\(safariVersion)"
            config.defaultWebpagePreferences.preferredContentMode = desktopMode ? .desktop : .mobile
        }
        if #available(iOS 18.4, *), let routing = routing as? RemoteBrowserRouting {
            if configuration == nil { routing.configure(config) }
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isFindInteractionEnabled = true
        web.isInspectable = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        let tab = Tab(web)
        if #available(iOS 18.4, *), let routing = routing as? RemoteBrowserRouting { tab.routingTab = routing.opened(web) }
        tab.row.alignment = .center
        tab.row.layer.cornerRadius = 8
        tab.row.clipsToBounds = true
        tab.width = tab.row.widthAnchor.constraint(equalToConstant: 240)
        tab.width?.isActive = true
        tab.button.titleLabel?.font = .systemFont(ofSize: 14)
        tab.button.titleLabel?.lineBreakMode = .byTruncatingMiddle
        tab.button.contentHorizontalAlignment = .leading
        tab.button.addAction(UIAction { [weak self, weak web] _ in
            guard let self = self, let index = self.tabs.firstIndex(where: { $0.webView === web }) else { return }
            self.selectTab(index)
        }, for: .touchUpInside)
        tab.address.font = .systemFont(ofSize: 14)
        tab.address.keyboardType = .URL
        tab.address.autocapitalizationType = .none
        tab.address.autocorrectionType = .no
        tab.address.returnKeyType = .go
        tab.address.clearButtonMode = .whileEditing
        tab.address.placeholder = "URL on \(peer)"
        tab.address.accessibilityLabel = "Address"
        tab.address.delegate = self
        tab.address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tab.button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(tab.close, symbol: "xmark", label: "Close tab")
        tab.close.addAction(UIAction { [weak self, weak web] _ in
            guard let self = self, let index = self.tabs.firstIndex(where: { $0.webView === web }) else { return }
            self.closeTab(index)
        }, for: .touchUpInside)
        tab.row.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        tab.row.isLayoutMarginsRelativeArrangement = true
        tab.row.addArrangedSubview(tab.button)
        tab.row.addArrangedSubview(tab.address)
        tab.row.addArrangedSubview(tab.close)
        tabStrip.addArrangedSubview(tab.row)
        tab.observations = [
            web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.refresh() },
            web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.refresh() },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.refresh() },
        ]
        if embedded {
            tab.observations += [
                web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.refresh() },
                web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.refresh() },
            ]
        }
        tabs.append(tab)
        selectTab(tabs.count - 1)
        if let url = url { load(url) }
        return web
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        view.endEditing(true)
        selected = index
        for tab in tabs { tab.webView.removeFromSuperview() }
        let web = tabs[index].webView
        web.translatesAutoresizingMaskIntoConstraints = false
        content.insertSubview(web, belowSubview: message)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor), web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        message.isHidden = true
        refresh()
        view.layoutIfNeeded()
        tabScroll.scrollRectToVisible(tabs[index].row.frame, animated: false)
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if #available(iOS 18.4, *), let routing = routing as? RemoteBrowserRouting { routing.closed(tab.routingTab) }
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabStrip.removeArrangedSubview(tab.row)
        tab.row.removeFromSuperview()
        tabs.remove(at: index)
        if index < selected { selected -= 1 }
        selected = min(selected, max(tabs.count - 1, 0))
        if tabs.isEmpty { _ = addTab() } else { selectTab(selected) }
    }

    private func saveTabs() {
        let state = SavedTabs(urls: tabs.map { $0.webView.url.map { RemoteBrowserLoopback.url($0, remote: false).absoluteString } ?? "about:blank" }, selected: selected)
        do { UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: storageKey) }
        catch { showMessage("Could not save browser tabs: " + error.localizedDescription) }
    }

    private func refresh() {
        guard isViewLoaded, !finished else { return }
        backButton.isEnabled = current?.canGoBack == true
        forwardButton.isEnabled = current?.canGoForward == true
        let loading = current?.isLoading == true
        reloadButton.setImage(UIImage(systemName: loading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = loading ? "Stop loading" : "Reload"
        for (index, tab) in tabs.enumerated() {
            let active = index == selected
            tab.row.backgroundColor = active ? .tertiarySystemFill : .secondarySystemBackground
            tab.button.isHidden = active
            tab.address.isHidden = !active
            let address = tab.webView.url.map { RemoteBrowserLoopback.url($0, remote: false).absoluteString }
            if !tab.address.isFirstResponder { tab.address.text = address }
            tab.button.setTitle(address ?? "New tab", for: .normal)
            tab.button.accessibilityLabel = "Select tab \(index + 1)"
            tab.close.accessibilityLabel = "Close tab \(index + 1)"
        }
        updateMenus()
        view.setNeedsLayout()
        saveTabs()
        if embedded && restored { onState?(workspaceState()) }
    }

    private func updateMenus() {
        let save = UIAction(title: "Bookmark this page", image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.editBookmark() }
        save.attributes = Self.webURL(current?.url?.absoluteString ?? "") == nil ? .disabled : []
        let open = bookmarks.map { bookmark in
            UIAction(title: bookmark.title, subtitle: bookmark.url, image: UIImage(systemName: "bookmark")) { [weak self] _ in
                guard let url = Self.webURL(bookmark.url) else { return }
                self?.load(url)
            }
        }
        let manage = bookmarks.enumerated().map { index, bookmark in
            UIMenu(title: bookmark.title, children: [
                UIAction(title: "Open in new tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                    self?.addTab(url: Self.webURL(bookmark.url))
                },
                UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.editBookmark(index) },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self = self, self.bookmarks.indices.contains(index) else { return }
                    self.bookmarks.remove(at: index)
                    self.saveBookmarks()
                },
            ])
        }
        bookmarksButton.menu = UIMenu(title: "Bookmarks · \(peer)", children: [save] + open + (manage.isEmpty ? [] : [UIMenu(title: "Manage bookmarks", children: manage)]))
        let desktop = UIAction(title: "Desktop website", image: UIImage(systemName: "desktopcomputer"), state: desktopMode ? .on : .off) { [weak self] _ in
            guard let self = self else { return }
            self.desktopMode.toggle()
            UserDefaults.standard.set(self.desktopMode, forKey: self.desktopKey)
            self.current?.reload()
            self.updateMenus()
        }
        let forward = UIAction(title: "Forward", image: UIImage(systemName: "chevron.right")) { [weak self] _ in self?.goForward() }
        forward.attributes = current?.canGoForward == true ? [] : .disabled
        moreButton.menu = UIMenu(title: "Browsing via \(peer)", children: [
            forward,
            UIAction(title: current?.isLoading == true ? "Stop loading" : "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() },
            desktop,
            UIAction(title: "Find on page", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.current?.findInteraction?.presentFindNavigator(showingReplace: false)
            },
            UIAction(title: "Copy address", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.current?.url.map { RemoteBrowserLoopback.url($0, remote: false).absoluteString }
            },
        ])
    }

    private func editBookmark(_ index: Int? = nil) {
        let bookmark = index.flatMap { bookmarks.indices.contains($0) ? bookmarks[$0] : nil }
        guard bookmark != nil || Self.webURL(current?.url?.absoluteString ?? "") != nil else { return }
        let alert = UIAlertController(title: bookmark == nil ? "Add bookmark" : "Edit bookmark", message: "Saved for \(peer)", preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = "Name"; field.text = bookmark?.title ?? self.current?.title }
        alert.addTextField { field in
            field.placeholder = "URL"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = bookmark?.url ?? self.current?.url.map { RemoteBrowserLoopback.url($0, remote: false).absoluteString }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let fields = alert?.textFields, let url = Self.addressURL(fields[1].text ?? "") else {
                self?.showMessage("Enter an HTTP or HTTPS bookmark URL.")
                return
            }
            let title = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updated = Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url.absoluteString)
            if let index = index, self.bookmarks.indices.contains(index) { self.bookmarks[index] = updated }
            else if let existing = self.bookmarks.firstIndex(where: { $0.url == updated.url }) { self.bookmarks[existing] = updated }
            else { self.bookmarks.append(updated) }
            self.saveBookmarks()
        })
        present(alert, animated: true)
    }

    private func saveBookmarks() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(bookmarks), forKey: bookmarksKey) }
        catch { showMessage("Could not save bookmarks: " + error.localizedDescription) }
        updateMenus()
        if embedded { onState?(workspaceState()) }
    }

    private func load(_ url: URL) {
        view.endEditing(true)
        message.isHidden = true
        let mapped = RemoteBrowserLoopback.url(url, remote: true)
        if mapped != url && routing == nil {
            showMessage("Remote localhost browsing requires iOS 18.4 or later.")
            return
        }
        current?.load(URLRequest(url: routing == nil ? url : mapped))
    }

    func workspaceState() -> [String: Any] {
        return ["ready": restored, "error": !restored && message.text?.hasPrefix("Could not prepare") == true ? (message.text ?? "") : "", "tabs": tabs.map { tab in
            ["id": tab.id, "url": tab.webView.url.map { RemoteBrowserLoopback.url($0, remote: false).absoluteString } ?? "about:blank",
             "title": tab.webView.title ?? "New tab", "loading": tab.webView.isLoading,
             "back": tab.webView.canGoBack, "forward": tab.webView.canGoForward] as [String: Any]
        }, "selected": tabs.indices.contains(selected) ? tabs[selected].id : "",
        "bookmarks": bookmarks.map { ["title": $0.title, "url": $0.url] },
        "recents": recents.map { ["title": $0.title, "url": $0.url] }]
    }

    static func saveOfflineTabs(identity: String, urls: [String], selected: Int) {
        let state = SavedTabs(urls: urls.isEmpty ? ["about:blank"] : Array(urls.prefix(32)), selected: selected)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "remote-browser.tabs." + profileID(for: identity).uuidString)
        }
    }

    func reconnect(port: UInt16, username: String, password: String) {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.allowFailover = false
        proxy.matchDomains = []
        proxy.excludedDomains = []
        proxy.applyCredential(username: username, password: password)
        store.proxyConfigurations = [proxy]
    }

    func workspaceCommand(_ command: String, tabID: String?, value: String?) {
        guard restored else { return }
        if let tabID = tabID {
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            if command == "close" { closeTab(index); return }
            selectTab(index)
        }
        switch command {
        case "select": break
        case "new": _ = addTab(url: value.flatMap(Self.addressURL))
        case "close": closeTab(selected)
        case "navigate":
            if let url = value.flatMap(Self.addressURL) { load(url) }
            else { showMessage("Enter an HTTP or HTTPS URL without credentials.") }
        case "back": goBack()
        case "forward": goForward()
        case "reload": reload()
        case "bookmark": editBookmark()
        case "editBookmark": if let index = value.flatMap(Int.init) { editBookmark(index) }
        case "deleteBookmark":
            if let index = value.flatMap(Int.init), bookmarks.indices.contains(index) { bookmarks.remove(at: index); saveBookmarks() }
        case "desktopWebsite": desktopMode.toggle(); UserDefaults.standard.set(desktopMode, forKey: desktopKey); current?.reload()
        case "find": current?.findInteraction?.presentFindNavigator(showingReplace: false)
        case "blur": view.endEditing(true)
        case "visibility": workspaceVisible = value == "true"; if !workspaceVisible { view.endEditing(true) }; return
        case "suspend":
            view.endEditing(true)
            for tab in tabs { tab.webView.stopLoading() }
        case "resume": if current?.url != nil { current?.reload() }
        default: break
        }
        refresh()
    }

    private func showMessage(_ text: String) {
        message.text = text
        message.isHidden = false
        if embedded && !restored { onState?(workspaceState()) }
    }

    @objc private func addBlankTab() {
        guard addTab() != nil else { return }
        tabs.last?.address.becomeFirstResponder()
    }
    @objc private func goBack() { message.isHidden = true; current?.goBack() }
    @objc private func goForward() { message.isHidden = true; current?.goForward() }
    @objc private func reload() {
        message.isHidden = true
        if current?.isLoading == true { current?.stopLoading() } else { current?.reload() }
    }

    @objc func finish() {
        guard !finished else { return }
        finished = true
        saveTabs()
        for tab in tabs { tab.webView.stopLoading() }
        let completion = onClose
        dismiss(animated: true) { completion?() }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { textField.selectAll(nil) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let url = Self.addressURL(textField.text ?? "") else {
            showMessage("Enter an HTTP or HTTPS URL without credentials.")
            return false
        }
        load(url)
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        guard let url = navigationAction.request.url,
              Self.allowsNavigation(url, mainFrame: navigationAction.targetFrame?.isMainFrame != false) else {
            if webView === current { showMessage("This link cannot be opened in the remote browser.") }
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return addTab(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) { closeTab(index) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard webView === current, (!embedded || (workspaceVisible && view.window != nil)), presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard webView === current, (!embedded || (workspaceVisible && view.window != nil)), presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard webView === current, (!embedded || (workspaceVisible && view.window != nil)), presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === current { message.isHidden = true }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if embedded, let url = webView.url.map({ RemoteBrowserLoopback.url($0, remote: false) }), Self.webURL(url.absoluteString) != nil {
            recents.removeAll { $0.url == url.absoluteString }
            recents.insert(Bookmark(title: webView.title ?? url.absoluteString, url: url.absoluteString), at: 0)
            recents = Array(recents.prefix(30))
            if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: storageKey + ".recents") }
        }
        refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if embedded && webView === current { showMessage("Page was unloaded. Choose Reload to recover it.") }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error, from: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error, from: webView) }
    private func show(_ error: Error, from web: WKWebView) {
        if web === current && (error as NSError).code != NSURLErrorCancelled { showMessage(error.localizedDescription) }
    }
}
