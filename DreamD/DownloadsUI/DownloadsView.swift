import SwiftUI
import UIKit

struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false

    private var activeItems: [DownloadItem] {
        downloads.items.filter { $0.state != .completed }
    }

    private var completedItems: [DownloadItem] {
        downloads.items.filter { $0.state == .completed }
    }

    var body: some View {
        NavigationStack {
            List {
                if !activeItems.isEmpty {
                    Section("In progress") {
                        ForEach(activeItems) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
                if !completedItems.isEmpty {
                    Section("Completed") {
                        ForEach(completedItems) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
            }
            .overlay {
                if downloads.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No downloads yet")
                            .foregroundColor(.secondary)
                        Text("Paste a link, an m3u8 stream, a magnet link,\nor open a .torrent file.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink {
                        FilesView()
                    } label: {
                        Image(systemName: "folder")
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddDownloadSheet()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var downloads: DownloadManager
    @State private var rowSheet: RowSheet?

    private enum RowSheet: Identifiable {
        case preview(URL), play(URL), share(URL)
        var id: String {
            switch self {
            case .preview(let u): return "preview:\(u.absoluteString)"
            case .play(let u): return "play:\(u.absoluteString)"
            case .share(let u): return "share:\(u.absoluteString)"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 24))
                .foregroundColor(iconColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                if item.state.isActive {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(ChromeColor.googleBlue)
                }

                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(item.state == .failed ? .red : .secondary)
                    .lineLimit(2)
            }

            Spacer()

            controlButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .completed, let url = item.destinationURL,
               FileManager.default.fileExists(atPath: url.path),
               !url.hasDirectoryPath {
                rowSheet = PlaybackEngine.isPlayable(url) ? .play(url) : .preview(url)
            }
        }
        .contextMenu {
            if item.state == .completed, let url = item.destinationURL {
                if PlaybackEngine.isPlayable(url) {
                    Button {
                        rowSheet = .play(url)
                    } label: {
                        Label("Play", systemImage: "play.circle")
                    }
                }
                Button {
                    rowSheet = .share(url)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                UIPasteboard.general.string = item.source
            } label: {
                Label("Copy source link", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                downloads.remove(item, deleteFile: false)
            } label: {
                Label("Remove from list", systemImage: "minus.circle")
            }
            Button(role: .destructive) {
                downloads.remove(item, deleteFile: true)
            } label: {
                Label("Delete with file", systemImage: "trash")
            }
        }
        .sheet(item: $rowSheet) { sheet in
            switch sheet {
            case .preview(let url): QuickLookView(url: url)
            case .play(let url): UniversalPlayerView(url: url)
            case .share(let url): ShareSheet(items: [url])
            }
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch item.state {
        case .downloading, .fetchingInfo, .queued:
            Button {
                downloads.pause(item)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(ChromeColor.googleBlue)
            }
            .buttonStyle(.plain)
        case .paused:
            Button {
                downloads.resume(item)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(ChromeColor.googleBlue)
            }
            .buttonStyle(.plain)
        case .failed:
            Button {
                downloads.resume(item)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.green)
        }
    }

    private var iconName: String {
        switch item.kind {
        case .file: return "doc.fill"
        case .hls: return "film.fill"
        case .torrent: return "point.3.connected.trianglepath.dotted"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .file: return ChromeColor.blue
        case .hls: return .purple
        case .torrent: return .green
        }
    }

    private var statusLine: String {
        switch item.state {
        case .queued:
            return "Waiting…"
        case .fetchingInfo:
            return item.detail.isEmpty ? "Connecting…" : item.detail
        case .downloading:
            var parts: [String] = []
            if item.totalBytes > 0 {
                parts.append("\(Fmt.bytes(item.receivedBytes)) of \(Fmt.bytes(item.totalBytes))")
            } else if item.receivedBytes > 0 {
                parts.append(Fmt.bytes(item.receivedBytes))
            }
            parts.append(Fmt.speed(item.speed))
            if let eta = item.etaSeconds {
                parts.append("\(Fmt.eta(eta)) left")
            }
            if !item.detail.isEmpty {
                parts.append(item.detail)
            }
            return parts.joined(separator: " • ")
        case .paused:
            if item.totalBytes > 0 {
                return "Paused • \(Fmt.bytes(item.receivedBytes)) of \(Fmt.bytes(item.totalBytes))"
            }
            return "Paused"
        case .completed:
            var line = Fmt.bytes(item.totalBytes > 0 ? item.totalBytes : item.receivedBytes)
            if !item.detail.isEmpty { line += " • \(item.detail)" }
            return line
        case .failed:
            return item.errorMessage ?? "Failed"
        }
    }
}
