import Foundation
import CryptoKit

/// Orchestrates a single torrent download: tracker announces, peer
/// connections, metadata fetching for magnet links, piece scheduling,
/// and serving blocks back to peers that request them.
final class TorrentDownloader: NSObject, DownloadWorker {
    private let item: DownloadItem
    private let queue = DispatchQueue(label: "dreamd.torrent.engine")
    private let peerID: Data = TorrentDownloader.makePeerID()
    private let listenPort: UInt16 = 6881

    private var magnet: MagnetURI?
    private var meta: TorrentMetaInfo?
    private var pieceManager: PieceManager?
    private var store: TorrentFileStore?
    private var trackers: [String] = []

    private var knownPeers: Set<PeerAddress> = []
    private var attemptedPeers: Set<PeerAddress> = []
    private var connections: [UUID: PeerWireConnection] = [:]
    private var outstanding: [UUID: Int] = [:]
    private let pipelineDepth = 12

    private var running = false
    private var storageReady = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastAnnounce = Date.distantPast
    private let announceInterval: TimeInterval = 300
    private var metadataBuffer: [Int: Data] = [:]
    private var metadataTotalSize = 0
    private var uploadedBytes: Int64 = 0
    private let meter = SpeedMeter()

    init(item: DownloadItem, magnet: MagnetURI) {
        self.item = item
        self.magnet = magnet
        self.trackers = magnet.trackers
        super.init()
    }

    init(item: DownloadItem, meta: TorrentMetaInfo) {
        self.item = item
        self.meta = meta
        self.trackers = meta.announceURLs
        super.init()
    }

    private var infoHash: Data {
        meta?.infoHash ?? magnet?.infoHash ?? Data(count: 20)
    }

