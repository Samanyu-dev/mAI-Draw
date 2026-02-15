import UIKit
import PencilKit
import AVFoundation

// MARK: - Non-Zoomable UITextView (bloqueia zoom do trackpad)

class NonZoomableTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupNoZoom()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupNoZoom()
    }

    private func setupNoZoom() {
        minimumZoomScale = 1.0
        maximumZoomScale = 1.0
        bouncesZoom = false
        pinchGestureRecognizer?.isEnabled = false
    }

    // Impedir que gesture recognizers de zoom ativem neste view
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPinchGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

// MARK: - Drawing Canvas (fica por cima de tudo)

class DrawingCanvas: PKCanvasView {
    weak var coordinator: CanvasCoordinator?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let container = superview else { return super.hitTest(point, with: event) }
        let pointInContainer = convert(point, to: container)

        // Só rotear para: botões, textViews editando, e selection box
        for sibling in container.subviews.reversed() {
            if sibling === self { continue }
            let pointInSibling = sibling.convert(pointInContainer, from: container)

            if let hit = sibling.hitTest(pointInSibling, with: event),
               hit.isUserInteractionEnabled {
                // Selection box e seus handles — sempre interagíveis
                if coordinator?.isSelectionBoxView(sibling) == true { return hit }
                // Botões (play audio, delete)
                if hit is UIButton { return hit }
                // Connection points (bolinhas para setas)
                if coordinator?.connectionPoints.contains(sibling) == true { return hit }
                // TextViews que estão sendo editados
                if let tv = hit as? UITextView, tv.isFirstResponder { return tv }
            }
        }

        // Tudo mais → canvas recebe (pencil desenha, dedo handled por gestures no canvas)
        return super.hitTest(point, with: event)
    }
}

// MARK: - Lasso Overlay (captura toques diretamente)

class LassoOverlayView: UIView {
    weak var coordinator: CanvasCoordinator?
    private var path = UIBezierPath()
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
        shapeLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        shapeLayer.lineWidth = 2.5
        shapeLayer.lineDashPattern = [8, 5]
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        coordinator?.clearSelection()
        path = UIBezierPath()
        path.move(to: touch.location(in: self))
        shapeLayer.path = path.cgPath
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        path.addLine(to: touch.location(in: self))
        shapeLayer.path = path.cgPath
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        path.close()
        shapeLayer.path = path.cgPath
        coordinator?.finishLasso(path: path)

        // Fade out do traço
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.shapeLayer.path = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        shapeLayer.path = nil
    }
}

// MARK: - Container

class CanvasContainer: UIView {
    weak var coordinator: CanvasCoordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if !MAIDRAW_PHONE
        if window != nil {
            coordinator?.activateDrawing()
        }
        #endif
    }
}

// MARK: - Selection Box (expande hit area pra handles nos cantos)

class SelectionBoxView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Handles nos cantos ficam parcialmente fora dos bounds
        // Expandir 40pt em cada direção pra cobrir a área de toque completa
        return bounds.insetBy(dx: -40, dy: -40).contains(point)
    }
}

// MARK: - Coordinator

class CanvasCoordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIDropInteractionDelegate, AVAudioRecorderDelegate, UIGestureRecognizerDelegate {
    let state: CanvasState
    let projectId: String
    private var scrollView: UIScrollView?
    private var containerView: CanvasContainer?
    private var canvasView: DrawingCanvas?
    private var toolPicker: PKToolPicker?
    private var imageViews: [UUID: UIImageView] = [:]
    private var allElementViews: [UUID: UIView] = [:]
    private var canvasTapGesture: UITapGestureRecognizer?
    private var selectionMovePan: UIPanGestureRecognizer?
    private var activeDragElement: UIView?
    private var autoSaveTimer: Timer?

    // Long press lasso
    private var inlineLassoPath: UIBezierPath?
    private var inlineLassoLayer: CAShapeLayer?

    // Audio
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayers: [UUID: AVAudioPlayer] = [:]
    private var recordingStartTime: Date?
    private var meteringTimer: Timer?

    // Lasso
    private var lassoOverlay: LassoOverlayView?
    private var selectionBox: UIView?
    private var selectedViews: [UIView] = []
    private var selectionStartCenters: [UIView: CGPoint] = [:]
    private var selectedStrokeIndices: [Int] = []
    private var resizeStartBoxFrame: CGRect = .zero
    private var resizeStartFrames: [UIView: CGRect] = [:]

    // Delete button
    private var activeDeleteButton: UIButton?
    private var activeHighlightButton: UIButton?
    private var deleteTargetView: UIView?

    // Connections (setas entre elementos)
    private var connections: [(from: UIView, to: UIView, layer: CAShapeLayer)] = []
    var connectionPoints: [UIView] = [] // bolinhas de conexão ativas
    private var connectionSourceView: UIView?   // elemento de onde está arrastando
    private var connectionPreviewLayer: CAShapeLayer? // preview da seta enquanto arrasta

    // Keys para objc_setAssociatedObject
    private static var audioURLKey: UInt8 = 0
    private static var audioIDKey: UInt8 = 0

    private let canvasSize = CGSize(width: 4096, height: 4096)
    private let handwritingFont = UIFont(name: "Noteworthy-Bold", size: 24) ?? UIFont.systemFont(ofSize: 24)

