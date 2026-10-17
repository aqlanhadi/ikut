import AVFoundation

/// A voice the picker can choose from, decoupled from AVFoundation so the choice is testable.
struct VoiceCandidate: Equatable {
    var identifier: String
    var language: String
    /// Higher is better (default 1, enhanced 2, premium 3).
    var quality: Int
}

enum VoicePicker {
    /// Languages in order of preference. iOS ships no Malaysian English voice today, but asking
    /// for it first picks it up if one appears.
    static let preferredLanguages = ["en-MY", "en-GB", "en-AU"]

    /// The best voice: the first preferred language that has any voice, best quality within it
    /// (ties keep the earlier voice). Nil when none match; the caller then uses the system default.
    static func pick(from voices: [VoiceCandidate], preferred: [String] = preferredLanguages) -> VoiceCandidate? {
        for language in preferred {
            // Voices report "en-GB" or "en_GB" depending on the OS version.
            let matches = voices.filter {
                $0.language.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare(language) == .orderedSame
            }
            var best: VoiceCandidate?
            for voice in matches where voice.quality > (best?.quality ?? -1) { best = voice }
            if let best { return best }
        }
        return nil
    }
}

/// Speaks through `AVSpeechSynthesizer`. The audio session is active only while speaking, ducking
/// other audio, and is released with `.notifyOthersOnDeactivation` so music comes back.
@MainActor
final class LiveSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        activateSession()
        defer { deactivateSession() }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    static func voice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceCandidate(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
        }
        if let pick = VoicePicker.pick(from: candidates), let voice = AVSpeechSynthesisVoice(identifier: pick.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-GB")
    }

    private func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback, mode: .spokenAudio,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // Speak anyway; the synthesizer will use whatever session state it can get.
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
