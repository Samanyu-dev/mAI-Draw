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

    // MARK: - Text Review (Gemini 3 Flash)

    static let flashModel = "gemini-3-flash-preview"

    struct TextElement {
        let index: Int
        let text: String
        let type: String // "text" ou "postit"
    }

    struct ReviewedText {
        let index: Int
        let text: String
    }

    static func reviewTexts(_ elements: [TextElement]) async throws -> [ReviewedText] {
        // Montar lista de textos para o prompt
        var textList = ""
        for el in elements {
            textList += "[\(el.index)] (\(el.type)): \(el.text)\n"
        }

        let prompt = """
        Você é um assistente de escrita. Abaixo estão textos de um quadro de notas (canvas).
        Cada texto tem um índice e tipo (text ou postit).

        Sua tarefa:
        1. Leia TODOS os textos e entenda o contexto geral
        2. Para cada texto, reescreva corrigindo ortografia, gramática e melhorando a clareza
        3. Mantenha a essência e intenção original de cada texto
        4. Se o texto é uma nota curta, mantenha curto. Se é longo, pode resumir
        5. Responda SOMENTE o JSON no formato especificado

        Textos:
        \(textList)
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "texts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "index": ["type": "integer", "description": "Índice do texto original"],
                            "text": ["type": "string", "description": "Texto corrigido/melhorado"]
                        ],
                        "required": ["index", "text"]
                    ]
                ]
            ],
            "required": ["texts"]
        ]

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema
            ]
        ]

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(flashModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw GeminiError.apiError("URL inválida") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Erro desconhecido"
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorMsg)")
        }

        return try parseReviewResponse(data)
    }

    private static func parseReviewResponse(_ data: Data) throws -> [ReviewedText] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiError.apiError(message)
            }
            throw GeminiError.apiError("Resposta inválida do Gemini Flash")
        }

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                guard let jsonData = text.data(using: .utf8),
                      let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let texts = parsed["texts"] as? [[String: Any]] else {
                    throw GeminiError.apiError("JSON inválido na resposta: \(text.prefix(200))")
                }

                return texts.compactMap { item in
                    guard let index = item["index"] as? Int,
                          let corrected = item["text"] as? String else { return nil }
                    return ReviewedText(index: index, text: corrected)
                }
            }
        }

        throw GeminiError.apiError("Nenhum texto na resposta")
    }

    // MARK: - Brain Dump → Mind Map (Gemini 3 Flash)

    struct MindMapNode: Codable {
        let id: Int
        let text: String
        let level: Int // 0 = central, 1 = sub-ideia, 2 = detalhe
    }

    struct MindMapConnection: Codable {
        let from: Int
        let to: Int
    }

    struct MindMapResult: Codable {
        let title: String
        let nodes: [MindMapNode]
        let connections: [MindMapConnection]
    }

    static func generateMindMap(from text: String, customPrompt: String = "") async throws -> MindMapResult {
        let userInstruction = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Simplifique e resuma — não copie o texto original"
            : customPrompt

        let prompt = """
        Você é um especialista em mapas mentais. Receba o texto abaixo e transforme em um mapa mental estruturado.

        Instruções do usuário: \(userInstruction)

        Regras técnicas:
        1. Crie um TÍTULO curto (2-4 palavras) que resuma o tema central
        2. Organize em hierarquia:
           - level 0: ideia central (apenas 1 nó)
           - level 1: sub-ideias principais (2-5 nós)
           - level 2: detalhes/exemplos (0-3 por sub-ideia)
        3. Cada nó deve ter texto CURTO (máximo 6 palavras)
        4. Crie conexões lógicas entre os nós (de pai para filho)
        5. IDs começam em 0 (o nó central)
        6. Máximo 15 nós no total

        Texto:
        \(text)
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Título curto do mapa mental"],
                "nodes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "integer"],
                            "text": ["type": "string"],
                            "level": ["type": "integer"]
                        ],
                        "required": ["id", "text", "level"]
                    ]
                ],
                "connections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "integer"],
                            "to": ["type": "integer"]
                        ],
                        "required": ["from", "to"]
                    ]
                ]
            ],
            "required": ["title", "nodes", "connections"]
        ]

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema
            ]
        ]

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(flashModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw GeminiError.apiError("URL inválida") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Erro desconhecido"
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorMsg)")
        }

        return try parseMindMapResponse(data)
    }

    private static func parseMindMapResponse(_ data: Data) throws -> MindMapResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiError.apiError(message)
            }
            throw GeminiError.apiError("Resposta inválida do Gemini Flash")
        }

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                guard let jsonData = text.data(using: .utf8) else {
                    throw GeminiError.apiError("JSON inválido na resposta")
                }
                let decoder = JSONDecoder()
                return try decoder.decode(MindMapResult.self, from: jsonData)
            }
        }

        throw GeminiError.apiError("Nenhum dado na resposta")
    }

    // MARK: - YouTube Transcript → Summary + Mind Map

    struct TranscriptSummaryResult: Codable {
        let summary: String
        let mindMap: MindMapResult

        enum CodingKeys: String, CodingKey {
            case summary
            case mindMap = "mind_map"
        }
    }

    static func summarizeTranscript(_ transcript: String, customPrompt: String = "") async throws -> TranscriptSummaryResult {
        let userInstruction = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Faça um resumo claro e organizado. Use linguagem direta."
            : customPrompt

        let prompt = """
        Você é um especialista em resumos e mapas mentais. Receba a transcrição de um vídeo do YouTube e gere:

        1. **summary**: Um resumo do conteúdo do vídeo (3-5 parágrafos).
        2. **mind_map**: Um mapa mental estruturado com as ideias principais.

        Instruções do usuário: \(userInstruction)

        Regras técnicas do mapa mental:
        - title: 2-4 palavras resumindo o tema
        - level 0: ideia central (1 nó)
        - level 1: tópicos principais (2-5 nós)
        - level 2: detalhes/exemplos (0-3 por tópico)
        - Texto de cada nó: máximo 6 palavras
        - IDs começam em 0
        - Máximo 15 nós
        - Conexões de pai para filho

        Transcrição:
        \(transcript.prefix(15000))
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string", "description": "Resumo do vídeo em 3-5 parágrafos"],
                "mind_map": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "nodes": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "integer"],
                                    "text": ["type": "string"],
                                    "level": ["type": "integer"]
                                ],
                                "required": ["id", "text", "level"]
                            ]
                        ],
                        "connections": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "from": ["type": "integer"],
                                    "to": ["type": "integer"]
                                ],
                                "required": ["from", "to"]
                            ]
                        ]
                    ],
                    "required": ["title", "nodes", "connections"]
                ]
            ],
            "required": ["summary", "mind_map"]
        ]

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema
            ]
        ]

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(flashModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw GeminiError.apiError("URL inválida") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Erro desconhecido"
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorMsg)")
        }

        return try parseTranscriptSummaryResponse(data)
    }

    private static func parseTranscriptSummaryResponse(_ data: Data) throws -> TranscriptSummaryResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GeminiError.apiError(message)
            }
            throw GeminiError.apiError("Resposta inválida do Gemini Flash")
        }

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                guard let jsonData = text.data(using: .utf8) else {
                    throw GeminiError.apiError("JSON inválido na resposta")
                }
                return try JSONDecoder().decode(TranscriptSummaryResult.self, from: jsonData)
            }
        }

        throw GeminiError.apiError("Nenhum dado na resposta")
    }

    // MARK: - Image Response Parser

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