    private var currentTextColor: UIColor { state.isDarkMode ? .white : .black }
    private var postItTextColor: UIColor { .black } // Post-its sempre texto escuro (fundo colorido)
    private var currentArrowColor: CGColor {
        state.isDarkMode ? UIColor.white.cgColor : UIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0).cgColor
    }

    init(state: CanvasState, projectId: String) {
        self.state = state
        self.projectId = projectId
    }

    // MARK: - Setup

    func buildCanvas(in frame: CGRect) -> UIView {
        let scroll = UIScrollView(frame: frame)
        scroll.delegate = self
        scroll.minimumZoomScale = 0.1
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = false
        scroll.bounces = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = state.isDarkMode
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        scroll.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        self.scrollView = scroll

        let container = CanvasContainer(frame: CGRect(origin: .zero, size: canvasSize))
        container.backgroundColor = UIColor(patternImage: Self.dotGridPattern(dark: state.isDarkMode))
        self.containerView = container
        scroll.addSubview(container)
        scroll.contentSize = canvasSize

        container.coordinator = self

        // Canvas fica POR CIMA de tudo — hitTest roteia dedo pra elementos abaixo
        let canvas = DrawingCanvas(frame: CGRect(origin: .zero, size: canvasSize))
        canvas.delegate = self
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: currentTextColor, width: 5)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1.0
        canvas.maximumZoomScale = 1.0
        canvas.pinchGestureRecognizer?.isEnabled = false
        self.canvasView = canvas
        canvas.coordinator = self
        container.addSubview(canvas)

        let toolPicker = PKToolPicker()
        toolPicker.addObserver(canvas)
        self.toolPicker = toolPicker

        // Finger gestures no canvas — dedo interage com elementos abaixo
        let fingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(fingerTap)

        let fingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleFingerPan(_:)))
        fingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerPan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(fingerPan)

        // Long press + drag = laço automático
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressLasso(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.minimumPressDuration = 0.4
        canvas.addGestureRecognizer(longPress)

        let drop = UIDropInteraction(delegate: self)
        container.addInteraction(drop)

        // Tap no container deseleciona (fallback)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        container.addGestureRecognizer(tap)
        canvasTapGesture = tap

        // Undo: dois dedos, toque duplo
        let undo = UITapGestureRecognizer(target: self, action: #selector(handleUndo))
        undo.numberOfTouchesRequired = 2
        undo.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(undo)

        // Redo: três dedos, toque duplo
        let redo = UITapGestureRecognizer(target: self, action: #selector(handleRedo))
        redo.numberOfTouchesRequired = 3
        redo.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(redo)

        let offsetX = max(0, (canvasSize.width - frame.width) / 2)
        let offsetY = max(0, (canvasSize.height - frame.height) / 2)
        scroll.contentOffset = CGPoint(x: offsetX, y: offsetY)

        return scroll
    }

    /// Posição central visível no canvas
    private func visibleCenter() -> CGPoint {
        guard let scroll = scrollView else { return CGPoint(x: 2048, y: 2048) }
        let zoomScale = scroll.zoomScale
        return CGPoint(
            x: (scroll.contentOffset.x + scroll.bounds.width / 2) / zoomScale,
            y: (scroll.contentOffset.y + scroll.bounds.height / 2) / zoomScale
        )
    }

    /// Adiciona elemento abaixo do canvas (canvas fica no topo visual)
    private func addElementToCanvas(_ view: UIView) {
        guard let container = containerView, let canvas = canvasView else { return }
        container.insertSubview(view, belowSubview: canvas)
    }

    // MARK: - Drawing

    func activateDrawing() {
        guard let canvas = canvasView, let picker = toolPicker else { return }
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func toggleDrawing() {
        guard let canvas = canvasView, let picker = toolPicker else { return }
        if canvas.isFirstResponder {
            canvas.resignFirstResponder()
            picker.setVisible(false, forFirstResponder: canvas)
        } else {
            activateDrawing()
        }
    }

    var isDrawingActive: Bool {
        canvasView?.isFirstResponder ?? false
    }

    // MARK: - Lasso Selection

    func toggleLasso() {
        Task { @MainActor in
            state.isLassoMode.toggle()
            if state.isLassoMode {
                // Desativa drawing, mostra overlay de lasso
                canvasView?.resignFirstResponder()
                toolPicker?.setVisible(false, forFirstResponder: canvasView!)
                canvasView?.isUserInteractionEnabled = false
                showLassoOverlay()
            } else {
                clearSelection()
                hideLassoOverlay()
                canvasView?.isUserInteractionEnabled = true
                activateDrawing()
            }
        }
    }

    private func showLassoOverlay() {
        guard let container = containerView else { return }
        let overlay = LassoOverlayView(frame: container.bounds)
        overlay.coordinator = self
        container.addSubview(overlay)
        lassoOverlay = overlay
    }

    private func hideLassoOverlay() {
        lassoOverlay?.removeFromSuperview()
        lassoOverlay = nil
    }

    private func lassoPathContainsView(_ path: UIBezierPath, _ view: UIView) -> Bool {
        let f = view.frame
        let points = [
            view.center,
            CGPoint(x: f.minX, y: f.minY),
            CGPoint(x: f.maxX, y: f.minY),
            CGPoint(x: f.minX, y: f.maxY),
            CGPoint(x: f.maxX, y: f.maxY),
            CGPoint(x: f.midX, y: f.minY),
            CGPoint(x: f.midX, y: f.maxY),
            CGPoint(x: f.minX, y: f.midY),
            CGPoint(x: f.maxX, y: f.midY),
        ]
        return points.contains(where: { path.contains($0) })
    }

    func finishLasso(path: UIBezierPath) {
        var found: [UIView] = []
        for (_, view) in allElementViews {
            if lassoPathContainsView(path, view) {
                found.append(view)
            }
        }

        // Selecionar strokes do PencilKit dentro do laço
        selectedStrokeIndices.removeAll()
        if let canvas = canvasView {
            let drawing = canvas.drawing
            for (i, stroke) in drawing.strokes.enumerated() {
                let b = stroke.renderBounds
                let points = [
                    CGPoint(x: b.midX, y: b.midY),
                    CGPoint(x: b.minX, y: b.minY),
                    CGPoint(x: b.maxX, y: b.maxY),
                    CGPoint(x: b.minX, y: b.maxY),
                    CGPoint(x: b.maxX, y: b.minY),
                ]
                if points.contains(where: { path.contains($0) }) {
                    selectedStrokeIndices.append(i)
                }
            }

            // Se tem strokes selecionados, renderizar como imagem e adicionar como view
            if !selectedStrokeIndices.isEmpty {
                let selectedStrokes = selectedStrokeIndices.map { drawing.strokes[$0] }
                var selectedDrawing = PKDrawing()
                selectedDrawing.strokes = selectedStrokes

                let bounds = selectedDrawing.bounds
                if !bounds.isEmpty {
                    let paddedBounds = bounds.insetBy(dx: -4, dy: -4)
                    let image = selectedDrawing.image(from: paddedBounds, scale: 2.0)

                    let strokeView = UIImageView(image: image)
                    strokeView.frame = paddedBounds
                    strokeView.isUserInteractionEnabled = true
                    strokeView.tag = 888 // Tag especial para stroke group
                    addDragGestures(to: strokeView)
                    addElementToCanvas(strokeView)
                    found.append(strokeView)

                    // Registrar no allElementViews para ser re-selecionável
                    let strokeGroupID = UUID()
                    allElementViews[strokeGroupID] = strokeView

                    // Remover strokes originais do canvas
                    var newDrawing = drawing
                    for i in selectedStrokeIndices.sorted().reversed() {
                        newDrawing.strokes.remove(at: i)
                    }
                    canvas.drawing = newDrawing
                }
            }
        }

        guard !found.isEmpty else { return }
        selectedViews = found
        showSelectionBox()
    }

    private func showSelectionBox() {
        guard let container = containerView, !selectedViews.isEmpty else { return }

        // Esconder overlay pra permitir interação com selection box
        lassoOverlay?.isHidden = true

        // Highlight nos elementos (exceto stroke groups)
        for view in selectedViews where view.tag != 888 {
            view.layer.borderColor = UIColor.systemBlue.cgColor
            view.layer.borderWidth = 2.5
        }

        // Calcular bounding box de todos selecionados
        var unionRect = selectedViews[0].frame
        for view in selectedViews.dropFirst() {
            unionRect = unionRect.union(view.frame)
        }
        let boxRect = unionRect.insetBy(dx: -16, dy: -16)

        // Selection box (usa SelectionBoxView pra expandir hit area nos cantos)
        let box = SelectionBoxView(frame: boxRect)
        box.backgroundColor = .clear
        box.layer.borderColor = UIColor.systemBlue.cgColor
        box.layer.borderWidth = 1.5
        box.layer.cornerRadius = 6
        box.clipsToBounds = false
        box.isUserInteractionEnabled = true
        container.addSubview(box)
        selectionBox = box

        // Guardar posições iniciais relativas ao box
        selectionStartCenters.removeAll()
        for view in selectedViews {
            selectionStartCenters[view] = CGPoint(
                x: view.center.x - box.center.x,
                y: view.center.y - box.center.y
            )
        }

        // Handles nos 4 cantos — grandes pra facilitar toque
        let handleVisualSize: CGFloat = 28
        let handleTouchSize: CGFloat = 56
        let corners: [(CGFloat, CGFloat)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        for (i, corner) in corners.enumerated() {
            let handle = UIView()
            handle.frame = CGRect(x: 0, y: 0, width: handleTouchSize, height: handleTouchSize)
            handle.center = CGPoint(
                x: corner.0 * boxRect.width,
                y: corner.1 * boxRect.height
            )
            handle.backgroundColor = .clear
            handle.tag = 100 + i
            handle.isUserInteractionEnabled = true

            // Bolinha visual
            let dot = UIView()
            dot.frame = CGRect(x: 0, y: 0, width: handleVisualSize, height: handleVisualSize)
            dot.center = CGPoint(x: handleTouchSize / 2, y: handleTouchSize / 2)
            dot.backgroundColor = .white
            dot.layer.borderColor = UIColor.systemBlue.cgColor
            dot.layer.borderWidth = 2.5
            dot.layer.cornerRadius = handleVisualSize / 2
            dot.layer.shadowColor = UIColor.black.cgColor
            dot.layer.shadowOpacity = 0.2
            dot.layer.shadowRadius = 3
            dot.layer.shadowOffset = CGSize(width: 0, height: 1)
            dot.isUserInteractionEnabled = false
            handle.addSubview(dot)

            // Aceita dedo E caneta
            let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
            handle.addGestureRecognizer(resize)
            box.addSubview(handle)
        }

        // Tap no box que não faz nada — impede tap do container de disparar
        let eatTap = UITapGestureRecognizer(target: self, action: #selector(handleBoxTapEat(_:)))
        box.addGestureRecognizer(eatTap)

        // Pan pra mover grupo — aceita dedo E caneta
        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionMove(_:)))
        movePan.delegate = self
        box.addGestureRecognizer(movePan)
        selectionMovePan = movePan

        // Pinch pra redimensionar grupo (alternativa aos handles)
        let boxPinch = UIPinchGestureRecognizer(target: self, action: #selector(handleSelectionPinch(_:)))
        box.addGestureRecognizer(boxPinch)
    }

    @objc private func handleSelectionMove(_ gesture: UIPanGestureRecognizer) {
        guard let box = selectionBox else { return }
        let t = gesture.translation(in: box.superview)

        box.center = CGPoint(x: box.center.x + t.x, y: box.center.y + t.y)

        // Mover todos os elementos selecionados junto
        for view in selectedViews {
            if let offset = selectionStartCenters[view] {
                view.center = CGPoint(
                    x: box.center.x + offset.x,
                    y: box.center.y + offset.y
                )
            }
        }
        gesture.setTranslation(.zero, in: box.superview)
        updateAllConnections()
    }

    @objc private func handleSelectionPinch(_ gesture: UIPinchGestureRecognizer) {
        guard let box = selectionBox else { return }

        if gesture.state == .began {
            resizeStartBoxFrame = box.frame
            resizeStartFrames.removeAll()
            for view in selectedViews {
                resizeStartFrames[view] = view.frame
            }
        }

        let scale = gesture.scale
        let startCenter = CGPoint(x: resizeStartBoxFrame.midX, y: resizeStartBoxFrame.midY)

        for view in selectedViews {
            guard let startFrame = resizeStartFrames[view] else { continue }
            let startViewCenter = CGPoint(x: startFrame.midX, y: startFrame.midY)
            let dx = startViewCenter.x - startCenter.x
            let dy = startViewCenter.y - startCenter.y

            let newW = startFrame.width * scale
            let newH = startFrame.height * scale
            let newCenterX = startCenter.x + dx * scale
            let newCenterY = startCenter.y + dy * scale

            view.transform = .identity
            view.frame = CGRect(x: newCenterX - newW/2, y: newCenterY - newH/2, width: newW, height: newH)
        }

        refreshSelectionBox()
    }

    @objc private func handleResizePan(_ gesture: UIPanGestureRecognizer) {
        guard let box = selectionBox, let handle = gesture.view else { return }

        if gesture.state == .began {
            // Capturar estado inicial
            resizeStartBoxFrame = box.frame
            resizeStartFrames.removeAll()
            for view in selectedViews {
                resizeStartFrames[view] = view.frame
            }
        }

        let t = gesture.translation(in: box.superview)
        let startW = resizeStartBoxFrame.width
        let startH = resizeStartBoxFrame.height
        guard startW > 0, startH > 0 else { return }

        let cornerIndex = handle.tag - 100
        let scaleX: CGFloat
        let scaleY: CGFloat

        switch cornerIndex {
        case 0: scaleX = (startW - t.x) / startW; scaleY = (startH - t.y) / startH
        case 1: scaleX = (startW + t.x) / startW; scaleY = (startH - t.y) / startH
        case 2: scaleX = (startW - t.x) / startW; scaleY = (startH + t.y) / startH
        case 3: scaleX = (startW + t.x) / startW; scaleY = (startH + t.y) / startH
        default: return
        }

        let uniformScale = max(0.3, min((scaleX + scaleY) / 2, 5.0))
        let startCenter = CGPoint(x: resizeStartBoxFrame.midX, y: resizeStartBoxFrame.midY)

        // Reposicionar e escalar cada elemento relativo ao frame inicial
        for view in selectedViews {
            guard let startFrame = resizeStartFrames[view] else { continue }
            let startViewCenter = CGPoint(x: startFrame.midX, y: startFrame.midY)

            // Offset relativo ao centro do box inicial
            let dx = startViewCenter.x - startCenter.x
            let dy = startViewCenter.y - startCenter.y

            // Novo centro = centro original + offset escalado
            let newCenterX = startCenter.x + dx * uniformScale
            let newCenterY = startCenter.y + dy * uniformScale

            // Novo tamanho
            let newW = startFrame.width * uniformScale
            let newH = startFrame.height * uniformScale

            view.transform = .identity
            view.frame = CGRect(x: newCenterX - newW/2, y: newCenterY - newH/2, width: newW, height: newH)
        }

        // Recalcular box
        refreshSelectionBox()
    }

    private func refreshSelectionBox() {
        guard let box = selectionBox, !selectedViews.isEmpty else { return }

        var unionRect = selectedViews[0].frame
        for view in selectedViews.dropFirst() {
            unionRect = unionRect.union(view.frame)
        }
        let boxRect = unionRect.insetBy(dx: -16, dy: -16)
        box.frame = boxRect

        // Reposicionar handles
        let corners: [(CGFloat, CGFloat)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        for (i, corner) in corners.enumerated() {
            if let handle = box.viewWithTag(100 + i) {
                handle.center = CGPoint(
                    x: corner.0 * boxRect.width,
                    y: corner.1 * boxRect.height
                )
            }
        }

        // Atualizar offsets
        selectionStartCenters.removeAll()
        for view in selectedViews {
            selectionStartCenters[view] = CGPoint(
                x: view.center.x - box.center.x,
                y: view.center.y - box.center.y
            )
        }
    }

    func clearSelection() {
        for view in selectedViews {
            // Stroke groups (tag 888) nunca recebem borda
            if view.tag == 888 {
                view.layer.borderColor = nil
                view.layer.borderWidth = 0
            } else if view is UIImageView {
                view.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
                view.layer.borderWidth = 1.5
            } else {
                view.layer.borderColor = nil
                view.layer.borderWidth = 0
            }
        }
        selectedViews.removeAll()
        selectionStartCenters.removeAll()
        selectionBox?.removeFromSuperview()
        selectionBox = nil
        selectionMovePan = nil

        // Reativar overlay se ainda no modo lasso
        if state.isLassoMode {
            lassoOverlay?.isHidden = false
        }
    }

    // MARK: - Undo / Redo

    @objc private func handleUndo() {
        canvasView?.undoManager?.undo()
    }

    @objc private func handleRedo() {
        canvasView?.undoManager?.redo()
    }

    // MARK: - Dot Grid Background

    private static func dotGridPattern(dark: Bool = false) -> UIImage {
        let spacing: CGFloat = 20
        let dotRadius: CGFloat = 1.2
        let size = CGSize(width: spacing, height: spacing)
        let bgColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)  // #1C1C1E
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        let dotColor = dark
            ? UIColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)
            : UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
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

    // MARK: - Dark Mode

    func applyColorScheme(dark: Bool) {
        guard let container = containerView, let canvas = canvasView else { return }

        // Fundo do canvas
        container.backgroundColor = UIColor(patternImage: Self.dotGridPattern(dark: dark))

        // ScrollView background
        scrollView?.backgroundColor = dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)

        let textColor: UIColor = dark ? .white : .black

        // Atualizar textos e elementos
        for sibling in container.subviews {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
            if connectionPoints.contains(sibling) { continue }

            // Textos livres (sem background)
            if let tv = sibling as? UITextView {
                tv.textColor = (tv.tag == 999) ? textColor.withAlphaComponent(0.35) : textColor
                tv.tintColor = textColor
                continue
            }

            // Post-its e blocos (têm subview UITextView)
            if let bg = sibling.backgroundColor, bg != .clear {
                // Bloco de resumo (branco/escuro)
                let isPostIt = PostItColor.allCases.contains(where: { $0.uiColor == bg })
                if !isPostIt {
                    sibling.backgroundColor = dark ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0) : .systemBackground
                    sibling.layer.borderColor = dark ? UIColor(white: 0.3, alpha: 1).cgColor : UIColor.separator.cgColor
                }
            }

            // Textos dentro de subviews
            let isPostIt = PostItColor.allCases.contains(where: { $0.uiColor == sibling.backgroundColor })
            for sub in sibling.subviews {
                if let tv = sub as? UITextView {
                    let color: UIColor = isPostIt ? .black : textColor
                    tv.textColor = (tv.tag == 999) ? color.withAlphaComponent(0.35) : color
                    tv.tintColor = color
                } else if let label = sub as? UILabel {
                    label.textColor = textColor
                }
            }
        }

        // Atualizar cor das setas
        let arrowColor = dark ? UIColor.white.cgColor : UIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0).cgColor
        for conn in connections {
            conn.layer.strokeColor = arrowColor
        }

        // Atualizar cor da caneta
        canvas.tool = PKInkingTool(.pen, color: textColor, width: 5)
    }

    // MARK: - ScrollView Delegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        // Só o scroll view principal faz zoom — UITextViews e PKCanvasView retornam nil
        if scrollView === self.scrollView {
            return containerView
        }
        return nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
    }

    // MARK: - Shared Gestures

    private func addDragGestures(to view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleElementTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(tap)

    }

    // MARK: - Highlight Scribble

    private static let highlightLayerName = "scribbleHighlight"

    private static let highlightColors: [UIColor] = [
        UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.8),
        UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 0.8),
        UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.8),
        UIColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.8),
        UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 0.8),
        UIColor(red: 0.9, green: 0.3, blue: 0.6, alpha: 0.8),
        UIColor(red: 0.1, green: 0.7, blue: 0.8, alpha: 0.8),
    ]

    static let highlightColorNames: [UIColor: String] = {
        var map: [UIColor: String] = [:]
        let names = ["red", "blue", "green", "purple", "orange", "pink", "cyan"]
        for (i, color) in highlightColors.enumerated() {
            map[color] = names[i]
        }
        return map
    }()

    static let highlightColorFromName: [String: UIColor] = {
        var map: [String: UIColor] = [:]
        let names = ["red", "blue", "green", "purple", "orange", "pink", "cyan"]
        for (i, name) in names.enumerated() {
            map[name] = highlightColors[i]
        }
        return map
    }()

    @objc private func highlightButtonTapped() {
        guard let view = deleteTargetView else { return }
        toggleHighlight(on: view)
    }

    func toggleHighlightOnSelected() {
        if let view = deleteTargetView {
            toggleHighlight(on: view)
        }
    }

    private func toggleHighlight(on view: UIView) {
        // Remove existing highlight
        if let existing = view.layer.sublayers?.first(where: { $0.name == Self.highlightLayerName }) {
            existing.removeFromSuperlayer()
            return
        }
        // Add new highlight with random color
        let color = Self.highlightColors.randomElement()!
        addScribbleHighlight(to: view, color: color)
    }

    private enum ScribbleStyle: CaseIterable {
        case oval, roundedRect, zigzag, cloud, spiral
    }

    func addScribbleHighlight(to view: UIView, color: UIColor) {
        addScribbleHighlight(to: view, color: color, style: nil)
    }

    private func addScribbleHighlight(to view: UIView, color: UIColor, style forceStyle: ScribbleStyle?) {
        let bounds = view.bounds
        let inset: CGFloat = -8
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let style = forceStyle ?? ScribbleStyle.allCases.randomElement()!

        let path = UIBezierPath()

        switch style {
        case .oval:
            drawOvalScribble(path: path, in: rect)
        case .roundedRect:
            drawRoundedRectScribble(path: path, in: rect)
        case .zigzag:
            drawZigzagScribble(path: path, in: rect)
        case .cloud:
            drawCloudScribble(path: path, in: rect)
        case .spiral:
            drawSpiralScribble(path: path, in: rect)
        }

        let layer = CAShapeLayer()
        layer.name = Self.highlightLayerName
        layer.path = path.cgPath
        layer.strokeColor = color.cgColor
        layer.fillColor = nil
        layer.lineWidth = 2.5
        layer.lineCap = .round
        layer.lineJoin = .round
        view.layer.addSublayer(layer)
    }

    // Estilo 1: Oval clássico (2 passadas)
    private func drawOvalScribble(path: UIBezierPath, in rect: CGRect) {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let steps = 60
        for pass in 0..<2 {
            let offset = CGFloat(pass) * 1.5
            for i in 0...steps {
                let angle = CGFloat(i) / CGFloat(steps) * .pi * 2
                let nx = CGFloat.random(in: -3...3)
                let ny = CGFloat.random(in: -3...3)
                let px = cx + (rx + nx + offset) * cos(angle)
                let py = cy + (ry + ny + offset) * sin(angle)
                if i == 0 && pass == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else { path.addLine(to: CGPoint(x: px, y: py)) }
            }
        }
    }

    // Estilo 2: Retângulo arredondado rabiscado
    private func drawRoundedRectScribble(path: UIBezierPath, in rect: CGRect) {
        let cornerRadius: CGFloat = min(rect.width, rect.height) * 0.2
        let corners = [
            CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            CGPoint(x: rect.maxX - cornerRadius, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
            CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            CGPoint(x: rect.minX + cornerRadius, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            CGPoint(x: rect.minX, y: rect.minY + cornerRadius)
        ]
        for pass in 0..<2 {
            let off = CGFloat(pass) * 2
            for (i, corner) in corners.enumerated() {
                let next = corners[(i + 1) % corners.count]
                let steps = 12
                for s in 0...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let px = corner.x + (next.x - corner.x) * t + CGFloat.random(in: -3...3) + off
                    let py = corner.y + (next.y - corner.y) * t + CGFloat.random(in: -3...3) + off
                    if i == 0 && s == 0 && pass == 0 { path.move(to: CGPoint(x: px, y: py)) }
                    else { path.addLine(to: CGPoint(x: px, y: py)) }
                }
            }
        }
    }

    // Estilo 3: Zigzag circular (dentes em volta)
    private func drawZigzagScribble(path: UIBezierPath, in rect: CGRect) {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let steps = 40
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * .pi * 2
            let spike = (i % 2 == 0) ? CGFloat.random(in: 6...12) : CGFloat.random(in: -4...0)
            let px = cx + (rx + spike) * cos(angle) + CGFloat.random(in: -2...2)
            let py = cy + (ry + spike) * sin(angle) + CGFloat.random(in: -2...2)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
    }

    // Estilo 4: Nuvem (bolhinhas em volta)
    private func drawCloudScribble(path: UIBezierPath, in rect: CGRect) {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let bumps = 16
        for pass in 0..<2 {
            let off = CGFloat(pass) * 2
            for i in 0...bumps {
                let angle = CGFloat(i) / CGFloat(bumps) * .pi * 2
                let bumpSize = CGFloat.random(in: 6...14)
                let midAngle = (CGFloat(i) + 0.5) / CGFloat(bumps) * .pi * 2
                let basePx = cx + (rx + off) * cos(angle)
                let basePy = cy + (ry + off) * sin(angle)
                let bumpPx = cx + (rx + bumpSize + off) * cos(midAngle) + CGFloat.random(in: -2...2)
                let bumpPy = cy + (ry + bumpSize + off) * sin(midAngle) + CGFloat.random(in: -2...2)
                if i == 0 && pass == 0 {
                    path.move(to: CGPoint(x: basePx, y: basePy))
                }
                path.addQuadCurve(to: CGPoint(x: basePx, y: basePy),
                                  controlPoint: CGPoint(x: bumpPx, y: bumpPy))
            }
        }
    }

    // Estilo 5: Espiral (circula 1.5 voltas)
    private func drawSpiralScribble(path: UIBezierPath, in rect: CGRect) {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let totalSteps = 90
        let totalAngle: CGFloat = .pi * 3 // 1.5 voltas
        for i in 0...totalSteps {
            let t = CGFloat(i) / CGFloat(totalSteps)
            let angle = t * totalAngle
            let grow = 1.0 + t * 0.15 // espiral cresce levemente
            let nx = CGFloat.random(in: -2.5...2.5)
            let ny = CGFloat.random(in: -2.5...2.5)
            let px = cx + (rx * grow + nx) * cos(angle)
            let py = cy + (ry * grow + ny) * sin(angle)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
    }

    /// Returns the highlight color name for a view, or nil if no highlight
    func highlightColorName(for view: UIView) -> String? {
        guard let layer = view.layer.sublayers?.first(where: { $0.name == Self.highlightLayerName }) as? CAShapeLayer,
              let cgColor = layer.strokeColor else { return nil }
        let uiColor = UIColor(cgColor: cgColor)
        return Self.highlightColorNames[uiColor]
    }

    /// Traz elemento pra frente (abaixo do canvas) e ativa textView se tiver
    @objc private func handleElementTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        bringElementToFront(view)
        activateTextEditing(in: view)
        showDeleteButton(for: view)
        showConnectionPoints(for: view)
    }

    private func bringElementToFront(_ view: UIView) {
        guard let container = containerView, let canvas = canvasView else { return }
        container.insertSubview(view, belowSubview: canvas)
    }

    private func activateTextEditing(in view: UIView) {
        // Se a view é um UITextView (texto avulso)
        if let tv = view as? UITextView {
            tv.becomeFirstResponder()
            return
        }
        // Se a view contém um UITextView (post-it)
        for sub in view.subviews {
            if let tv = sub as? UITextView {
                tv.becomeFirstResponder()
                return
            }
        }
    }

    // MARK: - Delete Button

    private func showDeleteButton(for view: UIView) {
        // Se já tem um delete button pro mesmo elemento, não recriar
        if deleteTargetView === view && activeDeleteButton != nil { return }
        hideDeleteButton()

        guard let container = containerView else { return }

        deleteTargetView = view

        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let size: CGFloat = 36

        // --- Botão Lixeira (canto superior direito) ---
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "trash.fill", withConfiguration: config), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.systemRed
        btn.layer.cornerRadius = 18
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.3
        btn.layer.shadowRadius = 4
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.frame = CGRect(
            x: view.frame.maxX - size / 2 + 8,
            y: view.frame.minY - size / 2 + 8,
            width: size, height: size
        )
        btn.addTarget(self, action: #selector(deleteElementTapped), for: .touchUpInside)
        container.addSubview(btn)
        activeDeleteButton = btn

        // --- Botão Highlight (à esquerda da lixeira) ---
        let hlBtn = UIButton(type: .system)
        hlBtn.setImage(UIImage(systemName: "lasso", withConfiguration: config), for: .normal)
        hlBtn.tintColor = .white
        hlBtn.backgroundColor = UIColor.systemOrange
        hlBtn.layer.cornerRadius = 18
        hlBtn.layer.shadowColor = UIColor.black.cgColor
        hlBtn.layer.shadowOpacity = 0.3
        hlBtn.layer.shadowRadius = 4
        hlBtn.layer.shadowOffset = CGSize(width: 0, height: 2)
        hlBtn.frame = CGRect(
            x: view.frame.maxX - size / 2 + 8 - size - 8,
            y: view.frame.minY - size / 2 + 8,
            width: size, height: size
        )
        hlBtn.addTarget(self, action: #selector(highlightButtonTapped), for: .touchUpInside)
        container.addSubview(hlBtn)
        activeHighlightButton = hlBtn

        // Animação de entrada (ambos)
        for b in [btn, hlBtn] {
            b.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            b.alpha = 0
        }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
            btn.transform = .identity
            btn.alpha = 1
            hlBtn.transform = .identity
            hlBtn.alpha = 1
        }
    }

    private func hideDeleteButton() {
        for btn in [activeDeleteButton, activeHighlightButton].compactMap({ $0 }) {
            UIView.animate(withDuration: 0.15, animations: {
                btn.alpha = 0
                btn.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            }) { _ in
                btn.removeFromSuperview()
            }
        }
        activeDeleteButton = nil
        activeHighlightButton = nil
        deleteTargetView = nil
    }

    @objc private func deleteElementTapped() {
        guard let view = deleteTargetView else { return }

        // Remover conexões do elemento
        removeConnections(for: view)

        // Remover do dicionário allElementViews
        if let key = allElementViews.first(where: { $0.value === view })?.key {
            allElementViews.removeValue(forKey: key)
            imageViews.removeValue(forKey: key)
        }

        // Animação de saída
        hideDeleteButton()
        hideConnectionPoints()
        UIView.animate(withDuration: 0.25, animations: {
            view.alpha = 0
            view.transform = view.transform.scaledBy(x: 0.3, y: 0.3)
        }) { _ in
            view.removeFromSuperview()
        }
    }

    // MARK: - Connection Points & Arrows

    private func showConnectionPoints(for view: UIView) {
        hideConnectionPoints()
        guard let container = containerView else { return }

        let frame = view.frame
        let pointSize: CGFloat = 20
        let touchSize: CGFloat = 44

        // 4 pontos: topo, base, esquerda, direita
        let positions = [
            CGPoint(x: frame.midX, y: frame.minY),  // top
            CGPoint(x: frame.midX, y: frame.maxY),  // bottom
            CGPoint(x: frame.minX, y: frame.midY),  // left
            CGPoint(x: frame.maxX, y: frame.midY),  // right
        ]

        for pos in positions {
            let point = UIView()
            point.frame = CGRect(x: pos.x - touchSize / 2, y: pos.y - touchSize / 2,
                                 width: touchSize, height: touchSize)
            point.backgroundColor = .clear
            point.isUserInteractionEnabled = true

            // Bolinha visual
            let dot = UIView()
            dot.frame = CGRect(x: (touchSize - pointSize) / 2, y: (touchSize - pointSize) / 2,
                               width: pointSize, height: pointSize)
            dot.backgroundColor = .systemBlue
            dot.layer.cornerRadius = pointSize / 2
            dot.layer.borderColor = UIColor.white.cgColor
            dot.layer.borderWidth = 2
            dot.layer.shadowColor = UIColor.black.cgColor
            dot.layer.shadowOpacity = 0.2
            dot.layer.shadowRadius = 2
            dot.layer.shadowOffset = CGSize(width: 0, height: 1)
            dot.isUserInteractionEnabled = false
            point.addSubview(dot)

            // Pan gesture para arrastar seta
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleConnectionDrag(_:)))
            point.addGestureRecognizer(pan)

            container.addSubview(point)
            connectionPoints.append(point)
        }

        connectionSourceView = view

        // Animar entrada
        for p in connectionPoints {
            p.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            p.alpha = 0
        }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) { [weak self] in
            for p in self?.connectionPoints ?? [] {
                p.transform = .identity
                p.alpha = 1
            }
        }
    }

    private func hideConnectionPoints() {
        for point in connectionPoints {
            point.removeFromSuperview()
        }
        connectionPoints.removeAll()
        connectionSourceView = nil
        connectionPreviewLayer?.removeFromSuperlayer()
        connectionPreviewLayer = nil
    }

    @objc private func handleConnectionDrag(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView, let sourceView = connectionSourceView else { return }

        let point = gesture.location(in: container)

        switch gesture.state {
        case .began:
            // Criar preview layer
            let layer = CAShapeLayer()
            layer.strokeColor = UIColor.darkGray.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2.5
            layer.lineCap = .round
            container.layer.addSublayer(layer)
            connectionPreviewLayer = layer

        case .changed:
            // Atualizar preview — seta do centro do source até o dedo
            let from = sourceView.center
            updateArrowPath(connectionPreviewLayer, from: from, to: point)

            // Highlight do destino potencial
            if let target = findElement(at: point), target !== sourceView {
                target.layer.borderColor = UIColor.systemBlue.cgColor
                target.layer.borderWidth = 2.5
            }

        case .ended:
            connectionPreviewLayer?.removeFromSuperlayer()
            connectionPreviewLayer = nil

            // Checar se soltou em cima de um elemento
            if let target = findElement(at: point), target !== sourceView {
                // Limpar highlight
                target.layer.borderColor = nil
                target.layer.borderWidth = 0
                // Criar conexão
                createConnection(from: sourceView, to: target)
            }

            hideConnectionPoints()

        case .cancelled, .failed:
            connectionPreviewLayer?.removeFromSuperlayer()
            connectionPreviewLayer = nil
            hideConnectionPoints()

        default: break
        }
    }

    private func createConnection(from: UIView, to: UIView) {
        guard let container = containerView else { return }

        // Checar se já existe essa conexão
        if connections.contains(where: { $0.from === from && $0.to === to }) { return }

        let layer = CAShapeLayer()
        layer.strokeColor = currentArrowColor
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 2.5
        layer.lineCap = .round

        // Inserir abaixo de todos os subviews (atrás dos elementos)
        container.layer.insertSublayer(layer, at: 0)
        connections.append((from: from, to: to, layer: layer))
        updateConnectionArrow(from: from, to: to, layer: layer)
    }

    private func updateConnectionArrow(from: UIView, to: UIView, layer: CAShapeLayer) {
        // Encontrar os pontos de borda mais próximos entre os dois elementos
        let (fromPoint, toPoint) = closestEdgePoints(from: from, to: to)
        updateArrowPath(layer, from: fromPoint, to: toPoint)
    }

    private func closestEdgePoints(from: UIView, to: UIView) -> (CGPoint, CGPoint) {
        let fromCenter = CGPoint(x: from.frame.midX, y: from.frame.midY)
        let toCenter = CGPoint(x: to.frame.midX, y: to.frame.midY)

        // Seta vai do centro ao centro, cortada na borda de cada elemento
        let fromEdge = edgeIntersection(rect: from.frame, center: fromCenter, target: toCenter)
        let toEdge = edgeIntersection(rect: to.frame, center: toCenter, target: fromCenter)

        // Recuar a ponta da seta para não encostar no elemento (gap de 14pt)
        let dx = toEdge.x - fromEdge.x
        let dy = toEdge.y - fromEdge.y
        let dist = sqrt(dx * dx + dy * dy)
        let gap: CGFloat = 14
        let adjustedTo: CGPoint
        if dist > gap * 2 {
            adjustedTo = CGPoint(x: toEdge.x - (dx / dist) * gap, y: toEdge.y - (dy / dist) * gap)
        } else {
            adjustedTo = toEdge
        }

        return (fromEdge, adjustedTo)
    }

    /// Encontra onde a linha center→target cruza a borda do rect
    private func edgeIntersection(rect: CGRect, center: CGPoint, target: CGPoint) -> CGPoint {
        let dx = target.x - center.x
        let dy = target.y - center.y

        // Se ambos são zero, retorna o centro
        guard dx != 0 || dy != 0 else { return center }

        let halfW = rect.width / 2
        let halfH = rect.height / 2

        // Escala necessária para atingir cada borda
        var t: CGFloat = .greatestFiniteMagnitude

        if dx != 0 {
            let tx = halfW / abs(dx)
            t = min(t, tx)
        }
        if dy != 0 {
            let ty = halfH / abs(dy)
            t = min(t, ty)
        }

        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    private func updateArrowPath(_ layer: CAShapeLayer?, from: CGPoint, to: CGPoint) {
        guard let layer = layer else { return }

        let path = UIBezierPath()
        path.move(to: from)

        // Bezier suave entre os pontos
        let dx = to.x - from.x
        let dy = to.y - from.y

        // Control points baseados na direção dominante
        let cp1: CGPoint
        let cp2: CGPoint
        if abs(dy) > abs(dx) {
            cp1 = CGPoint(x: from.x, y: from.y + dy * 0.4)
            cp2 = CGPoint(x: to.x, y: to.y - dy * 0.4)
        } else {
            cp1 = CGPoint(x: from.x + dx * 0.4, y: from.y)
            cp2 = CGPoint(x: to.x - dx * 0.4, y: to.y)
        }
        path.addCurve(to: to, controlPoint1: cp1, controlPoint2: cp2)

        // Ponta da seta — ângulo baseado na tangente da curva no ponto final
        let arrowSize: CGFloat = 12
        let angle = atan2(to.y - cp2.y, to.x - cp2.x)
        let arrowPoint1 = CGPoint(
            x: to.x - arrowSize * cos(angle - .pi / 6),
            y: to.y - arrowSize * sin(angle - .pi / 6)
        )
        let arrowPoint2 = CGPoint(
            x: to.x - arrowSize * cos(angle + .pi / 6),
            y: to.y - arrowSize * sin(angle + .pi / 6)
        )

        path.move(to: arrowPoint1)
        path.addLine(to: to)
        path.addLine(to: arrowPoint2)

        // Desativar animação implícita para seta acompanhar o dedo instantaneamente
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path.cgPath
        CATransaction.commit()
    }

    func updateAllConnections() {
        for conn in connections {
            updateConnectionArrow(from: conn.from, to: conn.to, layer: conn.layer)
        }
    }

    private func removeConnections(for view: UIView) {
        connections.removeAll { conn in
            if conn.from === view || conn.to === view {
                conn.layer.removeFromSuperlayer()
                return true
            }
            return false
        }
    }

    // Tocar numa seta pra deletar
    func handleTapOnConnection(at point: CGPoint) -> Bool {
        for (i, conn) in connections.enumerated().reversed() {
            guard let path = conn.layer.path else { continue }
            // Criar path mais gordo pra facilitar o toque
            let strokedPath = path.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 0)
            if strokedPath.contains(point) {
                // Animar remoção
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                conn.layer.opacity = 0
                CATransaction.setCompletionBlock {
                    conn.layer.removeFromSuperlayer()
                }
                CATransaction.commit()
                connections.remove(at: i)
                return true
            }
        }
        return false
    }

    // MARK: - Finger → Element Proxy (canvas recebe, elemento reage)

    /// Encontra o elemento abaixo do canvas no ponto dado (coordenadas do container)
    private func findElement(at pointInContainer: CGPoint) -> UIView? {
        guard let container = containerView, let canvas = canvasView else { return nil }
        for sibling in container.subviews.reversed() {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
            if sibling === activeDeleteButton { continue }
            if connectionPoints.contains(sibling) { continue }
            if sibling.frame.contains(pointInContainer) {
                return sibling
            }
        }
        return nil
    }

    /// Checa se a view é o selection box ou subview dele
    func isSelectionBoxView(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let current = v {
            if current === selectionBox { return true }
            v = current.superview
        }
        return false
    }

    @objc private func handleFingerTap(_ gesture: UITapGestureRecognizer) {
        guard let container = containerView else { return }
        let point = gesture.location(in: container)

        if let element = findElement(at: point) {
            bringElementToFront(element)
            activateTextEditing(in: element)
            showDeleteButton(for: element)
            showConnectionPoints(for: element)
        } else {
            // Checar se tocou numa seta
            if handleTapOnConnection(at: point) { return }
            // Tap em área vazia — deselecionar tudo
            if !selectedViews.isEmpty { clearSelection() }
            hideDeleteButton()
            hideConnectionPoints()
            // Resign text editing
            resignAllTextViews()
        }
    }

    @objc private func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView else { return }

        switch gesture.state {
        case .began:
            hideDeleteButton()
            hideConnectionPoints()
            let point = gesture.location(in: container)
            activeDragElement = findElement(at: point)
            if let el = activeDragElement {
                bringElementToFront(el)
                el.layer.shadowColor = UIColor.systemBlue.cgColor
                el.layer.shadowOpacity = 0.5
                el.layer.shadowRadius = 8
                el.layer.shadowOffset = .zero
            }
        case .changed:
            if let el = activeDragElement {
                let t = gesture.translation(in: container)
                el.center = CGPoint(x: el.center.x + t.x, y: el.center.y + t.y)
                gesture.setTranslation(.zero, in: container)
                updateAllConnections()
            }
        case .ended, .cancelled:
            activeDragElement?.layer.shadowOpacity = 0
            activeDragElement = nil
        default: break
        }
    }

    @objc private func handleLongPressLasso(_ gesture: UILongPressGestureRecognizer) {
        guard let container = containerView else { return }

        switch gesture.state {
        case .began:
            let point = gesture.location(in: container)
            clearSelection()
            inlineLassoPath = UIBezierPath()
            inlineLassoPath?.move(to: point)

            let layer = CAShapeLayer()
            layer.strokeColor = UIColor.systemBlue.cgColor
            layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
            layer.lineWidth = 2.5
            layer.lineDashPattern = [8, 5]
            container.layer.addSublayer(layer)
            inlineLassoLayer = layer

        case .changed:
            let point = gesture.location(in: container)
            inlineLassoPath?.addLine(to: point)
            inlineLassoLayer?.path = inlineLassoPath?.cgPath

        case .ended:
            inlineLassoPath?.close()
            inlineLassoLayer?.path = inlineLassoPath?.cgPath

            if let path = inlineLassoPath {
                finishLasso(path: path)
            }

            // Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.inlineLassoLayer?.removeFromSuperlayer()
                self?.inlineLassoLayer = nil
                self?.inlineLassoPath = nil
            }

        case .cancelled, .failed:
            inlineLassoLayer?.removeFromSuperlayer()
            inlineLassoLayer = nil
            inlineLassoPath = nil

        default: break
        }
    }

    private func resignAllTextViews() {
        guard let container = containerView else { return }
        for view in container.subviews where view !== canvasView {
            if let tv = view as? UITextView { tv.resignFirstResponder() }
            for sub in view.subviews {
                if let tv = sub as? UITextView { tv.resignFirstResponder() }
            }
        }
    }

    // MARK: - Gesture Delegate

    private func isViewInsideSelectionBox(_ view: UIView?) -> Bool {
        var v = view
        while let current = v {
            if current === selectionBox { return true }
            v = current.superview
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Bloquear tap do container quando toca no selection box ou handles
        if gestureRecognizer === canvasTapGesture && isViewInsideSelectionBox(touch.view) {
            return false
        }
        // Bloquear move pan quando toca num handle (deixar resize pan agir)
        if gestureRecognizer === selectionMovePan,
           let v = touch.view, v !== selectionBox, v.superview === selectionBox {
            return false
        }
        return true
    }

    @objc private func handleBoxTapEat(_ gesture: UITapGestureRecognizer) {
        // Não faz nada — só existe pra impedir o tap do container de disparar
    }

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        // Fallback: checar por coordenada se delegate não bloqueou
        if let box = selectionBox, let container = containerView {
            let point = gesture.location(in: container)
            if box.frame.insetBy(dx: -40, dy: -40).contains(point) {
                return
            }
        }
    }

    // MARK: - Image

    func addImage(_ item: CanvasImageItem) {
        guard let container = containerView else { return }

        let imageView = UIImageView(image: item.image)
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = .scaleAspectFit

        let maxSide: CGFloat = 500
        let imgSize = item.image.size
        let scale = min(maxSide / imgSize.width, maxSide / imgSize.height, 1.0)
        let w = imgSize.width * scale
        let h = imgSize.height * scale
        imageView.frame = CGRect(x: item.position.x - w/2, y: item.position.y - h/2, width: w, height: h)
        imageView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        imageView.layer.borderWidth = 1.5
        imageView.layer.cornerRadius = 4

        addDragGestures(to: imageView)
        addElementToCanvas(imageView)
        imageViews[item.id] = imageView
        allElementViews[item.id] = imageView
    }

    // MARK: - Text (handwriting font)

    func addText(at position: CGPoint? = nil) {
        guard let container = containerView else { return }
        let pos = position ?? visibleCenter()

        let textView = NonZoomableTextView()

        textView.text = ""
        textView.font = handwritingFont
        textView.textColor = currentTextColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = CGRect(x: pos.x - 120, y: pos.y - 30, width: 240, height: 60)
        textView.layer.cornerRadius = 4
        textView.isUserInteractionEnabled = true
        textView.tintColor = currentTextColor
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]

        // Placeholder
        textView.text = "Toque para digitar"
        textView.textColor = currentTextColor.withAlphaComponent(0.35)
        textView.tag = 999
        textView.delegate = self

        addDragGestures(to: textView)
        addElementToCanvas(textView)

        let item = CanvasTextItem(text: "", position: pos)
        allElementViews[item.id] = textView

        // Ativar edição imediata
        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
    }

    // MARK: - Summary Block (YouTube)

    func addSummaryBlock(text: String) {
        guard let container = containerView else { return }
        let center = visibleCenter()
        // Posicionar bem à esquerda do centro (mapa mental ficará à direita)
        let pos = CGPoint(x: center.x - 900, y: center.y)

        let blockWidth: CGFloat = 400
        let headerHeight: CGFloat = 50 // título + separador
        let padding: CGFloat = 12

        // Calcular altura necessária para o texto
        let textWidth = blockWidth - (padding * 2)
        let tempTextView = UITextView()
        tempTextView.text = text
        tempTextView.font = .systemFont(ofSize: 14)
        let textSize = tempTextView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let textHeight = ceil(textSize.height) + 16 // margem extra
        let totalHeight = headerHeight + textHeight + padding

        let block = UIView()
        block.frame = CGRect(x: pos.x - blockWidth / 2, y: pos.y - totalHeight / 2, width: blockWidth, height: totalHeight)
        block.backgroundColor = UIColor.systemBackground
        block.layer.cornerRadius = 12
        block.layer.borderWidth = 1
        block.layer.borderColor = UIColor.separator.cgColor
        block.layer.shadowColor = UIColor.black.cgColor
        block.layer.shadowOpacity = 0.1
        block.layer.shadowRadius = 8
        block.layer.shadowOffset = CGSize(width: 0, height: 4)
        block.isUserInteractionEnabled = true

        // Ícone + título
        let headerLabel = UILabel()
        headerLabel.text = "  Resumo do Vídeo"
        headerLabel.font = .systemFont(ofSize: 16, weight: .bold)
        headerLabel.textColor = .label
        headerLabel.frame = CGRect(x: 16, y: 12, width: blockWidth - 32, height: 28)
        block.addSubview(headerLabel)

        // Separador
        let separator = UIView()
        separator.frame = CGRect(x: 16, y: 44, width: blockWidth - 32, height: 1)
        separator.backgroundColor = .separator
        block.addSubview(separator)

        // Texto do resumo
        let textView = NonZoomableTextView()

        textView.text = text
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.frame = CGRect(x: padding, y: headerHeight, width: textWidth, height: textHeight)
        textView.tintColor = currentTextColor
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]
        textView.tag = 0
        textView.delegate = self
        block.addSubview(textView)

        addDragGestures(to: block)
        addElementToCanvas(block)
        allElementViews[UUID()] = block

        // Animação de entrada
        block.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        block.alpha = 0
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            block.transform = .identity
            block.alpha = 1
        }
    }

    // MARK: - Post-it

    func addPostIt(color: PostItColor = .yellow, at position: CGPoint? = nil) {
        guard let container = containerView else { return }
        let pos = position ?? visibleCenter()

        let postIt = UIView()
        postIt.frame = CGRect(x: pos.x - 100, y: pos.y - 100, width: 200, height: 200)
        postIt.backgroundColor = color.uiColor
        postIt.layer.cornerRadius = 4
        postIt.layer.shadowColor = UIColor.black.cgColor
        postIt.layer.shadowOpacity = 0.15
        postIt.layer.shadowRadius = 4
        postIt.layer.shadowOffset = CGSize(width: 2, height: 2)
        postIt.isUserInteractionEnabled = true

        // Rotação leve aleatória pra parecer natural
        let randomAngle = CGFloat.random(in: -0.05...0.05)
        postIt.transform = CGAffineTransform(rotationAngle: randomAngle)

        // Texto dentro do post-it
        let textView = NonZoomableTextView()

        textView.text = ""
        textView.font = handwritingFont
        textView.textColor = postItTextColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = postIt.bounds.insetBy(dx: 12, dy: 12)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.tintColor = postItTextColor
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]

        // Placeholder
        textView.text = "Toque para digitar"
        textView.textColor = postItTextColor.withAlphaComponent(0.35)
        textView.tag = 999
        textView.delegate = self

        postIt.addSubview(textView)

        addDragGestures(to: postIt)
        addElementToCanvas(postIt)

        let item = CanvasPostItItem(text: "", position: pos, color: color)
        allElementViews[item.id] = postIt

        // Ativar edição imediata
        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
    }

    // MARK: - Brain Dump → Mind Map

    func createMindMap(from result: GeminiService.MindMapResult, layout: MindMapLayout = .radial) {
        guard let container = containerView else { return }

        let center = visibleCenter()
        let levelColors: [PostItColor] = [.blue, .yellow, .green, .purple, .pink]
        let levelSizes: [(w: CGFloat, h: CGFloat)] = [
            (240, 120), (180, 100), (150, 80)
        ]

        // Agrupar nós por nível
        var nodesByLevel: [[GeminiService.MindMapNode]] = [[], [], []]
        for node in result.nodes {
            nodesByLevel[min(node.level, 2)].append(node)
        }

        // Mapa pai→filhos via connections
        var parentOf: [Int: Int] = [:]
        var childrenOf: [Int: [GeminiService.MindMapNode]] = [:]
        for conn in result.connections {
            let fromNode = result.nodes.first { $0.id == conn.from }
            let toNode = result.nodes.first { $0.id == conn.to }
            if let from = fromNode, let to = toNode, to.level > from.level {
                parentOf[to.id] = from.id
                childrenOf[from.id, default: []].append(to)
            }
        }

        // Calcular posições baseado no layout
        var positions: [Int: CGPoint] = [:]

        switch layout {
        case .radial:
            layoutRadial(center: center, nodesByLevel: nodesByLevel, parentOf: parentOf, childrenOf: childrenOf, positions: &positions)
        case .tree:
            layoutTree(center: center, nodesByLevel: nodesByLevel, childrenOf: childrenOf, positions: &positions)
        case .flow:
            layoutFlow(center: center, nodesByLevel: nodesByLevel, childrenOf: childrenOf, positions: &positions)
        }

        // Criar post-its nas posições calculadas
        var nodeViews: [Int: UIView] = [:]
        for node in result.nodes {
            let lvl = min(node.level, 2)
            let size = levelSizes[lvl]
            let fontSize: CGFloat = [20, 16, 14][lvl]
            let pos = positions[node.id] ?? center

            let view = createPostItForMindMap(
                text: node.text,
                color: levelColors[lvl],
                position: pos,
                size: CGSize(width: size.w, height: size.h),
                fontSize: fontSize
            )
            nodeViews[node.id] = view
        }

        // Criar conexões (setas)
        for conn in result.connections {
            guard let fromView = nodeViews[conn.from],
                  let toView = nodeViews[conn.to] else { continue }
            createConnection(from: fromView, to: toView)
        }
    }

    // MARK: - Layout Radial (circular ao redor do centro)

    private func layoutRadial(
        center: CGPoint,
        nodesByLevel: [[GeminiService.MindMapNode]],
        parentOf: [Int: Int],
        childrenOf: [Int: [GeminiService.MindMapNode]],
        positions: inout [Int: CGPoint]
    ) {
        for node in nodesByLevel[0] {
            positions[node.id] = center
        }

        let level1 = nodesByLevel[1]
        let r1: CGFloat = 450
        for (i, node) in level1.enumerated() {
            let angle = (CGFloat(i) / CGFloat(max(level1.count, 1))) * 2 * .pi - .pi / 2
            positions[node.id] = CGPoint(x: center.x + r1 * cos(angle), y: center.y + r1 * sin(angle))
        }

        let r2: CGFloat = 280
        for node in nodesByLevel[2] {
            let pid = parentOf[node.id] ?? 0
            let parentPos = positions[pid] ?? center
            let parentAngle = atan2(parentPos.y - center.y, parentPos.x - center.x)
            let siblings = childrenOf[pid] ?? []
            let idx = siblings.firstIndex(where: { $0.id == node.id }) ?? 0
            let spread: CGFloat = 0.8
            let offset = CGFloat(idx) - CGFloat(siblings.count - 1) / 2
            let angle = parentAngle + offset * spread
            positions[node.id] = CGPoint(x: parentPos.x + r2 * cos(angle), y: parentPos.y + r2 * sin(angle))
        }
    }

    // MARK: - Layout Árvore (hierarquia vertical, de cima pra baixo)

    private func layoutTree(
        center: CGPoint,
        nodesByLevel: [[GeminiService.MindMapNode]],
        childrenOf: [Int: [GeminiService.MindMapNode]],
        positions: inout [Int: CGPoint]
    ) {
        let rowGap: CGFloat = 250

        // Level 0 — topo
        for node in nodesByLevel[0] {
            positions[node.id] = center
        }

        // Contar quantos filhos level 2 cada level 1 tem para calcular largura total
        let level1 = nodesByLevel[1]
        // Cada level 1 precisa de espaço para si + seus filhos level 2
        let childSpacing: CGFloat = 200
        var slotWidths: [CGFloat] = []
        for node in level1 {
            let children = childrenOf[node.id] ?? []
            let w = max(1, CGFloat(children.count)) * childSpacing
            slotWidths.append(w)
        }
        let totalWidth = slotWidths.reduce(0, +)

        // Posicionar level 1 com espaço proporcional
        var currentX = center.x - totalWidth / 2
        for (i, node) in level1.enumerated() {
            let slotCenter = currentX + slotWidths[i] / 2
            positions[node.id] = CGPoint(x: slotCenter, y: center.y + rowGap)
            currentX += slotWidths[i]
        }

        // Level 2 — distribuir abaixo de cada pai, centrados
        for node in nodesByLevel[2] {
            var parentId = 0
            for (pid, children) in childrenOf {
                if children.contains(where: { $0.id == node.id }) { parentId = pid; break }
            }
            let parentPos = positions[parentId] ?? center
            let siblings = childrenOf[parentId] ?? []
            let idx = siblings.firstIndex(where: { $0.id == node.id }) ?? 0
            let totalW = CGFloat(siblings.count - 1) * childSpacing
            let x = parentPos.x - totalW / 2 + CGFloat(idx) * childSpacing
            positions[node.id] = CGPoint(x: x, y: parentPos.y + rowGap)
        }
    }

    // MARK: - Layout Fluxo (horizontal, esquerda → direita)

    private func layoutFlow(
        center: CGPoint,
        nodesByLevel: [[GeminiService.MindMapNode]],
        childrenOf: [Int: [GeminiService.MindMapNode]],
        positions: inout [Int: CGPoint]
    ) {
        let colGap: CGFloat = 400
        let rowSpacing: CGFloat = 140

        // Contar total de linhas necessárias na coluna do meio (level 1)
        // e na coluna da direita (level 2 por pai)
        let level1 = nodesByLevel[1]

        // Cada level 1 precisa de espaço vertical para si + filhos
        var slotHeights: [CGFloat] = []
        for node in level1 {
            let children = childrenOf[node.id] ?? []
            let h = max(1, CGFloat(children.count)) * rowSpacing
            slotHeights.append(h)
        }
        let totalHeight = slotHeights.reduce(0, +)

        // Level 0 — esquerda
        for node in nodesByLevel[0] {
            positions[node.id] = CGPoint(x: center.x - colGap, y: center.y)
        }

        // Level 1 — coluna do meio, espaçados proporcionalmente
        var currentY = center.y - totalHeight / 2
        for (i, node) in level1.enumerated() {
            let slotCenter = currentY + slotHeights[i] / 2
            positions[node.id] = CGPoint(x: center.x, y: slotCenter)
            currentY += slotHeights[i]
        }

        // Level 2 — coluna da direita, alinhados ao pai
        for node in nodesByLevel[2] {
            var parentId = 0
            for (pid, children) in childrenOf {
                if children.contains(where: { $0.id == node.id }) { parentId = pid; break }
            }
            let parentPos = positions[parentId] ?? center
            let siblings = childrenOf[parentId] ?? []
            let idx = siblings.firstIndex(where: { $0.id == node.id }) ?? 0
            let totalH = CGFloat(siblings.count - 1) * rowSpacing
            let y = parentPos.y - totalH / 2 + CGFloat(idx) * rowSpacing
            positions[node.id] = CGPoint(x: center.x + colGap, y: y)
        }
    }

    private func createPostItForMindMap(
        text: String,
        color: PostItColor,
        position: CGPoint,
        size: CGSize,
        fontSize: CGFloat
    ) -> UIView {
        let postIt = UIView()
        postIt.frame = CGRect(
            x: position.x - size.width / 2,
            y: position.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        postIt.backgroundColor = color.uiColor
        postIt.layer.cornerRadius = 8
        postIt.layer.shadowColor = UIColor.black.cgColor
        postIt.layer.shadowOpacity = 0.15
        postIt.layer.shadowRadius = 4
        postIt.layer.shadowOffset = CGSize(width: 2, height: 2)
        postIt.isUserInteractionEnabled = true

        let textView = NonZoomableTextView()

        textView.text = text
        textView.font = UIFont(name: "MarkerFelt-Wide", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .medium)
        textView.textColor = postItTextColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = postIt.bounds.insetBy(dx: 10, dy: 8)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.tintColor = postItTextColor
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]
        textView.tag = 0
        textView.delegate = self

        postIt.addSubview(textView)

        addDragGestures(to: postIt)
        addElementToCanvas(postIt)
        allElementViews[UUID()] = postIt

        // Animação de entrada
        postIt.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        postIt.alpha = 0
        UIView.animate(withDuration: 0.4, delay: Double.random(in: 0...0.3), usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
            postIt.transform = .identity
            postIt.alpha = 1
        }

        return postIt
    }

    // MARK: - Audio Recording

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
            return
        }

        let filename = "audio_\(UUID().uuidString.prefix(8)).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            recordingStartTime = Date()
            Task { @MainActor in
                state.isRecording = true
            }
            // Timer para ler nível do mic
            meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0) // -160 a 0
                let normalized = max(0, (power + 50) / 50) // normaliza -50..0 → 0..1
                Task { @MainActor in
                    self.state.audioLevel = CGFloat(normalized)
                }
            }
        } catch {
            print("Recording error: \(error)")
        }
    }

    func stopRecording() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let url = recorder.url
        recorder.stop()
        audioRecorder = nil
        meteringTimer?.invalidate()
        meteringTimer = nil

        Task { @MainActor in
            state.isRecording = false
            state.audioLevel = 0
        }

        addAudioPlayer(url: url, duration: duration)
    }

    private func addAudioPlayer(url: URL, duration: TimeInterval, at position: CGPoint? = nil) {
        guard let container = containerView else { return }
        let pos = position ?? visibleCenter()

        let item = CanvasAudioItem(fileURL: url, position: pos, duration: duration)

        // Player widget
        let playerView = UIView()
        playerView.frame = CGRect(x: pos.x - 120, y: pos.y - 30, width: 240, height: 60)
        playerView.backgroundColor = UIColor.systemGray6
        playerView.layer.cornerRadius = 12
        playerView.layer.borderColor = UIColor.systemGray4.cgColor
        playerView.layer.borderWidth = 1
        playerView.isUserInteractionEnabled = true

        // Ícone de play
        let playButton = UIButton(type: .system)
        playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        playButton.tintColor = .systemBlue
        playButton.frame = CGRect(x: 8, y: 10, width: 40, height: 40)
        playButton.contentHorizontalAlignment = .fill
        playButton.contentVerticalAlignment = .fill
        playButton.addTarget(self, action: #selector(playAudioTapped(_:)), for: .touchUpInside)
        objc_setAssociatedObject(playButton, &Self.audioURLKey, url, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(playButton, &Self.audioIDKey, item.id, .OBJC_ASSOCIATION_RETAIN)
        playerView.addSubview(playButton)

        // Waveform fake (visual)
        let waveLabel = UILabel()
        waveLabel.text = "~~~~~~~~~~"
        waveLabel.font = .systemFont(ofSize: 16, weight: .light)
        waveLabel.textColor = .systemGray2
        waveLabel.frame = CGRect(x: 56, y: 10, width: 120, height: 40)
        playerView.addSubview(waveLabel)

        // Duração
        let durationLabel = UILabel()
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        durationLabel.text = String(format: "%d:%02d", mins, secs)
        durationLabel.font = .systemFont(ofSize: 13, weight: .medium)
        durationLabel.textColor = .secondaryLabel
        durationLabel.textAlignment = .right
        durationLabel.frame = CGRect(x: 180, y: 10, width: 50, height: 40)
        playerView.addSubview(durationLabel)

        addDragGestures(to: playerView)
        addElementToCanvas(playerView)
        allElementViews[item.id] = playerView
    }

    @objc private func playAudioTapped(_ sender: UIButton) {
        guard let url = objc_getAssociatedObject(sender, &Self.audioURLKey) as? URL,
              let id = objc_getAssociatedObject(sender, &Self.audioIDKey) as? UUID else { return }

        // Se já tocando, para
        if let player = audioPlayers[id], player.isPlaying {
            player.stop()
            sender.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
            audioPlayers.removeValue(forKey: id)
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayers[id] = player
            sender.setImage(UIImage(systemName: "stop.circle.fill"), for: .normal)

            // Voltar ícone quando terminar
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) { [weak self] in
                sender.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
                self?.audioPlayers.removeValue(forKey: id)
            }
        } catch {
            print("Playback error: \(error)")
        }
    }

    // MARK: - Drop Delegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: UIImage.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let container = containerView else { return }
        let location = session.location(in: container)

        session.loadObjects(ofClass: UIImage.self) { [weak self] items in
            guard let self = self, let image = items.first as? UIImage else { return }
            Task { @MainActor in
                let item = CanvasImageItem(image: image, position: location)
                self.state.images.append(item)
                self.addImage(item)
            }
        }
    }

    // MARK: - Overlay Result

    func overlayResult(_ resultImage: UIImage) {
        guard let canvasView = canvasView else { return }

        let drawing = canvasView.drawing
        var bounds = drawing.bounds

        for (_, view) in imageViews {
            bounds = bounds.union(view.frame)
        }

        if bounds.isEmpty {
            guard let scroll = scrollView else { return }
            let visibleRect = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            let zoomScale = scroll.zoomScale
            bounds = CGRect(
                x: visibleRect.origin.x / zoomScale + 100,
                y: visibleRect.origin.y / zoomScale + 100,
                width: visibleRect.width / zoomScale - 200,
                height: visibleRect.height / zoomScale - 200
            )
        }

        let padded = bounds.insetBy(dx: -20, dy: -20)
        let item = CanvasImageItem(image: resultImage, position: CGPoint(x: padded.midX, y: padded.midY))

        let imageView = UIImageView(image: resultImage)
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = .scaleAspectFit
        imageView.frame = padded
        imageView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        imageView.layer.borderWidth = 1.5
        imageView.layer.cornerRadius = 4

        addDragGestures(to: imageView)
        addElementToCanvas(imageView)
        imageViews[item.id] = imageView
        allElementViews[item.id] = imageView
        state.images.append(item)

        canvasView.drawing = PKDrawing()
    }

    // MARK: - Review Texts (IA corrige todos os textos)

    func collectAllTexts() -> [GeminiService.TextElement] {
        guard let container = containerView else { return [] }
        var elements: [GeminiService.TextElement] = []
        var index = 0

        for sibling in container.subviews {
            if sibling === canvasView || sibling === lassoOverlay || sibling === selectionBox { continue }

            // Texto avulso (UITextView direto)
            if let tv = sibling as? UITextView {
                let text = tv.text ?? ""
                if !text.isEmpty && tv.tag != Self.placeholderTag {
                    elements.append(GeminiService.TextElement(index: index, text: text, type: "text"))
                    index += 1
                }
                continue
            }

            // Post-it (UIView com UITextView dentro)
            for sub in sibling.subviews {
                if let tv = sub as? UITextView {
                    let text = tv.text ?? ""
                    if !text.isEmpty && tv.tag != Self.placeholderTag {
                        elements.append(GeminiService.TextElement(index: index, text: text, type: "postit"))
                        index += 1
                    }
                }
            }
        }

        return elements
    }

    func applyReviewedTexts(_ reviewed: [GeminiService.ReviewedText]) {
        guard let container = containerView else { return }
        var index = 0

        // Mapear index → texto corrigido
        var corrections: [Int: String] = [:]
        for r in reviewed {
            corrections[r.index] = r.text
        }

        for sibling in container.subviews {
            if sibling === canvasView || sibling === lassoOverlay || sibling === selectionBox { continue }

            if let tv = sibling as? UITextView {
                let text = tv.text ?? ""
                if !text.isEmpty && tv.tag != Self.placeholderTag {
                    if let corrected = corrections[index] {
                        tv.text = corrected
                        tv.textColor = currentTextColor
                        // Flash verde pra indicar que foi corrigido
                        flashGreen(tv)
                    }
                    index += 1
                }
                continue
            }

            for sub in sibling.subviews {
                if let tv = sub as? UITextView {
                    let text = tv.text ?? ""
                    if !text.isEmpty && tv.tag != Self.placeholderTag {
                        if let corrected = corrections[index] {
                            tv.text = corrected
                            tv.textColor = postItTextColor
                            flashGreen(sibling)
                        }
                        index += 1
                    }
                }
            }
        }
    }

    private func flashGreen(_ view: UIView) {
        let original = view.backgroundColor
        UIView.animate(withDuration: 0.3) {
            view.layer.borderColor = UIColor.systemGreen.cgColor
            view.layer.borderWidth = 3
        } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 0.8) {
                view.layer.borderColor = nil
                view.layer.borderWidth = 0
                view.backgroundColor = original
            }
        }
    }

    // MARK: - Capture Canvas

    func captureCanvas() -> UIImage? {
        guard let canvasView = canvasView, let container = containerView else { return nil }

        let drawing = canvasView.drawing
        var bounds = drawing.bounds

        // Incluir TODOS os elementos (imagens, post-its, textos, áudio, stroke groups)
        for (_, view) in allElementViews {
            bounds = bounds.union(view.frame)
        }

        guard !bounds.isEmpty else { return nil }

        let paddedBounds = bounds.insetBy(dx: -50, dy: -50)

        let renderer = UIGraphicsImageRenderer(size: paddedBounds.size)
        return renderer.image { ctx in
            let context = ctx.cgContext

            // Transladar pra que paddedBounds.origin vire (0,0)
            context.translateBy(x: -paddedBounds.origin.x, y: -paddedBounds.origin.y)

            // Fundo branco
            UIColor.white.setFill()
            context.fill(CGRect(origin: paddedBounds.origin, size: paddedBounds.size))

            // Renderizar setas de conexão (CAShapeLayers no container.layer)
            for conn in connections {
                context.saveGState()
                if let path = conn.layer.path {
                    context.addPath(path)
                    if let strokeColor = conn.layer.strokeColor {
                        context.setStrokeColor(strokeColor)
                    }
                    context.setLineWidth(conn.layer.lineWidth)
                    context.setLineCap(.round)
                    context.strokePath()
                }
                context.restoreGState()
            }

            // Renderizar todos os elementos na ordem da z-order (de trás pra frente)
            for sibling in container.subviews {
                if sibling === canvasView || sibling === lassoOverlay || sibling === selectionBox { continue }
                // Pular connection points e delete buttons
                if connectionPoints.contains(sibling) { continue }
                if !sibling.isHidden && sibling.alpha > 0 {
                    context.saveGState()
                    context.translateBy(x: sibling.frame.origin.x, y: sibling.frame.origin.y)
                    // Aplicar transform (rotação de post-its)
                    context.concatenate(sibling.transform)
                    // Renderizar a view e todas as subviews
                    sibling.drawHierarchy(in: CGRect(origin: .zero, size: sibling.bounds.size), afterScreenUpdates: false)
                    context.restoreGState()
                }
            }

            // Renderizar rabiscos do PencilKit por cima de tudo
            let drawingImage = drawing.image(from: paddedBounds, scale: 2.0)
            drawingImage.draw(in: paddedBounds)
        }
    }

    // MARK: - Save / Load (Persistência)

    func startAutoSave() {
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveProject()
        }
    }

    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    func saveProject() {
        guard let container = containerView, let canvas = canvasView else { return }

        UserDefaults.standard.set(state.prompt, forKey: "illustrationPrompt")

        let (doc, drawingData, thumbnail) = collectProjectData(container: container, canvas: canvas)

        // Save to local cache for instant access
        StorageService.save(document: doc, drawing: canvas.drawing, thumbnail: thumbnail)

        // Save to cloud (source of truth) — fire and forget for auto-save
        Task {
            await SyncService.saveProject(doc, drawingData: drawingData, thumbnail: thumbnail)
        }
    }

    /// Save locally + await cloud upload (used when closing canvas)
    func saveAndSync() async {
        guard let container = containerView, let canvas = canvasView else { return }

        // Collect all data (same logic as saveProject but without firing background Task)
        UserDefaults.standard.set(state.prompt, forKey: "illustrationPrompt")

        let (doc, drawingData, thumbnail) = collectProjectData(container: container, canvas: canvas)

        // Save to local cache
        StorageService.save(document: doc, drawing: canvas.drawing, thumbnail: thumbnail)

        // Await cloud upload (blocking — waits for completion)
        await SyncService.saveProject(doc, drawingData: drawingData, thumbnail: thumbnail)
    }

    /// Collects project data from canvas without saving
    private func collectProjectData(container: UIView, canvas: PKCanvasView) -> (CanvasDocument, Data, UIImage?) {
        var elements: [CanvasElement] = []
        var fileIndex = 0

        for sibling in container.subviews {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
            if sibling === activeDeleteButton { continue }
            if connectionPoints.contains(sibling) { continue }
            if sibling.alpha <= 0 || sibling.isHidden { continue }

            let hl = highlightColorName(for: sibling)

            if let tv = sibling as? UITextView {
                let text = (tv.tag == Self.placeholderTag) ? "" : (tv.text ?? "")
                elements.append(CanvasElement(type: .text, text: text, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, highlightColor: hl))
                continue
            }

            if let bgColor = sibling.backgroundColor,
               sibling.subviews.contains(where: { $0 is UITextView }) {
                let textView = sibling.subviews.compactMap { $0 as? UITextView }.first
                let text = (textView?.tag == Self.placeholderTag) ? "" : (textView?.text ?? "")
                let color = PostItColor.from(uiColor: bgColor)
                let rotation = atan2(sibling.transform.b, sibling.transform.a)
                elements.append(CanvasElement(type: .postit, text: text, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.bounds.width, height: sibling.bounds.height, color: color, rotation: rotation, highlightColor: hl))
                continue
            }

            if let imgView = sibling as? UIImageView, let image = imgView.image {
                let filename = "img_\(fileIndex).jpg"
                fileIndex += 1
                StorageService.saveImage(image, named: filename, canvasId: projectId)
                elements.append(CanvasElement(type: sibling.tag == 888 ? .strokeGroup : .image, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, file: filename, highlightColor: hl))
                continue
            }

            if sibling.subviews.contains(where: { $0 is UIButton }) && sibling.layer.cornerRadius == 12 {
                if let playBtn = sibling.subviews.compactMap({ $0 as? UIButton }).first,
                   let audioURL = objc_getAssociatedObject(playBtn, &Self.audioURLKey) as? URL {
                    let filename = audioURL.lastPathComponent
                    _ = StorageService.copyAudioFile(from: audioURL, named: filename, canvasId: projectId)
                    let durationLabel = sibling.subviews.compactMap { $0 as? UILabel }.last
                    let durationText = durationLabel?.text ?? "0:00"
                    let parts = durationText.split(separator: ":")
                    let duration = parts.count == 2 ? (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0) : 0
                    elements.append(CanvasElement(type: .audio, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, file: filename, duration: duration, highlightColor: hl))
                }
                continue
            }
        }

        var viewToIndex: [ObjectIdentifier: Int] = [:]
        var viewIndex = 0
        for sibling in container.subviews {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
            if sibling === activeDeleteButton { continue }
            if sibling.alpha <= 0 || sibling.isHidden { continue }
            if connectionPoints.contains(where: { $0 === sibling }) { continue }
            viewToIndex[ObjectIdentifier(sibling)] = viewIndex
            viewIndex += 1
        }

        var connectionData: [CanvasConnectionData] = []
        for conn in connections {
            if let fromIdx = viewToIndex[ObjectIdentifier(conn.from)],
               let toIdx = viewToIndex[ObjectIdentifier(conn.to)] {
                connectionData.append(CanvasConnectionData(fromIndex: fromIdx, toIndex: toIdx))
            }
        }

        let doc = CanvasDocument(
            id: projectId,
            title: StorageService.loadDocument(id: projectId)?.title ?? "Sem título",
            createdAt: StorageService.loadDocument(id: projectId)?.createdAt ?? Date(),
            updatedAt: Date(),
            prompt: state.prompt,
            elements: elements,
            connections: connectionData.isEmpty ? nil : connectionData
        )

        let thumbnail = captureCanvas()
        let drawingData = canvas.drawing.dataRepresentation()

        return (doc, drawingData, thumbnail)
    }

    func loadProject() {
        // Try local cache first for instant display
        if let localDoc = StorageService.loadDocument(id: projectId) {
            restoreDocument(localDoc)
        }

        // Then fetch from cloud (source of truth) and update
        Task {
            if let cloudDoc = await SyncService.loadDocument(id: projectId) {
                await MainActor.run {
                    restoreDocument(cloudDoc)
                }
            }
        }
    }

    private func restoreDocument(_ doc: CanvasDocument) {
        state.prompt = doc.prompt

        // Carregar drawing
        if let drawing = StorageService.loadDrawing(id: projectId) {
            canvasView?.drawing = drawing
        }

        // Limpar elementos existentes antes de restaurar
        for (_, view) in allElementViews {
            view.removeFromSuperview()
        }
        allElementViews.removeAll()
        imageViews.removeAll()

        // Array ordenado para mapear índices → views (para restaurar conexões)
        var loadedViews: [UIView?] = []

        // Recriar elementos
        for element in doc.elements {
            let pos = CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)

            switch element.type {
            case .text:
                let textView = NonZoomableTextView()
        
                textView.font = handwritingFont
                textView.textColor = currentTextColor
                textView.backgroundColor = .clear
                textView.isScrollEnabled = false
                textView.textAlignment = .center
                textView.frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                textView.layer.cornerRadius = 4
                textView.isUserInteractionEnabled = true
                textView.tintColor = currentTextColor
                textView.dataDetectorTypes = []
                textView.linkTextAttributes = [:]
                textView.delegate = self

                if let text = element.text, !text.isEmpty {
                    textView.text = text
                    textView.textColor = currentTextColor
                    textView.tag = 0
                } else {
                    textView.text = "Toque para digitar"
                    textView.textColor = currentTextColor.withAlphaComponent(0.35)
                    textView.tag = Self.placeholderTag
                }

                addDragGestures(to: textView)
                addElementToCanvas(textView)
                allElementViews[UUID()] = textView
                if let hlName = element.highlightColor, let hlColor = Self.highlightColorFromName[hlName] {
                    addScribbleHighlight(to: textView, color: hlColor)
                }
                loadedViews.append(textView)

            case .postit:
                let color = element.color ?? .yellow
                let postIt = UIView()
                postIt.frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                postIt.backgroundColor = color.uiColor
                postIt.layer.cornerRadius = 4
                postIt.layer.shadowColor = UIColor.black.cgColor
                postIt.layer.shadowOpacity = 0.15
                postIt.layer.shadowRadius = 4
                postIt.layer.shadowOffset = CGSize(width: 2, height: 2)
                postIt.isUserInteractionEnabled = true
                if let rot = element.rotation {
                    postIt.transform = CGAffineTransform(rotationAngle: rot)
                }

                let textView = NonZoomableTextView()
        
                textView.font = handwritingFont
                textView.textColor = postItTextColor
                textView.backgroundColor = .clear
                textView.isScrollEnabled = false
                textView.textAlignment = .center
                textView.frame = postIt.bounds.insetBy(dx: 12, dy: 12)
                textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                textView.tintColor = postItTextColor
                textView.dataDetectorTypes = []
                textView.linkTextAttributes = [:]
                textView.delegate = self

                if let text = element.text, !text.isEmpty {
                    textView.text = text
                    textView.textColor = postItTextColor
                    textView.tag = 0
                } else {
                    textView.text = "Toque para digitar"
                    textView.textColor = postItTextColor.withAlphaComponent(0.35)
                    textView.tag = Self.placeholderTag
                }

                postIt.addSubview(textView)
                addDragGestures(to: postIt)
                addElementToCanvas(postIt)
                allElementViews[UUID()] = postIt
                if let hlName = element.highlightColor, let hlColor = Self.highlightColorFromName[hlName] {
                    addScribbleHighlight(to: postIt, color: hlColor)
                }
                loadedViews.append(postIt)

            case .image, .strokeGroup:
                guard let filename = element.file,
                      let image = StorageService.loadImage(named: filename, canvasId: projectId) else {
                    loadedViews.append(nil)
                    continue
                }
                let imgView = UIImageView(image: image)
                imgView.isUserInteractionEnabled = true
                imgView.contentMode = .scaleAspectFit
                imgView.frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                if element.type == .strokeGroup {
                    imgView.tag = 888
                } else {
                    imgView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
                    imgView.layer.borderWidth = 1.5
                    imgView.layer.cornerRadius = 4
                }
                addDragGestures(to: imgView)
                addElementToCanvas(imgView)
                let id = UUID()
                allElementViews[id] = imgView
                if element.type == .image {
                    imageViews[id] = imgView
                }
                if let hlName = element.highlightColor, let hlColor = Self.highlightColorFromName[hlName] {
                    addScribbleHighlight(to: imgView, color: hlColor)
                }
                loadedViews.append(imgView)

            case .audio:
                guard let filename = element.file else {
                    loadedViews.append(nil)
                    continue
                }
                let url = StorageService.audioFileURL(named: filename, canvasId: projectId)
                let duration = element.duration ?? 0
                addAudioPlayer(url: url, duration: duration, at: pos)
                loadedViews.append(nil) // áudio não tem view conectável
            }
        }

        // Restaurar conexões
        if let connData = doc.connections {
            for conn in connData {
                guard conn.fromIndex < loadedViews.count,
                      conn.toIndex < loadedViews.count,
                      let fromView = loadedViews[conn.fromIndex],
                      let toView = loadedViews[conn.toIndex] else { continue }
                createConnection(from: fromView, to: toView)
            }
        }
    }
}

