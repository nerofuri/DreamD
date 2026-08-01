import Foundation
import Network

protocol PeerWireDelegate: AnyObject {
    func peerHandshaked(_ peer: PeerWireConnection)
    func peerExtendedHandshake(_ peer: PeerWireConnection)
    func peerClosed(_ peer: PeerWireConnection, error: Error?)
    func peerChoked(_ peer: PeerWireConnection)
    func peerUnchoked(_ peer: PeerWireConnection)
    func peerHasPieces(_ peer: PeerWireConnection)
    func peerInterestedChanged(_ peer: PeerWireConnection)
    func peer(_ peer: PeerWireConnection, gotBlock index: Int, begin: Int, data: Data)
    func peer(_ peer: PeerWireConnection, wantsBlock index: Int, begin: Int, length: Int)
    func peer(_ peer: PeerWireConnection, gotMetadataPiece piece: Int, totalSize: Int, data: Data)
    func peer(_ peer: PeerWireConnection, metadataRequest piece: Int)
    func peerMetadataRejected(_ peer: PeerWireConnection)
}

/// A single BitTorrent peer connection (BEP 3 wire protocol) with support for
/// the extension protocol (BEP 10) and metadata exchange (BEP 9, ut_metadata),
/// which is what makes magnet links work.
final class PeerWireConnection {
    let id = UUID()
    let address: PeerAddress

    private let infoHash: Data
    private let myPeerID: Data
    private let queue: DispatchQueue
    weak var delegate: PeerWireDelegate?

    private var connection: NWConnection?
    private var buffer = Data()
    private(set) var handshaked = false
    private(set) var peerChoking = true
    private(set) var amChoking = true
    private(set) var amInterested = false
    private(set) var peerInterested = false
    private(set) var peerSupportsExtended = false
    private(set) var utMetadataID = 0
    private(set) var metadataSize = 0
    private var rawBitfield: [UInt8] = []
    private var closed = false

    /// The extension message ID we advertise for ut_metadata: peers send
    /// metadata messages back to us using this ID.
    static let localMetadataID: UInt8 = 2

    init(address: PeerAddress, infoHash: Data, peerID: Data, queue: DispatchQueue) {
        self.address = address
        self.infoHash = infoHash
        self.myPeerID = peerID
        self.queue = queue
    }

    func hasPiece(_ index: Int) -> Bool {
        let byte = index >> 3
        guard byte >= 0, byte < rawBitfield.count else { return false }
        return (rawBitfield[byte] >> (7 - UInt8(index & 7))) & 1 == 1
    }

    // MARK: - Lifecycle

    func connect() {
        guard let port = NWEndpoint.Port(rawValue: address.port) else {
            delegate?.peerClosed(self, error: TrackerError.badResponse)
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
                self.receiveLoop()
            case .failed(let error):
                self.closeInternal(error: error)
            case .waiting(let error):
                self.closeInternal(error: error)
            case .cancelled:
                self.closeInternal(error: nil)
            default:
                break
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.handshaked, !self.closed else { return }
            self.closeInternal(error: TrackerError.timeout)
        }
    }

    func close() {
        closed = true
        connection?.cancel()
        connection = nil
    }

