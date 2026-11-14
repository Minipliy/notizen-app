import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Verschlüsselung gesperrter Notizen (AES-GCM, Schlüssel per PBKDF2 aus dem Passwort).
/// Der Server sieht nur den Titel, der Inhalt bleibt Ende-zu-Ende verschlüsselt.
enum NoteCrypto {
    static let iterations: UInt32 = 200_000

    static func key(password: String, salt: Data) -> SymmetricKey {
        var derived = Data(count: 32)
        let pw = Array(password.utf8)
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: derived)
    }

    static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    /// Payload: "v1:<salt>:<nonce+ciphertext+tag>" (Base64).
    static func seal(_ blocks: [NoteBlock], key: SymmetricKey, salt: Data) -> String? {
        guard let json = try? JSONEncoder().encode(blocks),
              let box = try? AES.GCM.seal(json, using: key), let combined = box.combined else { return nil }
        return "v1:\(salt.base64EncodedString()):\(combined.base64EncodedString())"
    }

    static func salt(of payload: String) -> Data? {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "v1" else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    static func open(_ payload: String, key: SymmetricKey) -> [NoteBlock]? {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "v1", let data = Data(base64Encoded: String(parts[2])),
              let box = try? AES.GCM.SealedBox(combined: data),
              let json = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode([NoteBlock].self, from: json)
    }
}

/// Passwort für gesperrte Notizen im Schlüsselbund, abrufbar mit Face ID / Touch ID.
enum LockKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "notizen") + ".lock"
    private static let account = "notes-password"

    static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Gerätecode"
        }
    }

    static func save(_ password: String) {
        delete()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Fragt Face ID / Touch ID ab und liefert das gespeicherte Passwort.
    static func load(reason: String) async -> String? {
        await Task.detached {
            let ctx = LAContext()
            ctx.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: ctx,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}

extension NoteBlock {
    var isSealed: Bool { sealed != nil }
}

extension Note {
    /// Gesperrte Notiz: Inhalt liegt verschlüsselt in einem einzigen Block.
    var isLocked: Bool { (blocks ?? []).contains { $0.isSealed } }
    var sealedPayload: String? { (blocks ?? []).first { $0.isSealed }?.sealed }
}

/// Geöffnete gesperrte Notiz: Schlüssel und entschlüsselter Inhalt, nur im Arbeitsspeicher.
struct UnlockedNote {
    var key: SymmetricKey
    var salt: Data
    var blocks: [NoteBlock]
}
