import Foundation
import CryptoKit

struct TorrentFileEntry {
    let path: String       // relative path inside the torrent
    let length: Int64
    let offset: Int64      // absolute offset in the concatenated piece space
}

enum TorrentError: LocalizedError {
    case invalidTorrent
    case invalidMagnet
    case noTrackers

    var errorDescription: String? {
        switch self {
        case .invalidTorrent: return "Invalid or corrupted torrent file"
        case .invalidMagnet: return "Invalid magnet link"
        case .noTrackers: return "Magnet link has no trackers (DHT is not supported)"
        }
    }
}

struct TorrentMetaInfo {
    let name: String
    let infoHash: Data          // 20-byte SHA1 of the raw info dictionary
    let infoRaw: Data           // raw bencoded info dictionary (served to peers requesting metadata)
    let pieceLength: Int
    let pieceHashes: [Data]
    let files: [TorrentFileEntry]
    let totalLength: Int64
    let announceURLs: [String]

    init(torrentData: Data) throws {
        let root = try Bencode.decode(torrentData)
        guard let info = root["info"],
              let infoRaw = try Bencode.infoSlice(torrentData) else {
            throw TorrentError.invalidTorrent
        }
        try self.init(infoValue: info, infoRaw: infoRaw, announce: Self.trackers(from: root))
    }

    init(infoDictData: Data, announce: [String]) throws {
        let info = try Bencode.decode(infoDictData)
        try self.init(infoValue: info, infoRaw: infoDictData, announce: announce)
    }

    private init(infoValue: BValue, infoRaw: Data, announce: [String]) throws {
        guard let pieceLength = infoValue["piece length"]?.intValue, pieceLength > 0,
              let piecesData = infoValue["pieces"]?.bytesValue,
              piecesData.count % 20 == 0 else {
            throw TorrentError.invalidTorrent
        }

        self.infoRaw = infoRaw
        self.infoHash = Data(Insecure.SHA1.hash(data: infoRaw))
        self.pieceLength = Int(pieceLength)
        self.announceURLs = announce

        var hashes: [Data] = []
        var index = piecesData.startIndex
        while index < piecesData.endIndex {
            let next = piecesData.index(index, offsetBy: 20)
            hashes.append(piecesData.subdata(in: index..<next))
            index = next
        }
        self.pieceHashes = hashes

        let torrentName = infoValue["name"]?.stringValue ?? "torrent"
        self.name = torrentName

        var entries: [TorrentFileEntry] = []
        var offset: Int64 = 0
        if let fileList = infoValue["files"]?.listValue {
            for file in fileList {
                guard let length = file["length"]?.intValue,
                      let pathParts = file["path"]?.listValue else {
                    throw TorrentError.invalidTorrent
                }
                let components = pathParts.compactMap { $0.stringValue }
                    .map { $0.replacingOccurrences(of: "..", with: "_") }
                let path = components.joined(separator: "/")
                entries.append(TorrentFileEntry(path: path, length: length, offset: offset))
                offset += length
            }
        } else if let length = infoValue["length"]?.intValue {
            entries.append(TorrentFileEntry(path: torrentName, length: length, offset: 0))
            offset = length
        } else {
            throw TorrentError.invalidTorrent
        }
        self.files = entries
        self.totalLength = offset

        guard !pieceHashes.isEmpty, totalLength > 0 else { throw TorrentError.invalidTorrent }
    }

    func pieceSize(_ index: Int) -> Int {
        if index == pieceHashes.count - 1 {
            let remainder = Int(totalLength % Int64(pieceLength))
            return remainder == 0 ? pieceLength : remainder
        }
        return pieceLength
    }

    private static func trackers(from root: BValue) -> [String] {
        var urls: [String] = []
        if let tiers = root["announce-list"]?.listValue {
            for tier in tiers {
                for tracker in tier.listValue ?? [] {
                    if let s = tracker.stringValue { urls.append(s) }
                }
            }
        }
        if let announce = root["announce"]?.stringValue, !urls.contains(announce) {
            urls.insert(announce, at: 0)
        }
        return urls
    }
}

struct MagnetURI {
    let infoHash: Data
    let displayName: String?
    let trackers: [String]

    init?(_ string: String) {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "magnet",
              let items = components.queryItems else { return nil }

        var hash: Data?
        var name: String?
        var trackerList: [String] = []

        for item in items {
            guard let value = item.value else { continue }
            switch item.name.lowercased() {
            case "xt":
                let lower = value.lowercased()
                guard lower.hasPrefix("urn:btih:") else { continue }
                let id = String(value.dropFirst("urn:btih:".count))
                if id.count == 40, let data = M3U8Parser.dataFromHex(id) {
                    hash = data
                } else if id.count == 32, let data = Self.base32Decode(id) {
                    hash = data
                }
            case "dn":
                name = value
            case "tr":
                trackerList.append(value)
            default:
                break
            }
        }

        guard let infoHash = hash, infoHash.count == 20 else { return nil }
        self.infoHash = infoHash
        self.displayName = name
        self.trackers = trackerList
    }

    private static func base32Decode(_ s: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0
        var value = 0
        var out = Data()
        for ch in s.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: idx)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
