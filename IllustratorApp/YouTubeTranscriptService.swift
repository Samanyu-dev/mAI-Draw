import Foundation

struct YouTubeTranscriptService {

    enum TranscriptError: LocalizedError {
        case invalidURL
        case noTranscript
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Link do YouTube inválido"
            case .noTranscript: return "Vídeo sem legendas/transcrição disponível"
            case .parseFailed(let msg): return "Erro ao extrair transcrição: \(msg)"
            }
        }
    }

    /// Extrai o video ID de uma URL do YouTube
    static func extractVideoId(from urlString: String) -> String? {
        let patterns = [
            "(?:youtube\\.com/watch\\?.*v=)([a-zA-Z0-9_-]{11})",
            "(?:youtu\\.be/)([a-zA-Z0-9_-]{11})",
            "(?:youtube\\.com/embed/)([a-zA-Z0-9_-]{11})",
            "(?:youtube\\.com/shorts/)([a-zA-Z0-9_-]{11})"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }

    /// Busca a transcrição de um vídeo do YouTube
    static func fetchTranscript(videoId: String) async throws -> String {
        // Usar Innertube API para obter caption tracks
        let innertubeURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "19.09.37",
                    "androidSdkVersion": 30,
                    "hl": "pt",
                    "gl": "BR"
                ]
            ],
            "videoId": videoId
        ]

        var request = URLRequest(url: innertubeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let captions = json["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]] else {
            throw TranscriptError.noTranscript
        }

        // Preferir português, depois inglês, depois qualquer idioma
        let preferredLangs = ["pt", "pt-BR", "en", "es"]
        var captionURL: String?

        for lang in preferredLangs {
            if let track = tracks.first(where: { ($0["languageCode"] as? String)?.hasPrefix(lang.prefix(2).description) == true }),
               let url = track["baseUrl"] as? String {
                captionURL = url
                break
            }
        }

        // Fallback: primeiro track disponível
        if captionURL == nil {
            captionURL = tracks.first?["baseUrl"] as? String
        }

        guard let urlStr = captionURL, let url = URL(string: urlStr) else {
            throw TranscriptError.noTranscript
        }

        // Buscar XML das legendas
        let (captionData, _) = try await URLSession.shared.data(from: url)

        guard let xml = String(data: captionData, encoding: .utf8) else {
            throw TranscriptError.parseFailed("Não foi possível ler legendas")
        }

        // Parsear XML simples: extrair texto de tags <text>
        return parseTranscriptXML(xml)
    }

    /// Parseia XML de legendas do YouTube e extrai o texto limpo
    private static func parseTranscriptXML(_ xml: String) -> String {
        // Tentar formato <s> (ANDROID client) primeiro, depois <text> (WEB client)
        let patterns = [
            "<s[^>]*>(.*?)</s>",        // ANDROID: <p><s>texto</s></p>
            "<text[^>]*>(.*?)</text>"    // WEB: <text>texto</text>
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            if matches.isEmpty { continue }

            var texts: [String] = []
            for match in matches {
                if let range = Range(match.range(at: 1), in: xml) {
                    var text = String(xml[range])
                    text = decodeHTMLEntities(text)
                    text = text.replacingOccurrences(of: "\n", with: " ")
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        texts.append(trimmed)
                    }
                }
            }
            if !texts.isEmpty {
                return texts.joined(separator: " ")
            }
        }

        return ""
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        return result
    }
}
