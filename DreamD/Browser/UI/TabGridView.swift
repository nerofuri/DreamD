import SwiftUI

/// Chrome-style tab switcher grid with snapshots.
struct TabGridView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if !tabManager.normalTabs.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(tabManager.normalTabs) { tab in
                            TabCard(tab: tab)
                        }
                    }
                    .padding(16)
                }
                if !tabManager.incognitoTabs.isEmpty {
                    HStack {
                        Image(systemName: "eyeglasses")
                        Text("Incognito")
                        Spacer()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ChromeColor.textSecondary)
                    .padding(.horizontal, 20)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(tabManager.incognitoTabs) { tab in
                            TabCard(tab: tab)
                        }
                    }
                    .padding(16)
                }
            }
            bottomBar
        }
        .background(ChromeColor.background.ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button(role: .destructive) {
                    tabManager.closeAll()
                } label: {
                    Label("Close all tabs", systemImage: "xmark.square")
                }
                Button(role: .destructive) {
                    tabManager.closeAll(incognitoOnly: true)
                } label: {
                    Label("Close Incognito tabs", systemImage: "eyeglasses")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundColor(ChromeColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button {
                tabManager.newTab()
            } label: {
                ZStack {
                    Circle().fill(ChromeColor.chip).frame(width: 40, height: 40)
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(ChromeColor.textPrimary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(ChromeColor.blue)
                .frame(height: 44)
        }
        .padding(.horizontal, 20)
        .background(ChromeColor.background)
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tabManager: TabManager

    private var isSelected: Bool { tabManager.selectedID == tab.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: tab.isIncognito ? "eyeglasses" : "globe")
                    .font(.system(size: 12))
                    .foregroundColor(ChromeColor.textSecondary)
                Text(tab.isNewTabPage ? "New tab" : tab.title)
                    .font(.system(size: 13))
                    .foregroundColor(ChromeColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    tabManager.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ChromeColor.textSecondary)
                        .frame(width: 26, height: 26)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(ChromeColor.surface)

            ZStack {
                Rectangle().fill(ChromeColor.card)
                if let snapshot = tab.snapshot, !tab.isNewTabPage {
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 10) {
                        GoogleWordmark()
                            .scaleEffect(0.4)
                            .frame(height: 30)
                        Capsule()
                            .fill(ChromeColor.surface)
                            .frame(width: 100, height: 16)
                    }
                }
            }
            .frame(height: 150)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? ChromeColor.googleBlue : Color.clear, lineWidth: 2.5)
        )
        .onTapGesture {
            tabManager.select(tab)
        }
    }
}
