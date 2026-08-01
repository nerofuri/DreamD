import Foundation
import Combine

final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []

    private var persistWork: DispatchWorkItem?

    static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var torrentsDirectory: URL {
        let dir = JSONDisk.url(for: "torrents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        load()
    }

    var activeCount: Int { items.filter { $0.state.isActive }.count }

    // MARK: - Adding downloads

    /// Auto-detects the kind of download from a pasted string.
    @discardableResult
    func add(from input: String) -> DownloadItem? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("magnet:") {
            return addMagnet(s)
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        if url.absoluteString.lowercased().contains(".m3u8") {
            return addHLS(url)
        }
        if url.pathExtension.lowercased() == "torrent" {
            return addRemoteTorrent(url)
        }
        return addHTTP(url)
    }

    @discardableResult
    func addHTTP(_ url: URL) -> DownloadItem {
        var name = url.lastPathComponent
        if name.isEmpty || name == "/" { name = "download" }
        let item = DownloadItem(kind: .file, source: url.absoluteString, name: name)
        item.worker = SegmentedHTTPDownloader(item: item, url: url)
        register(item)
        return item
    }

    @discardableResult
    func addHLS(_ url: URL, title: String? = nil) -> DownloadItem {
        var name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
        if name.isEmpty { name = "video" }
        name = Self.sanitizeFileName(name)
        let item = DownloadItem(kind: .hls, source: url.absoluteString, name: name)
        item.worker = HLSDownloader(item: item, url: url)
        register(item)
        return item
    }

    @discardableResult
    func addMagnet(_ uri: String) -> DownloadItem? {
        guard let magnet = MagnetURI(uri) else { return nil }
        let item = DownloadItem(kind: .torrent, source: uri,
                                name: magnet.displayName ?? magnet.infoHash.hexString)
        item.worker = TorrentDownloader(item: item, magnet: magnet)
        register(item)
        return item
    }

    func addTorrentFile(data: Data, suggestedName: String) {
        guard let meta = try? TorrentMetaInfo(torrentData: data) else { return }
        let id = UUID()
        // Keep a copy of the .torrent so the download can be recreated after relaunch.
        let stored = Self.torrentsDirectory.appendingPathComponent("\(id.uuidString).torrent")
        try? data.write(to: stored)
        let item = DownloadItem(id: id, kind: .torrent, source: stored.path,
                                name: meta.name.isEmpty ? suggestedName : meta.name)
        item.worker = TorrentDownloader(item: item, meta: meta)
        register(item)
    }

    /// Downloads a remote .torrent file, then starts the torrent.
    @discardableResult
    private func addRemoteTorrent(_ url: URL) -> DownloadItem? {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, (try? TorrentMetaInfo(torrentData: data)) != nil else { return }
            DispatchQueue.main.async {
                self.addTorrentFile(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
            }
        }.resume()
        return nil
    }

    private func register(_ item: DownloadItem) {
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            item.worker?.start()
            self.persistSoon()
        }
    }

    // MARK: - Controls

    func pause(_ item: DownloadItem) {
        item.worker?.pause()
        persistSoon()
    }

    func resume(_ item: DownloadItem) {
        if item.worker == nil {
            item.worker = makeWorker(for: item)
            item.worker?.start()
        } else {
            item.worker?.resume()
        }
        persistSoon()
    }

    func remove(_ item: DownloadItem, deleteFile: Bool) {
        item.worker?.cancel()
        item.worker = nil
        if deleteFile, let url = item.destinationURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        persistSoon()
    }

    /// Recreates a worker for an item restored from disk.
    private func makeWorker(for item: DownloadItem) -> DownloadWorker? {
        switch item.kind {
        case .file:
            guard let url = URL(string: item.source) else { return nil }
            item.receivedBytes = 0
            return SegmentedHTTPDownloader(item: item, url: url)
        case .hls:
            guard let url = URL(string: item.source) else { return nil }
            item.receivedBytes = 0
            return HLSDownloader(item: item, url: url)
        case .torrent:
            if item.source.lowercased().hasPrefix("magnet:") {
                guard let magnet = MagnetURI(item.source) else { return nil }
                return TorrentDownloader(item: item, magnet: magnet)
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.source)),
                  let meta = try? TorrentMetaInfo(torrentData: data) else { return nil }
            return TorrentDownloader(item: item, meta: meta)
        }
    }

    // MARK: - Destination paths

    func uniqueDestination(for fileName: String) -> URL {
        let dir = Self.downloadsDirectory
        let clean = Self.sanitizeFileName(fileName)
        var candidate = dir.appendingPathComponent(clean)
        var counter = 1
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    static func sanitizeFileName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 120 { s = String(s.prefix(120)) }
        return s.isEmpty ? "download" : s
    }

    // MARK: - Persistence

    func persistSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persistNow() }
            self.persistWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func persistNow() {
        let records = items.map { item -> DownloadRecord in
            var state = item.state
            if state.isActive { state = .paused }
            return DownloadRecord(id: item.id, kind: item.kind, source: item.source,
                                  name: item.name, state: state,
                                  totalBytes: item.totalBytes, receivedBytes: item.receivedBytes,
                                  destinationPath: item.destinationURL?.path,
                                  createdAt: item.createdAt)
        }
        JSONDisk.save(records, name: "downloads.json")
    }

    private func load() {
        let records: [DownloadRecord] = JSONDisk.load("downloads.json", fallback: [])
        items = records.map { r in
            let item = DownloadItem(id: r.id, kind: r.kind, source: r.source, name: r.name, createdAt: r.createdAt)
            item.state = r.state
            item.totalBytes = r.totalBytes
            item.receivedBytes = r.state == .completed ? r.receivedBytes : 0
            if r.kind == .torrent { item.receivedBytes = r.receivedBytes }
            if let p = r.destinationPath { item.destinationURL = URL(fileURLWithPath: p) }
            return item
        }
    }
}
