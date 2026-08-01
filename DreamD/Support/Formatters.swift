import Foundation
import SwiftUI

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func bytes(_ n: Int64) -> String {
        guard n > 0 else { return "0 KB" }
        return byteFormatter.string(fromByteCount: n)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "0 KB/s" }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Rolling window speed measurement.
final class SpeedMeter {
    private var samples: [(time: Date, bytes: Int64)] = []
    private let window: TimeInterval = 4
    private let lock = NSLock()

    func add(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        samples.append((Date(), bytes))
        trim()
    }

    var speed: Double {
        lock.lock(); defer { lock.unlock() }
        trim()
        guard let first = samples.first else { return 0 }
        let elapsed = max(Date().timeIntervalSince(first.time), 1)
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(total) / elapsed
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-window)
        samples.removeAll { $0.time < cutoff }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Chrome dark-theme palette.
enum ChromeColor {
    static let background = Color(hex: 0x202124)
    static let surface = Color(hex: 0x303134)
    static let card = Color(hex: 0x292A2D)
    static let chip = Color(hex: 0x3C4043)
    static let textPrimary = Color(hex: 0xE8EAED)
    static let textSecondary = Color(hex: 0x9AA0A6)
    static let blue = Color(hex: 0x8AB4F8)
    static let googleBlue = Color(hex: 0x4285F4)
    static let googleRed = Color(hex: 0xEA4335)
    static let googleYellow = Color(hex: 0xFBBC05)
    static let googleGreen = Color(hex: 0x34A853)
}

enum JSONDisk {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DreamD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func load<T: Codable>(_ name: String, fallback: T) -> T {
        guard let data = try? Data(contentsOf: url(for: name)),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    static func save<T: Codable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(for: name), options: .atomic)
    }
}

extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xFF))
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    mutating func appendUInt64BE(_ v: UInt64) {
        appendUInt32BE(UInt32(v >> 32)); appendUInt32BE(UInt32(v & 0xFFFF_FFFF))
    }

    func beUInt16(at offset: Int) -> UInt16 {
        var v: UInt16 = 0
        for k in 0..<2 { v = (v << 8) | UInt16(self[startIndex + offset + k]) }
        return v
    }

    func beUInt32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v = (v << 8) | UInt32(self[startIndex + offset + k]) }
        return v
    }

    func beUInt64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[startIndex + offset + k]) }
        return v
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum AppSettings {
    static var maxConnectionsPerDownload: Int {
        let v = UserDefaults.standard.integer(forKey: "maxConnections")
        return v > 0 ? min(v, 16) : 8
    }

    static var maxPeersPerTorrent: Int {
        let v = UserDefaults.standard.integer(forKey: "maxPeers")
        return v > 0 ? min(v, 60) : 30
    }
}