    // MARK: - DownloadWorker

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            guard !self.trackers.isEmpty else {
                self.item.fail(TorrentError.noTrackers.localizedDescription)
                return
            }
            self.running = true
            self.item.update { $0.state = .fetchingInfo; $0.errorMessage = nil }
            if self.meta != nil {
                self.setupStorageIfNeeded()
            }
            self.announceAll(event: "started")
            self.startMaintenance()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.stopMaintenance()
            for peer in self.connections.values { peer.close() }
            self.connections.removeAll()
            self.outstanding.removeAll()
            self.attemptedPeers.removeAll()
            self.meter.reset()
            self.announceAll(event: "stopped")
            self.item.update { $0.state = .paused; $0.speed = 0 }
        }
    }

    func resume() {
        start()
    }

    func cancel() {
        pause()
        queue.async { [weak self] in
            self?.store?.closeAll()
        }
    }

    // MARK: - Storage

    private func setupStorageIfNeeded() {
        guard let meta, !storageReady else { return }
        do {
            let store = try TorrentFileStore(meta: meta, downloadsDirectory: DownloadManager.downloadsDirectory)
            let pm = PieceManager(meta: meta, store: store)
            pm.verifyExistingData()
            self.store = store
            self.pieceManager = pm
            self.storageReady = true
            self.item.destinationURL = store.rootURL
            let total = meta.totalLength
            let done = pm.completedBytes
            let name = meta.name
            item.update {
                $0.name = name
                $0.totalBytes = total
                $0.receivedBytes = done
                $0.state = .downloading
            }
            if pm.isComplete {
                finishTorrent()
            }
        } catch {
            item.fail("Could not create files: \(error.localizedDescription)")
            running = false
        }
    }

    // MARK: - Trackers

    private func announceAll(event: String?) {
        lastAnnounce = Date()
        let left = meta.map { max(0, $0.totalLength - (pieceManager?.completedBytes ?? 0)) } ?? (1 << 20)
        let downloaded = pieceManager?.completedBytes ?? 0
        let uploaded = uploadedBytes
        let hash = infoHash
        let id = peerID
        let port = listenPort

        for tracker in trackers {
            Task.detached { [weak self] in
                do {
                    let response = try await TrackerClient.announce(
                        urlString: tracker, infoHash: hash, peerID: id, port: port,
                        uploaded: uploaded, downloaded: downloaded, left: left, event: event)
                    self?.queue.async {
                        guard let self, self.running else { return }
                        self.knownPeers.formUnion(response.peers)
                        self.dialPeers()
                    }
                } catch {
                    // Individual tracker failures are expected; other trackers cover for it.
                }
            }
        }
    }

    // MARK: - Peer management

    private func dialPeers() {
        guard running else { return }
        let maxPeers = AppSettings.maxPeersPerTorrent
        guard connections.count < maxPeers else { return }
        let candidates = knownPeers.subtracting(attemptedPeers).prefix(maxPeers - connections.count)
        for address in candidates {
            attemptedPeers.insert(address)
            let peer = PeerWireConnection(address: address, infoHash: infoHash, peerID: peerID, queue: queue)
            peer.delegate = self
            connections[peer.id] = peer
            outstanding[peer.id] = 0
            peer.connect()
        }
    }

    private func topUpRequests(_ peer: PeerWireConnection) {
        guard running, storageReady, let pm = pieceManager, !peer.peerChoking, peer.amInterested else { return }
        var current = outstanding[peer.id] ?? 0
        while current < pipelineDepth {
            let requests = pm.assign(to: peer.id, peerHas: peer.hasPiece, max: pipelineDepth - current)
            guard !requests.isEmpty else { break }
            for request in requests {
                peer.sendRequest(index: request.piece, begin: request.begin, length: request.length)
            }
            current += requests.count
        }
        outstanding[peer.id] = current
    }

    // MARK: - Maintenance

    private func startMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.pieceManager?.requeueStale(timeout: 25)
            for peer in self.connections.values where peer.handshaked {
                self.topUpRequests(peer)
            }
            if Date().timeIntervalSince(self.lastAnnounce) > self.announceInterval {
                self.announceAll(event: nil)
                // Allow another attempt at peers that failed earlier.
                self.attemptedPeers = Set(self.connections.values.map { $0.address })
            }
            self.dialPeers()
            self.publishStats()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    private func stopMaintenance() {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
    }

    private func publishStats() {
        let peerCount = connections.values.filter { $0.handshaked }.count
        let speed = meter.speed
        let received = pieceManager?.completedBytes
        let fetchingMetadata = !storageReady
        item.update {
            if let received { $0.receivedBytes = received }
            $0.speed = speed
            if fetchingMetadata {
                $0.detail = "\(peerCount) peers • fetching metadata"
            } else {
                $0.detail = "\(peerCount) peers"
            }
        }
    }

    // MARK: - Completion

    private func finishTorrent() {
        running = false
        stopMaintenance()
        for peer in connections.values { peer.close() }
        connections.removeAll()
        outstanding.removeAll()
        let total = meta?.totalLength ?? 0
        item.update {
            $0.state = .completed
            $0.receivedBytes = total
            $0.speed = 0
            $0.detail = ""
        }
        DownloadManager.shared.persistSoon()
        announceAllDetachedCompleted()
    }

    private func announceAllDetachedCompleted() {
        let hash = infoHash
        let id = peerID
        let port = listenPort
        let total = meta?.totalLength ?? 0
        let uploaded = uploadedBytes
        for tracker in trackers {
            Task.detached {
                _ = try? await TrackerClient.announce(urlString: tracker, infoHash: hash, peerID: id,
                                                      port: port, uploaded: uploaded,
                                                      downloaded: total, left: 0, event: "completed")
            }
        }
    }

    // MARK: - Metadata (magnet links)

    private func requestMetadata(from peer: PeerWireConnection) {
        guard meta == nil, peer.utMetadataID > 0, peer.metadataSize > 0 else { return }
        if metadataTotalSize == 0 {
            metadataTotalSize = peer.metadataSize
        }
        let pieceCount = (metadataTotalSize + 16383) / 16384
        for piece in 0..<pieceCount where metadataBuffer[piece] == nil {
            peer.sendMetadataRequest(piece: piece)
        }
    }

    private func assembleMetadataIfComplete() {
        guard meta == nil, metadataTotalSize > 0 else { return }
        let pieceCount = (metadataTotalSize + 16383) / 16384
        guard metadataBuffer.count >= pieceCount else { return }
        var assembled = Data()
        for piece in 0..<pieceCount {
            guard let chunk = metadataBuffer[piece] else { return }
            assembled.append(chunk)
        }
        if assembled.count > metadataTotalSize {
            assembled = assembled.subdata(in: assembled.startIndex..<(assembled.startIndex + metadataTotalSize))
        }
        guard Data(Insecure.SHA1.hash(data: assembled)) == infoHash,
              let newMeta = try? TorrentMetaInfo(infoDictData: assembled, announce: trackers) else {
            metadataBuffer.removeAll()
            return
        }
        meta = newMeta
        setupStorageIfNeeded()
        guard storageReady, let pm = pieceManager else { return }
        for peer in connections.values where peer.handshaked {
            if pm.have.setCount > 0 {
                peer.sendBitfield(pm.have)
            }
            if pm.amInterested(peerHas: peer.hasPiece) {
                peer.sendInterested()
            }
        }
    }

    private static func makePeerID() -> Data {
        var id = Data("-DD0100-".utf8)
        for _ in 0..<12 {
            id.append(UInt8.random(in: 0...255))
        }
        return id
    }
}

