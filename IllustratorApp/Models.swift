import UIKit

// MARK: - Canvas Items (runtime)

struct CanvasImageItem: Identifiable {
    let id = UUID()
    var image: UIImage
    var position: CGPoint
    var scale: CGFloat = 1.0
}

struct CanvasTextItem: Identifiable {
    let id = UUID()
    var text: String
    var position: CGPoint
}

enum PostItColor: String, CaseIterable, Codable {
    case yellow, pink, green, blue, purple

    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 1.0)
        case .pink: return UIColor(red: 0.95, green: 0.6, blue: 0.95, alpha: 1.0)
        case .green: return UIColor(red: 0.6, green: 0.95, blue: 0.7, alpha: 1.0)
        case .blue: return UIColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1.0)
        case .purple: return UIColor(red: 0.8, green: 0.65, blue: 1.0, alpha: 1.0)
        }
    }
}

struct CanvasPostItItem: Identifiable {
    let id = UUID()
    var text: String
    var position: CGPoint
    var color: PostItColor
}

struct CanvasAudioItem: Identifiable {
    let id = UUID()
    var fileURL: URL
    var position: CGPoint
    var duration: TimeInterval
}

// MARK: - Canvas Document (persistência)

struct CanvasDocument: Codable, Identifiable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var prompt: String
    var elements: [CanvasElement]
    var connections: [CanvasConnectionData]?
}

enum CanvasElementType: String, Codable {
    case text, postit, image, audio, strokeGroup
}

struct CanvasElement: Codable {
    var id: String? = nil
    var type: CanvasElementType
    var text: String?
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var color: PostItColor?
    var rotation: CGFloat?
    var file: String?
    var duration: TimeInterval?
    var scale: CGFloat?
    var highlightColor: String?
    var completionColor: String?
    var completionStyle: String?
}

// MARK: - Connection (setas entre elementos)

struct CanvasConnectionData: Codable {
    var fromIndex: Int
    var toIndex: Int
    var fromId: String? = nil
    var toId: String? = nil
}

// MARK: - Canvas State

@MainActor
class CanvasState: ObservableObject {
    @Published var images: [CanvasImageItem] = []
    @Published var isProcessing = false
    @Published var resultImage: UIImage? = nil
    @Published var prompt: String = UserDefaults.standard.string(forKey: "illustrationPrompt") ?? "Transform this sketch into a colorful children's book illustration with vibrant colors, hand-drawn whimsical style"
    @Published var isRecording = false
    @Published var isLassoMode = false
    @Published var audioLevel: CGFloat = 0.0
    @Published var isReviewing = false
    @Published var isDarkMode: Bool = UserDefaults.standard.bool(forKey: "isDarkMode")
}

// MARK: - Mind Map Layout

enum MindMapLayout: String, CaseIterable {
    case radial, tree, flow

    var label: String {
        switch self {
        case .radial: return "Radial"
        case .tree: return "Árvore"
        case .flow: return "Fluxo"
        }
    }

    var icon: String {
        switch self {
        case .radial: return "circle.grid.cross"
        case .tree: return "list.bullet.indent"
        case .flow: return "arrow.right.arrow.left"
        }
    }
}

// MARK: - Project Item (para galeria)

struct ProjectItem: Identifiable, Codable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
}
