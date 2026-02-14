import UIKit

enum GeminiError: LocalizedError {
    case encodingFailed
    case noImageInResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Falha ao codificar imagem"
        case .noImageInResponse: return "API não retornou imagem"
        case .apiError(let msg): return msg
        }
    }
}

struct GeminiService {
    static let apiKey = "GEMINI_API_KEY_REMOVED"
    static let model = "gemini-3-pro-image-preview"

    static func illustrate(image: UIImage, prompt: String) async throws -> UIImage {
        // Comprimir como JPEG pra reduzir tamanho do payload (mesmo approach do SDK)
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw GeminiError.encodingFailed
        }
        let base64 = jpegData.base64EncodedString()

        // Formato validado — mesmo que o SDK google-genai usa internamente
        // contents: [image, prompt] → responseModalities: ["TEXT", "IMAGE"]
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    [
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": base64
                        ]
                    ],
                    [
                        "text": prompt
                    ]
                ]
            ]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw GeminiError.apiError("URL inválida") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Erro desconhecido"
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorMsg)")
        }

        return try parseImageFromResponse(data)
    }

    private static func parseImageFromResponse(_ data: Data) throws -> UIImage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // Tentar extrair mensagem de erro
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiError.apiError(message)
            }
            throw GeminiError.noImageInResponse
        }

        for part in parts {
            // Resposta pode vir como "inlineData" ou "inline_data"
            let inlineData = (part["inlineData"] as? [String: Any])
                          ?? (part["inline_data"] as? [String: Any])

            if let inlineData = inlineData,
               let b64 = inlineData["data"] as? String,
               let imageData = Data(base64Encoded: b64),
               let image = UIImage(data: imageData) {
                return image
            }
        }

        // Se não encontrou imagem, mostrar texto da resposta se houver
        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                throw GeminiError.apiError("IA respondeu texto, sem imagem: \(text.prefix(200))")
            }
        }

        throw GeminiError.noImageInResponse
    }
}
