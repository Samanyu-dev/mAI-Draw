import UIKit
import PencilKit
import AVFoundation

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
                // Botões (play audio)
                if hit is UIButton { return hit }
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
        if window != nil {
            coordinator?.activateDrawing()
        }
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
    private var scrollView: UIScrollView?
    private var containerView: CanvasContainer?
    private var canvasView: DrawingCanvas?
    private var toolPicker: PKToolPicker?
    private var imageViews: [UUID: UIImageView] = [:]
    private var allElementViews: [UUID: UIView] = [:]
    private var canvasTapGesture: UITapGestureRecognizer?
    private var selectionMovePan: UIPanGestureRecognizer?
    private var activeDragElement: UIView?

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

    // Keys para objc_setAssociatedObject
    private static var audioURLKey: UInt8 = 0
    private static var audioIDKey: UInt8 = 0

    private let canvasSize = CGSize(width: 4096, height: 4096)
    private let handwritingFont = UIFont(name: "Noteworthy-Bold", size: 24) ?? UIFont.systemFont(ofSize: 24)

    init(state: CanvasState) {
        self.state = state
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
        scroll.backgroundColor = UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        self.scrollView = scroll

        let container = CanvasContainer(frame: CGRect(origin: .zero, size: canvasSize))
        container.backgroundColor = UIColor(patternImage: Self.dotGridPattern())
        self.containerView = container
        scroll.addSubview(container)
        scroll.contentSize = canvasSize

        container.coordinator = self

        // Canvas fica POR CIMA de tudo — hitTest roteia dedo pra elementos abaixo
        let canvas = DrawingCanvas(frame: CGRect(origin: .zero, size: canvasSize))
        canvas.delegate = self
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1.0
        canvas.maximumZoomScale = 1.0
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

        let fingerPinch = UIPinchGestureRecognizer(target: self, action: #selector(handleFingerPinch(_:)))
        fingerPinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(fingerPinch)

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

    private static func dotGridPattern() -> UIImage {
        let spacing: CGFloat = 20
        let dotRadius: CGFloat = 1.2
        let size = CGSize(width: spacing, height: spacing)
        let bgColor = UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        let dotColor = UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0)

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

    // MARK: - ScrollView Delegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        containerView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Não centralizar — manter posição fixa como Freeform
    }

    // MARK: - Shared Gestures

    private func addDragGestures(to view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(pinch)

        // Tap pra ativar edição de texto e trazer pra frente
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleElementTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(tap)
    }

    /// Traz elemento pra frente (abaixo do canvas) e ativa textView se tiver
    @objc private func handleElementTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        bringElementToFront(view)
        activateTextEditing(in: view)
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

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began:
            // Trazer pra frente (abaixo do canvas)
            bringElementToFront(view)
            view.layer.shadowColor = UIColor.systemBlue.cgColor
            view.layer.shadowOpacity = 0.5
            view.layer.shadowRadius = 8
            view.layer.shadowOffset = .zero
        case .changed:
            let t = gesture.translation(in: view.superview)
            view.center = CGPoint(x: view.center.x + t.x, y: view.center.y + t.y)
            gesture.setTranslation(.zero, in: view.superview)
        case .ended, .cancelled:
            view.layer.shadowOpacity = 0
        default: break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let view = gesture.view else { return }
        view.transform = view.transform.scaledBy(x: gesture.scale, y: gesture.scale)
        gesture.scale = 1
    }

    // MARK: - Finger → Element Proxy (canvas recebe, elemento reage)

    /// Encontra o elemento abaixo do canvas no ponto dado (coordenadas do container)
    private func findElement(at pointInContainer: CGPoint) -> UIView? {
        guard let container = containerView, let canvas = canvasView else { return nil }
        for sibling in container.subviews.reversed() {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
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
        } else {
            // Tap em área vazia — deselecionar tudo
            if !selectedViews.isEmpty { clearSelection() }
            // Resign text editing
            resignAllTextViews()
        }
    }

    @objc private func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView else { return }

        switch gesture.state {
        case .began:
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
            }
        case .ended, .cancelled:
            activeDragElement?.layer.shadowOpacity = 0
            activeDragElement = nil
        default: break
        }
    }

    @objc private func handleFingerPinch(_ gesture: UIPinchGestureRecognizer) {
        guard let container = containerView else { return }

        if gesture.state == .began {
            let mid = gesture.location(in: container)
            activeDragElement = findElement(at: mid)
        }

        if let el = activeDragElement {
            el.transform = el.transform.scaledBy(x: gesture.scale, y: gesture.scale)
            gesture.scale = 1
        }

        if gesture.state == .ended || gesture.state == .cancelled {
            activeDragElement = nil
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

        let textView = UITextView()
        textView.text = ""
        textView.font = handwritingFont
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = CGRect(x: pos.x - 120, y: pos.y - 30, width: 240, height: 60)
        textView.layer.cornerRadius = 4
        textView.isUserInteractionEnabled = true
        textView.tintColor = .black
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]

        // Placeholder
        textView.text = "Toque para digitar"
        textView.textColor = UIColor.black.withAlphaComponent(0.35)
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
        let textView = UITextView()
        textView.text = ""
        textView.font = handwritingFont
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = postIt.bounds.insetBy(dx: 12, dy: 12)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.tintColor = .black
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]

        // Placeholder
        textView.text = "Toque para digitar"
        textView.textColor = UIColor.black.withAlphaComponent(0.35)
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

    // MARK: - Capture Canvas

    func captureCanvas() -> UIImage? {
        guard let canvasView = canvasView else { return nil }

        let drawing = canvasView.drawing
        var bounds = drawing.bounds

        for (_, view) in imageViews {
            bounds = bounds.union(view.frame)
        }

        guard !bounds.isEmpty else { return nil }

        let paddedBounds = bounds.insetBy(dx: -50, dy: -50)

        let renderer = UIGraphicsImageRenderer(size: paddedBounds.size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: -paddedBounds.origin.x, y: -paddedBounds.origin.y)

            UIColor.white.setFill()
            ctx.fill(CGRect(origin: paddedBounds.origin, size: paddedBounds.size))

            for (_, view) in imageViews {
                view.image?.draw(in: view.frame)
            }

            let drawingImage = drawing.image(from: paddedBounds, scale: 2.0)
            drawingImage.draw(in: CGRect(origin: .zero, size: paddedBounds.size))
        }
    }
}

// MARK: - UITextViewDelegate (placeholder behavior)

extension CanvasCoordinator: UITextViewDelegate {
    private static let placeholderTag = 999

    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.tag == Self.placeholderTag {
            textView.text = ""
            textView.textColor = .black
            textView.tag = 0
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.isEmpty {
            textView.text = "Toque para digitar"
            textView.textColor = UIColor.black.withAlphaComponent(0.35)
            textView.tag = Self.placeholderTag
        }
    }
}
