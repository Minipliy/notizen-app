import SwiftUI

struct SettingsView: View {
    @Environment(NotesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://notizen.example.com", text: $url)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("Token", text: $token)
                } header: {
                    Text("Eigener Server")
                } footer: {
                    Text("Adresse und Token deines Notizen-Servers. Trage auf allen Geräten dieselben Werte ein. Von unterwegs ist nur eine https://-Adresse möglich.")
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Verbindung testen")
                            if testing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(testing || url.isEmpty)
                    if let result {
                        Label(result, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(success ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Einstellungen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        store.configure(serverURL: url, token: token)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 320)
        #endif
        .onAppear {
            url = store.serverURL
            token = store.token
        }
    }

    private func test() async {
        testing = true
        result = nil
        store.configure(serverURL: url, token: token)
        let error = await store.testConnection()
        success = error == nil
        result = error ?? "Verbindung steht"
        testing = false
    }
}