    private func closeInternal(error: Error?) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        delegate?.peerClosed(self, error: error)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.closeInternal(error: error)
                return
            }
            self.receiveLoop()
        }
    }

    private func processBuffer() {
        while !closed {
            if !handshaked {
                guard buffer.count >= 68 else { return }
                guard buffer[buffer.startIndex] == 19 else {
                    closeInternal(error: TrackerError.badResponse)
                    return
                }
                let theirHash = buffer.subdata(in: (buffer.startIndex + 28)..<(buffer.startIndex + 48))
                guard theirHash == infoHash else {
                    closeInternal(error: TrackerError.badResponse)
                    return
                }
                peerSupportsExtended = (buffer[buffer.startIndex + 25] & 0x10) != 0
                consume(68)
                handshaked = true
                if peerSupportsExtended {
                    sendExtendedHandshake()
                }
                delegate?.peerHandshaked(self)
                continue
            }

            guard buffer.count >= 4 else { return }
            let length = Int(buffer.beUInt32(at: 0))
            if length == 0 {
                consume(4)   // keep-alive
                continue
            }
            guard length <= (1 << 18) else {
                closeInternal(error: TrackerError.badResponse)
                return
            }
            guard buffer.count >= 4 + length else { return }
            let messageID = buffer[buffer.startIndex + 4]
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 4 + length))
            consume(4 + length)
            handleMessage(id: messageID, payload: payload)
        }
    }

    private func consume(_ n: Int) {
        buffer = buffer.subdata(in: (buffer.startIndex + n)..<buffer.endIndex)
    }

    private func handleMessage(id: UInt8, payload: Data) {
        switch id {
        case 0:
            peerChoking = true
            delegate?.peerChoked(self)
        case 1:
            peerChoking = false
            delegate?.peerUnchoked(self)
        case 2:
            peerInterested = true
            delegate?.peerInterestedChanged(self)
        case 3:
            peerInterested = false
            delegate?.peerInterestedChanged(self)
        case 4:
            guard payload.count >= 4 else { return }
            setRawBit(Int(payload.beUInt32(at: 0)))
            delegate?.peerHasPieces(self)
        case 5:
            rawBitfield = [UInt8](payload)
            delegate?.peerHasPieces(self)
        case 6:
            guard payload.count >= 12 else { return }
            delegate?.peer(self,
                           wantsBlock: Int(payload.beUInt32(at: 0)),
                           begin: Int(payload.beUInt32(at: 4)),
                           length: Int(payload.beUInt32(at: 8)))
        case 7:
            guard payload.count > 8 else { return }
            let index = Int(payload.beUInt32(at: 0))
            let begin = Int(payload.beUInt32(at: 4))
            let block = payload.subdata(in: (payload.startIndex + 8)..<payload.endIndex)
            delegate?.peer(self, gotBlock: index, begin: begin, data: block)
        case 20:
            guard payload.count >= 1 else { return }
            let extensionID = payload[payload.startIndex]
            let body = payload.subdata(in: (payload.startIndex + 1)..<payload.endIndex)
            handleExtended(extensionID: extensionID, body: body)
        default:
            break
        }
    }

    private func setRawBit(_ index: Int) {
        let byte = index >> 3
        guard byte >= 0, byte < (1 << 21) else { return }
        if byte >= rawBitfield.count {
            rawBitfield.append(contentsOf: [UInt8](repeating: 0, count: byte - rawBitfield.count + 1))
        }
        rawBitfield[byte] |= 1 << (7 - UInt8(index & 7))
    }

    private func handleExtended(extensionID: UInt8, body: Data) {
        if extensionID == 0 {
            guard let dict = try? Bencode.decode(body) else { return }
            if let m = dict["m"]?.dictValue, let metadataID = m["ut_metadata"]?.intValue {
                utMetadataID = Int(metadataID)
            }
            if let size = dict["metadata_size"]?.intValue {
                metadataSize = Int(size)
            }
            delegate?.peerExtendedHandshake(self)
        } else if extensionID == Self.localMetadataID {
            guard let (header, consumed) = try? Bencode.decodePrefix(body),
                  let type = header["msg_type"]?.intValue,
                  let piece = header["piece"]?.intValue else { return }
            switch type {
            case 0:
                delegate?.peer(self, metadataRequest: Int(piece))
            case 1:
                let total = Int(header["total_size"]?.intValue ?? 0)
                let data = body.subdata(in: (body.startIndex + consumed)..<body.endIndex)
                delegate?.peer(self, gotMetadataPiece: Int(piece), totalSize: total, data: data)
            case 2:
                delegate?.peerMetadataRejected(self)
            default:
                break
            }
        }
    }

    // MARK: - Sending

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendHandshake() {
        var packet = Data()
        packet.append(19)
        packet.append(Data("BitTorrent protocol".utf8))
        var reserved = Data(count: 8)
        reserved[5] = 0x10   // extension protocol (BEP 10)
        packet.append(reserved)
        packet.append(infoHash)
        packet.append(myPeerID)
        sendRaw(packet)
    }

    private func sendMessage(id: UInt8, payload: Data = Data()) {
        var packet = Data()
        packet.appendUInt32BE(UInt32(1 + payload.count))
        packet.append(id)
        packet.append(payload)
        sendRaw(packet)
    }

    func sendInterested() {
        guard !amInterested else { return }
        amInterested = true
        sendMessage(id: 2)
    }

    func sendNotInterested() {
        guard amInterested else { return }
        amInterested = false
        sendMessage(id: 3)
    }

    func sendUnchoke() {
        guard amChoking else { return }
        amChoking = false
        sendMessage(id: 1)
    }

    func sendHave(_ index: Int) {
        var payload = Data()
        payload.appendUInt32BE(UInt32(index))
        sendMessage(id: 4, payload: payload)
    }

    func sendBitfield(_ bitfield: Bitfield) {
        sendMessage(id: 5, payload: bitfield.data)
    }

    func sendRequest(index: Int, begin: Int, length: Int) {
        var payload = Data()
        payload.appendUInt32BE(UInt32(index))
        payload.appendUInt32BE(UInt32(begin))
        payload.appendUInt32BE(UInt32(length))
        sendMessage(id: 6, payload: payload)
    }

    func sendPiece(index: Int, begin: Int, block: Data) {
        var payload = Data()
        payload.appendUInt32BE(UInt32(index))
        payload.appendUInt32BE(UInt32(begin))
        payload.append(block)
        sendMessage(id: 7, payload: payload)
    }

    func sendExtendedHandshake(metadataSize: Int? = nil) {
        var dict: [String: BValue] = [
            "m": .dict(["ut_metadata": .int(Int64(Self.localMetadataID))])
        ]
        if let metadataSize {
            dict["metadata_size"] = .int(Int64(metadataSize))
        }
        var payload = Data([0])
        payload.append(Bencode.encode(.dict(dict)))
        sendMessage(id: 20, payload: payload)
    }

    func sendMetadataRequest(piece: Int) {
        guard utMetadataID > 0 else { return }
        var payload = Data([UInt8(utMetadataID)])
        payload.append(Bencode.encode(.dict(["msg_type": .int(0), "piece": .int(Int64(piece))])))
        sendMessage(id: 20, payload: payload)
    }

    func sendMetadataData(piece: Int, totalSize: Int, data: Data) {
        guard utMetadataID > 0 else { return }
        var payload = Data([UInt8(utMetadataID)])
        payload.append(Bencode.encode(.dict([
            "msg_type": .int(1),
            "piece": .int(Int64(piece)),
            "total_size": .int(Int64(totalSize))
        ])))
        payload.append(data)
        sendMessage(id: 20, payload: payload)
    }

    func sendMetadataReject(piece: Int) {
        guard utMetadataID > 0 else { return }
        var payload = Data([UInt8(utMetadataID)])
        payload.append(Bencode.encode(.dict(["msg_type": .int(2), "piece": .int(Int64(piece))])))
        sendMessage(id: 20, payload: payload)
    }
}
