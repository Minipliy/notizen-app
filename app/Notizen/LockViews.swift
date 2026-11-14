import SwiftUI

/// Ansicht einer gesperrten Notiz: Passwort oder Face ID / Touch ID.
struct LockedNoteView: View {
    let noteID: String
    @Environment(NotesStore.self) private var store
    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.notesAccent)
            Text(store.note(noteID)?.title ?? "Gesperrte Notiz")
                .font(.title2.bold())
            Text("Diese Notiz ist gesperrt.")
                .foregroundStyle(.secondary)
            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($focused)
                .onSubmit(unlockWithPassword)
            if wrong {
                Text("Falsches Passwort").font(.footnote).foregroundStyle(.red)
            }
            Button("Entsperren", action: unlockWithPassword)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            if LockSettings.hasSavedPassword {
                Button("Mit \(LockKeychain.biometryName) entsperren", systemImage: "faceid") {
                    Task { await unlockWithBiometrics() }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !LockSettings.hasSavedPassword { focused = true }
        }
    }

    private func unlockWithPassword() {
        if store.unlock(noteID, password: password) {
            LockSettings.remember(password)
        } else {
            wrong = true
        }
    }

    private func unlockWithBiometrics() async {
        guard let pw = await LockKeychain.load(reason: "Gesperrte Notiz öffnen") else { focused = true; return }
        if !store.unlock(noteID, password: pw) { focused = true }
    }
}

enum LockSettings {
    static var hasSavedPassword: Bool { UserDefaults.standard.bool(forKey: "lockPasswordSaved") }

    static func remember(_ password: String) {
        LockKeychain.save(password)
        UserDefaults.standard.set(true, forKey: "lockPasswordSaved")
    }
}

/// Passwort festlegen bzw. eingeben, um eine Notiz zu sperren.
struct LockPasswordSheet: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeatPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passwort", text: $password)
                    SecureField("Passwort wiederholen", text: $repeatPassword)
                } footer: {
                    Text("Gesperrte Notizen werden mit diesem Passwort verschlüsselt – auch auf deinem Server. Vergisst du es, lassen sich die Notizen nicht mehr öffnen. Nutze auf allen Geräten dasselbe Passwort.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notiz sperren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sperren") {
                        onDone(password)
                        dismiss()
                    }
                    .disabled(password.count < 4 || password != repeatPassword)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 280)
        #endif
    }
}
