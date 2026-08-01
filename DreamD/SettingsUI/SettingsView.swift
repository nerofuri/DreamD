import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("maxConnections") private var maxConnections = 8
    @AppStorage("maxPeers") private var maxPeers = 30
    @ObservedObject private var keepAlive = BackgroundKeepAlive.shared
    @State private var clearedHistory = false
    @State private var clearedCookies = false

    @ViewBuilder
    private var backgroundSection: some View {
        Section {
            Toggle("Run downloads in background", isOn: $keepAlive.isEnabled)
            if keepAlive.isEnabled {
                Picker("Method", selection: $keepAlive.method) {
                    ForEach(KeepAliveMethod.allCases) { m in
                        Text(m == .audio ? "Audio" : "Location").tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Background")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("This keeps DreamD active in the background so downloads keep running, but will increase your battery usage.")
                if keepAlive.isEnabled {
                    Text(keepAlive.method == .audio
                         ? "Audio: plays silent audio (mixes with your music) to stay awake."
                         : "Location: uses low-accuracy background location as a wake source. Nothing is stored or shared.")
                        .foregroundColor(.secondary)
                }
                if keepAlive.isEnabled && keepAlive.method == .location && keepAlive.locationDenied {
                    Text("Location access is off. Enable it in Settings → DreamD → Location (set to Always) for background downloads.")
                        .foregroundColor(.orange)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                backgroundSection

                Section {
                    Stepper(value: $maxConnections, in: 1...16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connections per download")
                            Text("\(maxConnections) parallel connections")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Stepper(value: $maxPeers, in: 5...60, step: 5) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max peers per torrent")
                            Text("\(maxPeers) peers")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("More connections can speed up downloads from servers that support ranged requests, like Internet Download Manager's segmented downloading.")
                }

                Section {
                    Button {
                        HistoryStore.shared.clear()
                        clearedHistory = true
                    } label: {
                        Label(clearedHistory ? "History cleared" : "Clear browsing history",
                              systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(clearedHistory)
                    Button {
                        let store = WKWebsiteDataStore.default()
                        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                         modifiedSince: .distantPast) {
                            clearedCookies = true
                        }
                    } label: {
                        Label(clearedCookies ? "Site data cleared" : "Clear cookies and site data",
                              systemImage: "trash")
                    }
                    .disabled(clearedCookies)
                } header: {
                    Text("Browser")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Downloads folder", value: "Files app → On My iPhone → DreamD")
                } header: {
                    Text("About")
                } footer: {
                    Text("Only download content you have the right to save. DRM-protected streams are not supported. Torrent and HLS downloads run while the app is open.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
