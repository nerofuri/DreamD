import SwiftUI

/// The Chrome-style new tab page: Google wordmark, search box, chips,
/// top sites, and the Shortcuts card.
struct NewTabPage: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var history = HistoryStore.shared

    var showBookmarks: () -> Void
    var showReadingList: () -> Void
    var showRecentTabs: () -> Void
    var showHistory: () -> Void
    var showSettings: () -> Void

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                topBar
                GoogleWordmark()
                    .padding(.top, 8)
                searchCapsule
                chipsRow
                topSitesRow
                shortcutsCard
                discoverCard
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 16)
        }
        .background(ChromeColor.background)
        .scrollDismissesKeyboard(.immediately)
    }

    private var topBar: some View {
        HStack {
            Button(action: showBookmarks) {
                Image(systemName: "pencil")
                    .font(.system(size: 17))
                    .foregroundColor(ChromeColor.blue)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ChromeColor.surface))
            }
            Spacer()
            Button(action: showSettings) {
                ZStack {
                    Circle()
                        .fill(ChromeColor.googleBlue)
                        .frame(width: 34, height: 34)
                    Text("D")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.top, 12)
    }

    private var searchCapsule: some View {
        HStack(spacing: 10) {
            Text("G")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(ChromeColor.googleBlue)
            TextField("Search Google or type URL", text: $searchText)
                .focused($searchFocused)
                .font(.system(size: 17))
                .foregroundColor(ChromeColor.textPrimary)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    tab.load(searchText)
                    searchText = ""
                    searchFocused = false
                }
            Image(systemName: "mic.fill")
                .font(.system(size: 16))
                .foregroundColor(ChromeColor.textSecondary)
            Rectangle()
                .fill(ChromeColor.textSecondary.opacity(0.4))
                .frame(width: 1, height: 20)
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 16))
                .foregroundColor(ChromeColor.textSecondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Capsule().fill(ChromeColor.surface))
    }

    private var chipsRow: some View {
        HStack(spacing: 12) {
            chip(icon: "sparkles", label: "AI Mode") {
                tab.load("https://www.google.com/search?udm=50")
            }
            chip(icon: "eyeglasses", label: "Incognito") {
                tabManager.newTab(incognito: true)
            }
        }
    }

    private func chip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 16))
            }
            .foregroundColor(ChromeColor.textPrimary)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(Capsule().fill(ChromeColor.chip))
        }
    }

    private var topSitesRow: some View {
        let sites = history.topSites
        let display = sites.isEmpty ? Self.defaultSites : sites
        return HStack(alignment: .top, spacing: 8) {
            ForEach(display) { site in
                Button {
                    if let url = URL(string: site.url) { tab.loadURL(url) }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(ChromeColor.surface)
                                .frame(width: 50, height: 50)
                            Text(String(site.host.prefix(1)).uppercased())
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(ChromeColor.blue)
                        }
                        Text(site.host)
                            .font(.system(size: 12))
                            .foregroundColor(ChromeColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(ChromeColor.card))
    }

    private static let defaultSites: [TopSite] = [
        TopSite(url: "https://www.google.com", host: "google.com", title: "Google"),
        TopSite(url: "https://www.youtube.com", host: "youtube.com", title: "YouTube"),
        TopSite(url: "https://www.wikipedia.org", host: "wikipedia.org", title: "Wikipedia"),
        TopSite(url: "https://www.ebay.com", host: "ebay.com", title: "eBay"),
        TopSite(url: "https://www.reddit.com", host: "reddit.com", title: "Reddit")
    ]

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shortcuts")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(ChromeColor.textPrimary)
            HStack(spacing: 12) {
                shortcut(icon: "star", label: "Bookmarks", action: showBookmarks)
                shortcut(icon: "list.bullet.rectangle", label: "Reading list", action: showReadingList)
                shortcut(icon: "laptopcomputer.and.iphone", label: "Recent tabs", action: showRecentTabs)
                shortcut(icon: "clock.arrow.circlepath", label: "History", action: showHistory)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(ChromeColor.card))
    }

    private func shortcut(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(ChromeColor.blue)
                    .frame(width: 64, height: 56)
                    .background(RoundedRectangle(cornerRadius: 14).fill(ChromeColor.chip.opacity(0.7)))
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(ChromeColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var discoverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discover")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(ChromeColor.textPrimary)
            Text("Pages you visit often and downloads you start will show up across DreamD. Use the download button that appears on pages with video to save streams for offline viewing.")
                .font(.system(size: 14))
                .foregroundColor(ChromeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(ChromeColor.card))
    }
}

struct GoogleWordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            letter("G", ChromeColor.googleBlue)
            letter("o", ChromeColor.googleRed)
            letter("o", ChromeColor.googleYellow)
            letter("g", ChromeColor.googleBlue)
            letter("l", ChromeColor.googleGreen)
            letter("e", ChromeColor.googleRed)
        }
    }

    private func letter(_ s: String, _ color: Color) -> some View {
        Text(s)
            .font(.system(size: 52, weight: .medium, design: .rounded))
            .foregroundColor(color)
    }
}
