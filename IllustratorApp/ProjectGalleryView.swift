import SwiftUI

struct ProjectGalleryView: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @State private var projects: [ProjectItem] = []
    @State private var openedProjectId: String?
    @State private var showRenameAlert = false
    @State private var renameTarget: ProjectItem?
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: ProjectItem?
    @State private var showSettings = false

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    // Botão novo canvas
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

                    // Projetos existentes
                    ForEach(projects) { project in
                        ProjectCard(project: project)
                            .onTapGesture {
                                openedProjectId = project.id
                            }
                            .contextMenu {
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
                .padding(20)
            }
            .navigationTitle("mAI Draw")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isDarkMode: $isDarkMode)
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
                        StorageService.renameProject(id: target.id, newTitle: renameText)
                        loadProjects()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Excluir canvas?", isPresented: $showDeleteConfirm) {
                Button("Excluir", role: .destructive) {
                    if let target = deleteTarget {
                        StorageService.deleteProject(id: target.id)
                        loadProjects()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Isso não pode ser desfeito.")
            }
            .onAppear { loadProjects() }
            .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }

    private func loadProjects() {
        projects = StorageService.listProjects()
    }

    private func createNewCanvas() {
        let id = UUID().uuidString.prefix(8).lowercased()
        let doc = CanvasDocument(
            id: String(id),
            title: "Sem título",
            createdAt: Date(),
            updatedAt: Date(),
            prompt: "Transform this sketch into a colorful children's book illustration with vibrant colors, hand-drawn whimsical style",
            elements: []
        )
        StorageService.save(document: doc, drawing: .init(), thumbnail: nil)
        openedProjectId = String(id)
    }

    private func duplicateProject(_ project: ProjectItem) {
        guard let doc = StorageService.loadDocument(id: project.id) else { return }
        let newId = UUID().uuidString.prefix(8).lowercased()
        var newDoc = doc
        newDoc.id = String(newId)
        newDoc.title = "\(doc.title) (cópia)"
        newDoc.createdAt = Date()
        newDoc.updatedAt = Date()

        let drawing = StorageService.loadDrawing(id: project.id) ?? .init()
        let thumb = StorageService.loadThumbnail(id: project.id)
        StorageService.save(document: newDoc, drawing: drawing, thumbnail: thumb)

        // Copiar arquivos de mídia
        let sourceFolder = StorageService.canvasURL(for: project.id)
        let destFolder = StorageService.canvasURL(for: String(newId))
        for element in doc.elements {
            if let file = element.file {
                let src = sourceFolder.appendingPathComponent(file)
                let dst = destFolder.appendingPathComponent(file)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        loadProjects()
    }
}

// MARK: - Project Card

struct ProjectCard: View {
    let project: ProjectItem
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
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
        .onAppear {
            thumbnail = StorageService.loadThumbnail(id: project.id)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Aparência") {
                    Toggle(isOn: $isDarkMode) {
                        Label("Modo Escuro", systemImage: isDarkMode ? "moon.fill" : "moon")
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
