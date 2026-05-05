import SwiftUI
import PencilKit
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static let maiDrawProject = UTType(exportedAs: "com.loop9.maidraw.project", conformingTo: .json)
}

private struct ExportedProjectFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ProjectGalleryView: View {
    @EnvironmentObject var authState: AuthState
    @AppStorage("isDarkMode") private var isDarkMode = false
    @State private var projects: [ProjectItem] = []
    @State private var isSyncing = false
    @State private var openedProjectId: String?
    @State private var showRenameAlert = false
    @State private var renameTarget: ProjectItem?
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: ProjectItem?
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var exportedFile: ExportedProjectFile?
    @State private var importErrorMessage: String?
    // Multi-select
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        // Botão novo canvas (esconde no modo seleção)
                        if !isSelecting {
                            Button {
                                createNewCanvas()
                            } label: {
                                VStack(spacing: 12) {
                                    Image(systemName: "plus.rectangle.on.rectangle")
                                        .font(.system(size: 40, weight: .light))
                                        .foregroundColor(.secondary)
                                    Text("Novo Canvas")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(height: 200)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                                        .foregroundColor(.secondary.opacity(0.3))
                                )
                            }
                        }

                        // Projetos existentes
                        ForEach(projects) { project in
                            ProjectCard(project: project, isSelecting: isSelecting, isSelected: selectedIds.contains(project.id))
                                .onTapGesture {
                                    if isSelecting {
                                        toggleSelection(project.id)
                                    } else {
                                        openedProjectId = project.id
                                    }
                                }
                                .contextMenu {
                                    if !isSelecting {
                                        Button {
                                            renameTarget = project
                                            renameText = project.title
                                            showRenameAlert = true
                                        } label: {
                                            Label("Renomear", systemImage: "pencil")
                                        }

                                        Button {
                                            duplicateProject(project)
                                        } label: {
                                            Label("Duplicar", systemImage: "doc.on.doc")
                                        }

                                        Button {
                                            exportProject(project)
                                        } label: {
                                            Label("Exportar", systemImage: "square.and.arrow.up")
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            deleteTarget = project
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Excluir", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, isSelecting ? 80 : 0)
                }

                // Barra de ações do modo seleção
                if isSelecting {
                    selectionBar
                }
            }
            .navigationTitle("mAIDraw")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button("Cancelar") {
                            isSelecting = false
                            selectedIds.removeAll()
                        }
                    } else if isSyncing {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button(selectedIds.count == projects.count ? "Desmarcar tudo" : "Selecionar tudo") {
                            if selectedIds.count == projects.count {
                                selectedIds.removeAll()
                            } else {
                                selectedIds = Set(projects.map(\.id))
                            }
                        }
                    } else {
                        HStack(spacing: 16) {
                            Button {
                                showImporter = true
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 18, weight: .medium))
                            }
                            Button {
                                isSelecting = true
                                selectedIds.removeAll()
                            } label: {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 18, weight: .medium))
                            }
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18, weight: .medium))
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isDarkMode: $isDarkMode)
                    .environmentObject(authState)
            }
            .sheet(item: $exportedFile) { file in
                ActivityView(activityItems: [file.url])
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.maiDrawProject, .json, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .fullScreenCover(item: $openedProjectId) { projectId in
                ContentView(projectId: projectId, onClose: {
                    openedProjectId = nil
                    loadProjects()
                })
            }
            .alert("Renomear", isPresented: $showRenameAlert) {
                TextField("Nome", text: $renameText)
                Button("OK") {
                    if let target = renameTarget, !renameText.isEmpty {
                        isSyncing = true
                        Task {
                            await SyncService.renameProject(id: target.id, newTitle: renameText)
                            await loadProjects()
                            await MainActor.run { isSyncing = false }
                        }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Excluir canvas?", isPresented: $showDeleteConfirm) {
                Button("Excluir", role: .destructive) {
                    if let target = deleteTarget {
                        isSyncing = true
                        Task {
                            await SyncService.deleteProject(target.id)
                            await loadProjects()
                            await MainActor.run { isSyncing = false }
                        }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Isso não pode ser desfeito.")
            }
            .alert("Excluir \(selectedIds.count) canvas?", isPresented: $showBatchDeleteConfirm) {
                Button("Excluir \(selectedIds.count)", role: .destructive) {
                    deleteBatchSelected()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Isso não pode ser desfeito.")
            }
            .alert("Importação", isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "")
            }
            .onAppear { loadProjects() }
            .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack {
            Text("\(selectedIds.count) selecionado\(selectedIds.count != 1 ? "s" : "")")
                .font(.subheadline.weight(.medium))

            Spacer()

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("Excluir", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            }
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Selection Helpers

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func deleteBatchSelected() {
        let idsToDelete = selectedIds
        isSyncing = true
        isSelecting = false
        selectedIds.removeAll()
        Task {
            for id in idsToDelete {
                await SyncService.deleteProject(id)
            }
            await loadProjects()
            await MainActor.run { isSyncing = false }
        }
    }

    private func loadProjects() {
        isSyncing = true
        Task {
            let cloudProjects = await SyncService.listProjects()
            await MainActor.run {
                projects = cloudProjects
                isSyncing = false
            }
        }
    }

    private func createNewCanvas() {
        let id = UUID().uuidString.prefix(8).lowercased()
        let nextNumber = projects.count + 1
        let title = String(format: "Projeto %02d", nextNumber)
        let prompt = "Transform this sketch into a colorful children's book illustration with vibrant colors, hand-drawn whimsical style"

        // Create in cloud
        isSyncing = true
        Task {
            await SyncService.createProject(id: String(id), title: title, prompt: prompt)
            await MainActor.run {
                isSyncing = false
                openedProjectId = String(id)
            }
        }
    }

    private func exportProject(_ project: ProjectItem) {
        isSyncing = true
        Task {
            _ = await SyncService.loadDocument(id: project.id)
            do {
                let url = try StorageService.exportProject(id: project.id)
                await MainActor.run {
                    exportedFile = ExportedProjectFile(url: url)
                    isSyncing = false
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = "Não foi possível exportar este projeto: \(error.localizedDescription)"
                    isSyncing = false
                }
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importProject(from: url)
        case .failure(let error):
            importErrorMessage = "Não foi possível selecionar o arquivo: \(error.localizedDescription)"
        }
    }

    private func importProject(from url: URL) {
        isSyncing = true
        Task {
            do {
                let document = try StorageService.importProject(from: url)
                await SyncService.saveProject(
                    document,
                    drawingData: StorageService.loadDrawingData(id: document.id),
                    thumbnail: StorageService.loadThumbnail(id: document.id)
                )
                await loadProjects()
                await MainActor.run {
                    isSyncing = false
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = "Não foi possível importar este projeto: \(error.localizedDescription)"
                    isSyncing = false
                }
            }
        }
    }

    private func duplicateProject(_ project: ProjectItem) {
        isSyncing = true
        Task {
            // Load original from cloud
            guard let doc = await SyncService.loadDocument(id: project.id) else {
                await MainActor.run { isSyncing = false }
                return
            }

            let newId = UUID().uuidString.prefix(8).lowercased()
            var newDoc = doc
            newDoc.id = String(newId)
            newDoc.title = "\(doc.title) (cópia)"
            newDoc.createdAt = Date()
            newDoc.updatedAt = Date()

            // Save copy to cloud
            let drawing = StorageService.loadDrawing(id: project.id)
            let thumb = StorageService.loadThumbnail(id: project.id)

            // Cache locally first
            if let drawing = drawing {
                StorageService.save(document: newDoc, drawing: drawing, thumbnail: thumb)
            } else {
                StorageService.saveDocumentJSON(newDoc)
            }

            // Copy media files locally
            let sourceFolder = StorageService.canvasURL(for: project.id)
            let destFolder = StorageService.canvasURL(for: String(newId))
            for element in doc.elements {
                if let file = element.file {
                    let src = sourceFolder.appendingPathComponent(file)
                    let dst = destFolder.appendingPathComponent(file)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }

            // Upload to cloud
            await SyncService.saveProject(newDoc, drawingData: drawing?.dataRepresentation(), thumbnail: thumb)
            await loadProjects()
            await MainActor.run { isSyncing = false }
        }
    }
}

// MARK: - Project Card

struct ProjectCard: View {
    let project: ProjectItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    @AppStorage("isDarkMode") private var isDarkMode = false
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack(alignment: .topLeading) {
                ZStack {
                    Color(.systemGray6)
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    }
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Checkmark
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.7))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .padding(8)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(project.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
        .onAppear(perform: refreshThumbnail)
        .onChange(of: isDarkMode) { _, _ in
            refreshThumbnail()
        }
    }

    private func refreshThumbnail() {
        let projectId = project.id
        let dark = isDarkMode

        Task {
            if StorageService.loadDocument(id: projectId) == nil {
                _ = await SyncService.loadDocument(id: projectId)
            }

            let rendered = ProjectThumbnailRenderer.render(projectId: projectId, isDarkMode: dark)
            let fallback = StorageService.loadThumbnail(id: projectId)
            await MainActor.run {
                thumbnail = rendered ?? fallback
            }
        }
    }
}

private enum ProjectThumbnailRenderer {
    static func render(projectId: String, isDarkMode: Bool) -> UIImage? {
        guard let document = StorageService.loadDocument(id: projectId) else { return nil }
        let drawing = StorageService.loadDrawing(id: projectId)
        return render(
            elements: document.elements,
            connections: document.connections,
            drawing: drawing,
            projectId: projectId,
            isDarkMode: isDarkMode
        )
    }

    private static func render(elements: [CanvasElement], connections: [CanvasConnectionData]?, drawing: PKDrawing?, projectId: String, isDarkMode: Bool) -> UIImage? {
        let renderableElements = elements.filter(hasVisiblePreviewContent)
        var bounds = CGRect.null

        if let drawingBounds = drawing?.bounds, !drawingBounds.isEmpty {
            bounds = bounds.union(drawingBounds)
        }

        for element in renderableElements {
            bounds = bounds.union(rect(for: element))
        }

        guard !bounds.isNull, !bounds.isEmpty, bounds.width > 1, bounds.height > 1 else { return nil }

        let paddedBounds = bounds.insetBy(dx: -80, dy: -80)
        let maxPixelSide: CGFloat = 1400
        let renderScale = min(1, maxPixelSide / max(paddedBounds.width, paddedBounds.height))
        let outputSize = CGSize(
            width: max(1, ceil(paddedBounds.width * renderScale)),
            height: max(1, ceil(paddedBounds.height * renderScale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { ctx in
            let context = ctx.cgContext
            context.interpolationQuality = .high
            context.scaleBy(x: renderScale, y: renderScale)
            context.translateBy(x: -paddedBounds.origin.x, y: -paddedBounds.origin.y)

            drawBackground(in: paddedBounds, isDarkMode: isDarkMode, context: context)
            drawConnections(connections, elements: elements, context: context, isDarkMode: isDarkMode)

            for element in elements {
                drawElement(element, projectId: projectId, isDarkMode: isDarkMode)
            }

            if let drawing {
                let drawingImage = drawing.image(from: paddedBounds, scale: 1)
                drawingImage.draw(in: paddedBounds)
            }
        }
    }

    private static func hasVisiblePreviewContent(_ element: CanvasElement) -> Bool {
        switch element.type {
        case .text, .postit, .markdownCard:
            return !(element.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .strokeGroup, .audio:
            return true
        }
    }

    private static func rect(for element: CanvasElement) -> CGRect {
        let minWidth: CGFloat = element.type == .postit ? 280 : 1
        let minHeight: CGFloat = element.type == .postit ? 220 : 1
        return CGRect(
            x: element.x,
            y: element.y,
            width: max(element.width, minWidth),
            height: max(element.height, minHeight)
        )
    }

    private static func drawBackground(in rect: CGRect, isDarkMode: Bool, context: CGContext) {
        UIColor(patternImage: dotGridPattern(dark: isDarkMode)).setFill()
        context.fill(rect)
    }

    private static func dotGridPattern(dark: Bool) -> UIImage {
        let spacing: CGFloat = 20
        let dotRadius: CGFloat = 1.2
        let size = CGSize(width: spacing, height: spacing)
        let bgColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        let dotColor = dark
            ? UIColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)
            : UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            bgColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            dotColor.setFill()
            let center = CGPoint(x: spacing / 2, y: spacing / 2)
            ctx.cgContext.fillEllipse(in: CGRect(
                x: center.x - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }
    }

    private static func drawConnections(_ connections: [CanvasConnectionData]?, elements: [CanvasElement], context: CGContext, isDarkMode: Bool) {
        guard let connections else { return }
        var idToRect: [String: CGRect] = [:]
        for element in elements {
            if let id = element.id {
                idToRect[id] = rect(for: element)
            }
        }
        let rects = elements.map(rect(for:))
        let color = isDarkMode ? UIColor.white.withAlphaComponent(0.55) : UIColor.black.withAlphaComponent(0.45)

        for connection in connections {
            let fromRect = connection.fromId.flatMap { idToRect[$0] } ?? rects[safe: connection.fromIndex]
            let toRect = connection.toId.flatMap { idToRect[$0] } ?? rects[safe: connection.toIndex]
            guard let fromRect, let toRect else { continue }
            drawArrow(from: CGPoint(x: fromRect.midX, y: fromRect.midY), to: CGPoint(x: toRect.midX, y: toRect.midY), color: color, context: context)
        }
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, color: UIColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 18
        let arrowAngle: CGFloat = .pi / 7
        let p1 = CGPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle))
        let p2 = CGPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle))
        context.move(to: end)
        context.addLine(to: p1)
        context.move(to: end)
        context.addLine(to: p2)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawElement(_ element: CanvasElement, projectId: String, isDarkMode: Bool) {
        let elementRect = rect(for: element)

        switch element.type {
        case .text:
            drawPlainText(element.text ?? "", in: elementRect, isDarkMode: isDarkMode, font: UIFont(name: "Noteworthy-Bold", size: 24) ?? .systemFont(ofSize: 24, weight: .semibold), centered: true)
        case .markdownCard, .postit:
            drawMarkdownCard(element, in: elementRect, isDarkMode: isDarkMode)
        case .image, .strokeGroup:
            guard let filename = element.file, let image = StorageService.loadImage(named: filename, canvasId: projectId) else { return }
            drawImage(image, in: elementRect)
        case .audio:
            drawAudio(element, in: elementRect, isDarkMode: isDarkMode)
        }

        drawVisualMarks(for: element, in: elementRect)
    }

    private static func drawPlainText(_ text: String, in rect: CGRect, isDarkMode: Bool, font: UIFont, centered: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isDarkMode ? UIColor.white : UIColor.black,
            .paragraphStyle: paragraph
        ]

        (trimmed as NSString).draw(
            with: rect.insetBy(dx: 8, dy: 8),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
    }

    private static func drawMarkdownCard(_ element: CanvasElement, in rect: CGRect, isDarkMode: Bool) {
        let color: MarkdownCardColor = {
            if let cardColor = element.cardColor { return cardColor }
            if let postItColor = element.color { return MarkdownCardColor(from: postItColor) }
            return .crystal
        }()

        let path = UIBezierPath(roundedRect: rect, cornerRadius: min(24, min(rect.width, rect.height) * 0.12))
        color.uiColor.setFill()
        path.fill()
        UIColor.white.withAlphaComponent(isDarkMode ? 0.12 : 0.35).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let text = readableMarkdown(element.text ?? "")
        drawPlainText(text, in: rect.insetBy(dx: 16, dy: 14), isDarkMode: isDarkMode, font: .systemFont(ofSize: 15, weight: .regular), centered: false)
    }

    private static func readableMarkdown(_ markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { line in
                var output = line
                for prefix in ["### ", "## ", "# ", "> ", "- "] where output.hasPrefix(prefix) {
                    output = String(output.dropFirst(prefix.count))
                    break
                }
                return output.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
            .joined(separator: "\n")
    }

    private static func drawImage(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size))
    }

    private static func drawAudio(_ element: CanvasElement, in rect: CGRect, isDarkMode: Bool) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        UIColor.systemBlue.withAlphaComponent(isDarkMode ? 0.32 : 0.18).setFill()
        path.fill()
        let duration = element.duration.map(formatDuration) ?? "0:00"
        drawPlainText("Play  \(duration)", in: rect.insetBy(dx: 12, dy: 10), isDarkMode: isDarkMode, font: .systemFont(ofSize: 15, weight: .medium), centered: false)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func drawVisualMarks(for element: CanvasElement, in rect: CGRect) {
        if let color = color(named: element.highlightColor) {
            color.setStroke()
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -8), cornerRadius: 10)
            path.lineWidth = 5
            path.stroke()
        }

        guard let completionColor = color(named: element.completionColor) else { return }
        completionColor.setStroke()
        let path = UIBezierPath()
        path.lineWidth = 5
        path.lineCapStyle = .round

        switch element.completionStyle ?? "x" {
        case "slash":
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case "horizontal":
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case "doubleHorizontal":
            path.move(to: CGPoint(x: rect.minX, y: rect.midY - 8))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - 8))
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + 8))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + 8))
        default:
            path.move(to: rect.origin)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.stroke()
    }

    private static func color(named name: String?) -> UIColor? {
        switch name {
        case "red": return UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.8)
        case "blue": return UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 0.8)
        case "green": return UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.8)
        case "purple": return UIColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.8)
        case "orange": return UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 0.8)
        case "pink": return UIColor(red: 0.9, green: 0.3, blue: 0.6, alpha: 0.8)
        case "cyan": return UIColor(red: 0.1, green: 0.7, blue: 0.8, alpha: 0.8)
        default: return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var isDarkMode: Bool
    @EnvironmentObject var authState: AuthState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Aparência") {
                    Toggle(isOn: $isDarkMode) {
                        Label("Modo Escuro", systemImage: isDarkMode ? "moon.fill" : "moon")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await authState.signOut()
                            dismiss()
                        }
                    } label: {
                        Label("Sair da conta", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

// MARK: - String Identifiable (for fullScreenCover)

extension String: @retroactive Identifiable {
    public var id: String { self }
}
