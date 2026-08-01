import SwiftUI

@main
struct DreamDApp: App {
    @StateObject private var tabManager = TabManager.shared
    @StateObject private var downloadManager = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tabManager)
                .environmentObject(downloadManager)
                .preferredColorScheme(.dark)
                .onAppear {
                    BackgroundKeepAlive.shared.applyOnLaunch()
                }
                .onOpenURL { url in
                    handleIncoming(url)
                }
        }
    }

    private func handleIncoming(_ url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            DownloadManager.shared.add(from: url.absoluteString)
        } else if url.isFileURL {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "torrent",
               let data = try? Data(contentsOf: url) {
                DownloadManager.shared.addTorrentFile(data: data,
                                                     suggestedName: url.deletingPathExtension().lastPathComponent)
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        BrowserView()
    }
}
