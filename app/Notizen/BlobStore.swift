import CryptoKit
import Foundation

/// Lokaler Speicher für Anhänge (Bilder, PDFs, Dateien), adressiert über ihren SHA-256.
/// Gleiche Dateien werden nur einmal gespeichert und übertragen.
final class BlobStore: @unchecked Sendable {
    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notizen/blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func url(_ sha: String) -> URL {
        directory.appendingPathComponent(sha)
    }

    func exists(_ sha: String) -> Bool {
        FileManager.default.fileExists(atPath: url(sha).path)
    }

    func data(_ sha: String) -> Data? {
        try? Data(contentsOf: url(sha), options: .mappedIfSafe)
    }

    /// Speichert Daten und gibt ihren Hash zurück.
    @discardableResult
    func put(_ data: Data) throws -> String {
        let sha = Self.sha256(data)
        if !exists(sha) {
            try data.write(to: url(sha), options: .atomic)
        }
        return sha
    }

    /// Übernimmt eine Datei (z. B. einen Download), wenn ihr Inhalt zum erwarteten Hash passt.
    func adopt(fileAt source: URL, expected sha: String) -> Bool {
        guard Self.sha256(fileAt: source) == sha else { return false }
        if exists(sha) { return true }
        do {
            try FileManager.default.moveItem(at: source, to: url(sha))
            return true
        } catch {
            return exists(sha)
        }
    }

    /// Kopie mit lesbarem Dateinamen, z. B. zum Teilen oder für die Vorschau.
    func namedCopy(_ sha: String, name: String) -> URL? {
        guard exists(sha) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(sha, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let target = dir.appendingPathComponent(safe.isEmpty ? "Datei" : safe)
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.copyItem(at: url(sha), to: target)
        }
        return target
    }
}
