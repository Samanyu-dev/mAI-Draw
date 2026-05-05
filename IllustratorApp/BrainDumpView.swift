import SwiftUI
import AVFoundation

struct BrainDumpView: View {
    @Binding var isPresented: Bool
    var onGenerate: (String, MindMapLayout, String) -> Void
    var onYouTubeSummary: (String, MindMapLayout, String) -> Void

    static let defaultMindMapPrompt = "Organize em hierarquia com título curto, tópicos principais e detalhes. Texto de cada nó: máximo 6 palavras. Simplifique e resuma."

    @State private var text = ""
    @State private var youtubeURL = ""
    @State private var isFetchingTranscript = false
    @State private var showPromptEditor = false
    @State private var mindMapPrompt: String = {
        UserDefaults.standard.string(forKey: "mindMapPrompt") ?? BrainDumpView.defaultMindMapPrompt
    }()
    @State private var selectedLayout: MindMapLayout = {
        if let saved = UserDefaults.standard.string(forKey: "mindMapLayout"),
           let layout = MindMapLayout(rawValue: saved) {
            return layout
        }
        return .radial
    }()
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioLevel: CGFloat = 0
    @State private var levelTimer: Timer?
    @State private var errorMessage: String?
    @State private var showError = false
    @FocusState private var isFocused: Bool

    private var audioFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braindump_recording.m4a")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                        .foregroundColor(.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brain Dump")
                            .font(.headline)
                        Text("Escreva ou fale tudo que vem na cabeça.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(wordCount) palavras")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(UIColor.systemGray6), in: Capsule())
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                // YouTube URL input
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)

                    TextField("Cole link do YouTube aqui...", text: $youtubeURL)
                        .font(.subheadline)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: youtubeURL) { _, newValue in
                            autoProcessYouTube(newValue)
                        }

                    if isFetchingTranscript {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                youtubeURL = clipboard
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Editor de texto
                TextEditor(text: $text)
                    .focused($isFocused)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Comece a escrever suas ideias aqui...\n\nOu toque no microfone para ditar.")
                                .font(.body)
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.horizontal, 17)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                // Seletor de layout
                HStack(spacing: 0) {
                    Text("Layout:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 12)

                    ForEach(MindMapLayout.allCases, id: \.rawValue) { layout in
                        Button {
                            selectedLayout = layout
                            UserDefaults.standard.set(layout.rawValue, forKey: "mindMapLayout")
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: layout.icon)
                                    .font(.system(size: 18))
                                Text(layout.label)
                                    .font(.caption2)
                            }
                            .foregroundColor(selectedLayout == layout ? .primary : .secondary)
                            .frame(width: 72, height: 50)
                            .background(
                                selectedLayout == layout ? Color(UIColor.systemGray4) : Color(UIColor.systemGray6),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        if layout != MindMapLayout.allCases.last {
                            Spacer().frame(width: 8)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Prompt customizável
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPromptEditor.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 14))
                            Text("Prompt da IA")
                                .font(.caption)
                            Image(systemName: showPromptEditor ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    if mindMapPrompt != Self.defaultMindMapPrompt {
                        Button {
                            mindMapPrompt = Self.defaultMindMapPrompt
                            UserDefaults.standard.set(mindMapPrompt, forKey: "mindMapPrompt")
                        } label: {
                            Text("Restaurar padrão")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if showPromptEditor {
                    TextEditor(text: $mindMapPrompt)
                        .font(.caption)
                        .frame(height: 80)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                                .padding(.horizontal, 12)
                        )
                }

                Divider()

                // Barra inferior — microfone
                HStack(spacing: 12) {
                    if isRecording {
                        Button {
                            stopAndTranscribe()
                        } label: {
                            AudioWaveView(level: audioLevel, color: .primary)
                                .frame(width: 44, height: 36)
                        }

                        Spacer()

                    } else if isTranscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Transcrevendo...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()

                    } else {
                        Button {
                            startRecording()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Ditar")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(.primary)
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        stopRecording()
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UserDefaults.standard.set(mindMapPrompt, forKey: "mindMapPrompt")
                        isPresented = false
                        if hasYouTubeLink {
                            onYouTubeSummary(youtubeURL, selectedLayout, mindMapPrompt)
                        } else {
                            onGenerate(text, selectedLayout, mindMapPrompt)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                            Text(hasYouTubeLink ? "Resumir Vídeo" : "Gerar Mapa")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(canGenerate ? .primary : .secondary)
                    }
                    .disabled(!canGenerate)
                }
            }
            .alert("Erro", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Erro desconhecido")
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            }
            .onDisappear {
                stopRecording()
                UserDefaults.standard.set(mindMapPrompt, forKey: "mindMapPrompt")
            }
        }
    }

    // MARK: - Computed

    private var wordCount: Int {
        text.split(separator: " ").count
    }

    private var canGenerate: Bool {
        let hasText = text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
        return (hasText || hasYouTubeLink) && !isRecording && !isTranscribing && !isFetchingTranscript
    }

    private var hasYouTubeLink: Bool {
        YouTubeTranscriptService.extractVideoId(from: youtubeURL) != nil
    }

    // MARK: - YouTube Auto-Process

    private func autoProcessYouTube(_ url: String) {
        guard !isFetchingTranscript else { return }
        guard YouTubeTranscriptService.extractVideoId(from: url) != nil else { return }

        isFetchingTranscript = true
        isFocused = false

        // Auto-disparar resumo usando o link direto no Gemini.
        UserDefaults.standard.set(mindMapPrompt, forKey: "mindMapPrompt")
        isPresented = false
        onYouTubeSummary(url.trimmingCharacters(in: .whitespacesAndNewlines), selectedLayout, mindMapPrompt)
    }

    // MARK: - Recording

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorMessage = "Sem acesso ao microfone"
            showError = true
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: audioFileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            audioRecorder = recorder
            isRecording = true
            isFocused = false

            // Timer para atualizar nível do áudio
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, min(1, (db + 50) / 50))
                DispatchQueue.main.async {
                    audioLevel = CGFloat(normalized)
                }
            }
        } catch {
            errorMessage = "Erro ao iniciar gravação: \(error.localizedDescription)"
            showError = true
        }
    }

    private func stopRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        audioLevel = 0
    }

    private func stopAndTranscribe() {
        stopRecording()
        isTranscribing = true

        Task {
            do {
                let transcription = try await WhisperService.transcribe(audioURL: audioFileURL)
                if !text.isEmpty && !text.hasSuffix("\n") {
                    text += "\n"
                }
                text += transcription
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isTranscribing = false
            isFocused = true
        }
    }
}
