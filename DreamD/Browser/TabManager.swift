import Foundation
import WebKit
import Combine

struct ClosedTab: Identifiable {
    let id = UUID()
    let title: String
    let url: URL?
}

final class TabManager: ObservableObject {
    static let shared = TabManager()

    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var showTabGrid = false
    @Published private(set) var recentlyClosed: [ClosedTab] = []

    private init() {
        let tab = BrowserTab()
        tabs = [tab]
        selectedID = tab.id
    }

    var selected: BrowserTab? {
        tabs.first { $0.id == selectedID }
    }

    var normalTabs: [BrowserTab] { tabs.filter { !$0.isIncognito } }
    var incognitoTabs: [BrowserTab] { tabs.filter { $0.isIncognito } }

    @discardableResult
    func newTab(incognito: Bool = false, url: URL? = nil,
                configuration: WKWebViewConfiguration? = nil,
                select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(incognito: incognito, configuration: configuration)
        tabs.append(tab)
        if select {
            selectedID = tab.id
            showTabGrid = false
        }
        if let url {
            tab.loadURL(url)
        }
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.isIncognito, !tab.isNewTabPage {
            recentlyClosed.insert(ClosedTab(title: tab.title, url: tab.currentURL), at: 0)
            if recentlyClosed.count > 20 { recentlyClosed.removeLast() }
        }
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = BrowserTab()
            tabs = [fresh]
            selectedID = fresh.id
        } else if selectedID == tab.id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeAll(incognitoOnly: Bool = false) {
        for tab in tabs where !incognitoOnly || tab.isIncognito {
            close(tab)
        }
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        showTabGrid = false
    }
}
