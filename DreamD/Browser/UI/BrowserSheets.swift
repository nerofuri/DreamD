import SwiftUI
import UIKit

// MARK: - History

struct HistorySheet: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(history.entries) { entry in
                    Button {
                        if let url = URL(string: entry.url) {
                            tab.loadURL(url)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(entry.url)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            history.remove(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if history.entries.isEmpty {
                    Text("No browsing history")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Bookmarks / Reading list

struct BookmarksSheet: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BookmarkStore
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.entries) { bookmark in
                    Button {
                        if let url = URL(string: bookmark.url) {
                            tab.loadURL(url)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 14))
                                .foregroundColor(ChromeColor.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bookmark.title)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(bookmark.url)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.remove(bookmark)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    Text("Nothing saved yet")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Recent tabs

struct RecentTabsSheet: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tabManager.recentlyClosed) { closed in
                    Button {
                        if let url = closed.url {
                            tabManager.newTab(url: url)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(closed.title)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(closed.url?.absoluteString ?? "")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .overlay {
                if tabManager.recentlyClosed.isEmpty {
                    Text("No recently closed tabs")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Recent tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Media found on page

struct MediaListSheet: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @State private var startedIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(tab.detectedMedia) { media in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: media.kind))
                            .font(.system(size: 20))
                            .foregroundColor(ChromeColor.blue)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(media.url.lastPathComponent.isEmpty ? (media.url.host ?? "stream") : media.url.lastPathComponent)
                                .font(.system(size: 14))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(media.kind == .hls ? "HLS stream" : media.kind.rawValue.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(ChromeColor.chip))
                                Text(media.url.host ?? "")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if startedIDs.contains(media.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button {
                                download(media)
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundColor(ChromeColor.googleBlue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = media.url.absoluteString
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .overlay {
                if tab.detectedMedia.isEmpty {
                    Text("No media detected on this page yet")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Media on this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func icon(for kind: MediaKind) -> String {
        switch kind {
        case .hls: return "dot.radiowaves.left.and.right"
        case .video: return "film"
        case .audio: return "music.note"
        }
    }

    private func download(_ media: DetectedMedia) {
        switch media.kind {
        case .hls:
            DownloadManager.shared.addHLS(media.url, title: media.pageTitle)
        case .video, .audio:
            DownloadManager.shared.addHTTP(media.url)
        }
        startedIDs.insert(media.id)
    }
}
