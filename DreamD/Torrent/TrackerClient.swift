import Foundation
import Network

struct PeerAddress: Hashable {
    let host: String
    let port: UInt16
}

struct TrackerResponse {
    let interval: Int
    let peers: [PeerAddress]
}

enum TrackerError: LocalizedError {
    case unsupportedScheme
    case badResponse
    case timeout
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Unsupported tracker protocol"
        case .badResponse: return "Malformed tracker response"
        case .timeout: return "Tracker timed out"
        case .failure(let reason): return reason
        }
    }
}

enum TrackerClient {
    static func announce(urlString: String, infoHash: Data, peerID: Data, port: UInt16,
                         uploaded: Int64, downloaded: Int64, left: Int64,
                         event: String?) async throws -> TrackerResponse {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw TrackerError.unsupportedScheme
        }
        switch scheme {
        case "http", "https":
            return try await announceHTTP(url: url, infoHash: infoHash, peerID: peerID, port: port,
                                          uploaded: uploaded, downloaded: downloaded, left: left, event: event)
        case "udp":
            guard let host = url.host, let udpPort = url.port.map({ UInt16($0) }) else {
                throw TrackerError.unsupportedScheme
            }
            return try await announceUDP(host: host, port: udpPort, infoHash: infoHash, peerID: peerID,
                                         listenPort: port, uploaded: uploaded, downloaded: downloaded,
                                         left: left, event: event)
        default:
            throw TrackerError.unsupportedScheme
        }
    }

    // MARK: - HTTP trackers

    private static func announceHTTP(url: URL, infoHash: Data, peerID: Data, port: UInt16,
                                     uploaded: Int64, downloaded: Int64, left: Int64,
                                     event: String?) async throws -> TrackerResponse {
        var query = url.query.map { $0 + "&" } ?? ""
        query += "info_hash=\(percentEncode(infoHash))"
        query += "&peer_id=\(percentEncode(peerID))"
        query += "&port=\(port)&uploaded=\(uploaded)&downloaded=\(downloaded)&left=\(left)"
        query += "&compact=1&numwant=80"
        if let event { query += "&event=\(event)" }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TrackerError.unsupportedScheme
        }
        components.percentEncodedQuery = query
        guard let requestURL = components.url else { throw TrackerError.unsupportedScheme }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let root = try Bencode.decode(data)

        if let failure = root["failure reason"]?.stringValue {
            throw TrackerError.failure(failure)
        }
        let interval = Int(root["interval"]?.intValue ?? 300)
        var peers: [PeerAddress] = []

        if let compact = root["peers"]?.bytesValue {
            peers.append(contentsOf: parseCompactPeers(compact))
        } else if let list = root["peers"]?.listValue {
            for entry in list {
                if let host = entry["ip"]?.stringValue,
                   let port = entry["port"]?.intValue, port > 0, port <= 65535 {
                    peers.append(PeerAddress(host: host, port: UInt16(port)))
                }
            }
        }
        return TrackerResponse(interval: interval, peers: peers)
    }

    static func parseCompactPeers(_ data: Data) -> [PeerAddress] {
        var peers: [PeerAddress] = []
        var offset = 0
        while offset + 6 <= data.count {
            let a = data[data.startIndex + offset]
            let b = data[data.startIndex + offset + 1]
            let c = data[data.startIndex + offset + 2]
            let d = data[data.startIndex + offset + 3]
            let port = data.beUInt16(at: offset + 4)
            if port > 0 {
                peers.append(PeerAddress(host: "\(a).\(b).\(c).\(d)", port: port))
            }
            offset += 6
        }
        return peers
    }

    private static func percentEncode(_ data: Data) -> String {
        var out = ""
        for byte in data {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - UDP trackers (BEP 15)

    private static func announceUDP(host: String, port: UInt16, infoHash: Data, peerID: Data,
                                    listenPort: UInt16, uploaded: Int64, downloaded: Int64,
                                    left: Int64, event: String?) async throws -> TrackerResponse {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port) ?? 6969,
                                      using: .udp)
        defer { connection.cancel() }
        try await ready(connection, timeout: 8)

        // Connect request.
        let transaction = UInt32.random(in: 0..<UInt32.max)
        var connectPacket = Data()
        connectPacket.appendUInt64BE(0x41727101980)
        connectPacket.appendUInt32BE(0)
        connectPacket.appendUInt32BE(transaction)
        let connectReply = try await exchange(connection, send: connectPacket, timeout: 8)
        guard connectReply.count >= 16,
              connectReply.beUInt32(at: 0) == 0,
              connectReply.beUInt32(at: 4) == transaction else {
            throw TrackerError.badResponse
        }
        let connectionID = connectReply.beUInt64(at: 8)

        // Announce request.
        let announceTransaction = UInt32.random(in: 0..<UInt32.max)
        let eventCode: UInt32
        switch event {
        case "completed": eventCode = 1
        case "started": eventCode = 2
        case "stopped": eventCode = 3
        default: eventCode = 0
        }
        var announcePacket = Data()
        announcePacket.appendUInt64BE(connectionID)
        announcePacket.appendUInt32BE(1)
        announcePacket.appendUInt32BE(announceTransaction)
        announcePacket.append(infoHash)
        announcePacket.append(peerID)
        announcePacket.appendUInt64BE(UInt64(max(0, downloaded)))
        announcePacket.appendUInt64BE(UInt64(max(0, left)))
        announcePacket.appendUInt64BE(UInt64(max(0, uploaded)))
        announcePacket.appendUInt32BE(eventCode)
        announcePacket.appendUInt32BE(0)                        // IP (default)
        announcePacket.appendUInt32BE(UInt32.random(in: 0..<UInt32.max)) // key
        announcePacket.appendUInt32BE(0xFFFF_FFFF)              // num_want (-1)
        announcePacket.appendUInt16BE(listenPort)

        let reply = try await exchange(connection, send: announcePacket, timeout: 8)
        guard reply.count >= 20,
              reply.beUInt32(at: 0) == 1,
              reply.beUInt32(at: 4) == announceTransaction else {
            throw TrackerError.badResponse
        }
        let interval = Int(reply.beUInt32(at: 8))
        let peerData = reply.subdata(in: (reply.startIndex + 20)..<reply.endIndex)
        return TrackerResponse(interval: interval, peers: parseCompactPeers(peerData))
    }

    private static func ready(_ connection: NWConnection, timeout: TimeInterval) async throws {
        let box = ResumeOnce<Void>()
        return try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                case .failed(let error):
                    box.resume(.failure(error))
                case .cancelled:
                    box.resume(.failure(TrackerError.timeout))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(.failure(TrackerError.timeout))
            }
        }
    }

    private static func exchange(_ connection: NWConnection, send packet: Data,
                                 timeout: TimeInterval) async throws -> Data {
        let box = ResumeOnce<Data>()
        return try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { box.resume(.failure(error)) }
            })
            connection.receiveMessage { data, _, _, error in
                if let data, !data.isEmpty {
                    box.resume(.success(data))
                } else {
                    box.resume(.failure(error ?? TrackerError.badResponse))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(.failure(TrackerError.timeout))
            }
        }
    }
}

/// Guards a checked continuation so it is resumed exactly once,
/// even when callbacks and timeouts race.
final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let stored = continuation
        continuation = nil
        lock.unlock()
        guard let stored else { return }
        switch result {
        case .success(let value): stored.resume(returning: value)
        case .failure(let error): stored.resume(throwing: error)
        }
    }
}
