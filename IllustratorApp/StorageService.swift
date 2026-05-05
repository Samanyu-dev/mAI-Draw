import UIKit
import PencilKit

struct ProjectExportBundle: Codable {
    var format: String = "com.loop9.maidraw.project"
    var version: Int = 1
    var exportedAt: Date
    var document: CanvasDocument
    var drawingData: Data?
    var thumbnailData: Data?
    var files: [ProjectExportFile]
}

struct ProjectExportFile: Codable {
    var name: String
    var data: Data
}

enum ProjectExportImportError: LocalizedError {
    case documentNotFound
    case invalidFormat
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .documentNotFound:
            return "Projeto não encontrado no cache local."
        case .invalidFormat:
            return "Arquivo de projeto inválido."
        case .unreadableFile:
            return "Não foi possível ler o arquivo selecionado."
        }
    }
}

struct StorageService {
    private static let rootFolder = "mAI-Draw"

    // MARK: - Paths

    private static var baseURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(rootFolder)
    }

    private static var rootURL: URL {
        let url: URL
        if let userId = SupabaseManager.shared.currentUserId {
            url = baseURL.appendingPathComponent(userId)
        } else {
            url = baseURL
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func canvasURL(for id: String) -> URL {
        let url = rootURL.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Save Document JSON (cache only)

    static func saveDocumentJSON(_ document: CanvasDocument) {
        let folder = canvasURL(for: document.id)
        if let data = try? JSONEncoder.withDates.encode(document) {
            try? data.write(to: folder.appendingPathComponent("canvas.json"))
        }
    }

    // MARK: - Save

    static func save(document: CanvasDocument, drawing: PKDrawing, thumbnail: UIImage?) {
        save(document: document, drawingData: drawing.dataRepresentation(), thumbnail: thumbnail)
    }

    static func save(document: CanvasDocument, drawingData: Data, thumbnail: UIImage?) {
        let folder = canvasURL(for: document.id)

        // JSON
        if let data = try? JSONEncoder.withDates.encode(document) {
            try? data.write(to: folder.appendingPathComponent("canvas.json"))
        }

        // PKDrawing
        try? drawingData.write(to: folder.appendingPathComponent("drawing.data"))

        // Thumbnail
        if let thumb = thumbnail, let jpegData = thumb.jpegData(compressionQuality: 0.7) {
            try? jpegData.write(to: folder.appendingPathComponent("thumbnail.jpg"))
        }
    }

    // MARK: - Load

    static func loadDocument(id: String) -> CanvasDocument? {
        let folder = canvasURL(for: id)
        let jsonURL = folder.appendingPathComponent("canvas.json")
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        return try? JSONDecoder.withDates.decode(CanvasDocument.self, from: data)
    }

    static func loadDrawing(id: String) -> PKDrawing? {
        let folder = canvasURL(for: id)
        let drawingURL = folder.appendingPathComponent("drawing.data")
        guard let data = try? Data(contentsOf: drawingURL) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func loadDrawingData(id: String) -> Data? {
        let folder = canvasURL(for: id)
        return try? Data(contentsOf: folder.appendingPathComponent("drawing.data"))
    }

    static func loadThumbnail(id: String) -> UIImage? {
        let folder = canvasURL(for: id)
        let thumbURL = folder.appendingPathComponent("thumbnail.jpg")
        guard let data = try? Data(contentsOf: thumbURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Save Image File

    static func saveImage(_ image: UIImage, named filename: String, canvasId: String) {
        let folder = canvasURL(for: canvasId)
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: folder.appendingPathComponent(filename))
        }
    }

    static func loadImage(named filename: String, canvasId: String) -> UIImage? {
        let folder = canvasURL(for: canvasId)
        let url = folder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Copy Audio File

    static func copyAudioFile(from sourceURL: URL, named filename: String, canvasId: String) -> URL? {
        let folder = canvasURL(for: canvasId)
        let dest = folder.appendingPathComponent(filename)
        try? FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }

    static func audioFileURL(named filename: String, canvasId: String) -> URL {
        canvasURL(for: canvasId).appendingPathComponent(filename)
    }

    // MARK: - Delete

    static func deleteProject(id: String) {
        let folder = canvasURL(for: id)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Rename

    static func renameProject(id: String, newTitle: String) {
        guard var doc = loadDocument(id: id) else { return }
        doc.title = newTitle
        doc.updatedAt = Date()
        let folder = canvasURL(for: id)
        if let data = try? JSONEncoder.withDates.encode(doc) {
            try? data.write(to: folder.appendingPathComponent("canvas.json"))
        }
    }

    // MARK: - Export / Import

    static func exportProject(id: String) throws -> URL {
        guard let document = loadDocument(id: id) else {
            throw ProjectExportImportError.documentNotFound
        }

        let folder = canvasURL(for: id)
        let excludedFiles = Set(["canvas.json", "drawing.data", "thumbnail.jpg"])
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let extraFiles = fileURLs.compactMap { url -> ProjectExportFile? in
            guard !excludedFiles.contains(url.lastPathComponent),
                  let data = try? Data(contentsOf: url) else { return nil }
            return ProjectExportFile(name: url.lastPathComponent, data: data)
        }

        let bundle = ProjectExportBundle(
            exportedAt: Date(),
            document: document,
            drawingData: loadDrawingData(id: id),
            thumbnailData: try? Data(contentsOf: folder.appendingPathComponent("thumbnail.jpg")),
            files: extraFiles
        )

        let filename = "\(safeFilename(document.title))-maidraw-\(document.id).maidrawproject"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        let data = try JSONEncoder.withDates.encode(bundle)
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func importProject(from sourceURL: URL) throws -> CanvasDocument {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: sourceURL) else {
            throw ProjectExportImportError.unreadableFile
        }

        let bundle = try JSONDecoder.withDates.decode(ProjectExportBundle.self, from: data)
        guard bundle.format == "com.loop9.maidraw.project" || bundle.format == "com.loop9.maidea.project" else {
            throw ProjectExportImportError.invalidFormat
        }

        var document = bundle.document
        document.id = makeImportedProjectId()
        document.title = importedTitle(from: document.title)
        document.createdAt = Date()
        document.updatedAt = Date()

        let folder = canvasURL(for: document.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let documentData = try JSONEncoder.withDates.encode(document)
        try documentData.write(to: folder.appendingPathComponent("canvas.json"), options: [.atomic])

        if let drawingData = bundle.drawingData {
            try drawingData.write(to: folder.appendingPathComponent("drawing.data"), options: [.atomic])
        }

        if let thumbnailData = bundle.thumbnailData {
            try thumbnailData.write(to: folder.appendingPathComponent("thumbnail.jpg"), options: [.atomic])
        }

        for file in bundle.files {
            let url = folder.appendingPathComponent(safeImportedFilename(file.name))
            try file.data.write(to: url, options: [.atomic])
        }

        return document
    }

    private static func makeImportedProjectId() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func importedTitle(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Projeto importado" : trimmed
    }

    private static func safeFilename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let compact = cleaned.replacingOccurrences(of: " ", with: "-")
        let trimmed = compact.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "projeto" : String(trimmed.prefix(48))
    }

    private static func safeImportedFilename(_ filename: String) -> String {
        URL(fileURLWithPath: filename).lastPathComponent
    }
}

// MARK: - JSON Coders with Date

extension JSONEncoder {
    static let withDates: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let withDates: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
