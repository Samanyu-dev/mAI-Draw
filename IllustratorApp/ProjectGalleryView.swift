import SwiftUI

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
        .onAppear {
            thumbnail = StorageService.loadThumbnail(id: project.id)
        }
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
