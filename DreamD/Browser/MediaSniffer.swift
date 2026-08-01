import Foundation
import WebKit

enum MediaKind: String {
    case hls, video, audio
}

struct DetectedMedia: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
    let pageTitle: String

    static func == (lhs: DetectedMedia, rhs: DetectedMedia) -> Bool {
        lhs.url == rhs.url
    }
}

enum MediaSniffer {
    static let messageName = "dreamdMedia"

    /// Injected into every frame: hooks fetch/XHR and scans media elements so
    /// stream URLs (especially .m3u8) surface in the download button.
    static let script = """
    (function() {
        if (window.__dreamdSniffer) { return; }
        window.__dreamdSniffer = true;
        var seen = {};
        function report(u) {
            try {
                window.webkit.messageHandlers.dreamdMedia.postMessage({
                    url: u,
                    page: location.href,
                    title: document.title || ''
                });
            } catch (e) {}
        }
        function check(u) {
            if (!u) { return; }
            u = String(u);
            if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) { return; }
            if (seen[u]) { return; }
            if (/\\.(m3u8|mp4|webm|mov|m4v|mkv|mp3|m4a|aac|flac|ogg)([?#]|$)/i.test(u) || /m3u8/i.test(u)) {
                seen[u] = 1;
                report(u);
            }
        }
        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function(input) {
                try { check(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
                return origFetch.apply(this, arguments);
            };
        }
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            try { check(url); } catch (e) {}
            return origOpen.apply(this, arguments);
        };
        function scan() {
            try {
                var els = document.querySelectorAll('video, audio, source');
                for (var i = 0; i < els.length; i++) {
                    check(els[i].currentSrc || els[i].src);
                }
            } catch (e) {}
        }
        setInterval(scan, 2000);
        document.addEventListener('play', function(e) {
            try { if (e.target) { check(e.target.currentSrc || e.target.src); } } catch (err) {}
        }, true);
    })();
    """

    static func kind(for url: URL) -> MediaKind {
        let s = url.absoluteString.lowercased()
        if s.contains(".m3u8") { return .hls }
        let ext = url.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "flac", "ogg"].contains(ext) { return .audio }
        return .video
    }
}

/// WKUserContentController retains its message handlers; this proxy breaks the
/// retain cycle between the web view configuration and the owning tab.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
