import Foundation
import CryptoKit

/// Maps the torrent's contiguous piece space onto one or more files on disk.
final class TorrentFileStore {
    let meta: TorrentMetaInfo
    let rootURL: URL          // single file: the file itself; multi-file: a folder
    private var handles: [Int: FileHandle] = [:]
    private(set) var existedBefore = false

    init(meta: TorrentMetaInfo, downloadsDirectory: URL) throws {
        self.meta = meta
        let fm = FileManager.default
        if meta.files.count == 1 && !meta.files[0].path.contains("/") {
            rootURL = downloadsDirectory.appendingPathComponent(DownloadManager.sanitizeFileName(meta.name))
        } else {
            rootURL = downloadsDirectory.appendingPathComponent(DownloadManager.sanitizeFileName(meta.name), isDirectory: true)
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        for (index, file) in meta.files.enumerated() {
            let url = fileURL(for: file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) {
                existedBefore = true
            } else {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forUpdating: url) else {
                throw TorrentError.invalidTorrent
            }
            let currentSize = handle.seekToEndOfFile()
            if currentSize < UInt64(file.length) {
                handle.truncateFile(toSize: UInt64(file.length))
            }
            handles[index] = handle
        }
    }

    private func fileURL(for file: TorrentFileEntry) -> URL {
        if meta.files.count == 1 && !meta.files[0].path.contains("/") {
            return rootURL
        }
        return rootURL.appendingPathComponent(file.path)
    }

    func write(offset: Int64, data: Data) {
        var remaining = data
        var position = offset
        for (index, file) in meta.files.enumerated() {
            guard !remaining.isEmpty else { break }
            let fileEnd = file.offset + file.length
            guard position < fileEnd, position + Int64(remaining.count) > file.offset else { continue }
            let localOffset = position - file.offset
            let available = Int(min(Int64(remaining.count), fileEnd - position))
            let chunk = remaining.subdata(in: remaining.startIndex..<(remaining.startIndex + available))
            if let handle = handles[index] {
                handle.seek(toFileOffset: UInt64(localOffset))
                handle.write(chunk)
            }
            remaining = remaining.subdata(in: (remaining.startIndex + available)..<remaining.endIndex)
            position += Int64(available)
        }
    }

    func read(offset: Int64, length: Int) -> Data? {
        var out = Data()
        var position = offset
        var remaining = length
        for (index, file) in meta.files.enumerated() {
            guard remaining > 0 else { break }
            let fileEnd = file.offset + file.length
            guard position < fileEnd, position + Int64(remaining) > file.offset else { continue }
            let localOffset = position - file.offset
            let available = Int(min(Int64(remaining), fileEnd - position))
            guard let handle = handles[index] else { return nil }
            handle.seek(toFileOffset: UInt64(localOffset))
            let chunk = handle.readData(ofLength: available)
            guard chunk.count == available else { return nil }
            out.append(chunk)
            position += Int64(available)
            remaining -= available
        }
        return out.count == length ? out : nil
    }

    func closeAll() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }
}

/// Tracks which pieces/blocks we have, assigns block requests to peers,
/// verifies completed pieces against their SHA1 hashes, and writes them to disk.
final class PieceManager {
    struct BlockRequest: Hashable {
        let piece: Int
        let begin: Int
        let length: Int
    }

    enum ReceiveResult {
        case ignored
        case progress
        case pieceDone
        case torrentDone
    }

    let meta: TorrentMetaInfo
    let store: TorrentFileStore
    static let blockSize = 16384

    private(set) var have: Bitfield
    private var pending: [Int: [BlockRequest]] = [:]       // piece -> unassigned blocks
    private var inflight: [BlockRequest: (owner: UUID, at: Date)] = [:]
    private var buffers: [Int: [Int: Data]] = [:]          // piece -> begin -> data
    private(set) var completedBytes: Int64 = 0
    private let maxActivePieces = 48

    init(meta: TorrentMetaInfo, store: TorrentFileStore) {
        self.meta = meta
        self.store = store
        have = Bitfield(count: meta.pieceHashes.count)
    }

    var isComplete: Bool { have.setCount == meta.pieceHashes.count }

    /// Hash-checks data already on disk (resume after relaunch).
    func verifyExistingData() {
        guard store.existedBefore else { return }
        for piece in 0..<meta.pieceHashes.count {
            let size = meta.pieceSize(piece)
            guard let data = store.read(offset: Int64(piece) * Int64(meta.pieceLength), length: size) else { continue }
            if Data(Insecure.SHA1.hash(data: data)) == meta.pieceHashes[piece] {
                have[piece] = true
                completedBytes += Int64(size)
            }
        }
    }

