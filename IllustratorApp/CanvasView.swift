import SwiftUI
import PencilKit

struct CanvasView: UIViewRepresentable {
    @ObservedObject var state: CanvasState
    let coordinator: CanvasCoordinator

    func makeUIView(context: Context) -> UIView {
        let rootView = coordinator.buildCanvas(in: UIScreen.main.bounds)
        return rootView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> CanvasCoordinator {
        coordinator
    }
}
