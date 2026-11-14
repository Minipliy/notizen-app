import Foundation
import Observation

/// Hält alle Notizen und Ordner, speichert sie lokal (funktioniert auch offline)
/// und gleicht sie mit dem Server auf dem Raspberry Pi ab.
@MainActor
@Observable
final class NotesStore {
    private(set) var notes: [Note] = []
    private(set) var folders: [Folder] = []
    var sidebarSelection: SidebarItem? = .all
    var selectedNoteID: String?
    private(set) var syncState: SyncState = .notConfigured
    private(set) var serverURL: String
    private(set) var token: String

    @ObservationIgnored private var lastRev = 0
    @ObservationIgnored private var serverId: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncDebounce: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsResync = false
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored let blobs = BlobStore()
    /// Steigt, sobald ein Anhang heruntergeladen wurde – Ansichten laden dann neu.
    private(set) var blobRevision = 0
    @ObservationIgnored private var uploadedBlobs: Set<String> = []
    @ObservationIgnored private var downloading: Set<String> = []
    @ObservationIgnored private let writer = FileWriter()
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    /// Entsperrte Notizen dieser Sitzung (Schlüssel + Klartext nur im Speicher).
    private(set) var unlocked: [String: UnlockedNote] = [:]

    /// Auf Zeichenflächen auch mit dem Finger zeichnen (sonst nur mit dem Apple Pencil).
    var fingerDrawing: Bool = UserDefaults.standard.bool(forKey: "fingerDrawing") {
        didSet { UserDefaults.standard.set(fingerDrawing, forKey: "fingerDrawing") }
    }

    private struct Persisted: Codable {
        var notes: [Note]
        var folders: [Folder]
        var lastRev: Int
        var serverId: String?
        var uploadedBlobs: [String]?
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        token = UserDefaults.standard.string(forKey: "serverToken") ?? ""
        load()
        purgeOldTrash()
        migrateInk()
        scheduleRecognition()
        #if DEBUG
        // Nur für Screenshots: Start mit  -shotNote <id>  bzw.  -shotFolder <id>
        if let id = UserDefaults.standard.string(forKey: "shotFolder") {
            sidebarSelection = id == "sidebar" ? nil : .folder(id)
        }
        if let id = UserDefaults.standard.string(forKey: "shotNote") { selectedNoteID = id }
        #endif
        startPolling()
    }

    // MARK: - Abfragen

