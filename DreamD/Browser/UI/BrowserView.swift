import SwiftUI

struct BrowserView: View {
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        ZStack {
            ChromeColor.background.ignoresSafeArea()
            if let tab = tabManager.selected {
                TabContentView(tab: tab)
                    .id(tab.id)
            }
        }
        .fullScreenCover(isPresented: $tabManager.showTabGrid) {
            TabGridView()
        }
    }
}

struct TabContentView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var downloads: DownloadManager

    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var showReadingList = false
    @State private var showRecentTabs = false
    @State private var showMediaSheet = false
    @State private var shareItem: URL?

    var body: some View {
        VStack(spacing: 0) {
            if tab.isNewTabPage {
                NewTabPage(tab: tab,
                           showBookmarks: { showBookmarks = true },
                           showReadingList: { showReadingList = true },
                           showRecentTabs: { showRecentTabs = true },
                           showHistory: { showHistory = true },
                           showSettings: { showSettings = true })
            } else {
                OmniboxBar(tab: tab)
                if tab.isLoading {
                    ProgressView(value: max(0.05, tab.progress))
                        .progressViewStyle(.linear)
                        .tint(ChromeColor.googleBlue)
                        .frame(height: 2)
                } else {
                    Divider().opacity(0)
                        .frame(height: 2)
                }
                ZStack(alignment: .bottomTrailing) {
                    WebViewContainer(webView: tab.webView)
                    if !tab.detectedMedia.isEmpty {
                        mediaPill
                    }
                }
            }
            BottomToolbar(tab: tab,
                          showMenu: menuContent)
        }
        .background(ChromeColor.background)
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistorySheet(tab: tab) }
        .sheet(isPresented: $showBookmarks) { BookmarksSheet(tab: tab, store: BookmarkStore.shared, title: "Bookmarks") }
        .sheet(isPresented: $showReadingList) { BookmarksSheet(tab: tab, store: BookmarkStore.readingList, title: "Reading list") }
        .sheet(isPresented: $showRecentTabs) { RecentTabsSheet() }
        .sheet(isPresented: $showMediaSheet) { MediaListSheet(tab: tab) }
        .sheet(item: $shareItem) { url in
            ShareSheet(items: [url])
        }
    }

    private var mediaPill: some View {
        Button {
            showMediaSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text("\(tab.detectedMedia.count)")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 16))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(ChromeColor.googleBlue))
            .shadow(radius: 4)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func menuContent() -> some View {
        Button { tabManager.newTab() } label: {
            Label("New tab", systemImage: "plus.square")
        }
        Button { tabManager.newTab(incognito: true) } label: {
            Label("New Incognito tab", systemImage: "eyeglasses")
        }
        Divider()
        Button { showDownloads = true } label: {
            if downloads.activeCount > 0 {
                Label("Downloads (\(downloads.activeCount) active)", systemImage: "arrow.down.circle")
            } else {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
        }
        Button { showBookmarks = true } label: {
            Label("Bookmarks", systemImage: "star")
        }
        Button { showReadingList = true } label: {
            Label("Reading list", systemImage: "list.bullet.rectangle")
        }
        Button { showHistory = true } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        if !tab.isNewTabPage, let url = tab.currentURL {
            Button {
                BookmarkStore.shared.toggle(url: url, title: tab.title)
            } label: {
                Label(BookmarkStore.shared.contains(url) ? "Remove bookmark" : "Add bookmark",
                      systemImage: BookmarkStore.shared.contains(url) ? "star.fill" : "star")
            }
            Button {
                BookmarkStore.readingList.toggle(url: url, title: tab.title)
            } label: {
                Label("Add to Reading list", systemImage: "text.badge.plus")
            }
            Button { shareItem = url } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button { tab.toggleDesktopMode() } label: {
                Label(tab.desktopMode ? "Mobile site" : "Desktop site",
                      systemImage: tab.desktopMode ? "iphone" : "desktopcomputer")
            }
            Button { tab.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            if !tab.detectedMedia.isEmpty {
                Button { showMediaSheet = true } label: {
                    Label("Media on this page (\(tab.detectedMedia.count))", systemImage: "film")
                }
            }
            Divider()
        }
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Omnibox

struct OmniboxBar: View {
    @ObservedObject var tab: BrowserTab
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { tab.goHome() } label: {
                Image(systemName: "house")
                    .font(.system(size: 18))
                    .foregroundColor(ChromeColor.textSecondary)
            }
            HStack(spacing: 8) {
                Image(systemName: tab.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 13))
                    .foregroundColor(ChromeColor.textSecondary)
                TextField("Search or type URL", text: $text)
                    .focused($focused)
                    .font(.system(size: 16))
                    .foregroundColor(ChromeColor.textPrimary)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        tab.load(text)
                        focused = false
                    }
                if tab.isLoading {
                    Button { tab.stopLoading() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ChromeColor.textSecondary)
                    }
                } else {
                    Button { tab.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ChromeColor.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(ChromeColor.surface))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ChromeColor.background)
        .onAppear { text = displayText }
        .onChange(of: tab.urlString) { newValue in
            if !focused { text = newValue }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { text = displayText }
        }
    }

    private var displayText: String {
        tab.urlString
    }
}

// MARK: - Bottom toolbar (Chrome style)

struct BottomToolbar<MenuItems: View>: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tabManager: TabManager
    @ViewBuilder var showMenu: () -> MenuItems

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
            HStack {
                Button { tab.goBack() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 22))
                        .foregroundColor(tab.canGoBack ? ChromeColor.textPrimary : ChromeColor.textSecondary.opacity(0.4))
                }
                .disabled(!tab.canGoBack)
                Spacer()
                Button { tab.goForward() } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 22))
                        .foregroundColor(tab.canGoForward ? ChromeColor.textPrimary : ChromeColor.textSecondary.opacity(0.4))
                }
                .disabled(!tab.canGoForward)
                Spacer()
                Button { tabManager.newTab() } label: {
                    ZStack {
                        Circle()
                            .fill(ChromeColor.chip)
                            .frame(width: 38, height: 38)
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(ChromeColor.textPrimary)
                    }
                }
                Spacer()
                Button {
                    tabManager.selected?.captureSnapshot()
                    tabManager.showTabGrid = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(ChromeColor.textPrimary, lineWidth: 2)
                            .frame(width: 26, height: 26)
                        Text("\(tabManager.tabs.count)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ChromeColor.textPrimary)
                            .minimumScaleFactor(0.5)
                    }
                }
                Spacer()
                Menu {
                    showMenu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20))
                        .foregroundColor(ChromeColor.textPrimary)
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
        }
        .background(ChromeColor.background)
    }
}
