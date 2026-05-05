import SwiftUI

struct PhoneContentView: View {
    let projectId: String
    var onClose: () -> Void

    @AppStorage("isDarkMode") private var isDarkMode = false
    @State private var document: CanvasDocument?
    @State private var showBrainDump = false
    @State private var isProcessing = false
    @State private var mindMapResult: GeminiService.MindMapResult?
    @State private var summaryText: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var thumbnail: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    }

                    if let summary = summaryText {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resumo")
                                .font(.headline)
                            Text(summary)
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    if let mindMap = mindMapResult {
                        PhoneMindMapView(result: mindMap)
                            .padding(.horizontal)
                    }

                    if thumbnail == nil && summaryText == nil && mindMapResult == nil {
                        VStack(spacing: 16) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 60, weight: .light))
                                .foregroundColor(.secondary)
                            Text("Toque em Brain Dump para começar")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 80)
                    }

                    Spacer(minLength: 100)
                }
                .padding(.top)
            }
            .navigationTitle(document?.title ?? "Sem título")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        Button {
                            showBrainDump = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "brain.head.profile")
                                Text("Brain Dump")
                            }
                            .font(.subheadline.bold())
                        }
                    }
                }
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
            .onAppear { loadProject() }
            .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }

    private func loadProject() {
        document = StorageService.loadDocument(id: projectId)
        thumbnail = StorageService.loadThumbnail(id: projectId)
    }

    private func generateMindMap(from text: String, layout: MindMapLayout, customPrompt: String) {
        isProcessing = true
        Task {
            do {
                let result = try await GeminiService.generateMindMap(from: text, customPrompt: customPrompt)
                mindMapResult = result
                summaryText = result.summary
                saveProject()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isProcessing = false
        }
    }

    private func generateYouTubeSummary(from input: String, layout: MindMapLayout, customPrompt: String) {
        isProcessing = true
        Task {
            do {
                let result = try await GeminiService.summarizeYouTubeInput(input, customPrompt: customPrompt)
                summaryText = result.summary
                mindMapResult = result.mindMap
                saveProject()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isProcessing = false
        }
    }

    private func saveProject() {
        guard var doc = document else { return }
        doc.updatedAt = Date()
        StorageService.save(document: doc, thumbnail: nil)
    }
}

// MARK: - Mind Map Tree View (iPhone)

struct PhoneMindMapView: View {
    let result: GeminiService.MindMapResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.title)
                .font(.title3.bold())
                .padding(.bottom, 4)

            ForEach(result.nodes.sorted(by: { $0.level < $1.level }), id: \.id) { node in
                HStack(spacing: 8) {
                    Circle()
                        .fill(colorForLevel(node.level))
                        .frame(width: 8, height: 8)

                    Text(node.text)
                        .font(fontForLevel(node.level))
                        .foregroundColor(node.level == 0 ? .primary : .secondary)
                }
                .padding(.leading, CGFloat(node.level) * 20)
            }
        }
        .padding()
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 0: return .blue
        case 1: return .orange
        default: return .green
        }
    }

    private func fontForLevel(_ level: Int) -> Font {
        switch level {
        case 0: return .headline
        case 1: return .subheadline.weight(.medium)
        default: return .caption
        }
    }
}
