import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let url: String
    var title: String
    var date: Date
    var visits: Int
}

struct TopSite: Identifiable {
    var id: String { url }
    let url: String
    let host: String
    let title: String
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry]

    private init() {
        entries = JSONDisk.load("history.json", fallback: [])
    }

    func add(url: URL, title: String) {
        let s = url.absoluteString
        guard !s.isEmpty, url.scheme?.hasPrefix("http") == true else { return }
        let cleanTitle = title.isEmpty ? (url.host ?? s) : title
        if let index = entries.firstIndex(where: { $0.url == s }) {
            var entry = entries.remove(at: index)
            entry.title = cleanTitle
            entry.date = Date()
            entry.visits += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(HistoryEntry(url: s, title: cleanTitle, date: Date(), visits: 1), at: 0)
        }
        if entries.count > 2000 {
            entries.removeLast(entries.count - 2000)
        }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    var topSites: [TopSite] {
        var byHost: [String: (visits: Int, entry: HistoryEntry)] = [:]
        for entry in entries {
            guard let host = URL(string: entry.url)?.host else { continue }
            if let existing = byHost[host] {
                byHost[host] = (existing.visits + entry.visits,
                                existing.entry.visits >= entry.visits ? existing.entry : entry)
            } else {
                byHost[host] = (entry.visits, entry)
            }
        }
        return byHost
            .sorted { $0.value.visits > $1.value.visits }
            .prefix(5)
            .map { host, value in
                TopSite(url: "https://\(host)",
                        host: host.replacingOccurrences(of: "www.", with: ""),
                        title: value.entry.title)
            }
    }

    private func save() {
        JSONDisk.save(entries, name: "history.json")
    }
}

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    let url: String
    var title: String
    var date: Date
}

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    private let fileName: String

    @Published private(set) var entries: [Bookmark]

    init(fileName: String = "bookmarks.json") {
        self.fileName = fileName
        entries = JSONDisk.load(fileName, fallback: [])
    }

    /// Chrome-style Reading List, stored separately from bookmarks.
    static let readingList = BookmarkStore(fileName: "readinglist.json")

    func contains(_ url: URL) -> Bool {
        entries.contains { $0.url == url.absoluteString }
    }

    func toggle(url: URL, title: String) {
        if let index = entries.firstIndex(where: { $0.url == url.absoluteString }) {
            entries.remove(at: index)
        } else {
            entries.insert(Bookmark(url: url.absoluteString,
                                    title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                                    date: Date()), at: 0)
        }
        save()
    }

    func remove(_ bookmark: Bookmark) {
        entries.removeAll { $0.id == bookmark.id }
        save()
    }

    private func save() {
        JSONDisk.save(entries, name: fileName)
    }
}
