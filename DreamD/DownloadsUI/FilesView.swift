import SwiftUI
import AVKit

/// Browses the app's Downloads folder. Files are also visible in the
/// system Files app (On My iPhone → DreamD) thanks to file sharing.
struct FilesView: View {
    var directory: URL = DownloadManager.downloadsDirectory

    @State private var entries: [FileEntry] = []
    @State private var previewURL: URL?
    @State private var playerURL: URL?
    @State private var shareURL: URL?

    struct FileEntry: Identifiable {
        let id: String
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let date: Date

        var name: String { url.lastPathComponent }
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FilesView(directory: entry.url)
                    } label: {
                        row(for: entry)
                    }
                } else {
                    Button {
                        open(entry)
                    } label: {
                        row(for: entry)
                    }
                    .foregroundColor(.primary)
                    .contextMenu {
                        if isPlayable(entry.url) {
                            Button {
                                playerURL = entry.url
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                        }
                        Button {
                            shareURL = entry.url
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: entry.url)
                            reload()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No files")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(directory == DownloadManager.downloadsDirectory ? "Files" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $previewURL) { url in
            QuickLookView(url: url)
        }
        .sheet(item: $playerURL) { url in
            PlayerView(url: url)
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
    }

    private func row(for entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: entry))
                .font(.system(size: 22))
                .foregroundColor(entry.isDirectory ? ChromeColor.googleYellow : ChromeColor.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Text(entry.isDirectory
                     ? entry.date.formatted(date: .abbreviated, time: .shortened)
                     : "\(Fmt.bytes(entry.size)) • \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch entry.url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "ts", "mkv", "webm": return "film.fill"
        case "mp3", "m4a", "aac", "flac", "ogg": return "music.note"
        case "zip", "rar", "7z", "gz", "tar": return "doc.zipper"
        case "pdf": return "doc.richtext.fill"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo.fill"
        case "torrent": return "point.3.connected.trianglepath.dotted"
        default: return "doc.fill"
        }
    }

    private func isPlayable(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "mp3", "m4a", "aac"].contains(url.pathExtension.lowercased())
    }

    private func open(_ entry: FileEntry) {
        if isPlayable(entry.url) {
            playerURL = entry.url
        } else {
            previewURL = entry.url
        }
    }

    private func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        entries = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return FileEntry(id: url.path,
                             url: url,
                             isDirectory: values?.isDirectory ?? false,
                             size: Int64(values?.fileSize ?? 0),
                             date: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }
}
