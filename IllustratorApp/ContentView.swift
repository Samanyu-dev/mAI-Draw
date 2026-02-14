import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var state = CanvasState()
    @State private var coordinator: CanvasCoordinator?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPromptEditor = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showPostItColors = false
    @State private var isDrawingMode = true
    @State private var showPhotoPicker = false

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
                    // Grupo esquerdo — ferramentas de conteúdo
                    HStack(spacing: 8) {
                        // Pencil (desenho)
                        Button {
                            coordinator?.toggleDrawing()
                            isDrawingMode.toggle()
                        } label: {
                            Image(systemName: isDrawingMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(isDrawingMode ? .blue : .primary)
                                .frame(width: 36, height: 36)
                        }

                        // Laço (seleção)
                        Button {
                            coordinator?.toggleLasso()
                        } label: {
                            Image(systemName: state.isLassoMode ? "lasso.badge.sparkles" : "lasso")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(state.isLassoMode ? .blue : .primary)
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
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    Spacer()

                    // Grupo direito — IA
                    HStack(spacing: 8) {
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
                                        .tint(.white)
                                        .scaleEffect(0.8)
                                    Text("Ilustrando...")
                                } else {
                                    Image(systemName: "wand.and.stars")
                                    Text("Ilustrar")
                                }
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(state.isProcessing ? Color.gray : Color.black, in: Capsule())
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
        .onAppear {
            coordinator = CanvasCoordinator(state: state)
        }
        .onChange(of: selectedPhoto) { _, newValue in
            loadPhoto(newValue)
        }
        .sheet(isPresented: $showPromptEditor) {
            PromptEditorView(prompt: $state.prompt)
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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let barLevel = barHeight(index: i, level: level)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: 3)
                    .frame(height: max(4, barLevel * 24))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }

    private func barHeight(index: Int, level: CGFloat) -> CGFloat {
        // Variar levemente cada barra pra parecer waveform natural
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
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}