    func blocks(for piece: Int) -> [BlockRequest] {
        let size = meta.pieceSize(piece)
        var result: [BlockRequest] = []
        var begin = 0
        while begin < size {
            let length = min(Self.blockSize, size - begin)
            result.append(BlockRequest(piece: piece, begin: begin, length: length))
            begin += length
        }
        return result
    }

    func amInterested(peerHas: (Int) -> Bool) -> Bool {
        for piece in 0..<meta.pieceHashes.count where !have[piece] && peerHas(piece) {
            return true
        }
        return false
    }

    /// Assigns up to `max` block requests to a peer. Prefers finishing
    /// already-started pieces before opening new ones.
    func assign(to owner: UUID, peerHas: (Int) -> Bool, max maxCount: Int) -> [BlockRequest] {
        var assigned: [BlockRequest] = []

        func take(from piece: Int) {
            guard var blocks = pending[piece], !blocks.isEmpty else { return }
            while assigned.count < maxCount, !blocks.isEmpty {
                let block = blocks.removeFirst()
                inflight[block] = (owner, Date())
                assigned.append(block)
            }
            pending[piece] = blocks.isEmpty ? nil : blocks
            if pending[piece] == nil && blocks.isEmpty && buffers[piece] == nil {
                // All blocks of this piece are now in flight; keep tracked via inflight.
            }
        }

        // Finish started pieces first.
        for piece in pending.keys.sorted() where peerHas(piece) {
            guard assigned.count < maxCount else { return assigned }
            take(from: piece)
        }

        // Open new pieces.
        while assigned.count < maxCount {
            guard activePieceCount < maxActivePieces,
                  let piece = nextFreshPiece(peerHas: peerHas) else { break }
            pending[piece] = blocks(for: piece)
            take(from: piece)
        }
        return assigned
    }

    private var activePieceCount: Int {
        Set(pending.keys).union(buffers.keys).count
    }

    private func nextFreshPiece(peerHas: (Int) -> Bool) -> Int? {
        let count = meta.pieceHashes.count
        guard count > 0 else { return nil }
        let start = Int.random(in: 0..<count)
        for offset in 0..<count {
            let piece = (start + offset) % count
            if !have[piece] && pending[piece] == nil && buffers[piece] == nil
                && !pieceHasInflight(piece) && peerHas(piece) {
                return piece
            }
        }
        return nil
    }

    private func pieceHasInflight(_ piece: Int) -> Bool {
        inflight.keys.contains { $0.piece == piece }
    }

    func received(piece: Int, begin: Int, data: Data) -> ReceiveResult {
        guard piece >= 0, piece < meta.pieceHashes.count, !have[piece] else { return .ignored }
        let block = BlockRequest(piece: piece, begin: begin, length: data.count)
        inflight.removeValue(forKey: block)
        var pieceBuffer = buffers[piece] ?? [:]
        guard pieceBuffer[begin] == nil else { return .ignored }
        pieceBuffer[begin] = data
        buffers[piece] = pieceBuffer

        let receivedSize = pieceBuffer.values.reduce(0) { $0 + $1.count }
        guard receivedSize >= meta.pieceSize(piece) else { return .progress }

        // Assemble and verify.
        var assembled = Data(capacity: receivedSize)
        for begin in pieceBuffer.keys.sorted() {
            assembled.append(pieceBuffer[begin]!)
        }
        buffers.removeValue(forKey: piece)
        pending.removeValue(forKey: piece)

        guard Data(Insecure.SHA1.hash(data: assembled)) == meta.pieceHashes[piece] else {
            // Corrupt piece: throw it away and re-request.
            pending[piece] = blocks(for: piece)
            return .progress
        }

        store.write(offset: Int64(piece) * Int64(meta.pieceLength), data: assembled)
        have[piece] = true
        completedBytes += Int64(assembled.count)
        return isComplete ? .torrentDone : .pieceDone
    }

    /// Returns blocks owned by a disappearing peer to the pending pool.
    func release(owner: UUID) {
        for (block, info) in inflight where info.owner == owner {
            inflight.removeValue(forKey: block)
            guard !have[block.piece] else { continue }
            if buffers[block.piece]?[block.begin] != nil { continue }
            pending[block.piece, default: []].append(block)
        }
    }

    /// Re-queues requests that have been in flight too long.
    func requeueStale(timeout: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-timeout)
        for (block, info) in inflight where info.at < cutoff {
            inflight.removeValue(forKey: block)
            guard !have[block.piece] else { continue }
            if buffers[block.piece]?[block.begin] != nil { continue }
            pending[block.piece, default: []].append(block)
        }
    }

    func readBlock(piece: Int, begin: Int, length: Int) -> Data? {
        guard piece >= 0, piece < meta.pieceHashes.count, have[piece],
              length <= (1 << 17) else { return nil }
        return store.read(offset: Int64(piece) * Int64(meta.pieceLength) + Int64(begin), length: length)
    }
}
