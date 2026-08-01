import Foundation
import Combine

enum DownloadKind: String, Codable {
    case file, hls, torrent
}

enum DownloadState: String, Codable {
    case queued, fetchingInfo, downloading, paused, completed, failed

    var isActive: Bool {
        self == .queued || self == .fetchingInfo || self == .downloading
    }
}

protocol DownloadWorker: AnyObject {
    func start()
    func pause()
    func resume()
    func cancel()
}

final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID
    let kind: DownloadKind
    /// Source: http(s) URL, m3u8 URL, magnet URI, or a local path to a stored .torrent file.
    let source: String
    let createdAt: Date

    @Published var name: String
    @Published var state: DownloadState = .queued
    @Published var totalBytes: Int64 = 0
    @Published var receivedBytes: Int64 = 0
    @Published var speed: Double = 0
    @Published var detail: String = ""
    @Published var errorMessage: String?

    var destinationURL: URL?
    var worker: DownloadWorker?

    init(id: UUID = UUID(), kind: DownloadKind, source: String, name: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.source = source
        self.name = name
        self.createdAt = createdAt
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var etaSeconds: Double? {
        guard speed > 1, totalBytes > receivedBytes else { return nil }
        return Double(totalBytes - receivedBytes) / speed
    }

    /// Apply a mutation on the main thread (workers call this from background queues).
    func update(_ block: @escaping (DownloadItem) -> Void) {
        if Thread.isMainThread {
            block(self)
        } else {
            DispatchQueue.main.async { block(self) }
        }
    }

    func fail(_ message: String) {
        update {
            $0.state = .failed
            $0.errorMessage = message
            $0.speed = 0
        }
        DownloadManager.shared.persistSoon()
    }
}

/// Codable snapshot used to persist the download list across launches.
struct DownloadRecord: Codable {
    let id: UUID
    let kind: DownloadKind
    let source: String
    let name: String
    let state: DownloadState
    let totalBytes: Int64
    let receivedBytes: Int64
    let destinationPath: String?
    let createdAt: Date
}