// MARK: - PostItColor from UIColor

extension PostItColor {
    static func from(uiColor: UIColor) -> PostItColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        // Encontrar cor mais próxima
        let colors = PostItColor.allCases
        var best = PostItColor.yellow
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for c in colors {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
            c.uiColor.getRed(&cr, green: &cg, blue: &cb, alpha: nil)
            let dist = abs(r - cr) + abs(g - cg) + abs(b - cb)
            if dist < bestDist {
                bestDist = dist
                best = c
            }
        }
        return best
    }
}

// MARK: - UIGestureRecognizerDelegate

extension CanvasCoordinator {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
}

// MARK: - UITextViewDelegate (placeholder behavior)

extension CanvasCoordinator: UITextViewDelegate {
    private static let placeholderTag = 999

    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.tag == Self.placeholderTag {
            textView.text = ""
            let color = isInsidePostIt(textView) ? postItTextColor : currentTextColor
            textView.textColor = color
            textView.tag = 0
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.isEmpty {
            textView.text = "Toque para digitar"
            let color = isInsidePostIt(textView) ? postItTextColor : currentTextColor
            textView.textColor = color.withAlphaComponent(0.35)
            textView.tag = Self.placeholderTag
        }
    }

    private func isInsidePostIt(_ view: UIView) -> Bool {
        guard let parent = view.superview else { return false }
        if let bg = parent.backgroundColor {
            return PostItColor.allCases.contains(where: { $0.uiColor == bg })
        }
        return false
    }
}
