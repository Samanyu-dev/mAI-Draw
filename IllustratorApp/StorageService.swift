import UIKit
import PencilKit

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