    var visibleFolders: [Folder] {
        folders.filter { !$0.deleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func note(_ id: String?) -> Note? {
        guard let id, var n = notes.first(where: { $0.id == id && !$0.deleted }) else { return nil }
        // Entsperrte Notiz: Klartext statt verschlüsseltem Block zeigen.
        if let u = unlocked[id], n.isLocked { n.blocks = u.blocks }
        return n
    }

    func notes(for item: SidebarItem, search: String = "", sort: NoteSort = .modified) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return notes.filter { n in
            guard !n.deleted else { return false }
            switch item {
            case .all: if n.trashed { return false }
            case .folder(let id): if n.trashed || n.folderId != id { return false }
            case .tag(let tag): if n.trashed || !n.hasTag(tag) { return false }
            case .trash: if !n.trashed { return false }
            }
            return query.isEmpty || n.matches(query)
        }
        .sorted {
            if item != .trash, $0.pinned != $1.pinned { return $0.pinned }
            switch sort {
            case .modified: return $0.modifiedAt > $1.modifiedAt
            case .created: return $0.createdAt > $1.createdAt
            case .title:
                let r = $0.title.localizedStandardCompare($1.title)
                return r == .orderedSame ? $0.modifiedAt > $1.modifiedAt : r == .orderedAscending
            }
        }
    }

    /// Alle Tags mit Anzahl der Notizen, alphabetisch.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for n in notes where !n.deleted && !n.trashed {
            for t in n.tags {
                let key = t.lowercased()
                counts[key] = (counts[key]?.name ?? t, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func count(for item: SidebarItem) -> Int {
        notes(for: item).count
    }

    // MARK: - Notizen ändern

    @discardableResult
    func newNote() -> String {
        var note = Note()
        var first = NoteBlock.text()
        if let paper = UserDefaults.standard.string(forKey: "defaultPaper"), paper != "blank" {
            first.paper = paper
        }
        // In einer Tag-Ansicht bekommt die neue Notiz den Tag gleich mit.
        if case .tag(let tag) = sidebarSelection { first.text = "\n#\(tag)" }
        note.blocks = [first]
        note.text = Note.plainText(of: [first])
        if case .folder(let id) = sidebarSelection { note.folderId = id }
        if sidebarSelection == .trash || sidebarSelection == nil { sidebarSelection = .all }
        notes.append(note)
        selectedNoteID = note.id
        changed()
        return note.id
    }

    /// Ändert die Blöcke einer Notiz; Titel, Vorschau und Suche werden mitgeführt.
    func updateBlocks(_ id: String, _ change: (inout [NoteBlock]) -> Void) {
        if var u = unlocked[id], notes.first(where: { $0.id == id })?.isLocked == true {
            // Gesperrte Notiz bearbeiten: im Klartext ändern, verschlüsselt speichern.
            var b = u.blocks
            change(&b)
            NoteBlock.normalize(&b)
            u.blocks = b
            unlocked[id] = u
            guard let payload = NoteCrypto.seal(b, key: u.key, salt: u.salt) else { return }
            mutateNote(id) {
                $0.blocks = [NoteBlock(kind: .text, sealed: payload)]
                $0.text = Note.plainText(of: b).components(separatedBy: "\n").first ?? ""
            }
            return
        }
        mutateNote(id) {
            var b = $0.content
            let paper = b.compactMap(\.paper).first
            change(&b)
            NoteBlock.normalize(&b)
            // Papier-Einstellung behalten, auch wenn der Block gelöscht wurde, an dem sie stand.
            if let paper, !b.isEmpty, !b.contains(where: { $0.paper != nil }) { b[0].paper = paper }
            $0.blocks = b
            $0.text = Note.plainText(of: b)
        }
    }

    /// Papier der Notiz wählen; gilt auch als Vorgabe für neue Notizen.
    func setPaper(_ noteID: String, _ paper: String) {
        UserDefaults.standard.set(paper, forKey: "defaultPaper")
        updateBlocks(noteID) { blocks in
            for i in blocks.indices { blocks[i].paper = nil }
            if !blocks.isEmpty { blocks[0].paper = paper }
        }
    }

    func updateBlock(_ noteID: String, _ blockID: String, _ change: (inout NoteBlock) -> Void) {
        updateBlocks(noteID) { blocks in
            if let i = blocks.firstIndex(where: { $0.id == blockID }) { change(&blocks[i]) }
        }
    }

    // MARK: - Links

    /// Zu der Notiz mit diesem Titel wechseln; gibt es keine, wird sie angelegt
    /// (im selben Ordner wie die Ausgangsnotiz).
    func openNote(titled title: String, from sourceID: String?) {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let target = notes.first(where: { !$0.deleted && !$0.trashed
            && $0.title.caseInsensitiveCompare(t) == .orderedSame }) {
            if let f = target.folderId, sidebarSelection != .folder(f), sidebarSelection != .all {
                sidebarSelection = .all
            }
            selectedNoteID = target.id
            return
        }
        var note = Note()
        note.folderId = sourceID.flatMap { id in notes.first { $0.id == id }?.folderId }
        note.blocks = [.text(t + "\n")]
        note.text = t
        notes.append(note)
        if case .tag = sidebarSelection { sidebarSelection = .all }
        selectedNoteID = note.id
        changed()
    }

    // MARK: - Sperren

    /// Notiz mit dem Passwort verschlüsseln; nur der Titel bleibt lesbar.
    func lock(_ id: String, password: String) {
        guard let n = note(id), !n.isLocked else { return }
        let salt = NoteCrypto.randomSalt()
        let key = NoteCrypto.key(password: password, salt: salt)
        let blocks = n.content
        guard let payload = NoteCrypto.seal(blocks, key: key, salt: salt) else { return }
        unlocked[id] = nil
        mutateNote(id) {
            $0.blocks = [NoteBlock(kind: .text, sealed: payload)]
            $0.text = n.title
        }
    }

    /// Entschlüsseln; `false` bei falschem Passwort.
    func unlock(_ id: String, password: String) -> Bool {
        guard let n = notes.first(where: { $0.id == id }), let payload = n.sealedPayload,
              let salt = NoteCrypto.salt(of: payload) else { return false }
        let key = NoteCrypto.key(password: password, salt: salt)
        guard let blocks = NoteCrypto.open(payload, key: key) else { return false }
        unlocked[id] = UnlockedNote(key: key, salt: salt, blocks: blocks)
        return true
    }

    /// Wieder sperren (Klartext aus dem Speicher entfernen).
    func relock(_ id: String) { unlocked[id] = nil }

    /// Gesperrt und (noch) nicht entsperrt.
    func isClosed(_ id: String) -> Bool {
        notes.first { $0.id == id }?.isLocked == true && unlocked[id] == nil
    }

    func relockAll() { unlocked.removeAll() }

    /// Sperre dauerhaft entfernen (nur wenn entsperrt).
    func removeLock(_ id: String) {
        guard let u = unlocked[id] else { return }
        unlocked[id] = nil
        mutateNote(id) {
            $0.blocks = u.blocks
            $0.text = Note.plainText(of: u.blocks)
        }
    }

    func togglePin(_ id: String) {
        mutateNote(id) { $0.pinned.toggle() }
    }

    func move(_ id: String, to folderId: String?) {
        mutateNote(id) { $0.folderId = folderId }
    }

    func trash(_ id: String) {
        if selectedNoteID == id { selectedNoteID = nil }
        mutateNote(id) { $0.trashed = true; $0.pinned = false }
    }

    func restore(_ id: String) {
        if selectedNoteID == id { selectedNoteID = nil }
        let folderIDs = Set(visibleFolders.map(\.id))
        mutateNote(id) {
            $0.trashed = false
            if let f = $0.folderId, !folderIDs.contains(f) { $0.folderId = nil }
        }
    }

    func deletePermanently(_ id: String) {
        if selectedNoteID == id { selectedNoteID = nil }
        mutateNote(id) { $0.deleted = true; $0.text = ""; $0.blocks = [] }
    }

    func emptyTrash() {
        for n in notes(for: .trash) { deletePermanently(n.id) }
    }

    /// Leere Notizen verschwinden beim Verlassen von selbst, wie in Apple Notizen.
    func discardIfBlank(_ id: String) {
        if let n = note(id), n.isBlank, !n.trashed { deletePermanently(id) }
    }

    private func mutateNote(_ id: String, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var n = notes[i]
        change(&n)
        guard n != notes[i] else { return }
        n.modifiedAt = max(nowMillis(), notes[i].modifiedAt + 1)
        n.dirty = true
        notes[i] = n
        changed()
    }

    // MARK: - Ordner ändern

    func addFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let folder = Folder(name: name)
        folders.append(folder)
        sidebarSelection = .folder(folder.id)
        changed()
    }

    func renameFolder(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mutateFolder(id) { $0.name = name }
    }

    /// Löscht den Ordner; seine Notizen wandern in „Zuletzt gelöscht“.
    func deleteFolder(_ id: String) {
        for n in notes(for: .folder(id)) { trash(n.id) }
        if sidebarSelection == .folder(id) { sidebarSelection = .all }
        mutateFolder(id) { $0.deleted = true }
    }

    private func mutateFolder(_ id: String, _ change: (inout Folder) -> Void) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var f = folders[i]
        change(&f)
        guard f != folders[i] else { return }
        f.modifiedAt = max(nowMillis(), folders[i].modifiedAt + 1)
        f.dirty = true
        folders[i] = f
        changed()
    }

    private func purgeOldTrash() {
        let limit = nowMillis() - 30 * 24 * 3600 * 1000
        for n in notes where n.trashed && !n.deleted && n.modifiedAt < limit {
            deletePermanently(n.id)
        }
    }

    // MARK: - Lokal speichern

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notizen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notizen.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        notes = p.notes
        folders = p.folders
        lastRev = p.lastRev
        serverId = p.serverId
        uploadedBlobs = Set(p.uploadedBlobs ?? [])
    }

