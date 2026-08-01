import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AddDownloadSheet: View {
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var showFilePicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…, .m3u8 or magnet:…", text: $input, axis: .vertical)
                        .lineLimit(3...6)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            input = pasted
                        }
                    } label: {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Link")
                } footer: {
                    Text("Direct file links download over multiple connections. m3u8 links are saved as video files. Magnet links start a torrent.")
                }

                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose a .torrent file", systemImage: "folder.badge.plus")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        startDownload()
                    } label: {
                        Text("Start Download")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("New Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: torrentTypes,
                          allowsMultipleSelection: false) { result in
                handlePickedFile(result)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var torrentTypes: [UTType] {
        var types: [UTType] = [.data]
        if let torrent = UTType(filenameExtension: "torrent") {
            types.insert(torrent, at: 0)
        }
        return types
    }

    private func startDownload() {
        if downloads.add(from: input) != nil || input.lowercased().contains(".torrent") {
            dismiss()
        } else {
            errorMessage = "That doesn't look like a valid http(s), m3u8 or magnet link."
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.pathExtension.lowercased() == "torrent" else {
            errorMessage = "Please pick a .torrent file."
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read the selected file."
            return
        }
        downloads.addTorrentFile(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
        dismiss()
    }
}
