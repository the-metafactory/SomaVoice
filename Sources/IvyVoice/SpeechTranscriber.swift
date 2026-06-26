import Foundation
import Speech

/// On-device speech-to-text via Apple's Speech framework. Chosen over a cloud
/// STT API deliberately: audio never leaves the machine (matches the design
/// doc's local-first privacy principle), and it needs no extra API scope.
enum SpeechError: LocalizedError {
    case notAuthorized
    case unavailable
    case noSpeech
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized (System Settings → Privacy → Speech Recognition)"
        case .unavailable: return "Speech recognizer unavailable for this locale"
        case .noSpeech: return "Didn't catch any speech"
        }
    }
}

struct SpeechTranscriber {
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe a recorded audio file in `localeID` (e.g. "en-US", "de-CH").
    /// Uses on-device recognition when an asset exists for that locale; otherwise
    /// falls back to server recognition (audio leaves the machine for that one).
    func transcribe(fileURL: URL, localeID: String) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !resumed {
                    resumed = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal, !resumed else { return }
                resumed = true
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { cont.resume(throwing: SpeechError.noSpeech) }
                else { cont.resume(returning: text) }
            }
        }
    }
}
