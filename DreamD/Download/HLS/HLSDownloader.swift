import Foundation

/// Downloads an HLS (m3u8) stream to a single local media file.
/// Handles master playlists (picks the highest-bandwidth variant),
/// AES-128 encrypted segments, and fMP4 init segments. Segments are fetched
/// concurrently and appended to the output file strictly in order.
final class HLSDownloader: NSObject, DownloadWorker {
    private let item: DownloadItem
    private let url: URL

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    private var task: Task<Void, Never>?
    private var segments: [M3U8Playlist.Segment] = []
    private var mapURL: URL?
    private var nextWriteIndex = 0
    private var mapWritten = false
    private var handle: FileHandle?
    private var bytesWritten: Int64 = 0
    private var keyCache: [String: Data] = [:]
    private let meter = SpeedMeter()

    private let concurrency = 4

    init(item: DownloadItem, url: URL) {
        self.item = item
        self.url = url
        super.init()
    }

    // MARK: - DownloadWorker

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func pause() {
        task?.cancel()
        task = nil
    }

    func resume() {
        start()
    }

    func cancel() {
        task?.cancel()
        task = nil
        try? handle?.close()
        handle = nil
    }

    // MARK: - Main flow

    private func run() async {
        do {
            if segments.isEmpty {
                try await prepare()
            }
            item.update { $0.state = .downloading }
            try await downloadSegments()
            try? handle?.close()
            handle = nil
            let total = bytesWritten
            item.update {
                $0.state = .completed
                $0.totalBytes = total
                $0.receivedBytes = total
                $0.speed = 0
                $0.detail = "\(self.segments.count) segments"
            }
            DownloadManager.shared.persistSoon()
        } catch is CancellationError {
            meter.reset()
            item.update { $0.state = .paused; $0.speed = 0 }
        } catch {
            item.fail(error.localizedDescription)
        }
        task = nil
    }

    private func prepare() async throws {
        item.update { $0.state = .fetchingInfo }
        var playlist = try await fetchPlaylist(url)

        if playlist.isMaster {
            guard let best = playlist.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSError.emptyPlaylist
            }
            playlist = try await fetchPlaylist(best.url)
        }

        guard !playlist.segments.isEmpty else { throw HLSError.emptyPlaylist }
        if playlist.isLive {
            throw HLSError.liveStream
        }
        if let key = playlist.segments.first?.key, key.method != "NONE", key.method != "AES-128" {
            throw HLSError.drmProtected(key.method)
        }

        segments = playlist.segments
        mapURL = playlist.mapURL

        let isFMP4 = playlist.mapURL != nil
            || segments.first.map { $0.url.pathExtension.lowercased().hasPrefix("m4") || $0.url.pathExtension.lowercased() == "mp4" } == true
        let ext = isFMP4 ? "mp4" : "ts"
        var baseName = item.name
        if (baseName as NSString).pathExtension.lowercased() == "m3u8" {
            baseName = (baseName as NSString).deletingPathExtension
        }
        let destination = DownloadManager.shared.uniqueDestination(for: "\(baseName).\(ext)")
        item.destinationURL = destination
        let finalName = destination.lastPathComponent
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: destination) else {
            throw HLSError.io
        }
        handle = h
        let count = segments.count
        item.update {
            $0.name = finalName
            $0.detail = "0/\(count) segments"
        }
    }

    private func downloadSegments() async throws {
        if let mapURL, !mapWritten {
            let (data, _) = try await session.data(from: mapURL)
            append(data)
            mapWritten = true
        }

        var buffer: [Int: Data] = [:]
        var launched = nextWriteIndex
        let total = segments.count

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            while launched < total && launched - nextWriteIndex < concurrency {
                let index = launched
                group.addTask { (index, try await self.fetchSegment(index)) }
                launched += 1
            }

            while let (index, data) = try await group.next() {
                buffer[index] = data
                while let ready = buffer[nextWriteIndex] {
                    buffer[nextWriteIndex] = nil
                    append(ready)
                    nextWriteIndex += 1
                    publishProgress()
                }
                while launched < total && launched - nextWriteIndex < concurrency + buffer.count {
                    let index = launched
                    group.addTask { (index, try await self.fetchSegment(index)) }
                    launched += 1
                }
            }
        }
    }

    private func fetchSegment(_ index: Int) async throws -> Data {
        try Task.checkCancellation()
        let segment = segments[index]
        var data: Data
        do {
            (data, _) = try await session.data(from: segment.url)
        } catch {
            // One retry for transient failures.
            try Task.checkCancellation()
            (data, _) = try await session.data(from: segment.url)
        }

        if let key = segment.key, key.method == "AES-128" {
            guard let keyURL = key.url else { throw HLSError.missingKey }
            let keyData = try await fetchKey(keyURL)
            var iv = key.iv
            if iv == nil {
                var generated = Data(count: 8)
                generated.appendUInt64BE(UInt64(segment.sequence))
                iv = generated
            }
            guard let ivData = iv, let decrypted = AESCBC.decrypt(data, key: keyData, iv: ivData) else {
                throw HLSError.decryptionFailed
            }
            data = decrypted
        }
        return data
    }

    private func fetchKey(_ url: URL) async throws -> Data {
        if let cached = keyCache[url.absoluteString] { return cached }
        let (data, _) = try await session.data(from: url)
        guard data.count == 16 else { throw HLSError.missingKey }
        keyCache[url.absoluteString] = data
        return data
    }

    private func append(_ data: Data) {
        handle?.seekToEndOfFile()
        handle?.write(data)
        bytesWritten += Int64(data.count)
        meter.add(Int64(data.count))
    }

    private func publishProgress() {
        let written = bytesWritten
        let done = nextWriteIndex
        let total = segments.count
        // Estimate total size from average segment size so the progress bar moves.
        let estimatedTotal = done > 0 ? Int64(Double(written) / Double(done) * Double(total)) : 0
        let speed = meter.speed
        item.update {
            $0.receivedBytes = written
            $0.totalBytes = max(estimatedTotal, written)
            $0.speed = speed
            $0.detail = "\(done)/\(total) segments"
        }
    }

    private func fetchPlaylist(_ url: URL) async throws -> M3U8Playlist {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw HLSError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            throw HLSError.notAPlaylist
        }
        return M3U8Parser.parse(text, baseURL: url)
    }
}

enum HLSError: LocalizedError {
    case emptyPlaylist
    case liveStream
    case drmProtected(String)
    case missingKey
    case decryptionFailed
    case notAPlaylist
    case io
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .emptyPlaylist: return "The playlist contains no video segments"
        case .liveStream: return "Live streams can't be downloaded (no end marker in playlist)"
        case .drmProtected(let method): return "Stream is protected with \(method) encryption and can't be downloaded"
        case .missingKey: return "Could not fetch the decryption key"
        case .decryptionFailed: return "Segment decryption failed"
        case .notAPlaylist: return "The URL did not return an m3u8 playlist"
        case .io: return "Could not create the output file"
        case .http(let code): return "Server returned HTTP \(code)"
        }
    }
}
