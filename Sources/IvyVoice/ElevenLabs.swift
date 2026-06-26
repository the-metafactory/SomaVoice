import Foundation

enum ElevenLabsError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .noKey: return "ELEVENLABS_API_KEY not found in ~/.env"
        case let .http(code, body): return "ElevenLabs HTTP \(code): \(body)"
        case .badResponse: return "Unexpected ElevenLabs response"
        }
    }
}

/// Thin client for the two ElevenLabs endpoints we need: speech-to-text
/// (scribe) for the mic, text-to-speech (turbo, low latency) for replies.
struct ElevenLabs {
    let apiKey: String

    init() throws {
        guard let key = Config.elevenLabsKey, !key.isEmpty else { throw ElevenLabsError.noKey }
        self.apiKey = key
    }

    /// Transcribe a recorded audio file → text. Uses the `scribe_v1` model.
    func transcribe(fileURL: URL) async throws -> String {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", "scribe_v1")
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw ElevenLabsError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synthesize speech for `text` in `voiceId` → mp3 audio data.
    func synthesize(text: String, voiceId: String) async throws -> Data {
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw ElevenLabsError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ElevenLabsError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
