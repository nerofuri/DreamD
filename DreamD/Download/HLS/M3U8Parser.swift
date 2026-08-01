import Foundation

struct M3U8Playlist {
    struct Variant {
        let url: URL
        let bandwidth: Int
        let resolution: String?
    }

    struct Key {
        let method: String
        let url: URL?
        let iv: Data?
    }

    struct Segment {
        let url: URL
        let duration: Double
        let key: Key?
        let sequence: Int
    }

    var isMaster = false
    var variants: [Variant] = []
    var segments: [Segment] = []
    var mapURL: URL?
    var isLive = false
}

enum M3U8Parser {
    static func parse(_ text: String, baseURL: URL) -> M3U8Playlist {
        var playlist = M3U8Playlist()
        var currentKey: M3U8Playlist.Key?
        var pendingVariant: [String: String]?
        var pendingDuration: Double = 0
        var mediaSequence = 0
        var sawEndList = false
        var segmentIndex = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                playlist.isMaster = true
                pendingVariant = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                var keyURL: URL?
                if let uri = attrs["URI"] {
                    keyURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL
                }
                var iv: Data?
                if let ivString = attrs["IV"] {
                    iv = dataFromHex(ivString)
                }
                currentKey = M3U8Playlist.Key(method: method, url: keyURL, iv: iv)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"] {
                    playlist.mapURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL
                }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                let durationPart = value.split(separator: ",").first ?? ""
                pendingDuration = Double(durationPart) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                sawEndList = true
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                if let variant = pendingVariant {
                    playlist.variants.append(M3U8Playlist.Variant(
                        url: url,
                        bandwidth: Int(variant["BANDWIDTH"] ?? "") ?? 0,
                        resolution: variant["RESOLUTION"]))
                    pendingVariant = nil
                } else {
                    playlist.segments.append(M3U8Playlist.Segment(
                        url: url,
                        duration: pendingDuration,
                        key: currentKey,
                        sequence: mediaSequence + segmentIndex))
                    segmentIndex += 1
                    pendingDuration = 0
                }
            }
        }

        playlist.isLive = !playlist.isMaster && !sawEndList
        return playlist
    }

    /// Parses `KEY=value,KEY="quoted,value"` attribute lists.
    static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false

        func commit() {
            if !key.isEmpty {
                result[key.trimmingCharacters(in: .whitespaces)] = value
            }
            key = ""; value = ""; inKey = true
        }

        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else { key.append(ch) }
            } else if inQuotes {
                if ch == "\"" { inQuotes = false } else { value.append(ch) }
            } else {
                if ch == "\"" { inQuotes = true }
                else if ch == "," { commit() }
                else { value.append(ch) }
            }
        }
        commit()
        return result
    }

    static func dataFromHex(_ hex: String) -> Data? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
