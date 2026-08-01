import Foundation
import WebKit
import UIKit
import Combine

/// One browser tab: owns a WKWebView, mirrors its state into published
/// properties, detects downloadable responses, and collects sniffed media URLs.
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isIncognito: Bool

    @Published var urlString = ""
    @Published var currentURL: URL?
    @Published var title = "New tab"
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var snapshot: UIImage?
    @Published var detectedMedia: [DetectedMedia] = []
    @Published var desktopMode = false
    /// Set when a page navigates to a video the web view can't render itself;
    /// the UI presents the universal player for it.
    @Published var pendingPlayback: URL?

    var isNewTabPage: Bool { currentURL == nil }

    private var providedConfiguration: WKWebViewConfiguration?
    private var observers: [NSKeyValueObservation] = []
    private var webViewCreated = false

    private(set) lazy var webView: WKWebView = makeWebView()

    init(incognito: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.isIncognito = incognito
        self.providedConfiguration = configuration
        super.init()
    }

    deinit {
        if webViewCreated {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: MediaSniffer.messageName)
        }
    }

    private func makeWebView() -> WKWebView {
        let config = providedConfiguration ?? WKWebViewConfiguration()
        providedConfiguration = nil
        if isIncognito, config.websiteDataStore.isPersistent {
            config.websiteDataStore = .nonPersistent()
        }
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = config.userContentController
        contentController.addUserScript(WKUserScript(source: MediaSniffer.script,
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: false))
        contentController.add(WeakMessageHandler(self), name: MediaSniffer.messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        observers = [
            webView.observe(\.estimatedProgress, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async { self?.isLoading = view.isLoading }
            },
            webView.observe(\.title, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async {
                    if let t = view.title, !t.isEmpty { self?.title = t }
                }
            },
            webView.observe(\.url, options: .new) { [weak self] view, _ in
                DispatchQueue.main.async {
                    guard let self, let url = view.url else { return }
                    self.currentURL = url
                    self.urlString = url.absoluteString
                }
            }
        ]
        webViewCreated = true
        return webView
    }

    // MARK: - Navigation

    /// Loads user input: a URL if it looks like one, otherwise a Google search.
    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var target: URL?
        if let url = URL(string: text), url.scheme != nil, url.host != nil || url.scheme == "about" {
            target = url
        } else if text.contains("."), !text.contains(" "), let url = URL(string: "https://\(text)") {
            target = url
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            target = components.url
        }
        if let target { loadURL(target) }
    }

    func loadURL(_ url: URL) {
        currentURL = url
        urlString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Returns to the new-tab page without destroying the web view.
    func goHome() {
        currentURL = nil
        urlString = ""
        title = "New tab"
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        webView.customUserAgent = desktopMode
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            : nil
        webView.reload()
    }

    func captureSnapshot() {
        guard !isNewTabPage else { return }
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    /// MIME types that should be downloaded rather than rendered.
    private static let downloadMIMEs: Set<String> = [
        "application/octet-stream", "application/zip", "application/x-zip-compressed",
        "application/x-rar-compressed", "application/vnd.rar", "application/x-7z-compressed",
        "application/gzip", "application/x-tar", "application/x-bittorrent",
        "application/x-apple-diskimage", "application/vnd.android.package-archive"
    ]

    private static let hlsMIMEs: Set<String> = [
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"
    ]

    /// Video containers the web view can't play but the universal player can.
    /// A direct navigation to one of these opens the in-app player instead of
    /// downloading, so the browser can play any format.
    private static let playableInBrowser: Set<String> = [
        "mkv", "avi", "flv", "wmv", "webm", "mov", "m4v", "mpg", "mpeg",
        "vob", "ogv", "3gp", "3g2", "m2ts", "mts", "asf", "divx", "f4v", "rmvb"
    ]

    fileprivate func handleDownloadableResponse(url: URL, mime: String) {
        let title = self.title
        DispatchQueue.main.async {
            if mime == "application/x-bittorrent" || url.pathExtension.lowercased() == "torrent" {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        DownloadManager.shared.addTorrentFile(
                            data: data,
                            suggestedName: url.deletingPathExtension().lastPathComponent)
                    }
                }.resume()
            } else if Self.hlsMIMEs.contains(mime) || url.absoluteString.lowercased().contains(".m3u8") {
                DownloadManager.shared.addHLS(url, title: title)
            } else {
                DownloadManager.shared.addHTTP(url)
            }
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "magnet" {
            DownloadManager.shared.add(from: url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let url = navigationResponse.response.url else {
            decisionHandler(.allow)
            return
        }
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        var disposition = ""
        if let http = navigationResponse.response as? HTTPURLResponse {
            disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        }
        let ext = url.pathExtension.lowercased()
        let isPlayableVideo = (Self.playableInBrowser.contains(ext) || mime.hasPrefix("video/"))
            && !disposition.contains("attachment")
            && ext != "torrent"
        if isPlayableVideo && !navigationResponse.canShowMIMEType && vlcPlaybackAvailable {
            // The web view can't render this format, but the universal player can.
            DispatchQueue.main.async { self.pendingPlayback = url }
            decisionHandler(.cancel)
            return
        }

        let shouldDownload = !navigationResponse.canShowMIMEType
            || disposition.contains("attachment")
            || Self.downloadMIMEs.contains(mime)
            || Self.hlsMIMEs.contains(mime)
            || ext == "torrent"
        if shouldDownload {
            handleDownloadableResponse(url: url, mime: mime)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, !isIncognito {
            HistoryStore.shared.add(url: url, title: webView.title ?? "")
        }
        captureSnapshot()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" links open in a new tab, like Chrome.
        let tab = TabManager.shared.newTab(incognito: isIncognito, configuration: configuration)
        if let url = navigationAction.request.url {
            tab.currentURL = url
            tab.urlString = url.absoluteString
        }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        TabManager.shared.close(self)
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == MediaSniffer.messageName,
              let body = message.body as? [String: Any],
              let urlText = body["url"] as? String,
              let url = URL(string: urlText),
              url.scheme?.hasPrefix("http") == true else { return }
        let pageTitle = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let media = DetectedMedia(url: url, kind: MediaSniffer.kind(for: url), pageTitle: pageTitle)
        DispatchQueue.main.async {
            guard !self.detectedMedia.contains(media) else { return }
            self.detectedMedia.append(media)
            if self.detectedMedia.count > 50 {
                self.detectedMedia.removeFirst()
            }
        }
    }
}