// MARK: - PeerWireDelegate

extension TorrentDownloader: PeerWireDelegate {
    func peerHandshaked(_ peer: PeerWireConnection) {
        guard running else { return }
        if storageReady, let pm = pieceManager {
            if pm.have.setCount > 0 {
                peer.sendBitfield(pm.have)
            }
        }
    }

    func peerExtendedHandshake(_ peer: PeerWireConnection) {
        guard running else { return }
        requestMetadata(from: peer)
    }

    func peerClosed(_ peer: PeerWireConnection, error: Error?) {
        connections.removeValue(forKey: peer.id)
        outstanding.removeValue(forKey: peer.id)
        pieceManager?.release(owner: peer.id)
        if running { dialPeers() }
    }

    func peerChoked(_ peer: PeerWireConnection) {
        pieceManager?.release(owner: peer.id)
        outstanding[peer.id] = 0
    }

    func peerUnchoked(_ peer: PeerWireConnection) {
        topUpRequests(peer)
    }

    func peerHasPieces(_ peer: PeerWireConnection) {
        guard running, storageReady, let pm = pieceManager else { return }
        if !peer.amInterested && pm.amInterested(peerHas: peer.hasPiece) {
            peer.sendInterested()
        }
        topUpRequests(peer)
    }

    func peerInterestedChanged(_ peer: PeerWireConnection) {
        if peer.peerInterested {
            peer.sendUnchoke()
        }
    }

    func peer(_ peer: PeerWireConnection, gotBlock index: Int, begin: Int, data: Data) {
        guard running, let pm = pieceManager else { return }
        outstanding[peer.id] = max(0, (outstanding[peer.id] ?? 1) - 1)
        meter.add(Int64(data.count))
        switch pm.received(piece: index, begin: begin, data: data) {
        case .pieceDone:
            for other in connections.values where other.handshaked {
                other.sendHave(index)
            }
            let received = pm.completedBytes
            item.update { $0.receivedBytes = received }
            topUpRequests(peer)
        case .torrentDone:
            for other in connections.values where other.handshaked {
                other.sendHave(index)
            }
            finishTorrent()
        case .progress, .ignored:
            topUpRequests(peer)
        }
    }

    func peer(_ peer: PeerWireConnection, wantsBlock index: Int, begin: Int, length: Int) {
        guard running, let pm = pieceManager,
              let block = pm.readBlock(piece: index, begin: begin, length: length) else { return }
        peer.sendPiece(index: index, begin: begin, block: block)
        uploadedBytes += Int64(length)
    }

    func peer(_ peer: PeerWireConnection, gotMetadataPiece piece: Int, totalSize: Int, data: Data) {
        guard meta == nil else { return }
        if metadataTotalSize == 0 && totalSize > 0 {
            metadataTotalSize = totalSize
        }
        metadataBuffer[piece] = data
        assembleMetadataIfComplete()
    }

    func peer(_ peer: PeerWireConnection, metadataRequest piece: Int) {
        guard let meta else {
            peer.sendMetadataReject(piece: piece)
            return
        }
        let start = piece * 16384
        guard start < meta.infoRaw.count else {
            peer.sendMetadataReject(piece: piece)
            return
        }
        let end = min(start + 16384, meta.infoRaw.count)
        let chunk = meta.infoRaw.subdata(in: (meta.infoRaw.startIndex + start)..<(meta.infoRaw.startIndex + end))
        peer.sendMetadataData(piece: piece, totalSize: meta.infoRaw.count, data: chunk)
    }

    func peerMetadataRejected(_ peer: PeerWireConnection) {
        // This peer won't give us metadata; others may.
    }
}
