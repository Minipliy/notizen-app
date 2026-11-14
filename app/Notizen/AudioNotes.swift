import AVFoundation
import Speech
import UniformTypeIdentifiers
import SwiftUI

/// Aufnahme einer Sprachnotiz (AAC/m4a).
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var error: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aufnahme-\(UUID().uuidString).m4a")

    func start() async {
        guard await Self.requestPermission() else {
            error = "Kein Zugriff aufs Mikrofon – in den Einstellungen erlauben."
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.record()
            recorder = r
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    self.elapsed = r.currentTime
                    self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
                }
            }
        } catch {
            self.error = "Aufnahme nicht möglich"
        }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// Blatt zum Aufnehmen.
struct AudioRecorderSheet: View {
    let onFinish: (URL, TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = AudioRecorder()

    var body: some View {
        VStack(spacing: 24) {
            Text(recorder.isRecording ? "Aufnahme läuft" : "Sprachnotiz")
                .font(.headline)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 48, weight: .light, design: .rounded).monospacedDigit())
            Capsule()
                .fill(Color.notesAccent.opacity(0.8))
                .frame(width: 40 + CGFloat(recorder.level) * 200, height: 8)
                .animation(.linear(duration: 0.1), value: recorder.level)
            if let error = recorder.error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            HStack(spacing: 40) {
                Button("Abbrechen") {
                    recorder.stop()
                    dismiss()
                }
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                        if recorder.elapsed > 0.5 { onFinish(recorder.url, recorder.elapsed) }
                        dismiss()
                        Task { await SpeechTranscriber.requestAuthorization() }
                    } else {
                        Task { await recorder.start() }
                    }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 64))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Aufnahme beenden" : "Aufnahme starten")
            }
        }
        .padding(32)
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(width: 380, height: 340)
        #endif
        .task { await recorder.start() }
    }
}

/// Abspielen einer Sprachnotiz.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func toggle(_ url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player == nil {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try? AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
        }
        guard let player else { return }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying {
                    self.isPlaying = false
                    self.progress = 0
                    self.timer?.invalidate()
                }
            }
        }
    }

    func load(_ url: URL) {
        if duration == 0 { duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0 }
    }
}

/// Sprachnotiz in der Notiz: Abspielen, Dauer, Transkript.
struct AudioBlockView: View {
    let file: FileRef
    let transcript: String?
    let transcribing: Bool
    @Environment(NotesStore.self) private var store
    @State private var playback = AudioPlayback()
    @State private var showTranscript = true

    var body: some View {
        let available = store.blobs.exists(file.blob) || store.blobRevision < 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if let url = store.blobs.namedCopy(file.blob, name: file.name) { playback.toggle(url) }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.notesAccent)
                }
                .buttonStyle(.plain)
                .disabled(!available)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sprachnotiz").font(.headline)
                    ProgressView(value: playback.progress)
                        .tint(Color.notesAccent)
                    Text(available
                         ? Duration.seconds(playback.duration).formatted(.time(pattern: .minuteSecond))
                         : "Wird geladen …")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let transcript, !transcript.isEmpty {
                DisclosureGroup("Transkript", isExpanded: $showTranscript) {
                    Text(transcript)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.footnote)
            } else if transcribing {
                Label("Wird in Text umgewandelt …", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .task(id: "\(file.blob)|\(store.blobRevision)") {
            if available, let url = store.blobs.namedCopy(file.blob, name: file.name) { playback.load(url) }
        }
    }
}

extension FileRef {
    var isAudio: Bool {
        guard let t = type.flatMap(UTType.init) else { return false }
        return t.conforms(to: .audio)
    }
}

/// Wandelt Sprachaufnahmen in Text um (möglichst auf dem Gerät).
enum SpeechTranscriber {
    /// Fragt nach der Erlaubnis (nur aufrufen, wenn der Nutzer selbst etwas aufnimmt).
    static func requestAuthorization() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        _ = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    /// Transkript; `nil`, wenn es gerade nicht geht (keine Erlaubnis, nicht verfügbar, Fehler) –
    /// dann wird es später erneut versucht.
    static func transcribe(_ url: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")), recognizer.isAvailable
        else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error = error as NSError? {
                    done = true
                    // „Keine Sprache erkannt“ ist ein gültiges (leeres) Ergebnis, alles andere später nochmal.
                    cont.resume(returning: error.code == 1110 ? "" : nil)
                }
            }
        }
    }
}
