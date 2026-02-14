import SwiftUI
import PhotosUI

struct ContentView: View {
    let projectId: String
    var onClose: () -> Void

    @StateObject private var state = CanvasState()
    @State private var coordinator: CanvasCoordinator?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPromptEditor = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showPostItColors = false
    @State private var isDrawingMode = true
    @State private var showPhotoPicker = false
    @State private var showBrainDump = false

    var body: some View {
        ZStack {
            // Canvas
            if let coord = coordinator {
                CanvasView(state: state, coordinator: coord)
                    .ignoresSafeArea()
            }

            // Toolbar superior — estilo Freeform
            VStack {
                HStack(spacing: 12) {
                    // Botão voltar
                    Button {
                        coordinator?.saveProject()
                        coordinator?.stopAutoSave()
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    // Grupo esquerdo — ferramentas de conteúdo
                    HStack(spacing: 8) {
                        // Pencil (desenho)
                        Button {
                            coordinator?.toggleDrawing()
                            isDrawingMode.toggle()
                        } label: {
                            Image(systemName: isDrawingMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(isDrawingMode ? .blue : Color(UIColor.systemGray3))
                                .frame(width: 36, height: 36)
                        }

                        // Laço (seleção)
                        Button {
                            coordinator?.toggleLasso()
                        } label: {
                            Image(systemName: state.isLassoMode ? "lasso.badge.sparkles" : "lasso")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(state.isLassoMode ? .primary : Color(UIColor.systemGray3))
                                .frame(width: 36, height: 36)
                        }

                        // Texto
                        toolButton(icon: "textformat.abc", tip: "Texto") {
                            coordinator?.addText()
                        }

                        // Post-it
                        toolButton(icon: "note.text", tip: "Post-it") {
                            showPostItColors.toggle()
                        }
                        .popover(isPresented: $showPostItColors) {
                            postItColorPicker
                        }

                        // Foto
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            toolIcon(icon: "photo.badge.plus")
                        }

                        // Áudio
                        if state.isRecording {
                            Button {
                                coordinator?.stopRecording()
                            } label: {
                                AudioWaveView(level: state.audioLevel)
                                    .frame(width: 36, height: 36)
                            }
                        } else {
                            toolButton(icon: "mic.fill", tip: "Gravar") {
                                coordinator?.startRecording()
                            }
                        }

                        // Brain Dump
                        toolButton(icon: "brain.head.profile", tip: "Brain Dump") {
                            showBrainDump = true
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    Spacer()

                    // Grupo direito — IA
                    HStack(spacing: 8) {
                        // Revisar Textos
                        Button {
                            reviewTexts()
                        } label: {
                            HStack(spacing: 4) {
                                if state.isReviewing {
                                    ProgressView()
                                        .tint(.primary)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "sparkle.magnifyingglass")
                                }
                                Text("Revisar")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .frame(height: 36)
                        }
                        .disabled(state.isReviewing || state.isProcessing)

                        // Prompt
                        toolButton(icon: "text.bubble", tip: "Prompt") {
                            showPromptEditor.toggle()
                        }

                        // Ilustrar
                        Button {
                            illustrate()
                        } label: {
                            HStack(spacing: 6) {
                                if state.isProcessing {
                                    ProgressView()
                                        .tint(.primary)
                                        .scaleEffect(0.8)
                                    Text("Ilustrando...")
                                } else {
                                    Image(systemName: "wand.and.stars")
                                    Text("Ilustrar")
                                }
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(state.isProcessing ? .secondary : .primary)
                        }
                        .disabled(state.isProcessing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }
        }
        .preferredColorScheme(state.isDarkMode ? .dark : .light)
        .onAppear {
            let coord = CanvasCoordinator(state: state, projectId: projectId)
            coordinator = coord
            // Carregar projeto salvo após o canvas ser montado
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                coord.loadProject()
                coord.startAutoSave()
                coord.applyColorScheme(dark: state.isDarkMode)
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            loadPhoto(newValue)
        }
        .sheet(isPresented: $showPromptEditor) {
            PromptEditorView(prompt: $state.prompt)
        }
        .sheet(isPresented: $showBrainDump) {
            BrainDumpView(isPresented: $showBrainDump) { text, layout, customPrompt in
                generateMindMap(from: text, layout: layout, customPrompt: customPrompt)
            } onYouTubeSummary: { text, layout, customPrompt in
                generateYouTubeSummary(from: text, layout: layout, customPrompt: customPrompt)
            }
        }
        .alert("Erro", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Erro desconhecido")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        // Keyboard shortcuts
        .background {
            // Cmd+T → Texto
            Button("") { coordinator?.addText() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden()
            // Cmd+P → Post-it (amarelo padrão)
            Button("") { coordinator?.addPostIt() }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
            // Cmd+R → Gravar/Parar
            Button("") {
                if state.isRecording {
                    coordinator?.stopRecording()
                } else {
                    coordinator?.startRecording()
                }
            }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            // Cmd+I → Importar imagem
            Button("") { showPhotoPicker = true }
                .keyboardShortcut("i", modifiers: .command)
                .hidden()
            // Cmd+S → Salvar
            Button("") { coordinator?.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Tool Button Helpers

    private func toolButton(icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolIcon(icon: icon)
        }
    }

    private func toolIcon(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.primary)
            .frame(width: 36, height: 36)
    }

    // MARK: - Post-it Color Picker

    private var postItColorPicker: some View {
        HStack(spacing: 12) {
            ForEach(Array(PostItColor.allCases.enumerated()), id: \.offset) { _, color in
                Button {
                    coordinator?.addPostIt(color: color)
                    showPostItColors = false
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(color.uiColor))
                        .frame(width: 40, height: 40)
                        .shadow(radius: 2)
                }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func illustrate() {
        guard let coord = coordinator else { return }
        guard let capturedImage = coord.captureCanvas() else {
            errorMessage = "Canvas vazio — desenhe algo primeiro!"
            showError = true
            return
        }

        state.isProcessing = true

        Task {
            do {
                let result = try await GeminiService.illustrate(image: capturedImage, prompt: state.prompt)
                coord.overlayResult(result)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            state.isProcessing = false
        }
    }

    private func reviewTexts() {
        guard let coord = coordinator else { return }
        let elements = coord.collectAllTexts()
        guard !elements.isEmpty else {
            errorMessage = "Nenhum texto para revisar — escreva algo primeiro!"
            showError = true
            return
        }

        state.isReviewing = true

        Task {
            do {
                let reviewed = try await GeminiService.reviewTexts(elements)
                coord.applyReviewedTexts(reviewed)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            state.isReviewing = false
        }
    }

    private func generateMindMap(from text: String, layout: MindMapLayout, customPrompt: String) {
        guard let coord = coordinator else { return }
        state.isProcessing = true

        Task {
            do {
                let result = try await GeminiService.generateMindMap(from: text, customPrompt: customPrompt)
                coord.createMindMap(from: result, layout: layout)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            state.isProcessing = false
        }
    }

    private func generateYouTubeSummary(from text: String, layout: MindMapLayout, customPrompt: String) {
        guard let coord = coordinator else { return }
        state.isProcessing = true

        Task {
            do {
                let result = try await GeminiService.summarizeTranscript(text, customPrompt: customPrompt)
                coord.addSummaryBlock(text: result.summary)
                coord.createMindMap(from: result.mindMap, layout: layout)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            state.isProcessing = false
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let coord = coordinator {
                let center = CGPoint(x: 2048, y: 2048)
                let canvasItem = CanvasImageItem(image: image, position: center)
                state.images.append(canvasItem)
                coord.addImage(canvasItem)
            }
        }
    }
}

// MARK: - Audio Wave Animation (real mic input)

struct AudioWaveView: View {
    var level: CGFloat // 0...1
    var color: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let barLevel = barHeight(index: i, level: level)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .frame(height: max(4, barLevel * 24))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }

    private func barHeight(index: Int, level: CGFloat) -> CGFloat {
        let offsets: [CGFloat] = [0.7, 0.9, 1.0, 0.85, 0.75]
        return level * offsets[index]
    }
}

// MARK: - Prompt Editor

struct PromptEditorView: View {
    @Binding var prompt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prompt para IA")
                    .font(.headline)

                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))

                Text("Esse texto será enviado junto com seu desenho para a IA transformar.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        UserDefaults.standard.set(prompt, forKey: "illustrationPrompt")
                        dismiss()
                    }
                }
            }
        }
    }
}
