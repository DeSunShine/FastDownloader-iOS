import SwiftUI
import WebKit
import UIKit
import Combine

final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?

    var currentTab: BrowserTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    func ensureInitialTab() {
        guard tabs.isEmpty else { return }
        _ = addTab(url: URL(string: "https://www.google.com"), select: true)
    }

    @discardableResult
    func addTab(url: URL? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(store: self)
        tabs.append(tab)
        if select {
            selectedTabID = tab.id
        }
        if let url {
            tab.urlString = url.absoluteString
            tab.navigationError = nil
            tab.loadProgress = 0.03
            tab.isLoading = true
            tab.webView.load(URLRequest(url: url))
        }
        return tab
    }

    func addPopupTab(for navigationAction: WKNavigationAction) -> WKWebView? {
        guard AppSettings.shared.openPopupsInTabs else {
            if let url = navigationAction.request.url {
                currentTab?.webView.load(URLRequest(url: url))
            }
            return nil
        }

        let tab = addTab(select: true)
        return tab.webView
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedTabID = nil
            ensureInitialTab()
            return
        }

        if wasSelected {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
    }

    func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    @discardableResult
    func navigate(_ input: String, in tab: BrowserTab) -> URL? {
        guard let url = Self.resolvedURL(from: input) else { return nil }
        tab.urlString = url.absoluteString
        tab.navigationError = nil
        tab.loadProgress = 0.03
        tab.isLoading = true
        tab.webView.load(URLRequest(url: url))
        return url
    }

    static func resolvedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            return url
        }

        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://" + trimmed)
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}

struct BrowserNavigationError: Equatable {
    let title: String
    let message: String
    let failingURL: String?
}

final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    var delegateProxy: BrowserWebDelegate!

    @Published var title = "New Tab"
    @Published var urlString: String?
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    @Published var navigationError: BrowserNavigationError?
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var cancellables = Set<AnyCancellable>()

    init(store: BrowserStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.delegateProxy = BrowserWebDelegate(store: store, tabID: id)

        webView.navigationDelegate = delegateProxy
        webView.uiDelegate = delegateProxy
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true

        webView.publisher(for: \.estimatedProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.loadProgress = progress
            }
            .store(in: &cancellables)
    }
}

final class BrowserWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var store: BrowserStore?
    let tabID: UUID

    init(store: BrowserStore, tabID: UUID) {
        self.store = store
        self.tabID = tabID
    }

    private var tab: BrowserTab? {
        store?.tabs.first(where: { $0.id == tabID })
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        beginLoading(url: webView.url)
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.urlString = webView.url?.absoluteString
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.isLoading = false
        tab?.loadProgress = 1
        tab?.navigationError = nil
        tab?.urlString = webView.url?.absoluteString
        tab?.title = webView.title ?? webView.url?.host ?? "Tab"
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error, webView: webView)
    }

    private func beginLoading(url: URL?) {
        tab?.navigationError = nil
        tab?.isLoading = true
        tab?.loadProgress = 0.03
        if let url {
            tab?.urlString = url.absoluteString
        }
    }

    private func handleNavigationFailure(_ error: Error, webView: WKWebView) {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            tab?.isLoading = false
            tab?.loadProgress = 0
            updateNavigationState(webView)
            return
        }

        if nsError.domain == WKErrorDomain && nsError.code == 102 {
            tab?.isLoading = false
            tab?.loadProgress = 0
            updateNavigationState(webView)
            return
        }

        tab?.isLoading = false
        tab?.loadProgress = 0
        tab?.navigationError = BrowserNavigationError(
            title: "Couldn’t Load Page",
            message: friendlyMessage(for: nsError),
            failingURL: tab?.urlString
        )
        updateNavigationState(webView)
    }

    private func friendlyMessage(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }

        switch error.code {
        case NSURLErrorTimedOut:
            return "The connection timed out."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "The server could not be found."
        case NSURLErrorCannotConnectToHost:
            return "Could not connect to the server."
        case NSURLErrorNotConnectedToInternet:
            return "There is no Internet connection."
        case NSURLErrorNetworkConnectionLost:
            return "The network connection was lost."
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "A secure connection to the server could not be established."
        default:
            return error.localizedDescription
        }
    }

    private func updateNavigationState(_ webView: WKWebView) {
        tab?.canGoBack = webView.canGoBack
        tab?.canGoForward = webView.canGoForward
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            DownloadCapture.capture(
                request: navigationAction.request,
                from: webView,
                preferredFilename: nil
            )
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            beginLoading(url: navigationAction.request.url)
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let http = response as? HTTPURLResponse
        let contentDisposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = contentDisposition.contains("attachment")
        let shouldDownload = isAttachment || !navigationResponse.canShowMIMEType

        if navigationResponse.isForMainFrame,
           let http,
           (400...599).contains(http.statusCode),
           !shouldDownload {
            tab?.isLoading = false
            tab?.loadProgress = 0
            tab?.urlString = response.url?.absoluteString ?? tab?.urlString
            tab?.navigationError = BrowserNavigationError(
                title: "HTTP \(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                failingURL: response.url?.absoluteString
            )
            decisionHandler(.cancel)
            return
        }

        guard shouldDownload, let url = response.url else {
            decisionHandler(.allow)
            return
        }

        DownloadCapture.capture(
            request: URLRequest(url: url),
            from: webView,
            preferredFilename: response.suggestedFilename
        )
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return store?.addPopupTab(for: navigationAction)
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.close(tabID)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let download = UIAction(
                title: "Download Link",
                image: UIImage(systemName: "arrow.down.circle")
            ) { _ in
                DownloadCapture.capture(
                    request: URLRequest(url: url),
                    from: webView,
                    preferredFilename: nil
                )
            }

            let open = UIAction(
                title: "Open in New Tab",
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                _ = self?.store?.addTab(url: url, select: true)
            }

            return UIMenu(children: [download, open])
        }

        completionHandler(configuration)
    }
}

enum DownloadCapture {
    static func capture(
        request: URLRequest,
        from webView: WKWebView,
        preferredFilename: String?
    ) {
        guard let url = request.url else { return }
        let sourcePage = webView.url?.absoluteString

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { allCookies in
            let cookies = matchingCookies(allCookies, for: url)

            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                let userAgent = result as? String
                DispatchQueue.main.async {
                    DownloadManager.shared.start(
                        request: request,
                        sourcePage: sourcePage,
                        cookies: cookies,
                        userAgent: userAgent,
                        preferredFilename: preferredFilename
                    )
                }
            }
        }
    }

    private static func matchingCookies(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"

        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            let pathMatches = path.hasPrefix(cookie.path)
            let secureMatches = !cookie.isSecure || secure
            return domainMatches && pathMatches && secureMatches
        }
    }
}

struct BrowserContainer: UIViewRepresentable {
    let tab: BrowserTab

    func makeUIView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