    private var snapshot: Persisted {
        Persisted(notes: notes, folders: folders, lastRev: lastRev, serverId: serverId,
                  uploadedBlobs: Array(uploadedBlobs))
    }

    /// Sofort speichern (z. B. wenn die App in den Hintergrund geht).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            guard let self else { return }
            // Zeichnungen können groß sein: im Hintergrund kodieren und schreiben.
            let p = self.snapshot
            let url = self.fileURL
            await self.writer.write(url) { try JSONEncoder().encode(p) }
        }
    }

    /// Übernimmt erkannten Text, ohne die Notiz als „bearbeitet“ nach oben zu sortieren.
    func applyRecognition(_ noteID: String, _ blockID: String, source: String, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }),
              var blocks = notes[i].blocks,
              let j = blocks.firstIndex(where: { $0.id == blockID }),
              blocks[j].recognitionSource == source else { return }
        blocks[j].recognized = text.isEmpty ? nil : text
        blocks[j].recognizedKey = source
        notes[i].blocks = blocks
        notes[i].modifiedAt += 1  // muss steigen, damit der Server die Fassung übernimmt
        notes[i].dirty = true
        scheduleSave()
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.sync()
        }
    }

    private func changed() {
        scheduleSave()
        scheduleRecognition()
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.sync()
        }
    }

    // MARK: - Server

    private var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    var isConfigured: Bool { baseURL != nil }

    func configure(serverURL: String, token: String) {
        self.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.serverURL, forKey: "serverURL")
        UserDefaults.standard.set(self.token, forKey: "serverToken")
        syncState = isConfigured ? .syncing : .notConfigured
        startPolling()
        Task { await sync() }
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard let base = baseURL,
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private struct SyncRequest: Encodable {
        var since: Int
        var notes: [Note]
        var folders: [Folder]
    }

    private struct SyncResponse: Decodable {
        var rev: Int
        var serverId: String
        var notes: [Note]
        var folders: [Folder]
    }

    private struct PollResponse: Decodable {
        var rev: Int
        var serverId: String
    }

    private enum SyncError: Error {
        case unauthorized
        case server(Int)
        case outdated
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case SyncError.unauthorized: return "Token falsch"
        case SyncError.server(let code): return "Serverfehler \(code)"
        case SyncError.outdated: return "Server veraltet – bitte aktualisieren"
        case let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection:
            return "Unterwegs nur mit https:// möglich"
        case let e as URLError where e.code.rawValue <= -1200 && e.code.rawValue >= -1206:
            return "HTTPS-Zertifikat ungültig"
        case is URLError: return "Server nicht erreichbar"
        case is DecodingError: return "Unerwartete Antwort vom Server"
        default: return error.localizedDescription
        }
    }

    private func fetch(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SyncError.unauthorized }
        guard code == 200 else { throw SyncError.server(code) }
        return data
    }

    /// Prüft Adresse und Token; gibt `nil` bei Erfolg zurück, sonst die Fehlermeldung.
    func testConnection() async -> String? {
        guard let req = request("api/ping") else { return "Adresse ungültig" }
        do {
            _ = try await fetch(req)
            return nil
        } catch {
            return describe(error)
        }
    }

    var hasUnsyncedChanges: Bool {
        notes.contains(where: \.dirty) || folders.contains(where: \.dirty)
    }

    func sync() async {
        guard isConfigured else {
            syncState = .notConfigured
            return
        }
        if isSyncing {
            needsResync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            if case .error = syncState {} else { syncState = .syncing }
            do {
                try await syncOnce()
                syncState = .idle(Date())
            } catch {
                syncState = .error(describe(error))
                return
            }
        } while needsResync
    }

    private func syncOnce() async throws {
        guard var req = request("api/sync") else { return }
        let sentNotes = notes.filter(\.dirty)
        let sentFolders = folders.filter(\.dirty)
        // Anhänge zuerst hochladen, damit andere Geräte sie sofort laden können.
        try await uploadBlobs(for: sentNotes)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            SyncRequest(since: lastRev, notes: sentNotes, folders: sentFolders))

        let r = try JSONDecoder().decode(SyncResponse.self, from: try await fetch(req))

        // Anderer oder neu aufgesetzter Server: alles noch einmal vollständig abgleichen.
        if r.serverId != serverId {
            let firstContact = serverId == nil && lastRev == 0
            serverId = r.serverId
            if !firstContact {
                lastRev = 0
                uploadedBlobs = []
                for i in notes.indices { notes[i].dirty = true }
                for i in folders.indices { folders[i].dirty = true }
                needsResync = true
                scheduleSave()
                return
            }
        }

        // Hat der Server eine hochgeschickte Fassung abgelehnt, weil ein anderes Gerät
        // inzwischen etwas Neueres gespeichert hat, bleibt die eigene Fassung als Kopie erhalten.
        var conflictCopies: [Note] = []
        var alreadyCopied: Set<String> = []
        let sentByID = Dictionary(sentNotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for remote in r.notes {
            guard let sent = sentByID[remote.id], remote.modifiedAt > sent.modifiedAt else { continue }
            // Neueste eigene Fassung nehmen (falls hier inzwischen weitergeschrieben wurde).
            let local = notes.first { $0.id == remote.id && $0.modifiedAt >= sent.modifiedAt } ?? sent
            if let copy = conflictCopy(local: local, remote: remote) {
                conflictCopies.append(copy)
                alreadyCopied.insert(remote.id)
            }
        }

        // Übertragenes ist angekommen – außer es wurde inzwischen weiterbearbeitet.
        let sentN = Dictionary(sentNotes.map { ($0.id, $0.modifiedAt) }, uniquingKeysWith: { a, _ in a })
        for i in notes.indices where notes[i].dirty {
            if sentN[notes[i].id] == notes[i].modifiedAt { notes[i].dirty = false }
        }
        let sentF = Dictionary(sentFolders.map { ($0.id, $0.modifiedAt) }, uniquingKeysWith: { a, _ in a })
        for i in folders.indices where folders[i].dirty {
            if sentF[folders[i].id] == folders[i].modifiedAt { folders[i].dirty = false }
        }

        // Änderungen der anderen Geräte übernehmen; die neuere Fassung gewinnt.
        // Wurde dieselbe Notiz hier gleichzeitig bearbeitet, bleibt die eigene Fassung als Kopie erhalten.
        var noteIndex = Dictionary(notes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for remote in r.notes {
            if let i = noteIndex[remote.id] {
                if !notes[i].dirty || remote.modifiedAt > notes[i].modifiedAt {
                    // Hier nach dem Hochschicken weiterbearbeitet und trotzdem überholt.
                    if notes[i].dirty, !alreadyCopied.contains(remote.id),
                       let copy = conflictCopy(local: notes[i], remote: remote) {
                        conflictCopies.append(copy)
                    }
                    if notes[i] != remote { notes[i] = remote }
                }
            } else {
                notes.append(remote)
                noteIndex[remote.id] = notes.count - 1
            }
        }
        // Entsperrte Notizen, die ein anderes Gerät geändert hat, neu entschlüsseln.
        for (id, u) in unlocked {
            guard let n = notes.first(where: { $0.id == id }) else { unlocked[id] = nil; continue }
            if let payload = n.sealedPayload {
                if let blocks = NoteCrypto.open(payload, key: u.key) {
                    if blocks != u.blocks { unlocked[id]?.blocks = blocks }
                } else if let salt = NoteCrypto.salt(of: payload), salt != u.salt {
                    unlocked[id] = nil
                }
            } else {
                unlocked[id] = nil  // Sperre wurde woanders entfernt
            }
        }
        if !conflictCopies.isEmpty {
            notes.append(contentsOf: conflictCopies)
            needsResync = true
        }
        var folderIndex = Dictionary(folders.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for remote in r.folders {
            if let i = folderIndex[remote.id] {
                if !folders[i].dirty || remote.modifiedAt > folders[i].modifiedAt {
                    if folders[i] != remote { folders[i] = remote }
                }
            } else {
                folders.append(remote)
                folderIndex[remote.id] = folders.count - 1
            }
        }

        // Endgültig Gelöschtes, das der Server kennt, lokal wegräumen.
        notes.removeAll { $0.deleted && !$0.dirty }
        folders.removeAll { $0.deleted && !$0.dirty }

        lastRev = r.rev
        migrateInk()
        scheduleRecognition()
        if hasUnsyncedChanges { needsResync = true }
        startDownloads()

        if let sel = selectedNoteID, note(sel) == nil { selectedNoteID = nil }
        if case .folder(let id) = sidebarSelection, !folders.contains(where: { $0.id == id }) {
            sidebarSelection = .all
        }
        scheduleSave()
    }

    /// Eigene, noch nicht übertragene Fassung als neue Notiz behalten, wenn ein anderes Gerät
    /// inhaltlich etwas anderes gespeichert hat.
    private func conflictCopy(local: Note, remote: Note) -> Note? {
        guard !local.deleted, !local.trashed, !local.isBlank, !remote.deleted else { return nil }
        let strip: (Note) -> [NoteBlock] = { n in
            n.content.map { b in
                var c = b
                c.recognized = nil
                c.recognizedKey = nil
                return c
            }
        }
        guard strip(local) != strip(remote) else { return nil }
        var copy = local
        copy.id = UUID().uuidString
        copy.pinned = false
        copy.createdAt = nowMillis()
        copy.modifiedAt = nowMillis()
        copy.dirty = true
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        var blocks = local.content
        for i in blocks.indices { blocks[i].id = UUID().uuidString }
        blocks.insert(NoteBlock.text("⚠︎ Konfliktkopie (\(stamp))\nDiese Fassung wurde gleichzeitig auf einem anderen Gerät geändert."), at: 0)
        copy.blocks = blocks
        copy.text = Note.plainText(of: blocks)
        return copy
    }

    // MARK: - Anhänge

    private struct MissingResponse: Decodable { var missing: [String] }

    private func uploadBlobs(for notes: [Note]) async throws {
        let refs = Set(notes.filter { !$0.deleted }.flatMap(\.blobRefs))
            .subtracting(uploadedBlobs)
            .filter { blobs.exists($0) }
        guard !refs.isEmpty, var check = request("api/blobs/missing") else { return }
        check.httpMethod = "POST"
        check.setValue("application/json", forHTTPHeaderField: "Content-Type")
        check.httpBody = try JSONEncoder().encode(["hashes": Array(refs)])
        let missing: [String]
        do {
            missing = try JSONDecoder().decode(MissingResponse.self, from: try await fetch(check)).missing
        } catch SyncError.server(404) {
            throw SyncError.outdated
        }
        for sha in missing {
            guard var put = request("api/blobs/\(sha)") else { continue }
            put.httpMethod = "PUT"
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.upload(for: put, fromFile: blobs.url(sha))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw SyncError.unauthorized }
            guard code == 200 else { throw SyncError.server(code) }
        }
        uploadedBlobs.formUnion(refs)
    }

    /// Lädt Anhänge, die andere Geräte hinzugefügt haben, im Hintergrund.
    private func startDownloads() {
        let needed = Set(notes.filter { !$0.deleted }.flatMap(\.blobRefs))
            .filter { !blobs.exists($0) && !downloading.contains($0) }
        for sha in needed {
            guard let req = request("api/blobs/\(sha)") else { continue }
            downloading.insert(sha)
            Task { [weak self] in
                guard let self else { return }
                defer { self.downloading.remove(sha) }
                guard let (tmp, response) = try? await self.session.download(for: req),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let store = self.blobs
                let ok = await Task.detached { store.adopt(fileAt: tmp, expected: sha) }.value
                if ok {
                    self.uploadedBlobs.insert(sha)
                    self.blobRevision += 1
                    self.scheduleRecognition()
                }
            }
        }
    }

    /// Wartet am Server auf Änderungen anderer Geräte und gleicht dann sofort ab.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.sync()
            while !Task.isCancelled {
                guard let self else { return }
                guard let req = self.request(
                    "api/poll", query: [URLQueryItem(name: "since", value: String(self.lastRev))])
                else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                do {
                    let r = try JSONDecoder().decode(PollResponse.self, from: try await self.fetch(req))
                    if Task.isCancelled { return }
                    if r.rev != self.lastRev || r.serverId != self.serverId || self.hasUnsyncedChanges {
                        await self.sync()
                    } else {
                        self.syncState = .idle(Date())
                    }
                    if case .error = self.syncState {
                        try? await Task.sleep(for: .seconds(5))
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.syncState = .error(self.describe(error))
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}

/// Schreibt Dateien nacheinander im Hintergrund.
actor FileWriter {
    func write(_ url: URL, _ encode: @Sendable () throws -> Data) {
        if let data = try? encode() {
            try? data.write(to: url, options: .atomic)
        }
    }
}
