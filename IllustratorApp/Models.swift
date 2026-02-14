import UIKit

// MARK: - Canvas Items

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

enum PostItColor: CaseIterable {
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

// MARK: - Canvas State

@MainActor
class CanvasState: ObservableObject {
    @Published var images: [CanvasImageItem] = []
    @Published var isProcessing = false
    @Published var resultImage: UIImage? = nil
    @Published var prompt: String = "Transform this sketch into a colorful children's book illustration with vibrant colors, hand-drawn whimsical style"
    @Published var isRecording = false
    @Published var isLassoMode = false
    @Published var audioLevel: CGFloat = 0.0
}
