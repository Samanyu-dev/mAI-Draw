import Foundation
import UIKit
import Supabase

struct SyncService {
    // MARK: - List Projects (Cloud = source of truth)

    struct RemoteProject: Decodable {
        let id: String
        let title: String
        let prompt: String?
        let created_at: String
        let updated_at: String
        let connections: [ConnectionJSON]?
    }

    struct ConnectionJSON: Codable {
        let fromIndex: Int
        let toIndex: Int
        let fromId: String?
        let toId: String?
    }

    static func listProjects() async -> [ProjectItem] {
        guard SupabaseManager.shared.isAuthenticated else { return [] }
        let client = SupabaseManager.shared.client

        do {
            let response: [RemoteProject] = try await client.from("projects")
                .select()
                .order("updated_at", ascending: false)
                .execute()
                .value

            let formatter = ISO8601DateFormatter()
            return response.compactMap { remote in
                guard let created = formatter.date(from: remote.created_at),
                      let updated = formatter.date(from: remote.updated_at) else { return nil }
                return ProjectItem(id: remote.id, title: remote.title, createdAt: created, updatedAt: updated)
            }
        } catch {
            print("[Sync] List projects error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Load Document (Cloud → Local Cache)

    struct RemoteElement: Decodable {
        let type: String
        let content: String?
        let position_x: CGFloat
        let position_y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let metadata: [String: String]?
    }

    /// Downloads project from cloud to local cache, then returns the document
    static func loadDocument(id: String) async -> CanvasDocument? {
        guard let userId = SupabaseManager.shared.currentUserId else { return nil }
        let client = SupabaseManager.shared.client

        // 1. Fetch project metadata
        do {
            let projects: [RemoteProject] = try await client.from("projects")
                .select()
                .eq("id", value: id)
                .execute()
                .value
            guard let remote = projects.first else { return nil }

            // 2. Fetch elements
            let rows: [RemoteElement] = try await client.from("elements")
                .select()
                .eq("project_id", value: id)
                .execute()
                .value

            let elements = rows.map { row in
                CanvasElement(
                    id: row.metadata?["elementId"],
                    type: CanvasElementType(rawValue: row.type) ?? .text,
                    text: row.content,
                    x: row.position_x,
                    y: row.position_y,
                    width: row.width,
                    height: row.height,
                    color: row.metadata?["color"].flatMap { PostItColor(rawValue: $0) },
                    cardColor: row.metadata?["cardColor"].flatMap { MarkdownCardColor(rawValue: $0) },
                    rotation: row.metadata?["rotation"].flatMap { CGFloat(Double($0) ?? 0) },
                    file: row.metadata?["file"],
                    duration: row.metadata?["duration"].flatMap { Double($0) },
                    scale: row.metadata?["scale"].flatMap { CGFloat(Double($0) ?? 1) },
                    highlightColor: row.metadata?["highlightColor"],
                    completionColor: row.metadata?["completionColor"],
                    completionStyle: row.metadata?["completionStyle"]
                )
            }

            let formatter = ISO8601DateFormatter()
            let connections = remote.connections?.map {
                CanvasConnectionData(
                    fromIndex: $0.fromIndex,
                    toIndex: $0.toIndex,
                    fromId: $0.fromId,
                    toId: $0.toId
                )
            }
            let doc = CanvasDocument(
                id: remote.id,
                title: remote.title,
                createdAt: formatter.date(from: remote.created_at) ?? Date(),
                updatedAt: formatter.date(from: remote.updated_at) ?? Date(),
                prompt: remote.prompt ?? "Transform this sketch into a colorful children's book illustration with vibrant colors, hand-drawn whimsical style",
                elements: elements,
                connections: connections
            )

            // A local edit may have been saved right before the app was closed while
            // the background cloud upload was still pending. Do not let older cloud
            // data overwrite the newer local position/state on next launch.
            if let localDoc = StorageService.loadDocument(id: id),
               localDoc.updatedAt > doc.updatedAt {
                return localDoc
            }

            // 3. Save to local cache
            StorageService.saveDocumentJSON(doc)

            // 4. Download binary files to local cache
            await downloadFiles(projectId: id, userId: userId, elements: elements)

            return doc
        } catch {
            print("[Sync] Load document error: \(error.localizedDescription)")
            // Fallback to local cache if cloud fails
            return StorageService.loadDocument(id: id)
        }
    }

    /// Downloads drawing, thumbnail and media files from storage to local cache
    private static func downloadFiles(projectId: String, userId: String, elements: [CanvasElement]) async {
        let client = SupabaseManager.shared.client
        let folder = StorageService.canvasURL(for: projectId)

        // Drawing
        let drawingPath = "\(userId)/\(projectId)/drawing.data"
        do {
            let data = try await client.storage.from("drawings").download(path: drawingPath)
            try? data.write(to: folder.appendingPathComponent("drawing.data"))
        } catch { /* No drawing, ok */ }

        // Thumbnail
        let thumbPath = "\(userId)/\(projectId)/thumbnail.jpg"
        do {
            let data = try await client.storage.from("thumbnails").download(path: thumbPath)
            try? data.write(to: folder.appendingPathComponent("thumbnail.jpg"))
        } catch { /* No thumbnail, ok */ }

        // Media files (images, audio)
        for element in elements {
            guard let file = element.file else { continue }
            let bucket = element.type == .audio ? "audio" : "images"
            let filePath = "\(userId)/\(projectId)/\(file)"
            do {
                let data = try await client.storage.from(bucket).download(path: filePath)
                try? data.write(to: folder.appendingPathComponent(file))
            } catch { /* File not in storage, skip */ }
        }
    }

    // MARK: - Save Project (Cloud + Local Cache)

    struct ProjectRow: Encodable {
        let id: String
        let user_id: String
        let title: String
        let prompt: String
        let created_at: String
        let updated_at: String
        let connections: [ConnectionJSON]?
    }

    struct ElementRow: Encodable {
        let project_id: String
        let user_id: String
        let type: String
        let content: String?
        let position_x: CGFloat
        let position_y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let metadata: [String: String]?
    }

    static func saveProject(_ doc: CanvasDocument, drawingData: Data?, thumbnail: UIImage?) async {
        guard let userId = SupabaseManager.shared.currentUserId else { return }
        let client = SupabaseManager.shared.client
        let formatter = ISO8601DateFormatter()

        // 1. Upsert project
        let connJSON = doc.connections?.map {
            ConnectionJSON(
                fromIndex: $0.fromIndex,
                toIndex: $0.toIndex,
                fromId: $0.fromId,
                toId: $0.toId
            )
        }
        let projectRow = ProjectRow(
            id: doc.id,
            user_id: userId,
            title: doc.title,
            prompt: doc.prompt,
            created_at: formatter.string(from: doc.createdAt),
            updated_at: formatter.string(from: doc.updatedAt),
            connections: connJSON
        )

        do {
            try await client.from("projects")
                .upsert(projectRow, onConflict: "id")
                .execute()
        } catch {
            print("[Sync] Save project error: \(error.localizedDescription)")
        }

        // 2. Replace elements (delete + insert)
        do {
            try await client.from("elements")
                .delete()
                .eq("project_id", value: doc.id)
                .execute()
        } catch {
            print("[Sync] Delete elements error: \(error.localizedDescription)")
        }

        for element in doc.elements {
            var meta: [String: String] = [:]
            if let elementId = element.id { meta["elementId"] = elementId }
            if let color = element.color { meta["color"] = color.rawValue }
            if let cardColor = element.cardColor { meta["cardColor"] = cardColor.rawValue }
            if let file = element.file { meta["file"] = file }
            if let rotation = element.rotation { meta["rotation"] = "\(rotation)" }
            if let scale = element.scale { meta["scale"] = "\(scale)" }
            if let duration = element.duration { meta["duration"] = "\(duration)" }
            if let hl = element.highlightColor { meta["highlightColor"] = hl }
            if let completion = element.completionColor { meta["completionColor"] = completion }
            if let completionStyle = element.completionStyle { meta["completionStyle"] = completionStyle }

            let row = ElementRow(
                project_id: doc.id,
                user_id: userId,
                type: element.type.rawValue,
                content: element.text,
                position_x: element.x,
                position_y: element.y,
                width: element.width,
                height: element.height,
                metadata: meta.isEmpty ? nil : meta
            )

            do {
                try await client.from("elements")
                    .insert(row)
                    .execute()
            } catch {
                print("[Sync] Insert element error: \(error.localizedDescription)")
            }
        }

        // 3. Upload drawing + thumbnail
        if let data = drawingData {
            await uploadFile(bucket: "drawings", path: "\(userId)/\(doc.id)/drawing.data", data: data)
        }

        if let thumb = thumbnail, let data = thumb.jpegData(compressionQuality: 0.7) {
            await uploadFile(bucket: "thumbnails", path: "\(userId)/\(doc.id)/thumbnail.jpg", data: data, contentType: "image/jpeg")
        }

        // 4. Upload media files (images, audio) from local cache
        let folder = StorageService.canvasURL(for: doc.id)
        for element in doc.elements {
            guard let file = element.file else { continue }
            let fileURL = folder.appendingPathComponent(file)
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            let bucket = element.type == .audio ? "audio" : "images"
            let contentType = element.type == .audio ? "audio/mpeg" : "image/jpeg"
            await uploadFile(bucket: bucket, path: "\(userId)/\(doc.id)/\(file)", data: fileData, contentType: contentType)
        }
    }

    // MARK: - Create Project (Cloud)

    static func createProject(id: String, title: String, prompt: String) async {
        guard let userId = SupabaseManager.shared.currentUserId else { return }
        let client = SupabaseManager.shared.client
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

        let row = ProjectRow(
            id: id,
            user_id: userId,
            title: title,
            prompt: prompt,
            created_at: now,
            updated_at: now,
            connections: nil
        )

        do {
            try await client.from("projects")
                .insert(row)
                .execute()
        } catch {
            print("[Sync] Create project error: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Project (Cloud + Local Cache)

    static func deleteProject(_ projectId: String) async {
        guard let userId = SupabaseManager.shared.currentUserId else { return }
        let client = SupabaseManager.shared.client

        // 1. Delete from tables
        do {
            try await client.from("elements")
                .delete()
                .eq("project_id", value: projectId)
                .execute()
            try await client.from("projects")
                .delete()
                .eq("id", value: projectId)
                .execute()
        } catch {
            print("[Sync] Delete project error: \(error.localizedDescription)")
        }

        // 2. Delete storage files
        for bucket in ["thumbnails", "drawings", "images", "audio"] {
            do {
                let files = try await client.storage.from(bucket).list(path: "\(userId)/\(projectId)")
                let paths = files.map { "\(userId)/\(projectId)/\($0.name)" }
                if !paths.isEmpty {
                    try await client.storage.from(bucket).remove(paths: paths)
                }
            } catch { /* Bucket may not have files */ }
        }

        // 3. Delete local cache
        StorageService.deleteProject(id: projectId)
    }

    // MARK: - Rename Project (Cloud + Local Cache)

    static func renameProject(id: String, newTitle: String) async {
        guard SupabaseManager.shared.isAuthenticated else { return }
        let client = SupabaseManager.shared.client

        do {
            try await client.from("projects")
                .update(["title": newTitle, "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: id)
                .execute()
        } catch {
            print("[Sync] Rename project error: \(error.localizedDescription)")
        }

        // Update local cache
        StorageService.renameProject(id: id, newTitle: newTitle)
    }

    // MARK: - Upload Media File

    static func uploadMediaFile(bucket: String, projectId: String, filename: String, data: Data, contentType: String = "application/octet-stream") async {
        guard let userId = SupabaseManager.shared.currentUserId else { return }
        let path = "\(userId)/\(projectId)/\(filename)"
        await uploadFile(bucket: bucket, path: path, data: data, contentType: contentType)
    }

    // MARK: - File Upload (Storage)

    private static func uploadFile(bucket: String, path: String, data: Data, contentType: String = "application/octet-stream") async {
        let client = SupabaseManager.shared.client
        do {
            try await client.storage.from(bucket)
                .upload(path, data: data, options: FileOptions(contentType: contentType, upsert: true))
        } catch {
            print("[Sync] Upload file error (\(bucket)/\(path)): \(error.localizedDescription)")
        }
    }

    // MARK: - Thumbnail URL

    static func thumbnailURL(for projectId: String) -> URL? {
        guard let userId = SupabaseManager.shared.currentUserId else { return nil }
        let path = "\(userId)/\(projectId)/thumbnail.jpg"
        let client = SupabaseManager.shared.client
        do {
            let url = try client.storage.from("thumbnails").getPublicURL(path: path)
            return url
        } catch {
            return nil
        }
    }
}
