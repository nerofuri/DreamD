import SwiftUI
import WebKit

/// Hosts a tab's WKWebView inside SwiftUI. Each tab keeps its own instance —
/// use `.id(tab.id)` at the call site so SwiftUI never swaps web views
/// between tabs.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
