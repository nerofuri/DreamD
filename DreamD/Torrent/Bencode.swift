import Foundation

enum BValue {
    case int(Int64)
    case bytes(Data)
    indirect case list([BValue])
    indirect case dict([String: BValue])

    var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    var bytesValue: Data? {
        if case .bytes(let v) = self { return v }
        return nil
    }

    var stringValue: String? {
        guard case .bytes(let v) = self else { return nil }
        return String(data: v, encoding: .utf8)
    }

    var listValue: [BValue]? {
        if case .list(let v) = self { return v }
        return nil
    }

    var dictValue: [String: BValue]? {
        if case .dict(let v) = self { return v }
        return nil
    }

    subscript(key: String) -> BValue? {
        dictValue?[key]
    }
}

enum BencodeError: Error {
    case malformed
}

enum Bencode {
    static func decode(_ data: Data) throws -> BValue {
        let parser = Parser(data)
        return try parser.parseValue(depth: 0)
    }

    /// Decodes a value from the start of `data`, returning the number of bytes consumed.
    static func decodePrefix(_ data: Data) throws -> (BValue, Int) {
        let parser = Parser(data)
        let value = try parser.parseValue(depth: 0)
        return (value, parser.position)
    }

    /// Returns the raw bytes of the top-level "info" dictionary of a .torrent file.
    /// Needed to compute the info hash exactly as encoded on the wire.
    static func infoSlice(_ data: Data) throws -> Data? {
        let parser = Parser(data)
        _ = try parser.parseValue(depth: 0)
        guard let range = parser.infoRange else { return nil }
        return data.subdata(in: range)
    }

    static func encode(_ value: BValue) -> Data {
        var out = Data()
        encode(value, into: &out)
        return out
    }

    private static func encode(_ value: BValue, into out: inout Data) {
        switch value {
        case .int(let v):
            out.append(Data("i\(v)e".utf8))
        case .bytes(let v):
            out.append(Data("\(v.count):".utf8))
            out.append(v)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { encode(item, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let entries):
            out.append(UInt8(ascii: "d"))
            for key in entries.keys.sorted() {
                encode(.bytes(Data(key.utf8)), into: &out)
                encode(entries[key]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }

    // MARK: - Parser

    private final class Parser {
        private let bytes: [UInt8]
        private(set) var position = 0
        var infoRange: Range<Int>?

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        func parseValue(depth: Int) throws -> BValue {
            guard position < bytes.count else { throw BencodeError.malformed }
            switch bytes[position] {
            case UInt8(ascii: "i"):
                return try parseInt()
            case UInt8(ascii: "l"):
                return try parseList(depth: depth)
            case UInt8(ascii: "d"):
                return try parseDict(depth: depth)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .bytes(try parseBytes())
            default:
                throw BencodeError.malformed
            }
        }

        private func parseInt() throws -> BValue {
            position += 1
            var text = ""
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") {
                text.append(Character(UnicodeScalar(bytes[position])))
                position += 1
            }
            guard position < bytes.count, let v = Int64(text) else { throw BencodeError.malformed }
            position += 1
            return .int(v)
        }

        private func parseBytes() throws -> Data {
            var lengthText = ""
            while position < bytes.count, bytes[position] != UInt8(ascii: ":") {
                let b = bytes[position]
                guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { throw BencodeError.malformed }
                lengthText.append(Character(UnicodeScalar(b)))
                position += 1
            }
            guard position < bytes.count, let length = Int(lengthText), length >= 0 else {
                throw BencodeError.malformed
            }
            position += 1
            guard position + length <= bytes.count else { throw BencodeError.malformed }
            let value = Data(bytes[position..<position + length])
            position += length
            return value
        }

        private func parseList(depth: Int) throws -> BValue {
            position += 1
            var items: [BValue] = []
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") {
                items.append(try parseValue(depth: depth + 1))
            }
            guard position < bytes.count else { throw BencodeError.malformed }
            position += 1
            return .list(items)
        }

        private func parseDict(depth: Int) throws -> BValue {
            position += 1
            var entries: [String: BValue] = [:]
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") {
                let keyData = try parseBytes()
                let key = String(data: keyData, encoding: .utf8) ?? keyData.hexString
                if depth == 0 && key == "info" {
                    let start = position
                    let value = try parseValue(depth: depth + 1)
                    infoRange = start..<position
                    entries[key] = value
                } else {
                    entries[key] = try parseValue(depth: depth + 1)
                }
            }
            guard position < bytes.count else { throw BencodeError.malformed }
            position += 1
            return .dict(entries)
        }
    }
}
