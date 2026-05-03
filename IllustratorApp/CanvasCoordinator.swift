import UIKit
import PencilKit
import AVFoundation

private func shouldSuppressFloatingEditAction(_ action: Selector) -> Bool {
    let name = NSStringFromSelector(action)
    return name == "selectAll:" || name == "insertSpace:" || name == "_insertSpace:"
}

private func dismissFloatingEditMenu() {
    UIMenuController.shared.hideMenu()
}

// MARK: - Non-Zoomable UITextView (bloqueia zoom do trackpad)

class NonZoomableTextView: UITextView {
    /// Janela de proteção contra PencilKit roubar first responder
    var resignBlockedUntil: Date = .distantPast
    /// Referência ao coordinator para notificar Enter
    weak var canvasCoordinator: CanvasCoordinator?
    /// Rastreia se Shift está segurado
    var isShiftHeld = false

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

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if shouldSuppressFloatingEditAction(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    // Bloquear resignFirstResponder do PencilKit (timer interno ~1s)
    @discardableResult
    override func resignFirstResponder() -> Bool {
        if Date() < resignBlockedUntil { return false }
        return super.resignFirstResponder()
    }

    // Enter = finalizar edição, Shift+Enter = quebra de linha
    override func insertText(_ text: String) {
        if text == "\n" {
            // Shift+Enter → quebra de linha (isShiftHeld rastreado via pressesBegan)
            if isShiftHeld {
                super.insertText(text)
                return
            }
            // Enter simples → finalizar edição e mostrar seleção
            resignBlockedUntil = .distantPast
            resignFirstResponder()
            canvasCoordinator?.showSelectionUI(for: self)
            return
        }
        super.insertText(text)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = true
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift {
                isShiftHeld = false
            }
        }
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - Markdown Liquid Glass Card

final class MarkdownCardView: UIView {
    let glassView = UIVisualEffectView()
    let textView = NonZoomableTextView()
    private(set) var cardColor: MarkdownCardColor
    var rawMarkdown: String = ""

    private let textInsets = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    private let cornerRadius: CGFloat = 24

    init(color: MarkdownCardColor) {
        self.cardColor = color
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.cardColor = .crystal
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = true

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 10)

        glassView.isUserInteractionEnabled = false
        glassView.clipsToBounds = true
        glassView.layer.cornerRadius = cornerRadius
        glassView.layer.borderWidth = 1
        glassView.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        addSubview(glassView)

        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textAlignment = .left
        textView.tintColor = .label
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        addSubview(textView)

        updateGlassEffect()
        renderMarkdown(textColor: .label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds
        textView.frame = bounds.inset(by: textInsets)

        if #available(iOS 26.0, *) {
            glassView.cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
            cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
        } else {
            glassView.layer.cornerRadius = cornerRadius
            layer.cornerRadius = cornerRadius
        }
    }

    func updateGlassEffect() {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = cardColor.uiColor
            effect.isInteractive = true
            glassView.effect = effect
        } else {
            glassView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            glassView.backgroundColor = cardColor.uiColor
        }
    }

    func applyColor(_ color: MarkdownCardColor) {
        cardColor = color
        updateGlassEffect()
    }

    func setMarkdown(_ markdown: String, textColor: UIColor) {
        rawMarkdown = markdown
        renderMarkdown(textColor: textColor)
    }

    func beginMarkdownEditing(textColor: UIColor) {
        textView.attributedText = nil
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textColor = textColor
        textView.tintColor = textColor
        textView.text = rawMarkdown
        textView.tag = 0
    }

    func updateMarkdownFromEditor() {
        if textView.tag != 999 {
            rawMarkdown = textView.text ?? ""
        }
    }

    func renderMarkdown(textColor: UIColor) {
        let trimmed = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            textView.attributedText = nil
            textView.font = .systemFont(ofSize: 16, weight: .regular)
            textView.text = "Toque para digitar Markdown"
            textView.textColor = textColor.withAlphaComponent(0.42)
            textView.tag = 999
            return
        }

        textView.tag = 0
        textView.attributedText = Self.renderedMarkdown(from: rawMarkdown, textColor: textColor)
    }

    private static func renderedMarkdown(from markdown: String, textColor: UIColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for rawLine in lines {
            let parsed = parseMarkdownLine(rawLine, textColor: textColor)
            let line = NSMutableAttributedString(string: parsed.text, attributes: parsed.attributes)
            applyInlineMarkdown(to: line, textColor: textColor)
            output.append(line)
            output.append(NSAttributedString(string: "\n", attributes: parsed.attributes))
        }

        return output
    }

    private static func parseMarkdownLine(_ rawLine: String, textColor: UIColor) -> (text: String, attributes: [NSAttributedString.Key: Any]) {
        var text = rawLine
        let font: UIFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8

        if text.hasPrefix("# ") {
            text.removeFirst(2)
            font = .systemFont(ofSize: 24, weight: .bold)
            paragraph.paragraphSpacing = 10
        } else if text.hasPrefix("## ") {
            text.removeFirst(3)
            font = .systemFont(ofSize: 19, weight: .semibold)
            paragraph.paragraphSpacing = 8
        } else if text.hasPrefix("### ") {
            text.removeFirst(4)
            font = .systemFont(ofSize: 16, weight: .semibold)
        } else if text.hasPrefix("- ") {
            text = "• " + String(text.dropFirst(2))
            font = .systemFont(ofSize: 15, weight: .regular)
        } else {
            font = .systemFont(ofSize: 15, weight: .regular)
        }

        return (text, [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ])
    }

    private static func applyInlineMarkdown(to attributed: NSMutableAttributedString, textColor: UIColor) {
        replaceMarkdown(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", in: attributed) { match, baseAttributes in
            let label = match[1]
            let urlString = match[2]
            let replacement = NSMutableAttributedString(string: label, attributes: baseAttributes)
            if let url = URL(string: urlString) {
                replacement.addAttributes([
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: NSRange(location: 0, length: replacement.length))
            }
            return replacement
        }

        replaceMarkdown(pattern: "\\*\\*([^*]+)\\*\\*", in: attributed) { match, baseAttributes in
            var attributes = baseAttributes
            attributes[.font] = UIFont.systemFont(ofSize: 15, weight: .bold)
            attributes[.foregroundColor] = textColor
            return NSAttributedString(string: match[1], attributes: attributes)
        }

        replaceMarkdown(pattern: "`([^`]+)`", in: attributed) { match, baseAttributes in
            var attributes = baseAttributes
            attributes[.font] = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            attributes[.foregroundColor] = textColor
            attributes[.backgroundColor] = UIColor.label.withAlphaComponent(0.08)
            return NSAttributedString(string: match[1], attributes: attributes)
        }
    }

    private static func replaceMarkdown(
        pattern: String,
        in attributed: NSMutableAttributedString,
        replacement: ([String], [NSAttributedString.Key: Any]) -> NSAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let source = attributed.string as NSString
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: source.length))

        for result in matches.reversed() {
            var captures: [String] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                captures.append(range.location == NSNotFound ? "" : source.substring(with: range))
            }
            let baseAttributes = attributed.attributes(at: max(0, result.range.location), effectiveRange: nil)
            attributed.replaceCharacters(in: result.range, with: replacement(captures, baseAttributes))
        }
    }
}

// MARK: - Drawing Canvas (fica por cima de tudo)

class DrawingCanvas: PKCanvasView {
    weak var coordinator: CanvasCoordinator?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if shouldSuppressFloatingEditAction(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

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
                // TextViews que estão sendo editados — capturar input direto
                if let tv = hit as? UITextView, tv.isFirstResponder { return tv }
                // Post-its (container com texto dentro) — rotear para gesture do elemento
                if !(sibling is UITextView), sibling.subviews.contains(where: { $0 is UITextView }) {
                    return sibling
                }
            }
        }

        // Tudo mais → canvas recebe (pencil desenha, dedo handled por gestures no canvas)
        return super.hitTest(point, with: event)
    }

    // Navegação por setas quando elemento está selecionado
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            // Só setas sem modifier → navegação entre elementos
            if key.modifierFlags.isEmpty {
                switch key.keyCode {
                case .keyboardUpArrow:
                    if coordinator?.navigateToElement(direction: 0) == true { return }
                case .keyboardDownArrow:
                    if coordinator?.navigateToElement(direction: 1) == true { return }
                case .keyboardLeftArrow:
                    if coordinator?.navigateToElement(direction: 2) == true { return }
                case .keyboardRightArrow:
                    if coordinator?.navigateToElement(direction: 3) == true { return }
                case .keyboardReturnOrEnter:
                    if coordinator?.enterSelectedElement() == true { return }
                default:
                    break
                }
            }
        }
        super.pressesBegan(presses, with: event)
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
    private var activeMarkdownColorButton: UIButton?
    private weak var activeMarkdownColorTarget: MarkdownCardView?
    private var deleteTargetView: UIView?

    // Connections (setas entre elementos)
    private var connections: [(from: UIView, to: UIView, layer: CAShapeLayer)] = []
    var connectionPoints: [UIView] = [] // bolinhas de conexão ativas
    private var connectionSourceView: UIView?   // elemento de onde está arrastando
    private var connectionPreviewLayer: CAShapeLayer? // preview da seta enquanto arrasta

    // Mind map — botões direcionais (+ nas 4 direções)
    private var directionalButtons: [UIButton] = []
    private var directionalSourceView: UIView?

    // Keys para objc_setAssociatedObject
    private static var audioURLKey: UInt8 = 0
    private static var audioIDKey: UInt8 = 0
    private static var elementIDKey: UInt8 = 0
    private static let connectionLayerName = "CanvasConnectionLayer"

    private let canvasSize = CGSize(width: 16384, height: 16384)
    private var canvasCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }
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
        scroll.minimumZoomScale = 0.025
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
        let fingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerDoubleTap(_:)))
        fingerDoubleTap.numberOfTapsRequired = 2
        fingerDoubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        canvas.addGestureRecognizer(fingerDoubleTap)

        let fingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        fingerTap.require(toFail: fingerDoubleTap)
        canvas.addGestureRecognizer(fingerTap)

        let fingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleFingerPan(_:)))
        fingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        fingerPan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(fingerPan)

        // Long press + drag = laço automático
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressLasso(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
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

        centerViewport(on: canvasCenter, animated: false)

        return scroll
    }

    /// Posição central visível no canvas
    private func visibleCenter() -> CGPoint {
        guard let scroll = scrollView else { return canvasCenter }
        let zoomScale = scroll.zoomScale
        return CGPoint(
            x: (scroll.contentOffset.x + scroll.bounds.width / 2) / zoomScale,
            y: (scroll.contentOffset.y + scroll.bounds.height / 2) / zoomScale
        )
    }

    func currentVisibleCenter() -> CGPoint {
        visibleCenter()
    }

    private func centerViewport(on point: CGPoint, animated: Bool) {
        guard let scroll = scrollView else { return }
        let zoomScale = scroll.zoomScale
        let maxOffsetX = max(0, canvasSize.width * zoomScale - scroll.bounds.width)
        let maxOffsetY = max(0, canvasSize.height * zoomScale - scroll.bounds.height)
        let target = CGPoint(
            x: min(max(0, point.x * zoomScale - scroll.bounds.width / 2), maxOffsetX),
            y: min(max(0, point.y * zoomScale - scroll.bounds.height / 2), maxOffsetY)
        )
        scroll.setContentOffset(target, animated: animated)
    }

    private func centerViewportOnLoadedContent(from doc: CanvasDocument) {
        var bounds = CGRect.null

        for element in doc.elements {
            let frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            bounds = bounds.union(frame)
        }

        if let drawingBounds = canvasView?.drawing.bounds,
           !drawingBounds.isNull,
           !drawingBounds.isEmpty {
            bounds = bounds.union(drawingBounds)
        }

        guard !bounds.isNull, !bounds.isEmpty else { return }
        centerViewport(on: CGPoint(x: bounds.midX, y: bounds.midY), animated: false)
    }

    /// Adiciona elemento abaixo do canvas (canvas fica no topo visual)
    private func addElementToCanvas(_ view: UIView) {
        guard let container = containerView, let canvas = canvasView else { return }
        ensureElementID(for: view)
        container.insertSubview(view, belowSubview: canvas)
    }

    @discardableResult
    private func ensureElementID(for view: UIView, preferred preferredId: String? = nil) -> String {
        if let preferredId, !preferredId.isEmpty {
            objc_setAssociatedObject(view, &Self.elementIDKey, preferredId as NSString, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            return preferredId
        }

        if let existing = elementID(for: view) {
            return existing
        }

        let newId = UUID().uuidString
        objc_setAssociatedObject(view, &Self.elementIDKey, newId as NSString, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        return newId
    }

    private func elementID(for view: UIView) -> String? {
        guard let stored = objc_getAssociatedObject(view, &Self.elementIDKey) as? NSString else { return nil }
        let id = stored as String
        return id.isEmpty ? nil : id
    }

    private func uuidKey(for elementId: String?) -> UUID {
        if let elementId, let uuid = UUID(uuidString: elementId) {
            return uuid
        }
        return UUID()
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
        selectionBox?.removeFromSuperview()
        selectionBox = nil
        selectionMovePan = nil

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

    private func isResizableImageElement(_ view: UIView) -> Bool {
        view is UIImageView && view.tag != 888
    }

    private func showResizeHandles(for view: UIView) {
        if !selectedViews.isEmpty || selectionBox != nil {
            clearSelection()
        }
        selectedViews = [view]
        showSelectionBox()
    }

    @objc private func handleSelectionMove(_ gesture: UIPanGestureRecognizer) {
        guard let box = selectionBox else { return }
        let t = gesture.translation(in: box.superview)

        if t != .zero {
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

        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            saveProject()
        }
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
        updateAllConnections()

        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            saveProject()
        }
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
        updateAllConnections()

        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            saveProject()
        }
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

            if let card = sibling as? MarkdownCardView {
                if card.textView.isFirstResponder {
                    card.textView.textColor = textColor
                    card.textView.tintColor = textColor
                } else {
                    card.renderMarkdown(textColor: textColor)
                }
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
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleElementDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleElementTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        if !(view is UITextView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleElementPan(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
        }
    }

    @objc private func handleElementPan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view, let container = containerView else { return }

        switch gesture.state {
        case .began:
            hideDeleteButton()
            hideConnectionPoints()
            hideDirectionalButtons()
            if !selectedViews.isEmpty || selectionBox != nil {
                clearSelection()
            }
            bringElementToFront(view)
            view.layer.shadowColor = UIColor.systemBlue.cgColor
            view.layer.shadowOpacity = 0.45
            view.layer.shadowRadius = 8
            view.layer.shadowOffset = .zero

        case .changed:
            let t = gesture.translation(in: container)
            guard t != .zero else { return }
            view.center = CGPoint(x: view.center.x + t.x, y: view.center.y + t.y)
            gesture.setTranslation(.zero, in: container)
            updateAllConnections()

        case .ended, .cancelled, .failed:
            view.layer.shadowOpacity = 0
            showSelectionUI(for: view)
            saveProject()

        default:
            break
        }
    }

    // MARK: - Highlight Scribble

    private static let highlightLayerName = "scribbleHighlight"
    private static let completionLayerName = "taskCompletionX"
    private static var completionStyleKey: UInt8 = 0

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
        if let view = selectedOrEditingElement() {
            toggleHighlight(on: view)
        }
    }

    func toggleCompletionOnSelected() {
        if let view = selectedOrEditingElement() {
            toggleCompletion(on: view)
        }
    }

    private func selectedOrEditingElement() -> UIView? {
        if let view = deleteTargetView { return view }
        guard let container = containerView else { return nil }
        return firstResponderElement(in: container)
    }

    private func firstResponderElement(in view: UIView) -> UIView? {
        if view.isFirstResponder {
            if view === canvasView || view === containerView { return nil }
            return canvasElement(containing: view)
        }

        for subview in view.subviews {
            if let element = firstResponderElement(in: subview) {
                return element
            }
        }
        return nil
    }

    private func canvasElement(containing view: UIView) -> UIView? {
        guard view !== canvasView, view !== containerView else { return nil }
        if let parent = view.superview,
           parent !== containerView,
           !(parent is UIScrollView) {
            return parent
        }
        return view
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

    private func toggleCompletion(on view: UIView) {
        if let existing = view.layer.sublayers?.first(where: { $0.name == Self.completionLayerName }) {
            existing.removeFromSuperlayer()
            return
        }

        let color = Self.highlightColors.randomElement()!
        let style = CompletionStyle.allCases.randomElement()!
        addCompletionMark(to: view, color: color, style: style)
    }

    private enum ScribbleStyle: CaseIterable {
        case oval, roundedRect, zigzag, cloud, spiral
    }

    private enum CompletionStyle: String, CaseIterable {
        case x
        case horizontal
        case doubleHorizontal
        case slash
        case loop
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
        layer.lineWidth = max(2.8, min(4.4, min(view.bounds.width, view.bounds.height) * 0.035))
        layer.lineCap = .round
        layer.lineJoin = .round
        view.layer.addSublayer(layer)
    }

    private func addCompletionMark(to view: UIView, color: UIColor, style: CompletionStyle) {
        let rect = view.bounds.insetBy(dx: -6, dy: -6)
        let path = UIBezierPath()

        switch style {
        case .x:
            drawCompletionX(path: path, in: rect)
        case .horizontal:
            drawHorizontalCompletion(path: path, in: rect, lines: 1)
        case .doubleHorizontal:
            drawHorizontalCompletion(path: path, in: rect, lines: 2)
        case .slash:
            drawSlashCompletion(path: path, in: rect)
        case .loop:
            drawLoopCompletion(path: path, in: rect)
        }

        let layer = CAShapeLayer()
        layer.name = Self.completionLayerName
        objc_setAssociatedObject(layer, &Self.completionStyleKey, style.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        layer.path = path.cgPath
        layer.strokeColor = color.cgColor
        layer.fillColor = nil
        layer.lineWidth = max(4.4, min(7.0, min(view.bounds.width, view.bounds.height) * 0.055))
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.zPosition = 1000
        view.layer.addSublayer(layer)
    }

    private func drawCompletionX(path: UIBezierPath, in rect: CGRect) {
        drawHumanCompletionStroke(
            path: path,
            from: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.05),
            to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.maxY - rect.height * 0.02),
            steps: 9,
            jitter: 4.5,
            bow: CGFloat.random(in: -16...16),
            passes: 2
        )
        drawHumanCompletionStroke(
            path: path,
            from: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.04),
            to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.04),
            steps: 9,
            jitter: 4.5,
            bow: CGFloat.random(in: -16...16),
            passes: 2
        )
    }

    private func drawHorizontalCompletion(path: UIBezierPath, in rect: CGRect, lines: Int) {
        let strokeCount = lines == 1 ? Int.random(in: 2...3) : Int.random(in: 3...4)
        let spacing = max(5, min(12, rect.height * 0.08))
        for index in 0..<strokeCount {
            let centered = CGFloat(index) - CGFloat(strokeCount - 1) / 2
            let y = rect.midY + centered * spacing + CGFloat.random(in: -4...4)
            drawHumanCompletionStroke(
                path: path,
                from: CGPoint(x: rect.minX - rect.width * 0.08 + CGFloat.random(in: -6...4), y: y),
                to: CGPoint(x: rect.maxX + rect.width * 0.08 + CGFloat.random(in: -4...8), y: y + CGFloat.random(in: -8...8)),
                steps: 10,
                jitter: 3.6,
                bow: CGFloat.random(in: -10...10),
                passes: 1
            )
        }
    }

    private func drawSlashCompletion(path: UIBezierPath, in rect: CGRect) {
        let points = [
            CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.06),
            CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.14),
            CGPoint(x: rect.minX + rect.width * 0.47, y: rect.maxY - rect.height * 0.08),
            CGPoint(x: rect.minX + rect.width * 0.63, y: rect.minY + rect.height * 0.10),
            CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.04)
        ]
        drawHumanCompletionPolyline(path: path, points: points, jitter: 5.5, passes: 2)
    }

    private func drawLoopCompletion(path: UIBezierPath, in rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width * 0.46
        let ry = rect.height * 0.38
        let steps = 42

        for pass in 0..<3 {
            var points: [CGPoint] = []
            let passOffset = CGFloat(pass) * 0.12
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let angle = t * .pi * 2.08 + passOffset + CGFloat.random(in: -0.02...0.02)
                let wobble = 1 + CGFloat.random(in: -0.055...0.055)
                points.append(
                    CGPoint(
                        x: center.x + cos(angle) * rx * wobble + CGFloat.random(in: -4...4),
                        y: center.y + sin(angle) * ry * wobble + CGFloat.random(in: -4...4)
                    )
                )
            }
            appendSmoothCompletionStroke(points, to: path)
        }
    }

    private func drawHumanCompletionStroke(
        path: UIBezierPath,
        from start: CGPoint,
        to end: CGPoint,
        steps: Int,
        jitter: CGFloat,
        bow: CGFloat,
        passes: Int
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(1, sqrt(dx * dx + dy * dy))
        let normal = CGPoint(x: -dy / length, y: dx / length)

        for pass in 0..<passes {
            var points: [CGPoint] = []
            let passDrift = (CGFloat(pass) - CGFloat(passes - 1) / 2) * CGFloat.random(in: 3...7)
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let base = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
                let curve = sin(t * .pi) * bow
                let noise = CGFloat.random(in: -jitter...jitter)
                let along = CGFloat.random(in: -jitter * 0.45...jitter * 0.45)
                points.append(
                    CGPoint(
                        x: base.x + normal.x * (curve + noise + passDrift) + (dx / length) * along,
                        y: base.y + normal.y * (curve + noise + passDrift) + (dy / length) * along
                    )
                )
            }
            appendSmoothCompletionStroke(points, to: path)
        }
    }

    private func drawHumanCompletionPolyline(path: UIBezierPath, points: [CGPoint], jitter: CGFloat, passes: Int) {
        guard points.count > 1 else { return }
        for pass in 0..<passes {
            let passDrift = CGFloat(pass) * 2.2
            let jittered = points.map {
                CGPoint(
                    x: $0.x + CGFloat.random(in: -jitter...jitter) + passDrift,
                    y: $0.y + CGFloat.random(in: -jitter...jitter) - passDrift
                )
            }
            appendSmoothCompletionStroke(jittered, to: path)
        }
    }

    private func appendSmoothCompletionStroke(_ points: [CGPoint], to path: UIBezierPath) {
        guard points.count > 1 else { return }
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, controlPoint: point)
        }
        path.addLine(to: points[points.count - 1])
    }

    private func drawScribbleStroke(path: UIBezierPath, from start: CGPoint, to end: CGPoint) {
        drawHumanCompletionStroke(
            path: path,
            from: start,
            to: end,
            steps: 9,
            jitter: 4,
            bow: CGFloat.random(in: -12...12),
            passes: 2
        )
    }

    private func drawOvalScribble(path: UIBezierPath, in rect: CGRect) {
        drawOrganicLoopScribble(path: path, in: rect, passes: 2, wobble: 5.0, stretch: 1.0)
    }

    private func drawRoundedRectScribble(path: UIBezierPath, in rect: CGRect) {
        let radius = min(rect.width, rect.height) * 0.23
        let anchors = [
            CGPoint(x: rect.minX + radius, y: rect.minY + CGFloat.random(in: -3...3)),
            CGPoint(x: rect.midX, y: rect.minY + CGFloat.random(in: -5...2)),
            CGPoint(x: rect.maxX - radius, y: rect.minY + CGFloat.random(in: -3...3)),
            CGPoint(x: rect.maxX + CGFloat.random(in: -2...5), y: rect.minY + radius),
            CGPoint(x: rect.maxX + CGFloat.random(in: -2...5), y: rect.midY),
            CGPoint(x: rect.maxX + CGFloat.random(in: -2...5), y: rect.maxY - radius),
            CGPoint(x: rect.maxX - radius, y: rect.maxY + CGFloat.random(in: -2...5)),
            CGPoint(x: rect.midX, y: rect.maxY + CGFloat.random(in: -2...6)),
            CGPoint(x: rect.minX + radius, y: rect.maxY + CGFloat.random(in: -2...5)),
            CGPoint(x: rect.minX + CGFloat.random(in: -5...2), y: rect.maxY - radius),
            CGPoint(x: rect.minX + CGFloat.random(in: -5...2), y: rect.midY),
            CGPoint(x: rect.minX + CGFloat.random(in: -5...2), y: rect.minY + radius)
        ]
        for pass in 0..<2 {
            let drift = CGFloat(pass) * 2.6
            let points = anchors.map {
                CGPoint(
                    x: $0.x + CGFloat.random(in: -3.5...3.5) + drift,
                    y: $0.y + CGFloat.random(in: -3.5...3.5) - drift
                )
            }
            appendClosedSmoothScribble(points, to: path)
        }
    }

    private func drawZigzagScribble(path: UIBezierPath, in rect: CGRect) {
        drawOrganicLoopScribble(path: path, in: rect, passes: 2, wobble: 8.0, stretch: 0.96)
    }

    private func drawCloudScribble(path: UIBezierPath, in rect: CGRect) {
        drawOrganicLoopScribble(path: path, in: rect, passes: 3, wobble: 6.5, stretch: 1.04)
    }

    private func drawSpiralScribble(path: UIBezierPath, in rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width * 0.5
        let ry = rect.height * 0.5
        let totalSteps = 56
        let totalAngle: CGFloat = .pi * CGFloat.random(in: 2.05...2.35)
        var points: [CGPoint] = []
        for i in 0...totalSteps {
            let t = CGFloat(i) / CGFloat(totalSteps)
            let angle = t * totalAngle + CGFloat.random(in: -0.018...0.018)
            let grow = 0.88 + t * 0.18
            points.append(
                CGPoint(
                    x: center.x + rx * grow * cos(angle) + CGFloat.random(in: -3...3),
                    y: center.y + ry * grow * sin(angle) + CGFloat.random(in: -3...3)
                )
            )
        }
        appendSmoothCompletionStroke(points, to: path)
    }

    private func drawOrganicLoopScribble(path: UIBezierPath, in rect: CGRect, passes: Int, wobble: CGFloat, stretch: CGFloat) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width * 0.5 * stretch
        let ry = rect.height * 0.5
        let steps = 54

        for pass in 0..<passes {
            var points: [CGPoint] = []
            let phase = CGFloat.random(in: 0...(CGFloat.pi * 2))
            let start = CGFloat.random(in: -0.35...0.18) + CGFloat(pass) * 0.08
            let total = CGFloat.pi * 2 * CGFloat.random(in: 1.02...1.10)
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let angle = start + total * t
                let wave = sin(angle * 2.4 + phase) * wobble + sin(angle * 4.7 + phase) * wobble * 0.35
                let drift = CGFloat(pass) * 1.8
                points.append(
                    CGPoint(
                        x: center.x + (rx + wave + CGFloat.random(in: -2.8...2.8) + drift) * cos(angle),
                        y: center.y + (ry + wave + CGFloat.random(in: -2.8...2.8) - drift) * sin(angle)
                    )
                )
            }
            appendSmoothCompletionStroke(points, to: path)
        }
    }

    private func appendClosedSmoothScribble(_ points: [CGPoint], to path: UIBezierPath) {
        guard let first = points.first else { return }
        appendSmoothCompletionStroke(points + [first], to: path)
    }

    /// Returns the highlight color name for a view, or nil if no highlight
    func highlightColorName(for view: UIView) -> String? {
        guard let layer = view.layer.sublayers?.first(where: { $0.name == Self.highlightLayerName }) as? CAShapeLayer,
              let cgColor = layer.strokeColor else { return nil }
        let uiColor = UIColor(cgColor: cgColor)
        return Self.highlightColorNames[uiColor]
    }

    func completionColorName(for view: UIView) -> String? {
        guard let layer = view.layer.sublayers?.first(where: { $0.name == Self.completionLayerName }) as? CAShapeLayer,
              let cgColor = layer.strokeColor else { return nil }
        let uiColor = UIColor(cgColor: cgColor)
        return Self.highlightColorNames[uiColor]
    }

    func completionStyleName(for view: UIView) -> String? {
        guard let layer = view.layer.sublayers?.first(where: { $0.name == Self.completionLayerName }) else { return nil }
        return (objc_getAssociatedObject(layer, &Self.completionStyleKey) as? String) ?? CompletionStyle.x.rawValue
    }

    private func restoreVisualMarks(to view: UIView, from element: CanvasElement) {
        if let hlName = element.highlightColor, let hlColor = Self.highlightColorFromName[hlName] {
            addScribbleHighlight(to: view, color: hlColor)
        }
        if let completionName = element.completionColor,
           let completionColor = Self.highlightColorFromName[completionName] {
            let style = element.completionStyle.flatMap(CompletionStyle.init(rawValue:)) ?? .x
            addCompletionMark(to: view, color: completionColor, style: style)
        }
    }

    /// Traz elemento pra frente (abaixo do canvas) e ativa textView se tiver
    @objc private func handleElementTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        showSelectionUI(for: view)
    }

    /// Navega para o elemento mais próximo na direção (0=up, 1=down, 2=left, 3=right)
    /// Retorna true se navegou, false se não havia elemento selecionado ou destino
    func navigateToElement(direction: Int) -> Bool {
        guard let current = deleteTargetView else { return false }
        let currentCenter = CGPoint(x: current.frame.midX, y: current.frame.midY)

        var bestView: UIView?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for (_, view) in allElementViews {
            if view === current { continue }
            if view.superview == nil { continue }
            let center = CGPoint(x: view.frame.midX, y: view.frame.midY)
            let dx = center.x - currentCenter.x
            let dy = center.y - currentCenter.y

            // Filtrar pela direção
            let isInDirection: Bool
            switch direction {
            case 0: isInDirection = dy < -20  // up
            case 1: isInDirection = dy > 20   // down
            case 2: isInDirection = dx < -20  // left
            case 3: isInDirection = dx > 20   // right
            default: isInDirection = false
            }
            guard isInDirection else { continue }

            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance {
                bestDistance = distance
                bestView = view
            }
        }

        guard let target = bestView else { return false }
        showSelectionUI(for: target)
        return true
    }

    /// Enter no elemento selecionado = ativar edição de texto
    /// Retorna true se ativou, false se não havia elemento selecionado
    func enterSelectedElement() -> Bool {
        guard let target = deleteTargetView, isTextElement(target) else { return false }
        hideConnectionPoints()
        hideDirectionalButtons()
        activateTextEditing(in: target)
        return true
    }

    @objc private func handleElementDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        guard isTextElement(view) else { return }
        bringElementToFront(view)
        hideConnectionPoints()
        hideDirectionalButtons()
        activateTextEditing(in: view)
    }

    private func bringElementToFront(_ view: UIView) {
        guard let container = containerView, let canvas = canvasView else { return }
        container.insertSubview(view, belowSubview: canvas)
    }

    /// Mostra UI de seleção (delete, conexões, direcionais) — chamado pelo Enter no teclado
    func showSelectionUI(for view: UIView) {
        // Se é um text view dentro de post-it, usar o post-it como elemento
        let element: UIView
        if let parent = view.superview, parent !== containerView, !(parent is UIScrollView) {
            element = parent
        } else {
            element = view
        }
        bringElementToFront(element)
        if isResizableImageElement(element) {
            showResizeHandles(for: element)
        } else if !selectedViews.isEmpty || selectionBox != nil {
            clearSelection()
        }
        showDeleteButton(for: element)
        if let card = element as? MarkdownCardView {
            showMarkdownCardColorButton(for: card)
        } else {
            hideMarkdownCardColorButton()
        }
        showConnectionPoints(for: element)
        showDirectionalButtons(for: element)
        // Canvas vira first responder para capturar setas do teclado
        canvasView?.becomeFirstResponder()
    }

    private func activateTextEditing(in view: UIView) {
        // Se a view é um UITextView (texto avulso)
        if let tv = view as? NonZoomableTextView {
            tv.resignBlockedUntil = Date().addingTimeInterval(1.5)
            tv.becomeFirstResponder()
            return
        }
        // Se a view contém um UITextView (post-it)
        for sub in view.subviews {
            if let tv = sub as? NonZoomableTextView {
                tv.resignBlockedUntil = Date().addingTimeInterval(1.5)
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
        for btn in [activeDeleteButton, activeHighlightButton, activeMarkdownColorButton].compactMap({ $0 }) {
            UIView.animate(withDuration: 0.15, animations: {
                btn.alpha = 0
                btn.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            }) { _ in
                btn.removeFromSuperview()
            }
        }
        activeDeleteButton = nil
        activeHighlightButton = nil
        activeMarkdownColorButton = nil
        activeMarkdownColorTarget = nil
        deleteTargetView = nil
    }

    private func hideMarkdownCardColorButton() {
        activeMarkdownColorButton?.removeFromSuperview()
        activeMarkdownColorButton = nil
        activeMarkdownColorTarget = nil
    }

    private func showMarkdownCardColorButton(for card: MarkdownCardView) {
        hideMarkdownCardColorButton()
        guard let container = containerView else { return }

        activeMarkdownColorTarget = card

        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let size: CGFloat = 36
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "paintpalette.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.systemBlue
        button.layer.cornerRadius = size / 2
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.frame = CGRect(
            x: card.frame.minX - size / 2 - 8,
            y: card.frame.minY - size / 2 + 8,
            width: size,
            height: size
        )
        button.menu = UIMenu(children: MarkdownCardColor.palette.map { color in
            UIAction(title: color.label, image: markdownColorSwatch(for: color)) { [weak self, weak card] _ in
                guard let self, let card else { return }
                card.applyColor(color)
                self.showMarkdownCardColorButton(for: card)
                self.saveProject()
            }
        })
        button.showsMenuAsPrimaryAction = true
        container.addSubview(button)
        activeMarkdownColorButton = button

        button.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        button.alpha = 0
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
            button.transform = .identity
            button.alpha = 1
        }
    }

    private func markdownColorSwatch(for color: MarkdownCardColor) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            color.uiColor.setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
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
        hideDirectionalButtons()
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
        let iconSize: CGFloat = 28
        let touchSize: CGFloat = 58
        let buttonSize: CGFloat = 32
        let gap: CGFloat = 16

        let top = CGPoint(x: frame.midX, y: frame.minY - gap - buttonSize / 2)
        let bottom = CGPoint(x: frame.midX, y: frame.maxY + gap + buttonSize / 2)
        let left = CGPoint(x: frame.minX - gap - buttonSize / 2, y: frame.midY)
        let right = CGPoint(x: frame.maxX + gap + buttonSize / 2, y: frame.midY)
        let midpoint: (CGPoint, CGPoint) -> CGPoint = { a, b in
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        // 4 handles nos intervalos diagonais entre os botoes verdes.
        let configs: [(pos: CGPoint, symbol: String)] = [
            (midpoint(top, left), "arrow.up.left"),
            (midpoint(top, right), "arrow.up.right"),
            (midpoint(bottom, left), "arrow.down.left"),
            (midpoint(bottom, right), "arrow.down.right"),
        ]

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)

        for cfg in configs {
            let point = UIView()
            point.frame = CGRect(x: cfg.pos.x - touchSize / 2, y: cfg.pos.y - touchSize / 2,
                                 width: touchSize, height: touchSize)
            point.backgroundColor = .clear
            point.isUserInteractionEnabled = true

            let badge = UIView()
            badge.frame = CGRect(x: (touchSize - iconSize) / 2, y: (touchSize - iconSize) / 2,
                                 width: iconSize, height: iconSize)
            badge.backgroundColor = UIColor.white.withAlphaComponent(0.94)
            badge.layer.cornerRadius = iconSize / 2
            badge.layer.borderColor = UIColor.systemBlue.cgColor
            badge.layer.borderWidth = 2
            badge.layer.shadowColor = UIColor.black.cgColor
            badge.layer.shadowOpacity = 0.22
            badge.layer.shadowRadius = 2
            badge.layer.shadowOffset = CGSize(width: 0, height: 1)
            badge.isUserInteractionEnabled = false

            let arrow = UIImageView(image: UIImage(systemName: cfg.symbol, withConfiguration: iconConfig))
            arrow.tintColor = .systemBlue
            arrow.contentMode = .scaleAspectFit
            arrow.frame = badge.bounds.insetBy(dx: 6, dy: 6)
            arrow.isUserInteractionEnabled = false
            badge.addSubview(arrow)
            point.addSubview(badge)

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

    // MARK: - Directional Mind Map Buttons

    private func isTextElement(_ view: UIView) -> Bool {
        if view is UITextView { return true }
        return view.subviews.contains(where: { $0 is UITextView })
    }

    private func showDirectionalButtons(for view: UIView) {
        hideDirectionalButtons()
        guard isTextElement(view), let container = containerView else { return }

        directionalSourceView = view
        let frame = view.frame
        let btnSize: CGFloat = 32
        let gap: CGFloat = 16

        // Posições: cima, baixo, esquerda, direita
        let configs: [(pos: CGPoint, symbol: String, tag: Int)] = [
            (CGPoint(x: frame.midX, y: frame.minY - gap - btnSize / 2), "plus", 0),  // top
            (CGPoint(x: frame.midX, y: frame.maxY + gap + btnSize / 2), "plus", 1),  // bottom
            (CGPoint(x: frame.minX - gap - btnSize / 2, y: frame.midY), "plus", 2),  // left
            (CGPoint(x: frame.maxX + gap + btnSize / 2, y: frame.midY), "plus", 3),  // right
        ]

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)

        for cfg in configs {
            let btn = UIButton(type: .system)
            btn.setImage(UIImage(systemName: cfg.symbol, withConfiguration: iconConfig), for: .normal)
            btn.tintColor = .white
            btn.backgroundColor = UIColor.systemGreen
            btn.layer.cornerRadius = btnSize / 2
            btn.layer.shadowColor = UIColor.black.cgColor
            btn.layer.shadowOpacity = 0.25
            btn.layer.shadowRadius = 3
            btn.layer.shadowOffset = CGSize(width: 0, height: 1)
            btn.frame = CGRect(x: cfg.pos.x - btnSize / 2, y: cfg.pos.y - btnSize / 2,
                               width: btnSize, height: btnSize)
            btn.tag = cfg.tag
            btn.addTarget(self, action: #selector(directionalButtonTapped(_:)), for: .touchUpInside)

            container.addSubview(btn)
            directionalButtons.append(btn)

            // Animação de entrada
            btn.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
            btn.alpha = 0
        }

        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) { [weak self] in
            for btn in self?.directionalButtons ?? [] {
                btn.transform = .identity
                btn.alpha = 1
            }
        }
    }

    private func hideDirectionalButtons() {
        for btn in directionalButtons {
            btn.removeFromSuperview()
        }
        directionalButtons.removeAll()
        directionalSourceView = nil
    }

    @objc private func directionalButtonTapped(_ sender: UIButton) {
        guard let sourceView = directionalSourceView else { return }
        createConnectedText(from: sourceView, direction: sender.tag)
    }

    private func connectedTextFrame(from sourceView: UIView, direction: Int, size: CGSize) -> CGRect {
        pruneStaleConnections()

        let sourceFrame = sourceView.frame
        let spacing: CGFloat = 200
        let baseCenter: CGPoint

        switch direction {
        case 0: baseCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.minY - spacing)
        case 1: baseCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.maxY + spacing)
        case 2: baseCenter = CGPoint(x: sourceFrame.minX - spacing, y: sourceFrame.midY)
        case 3: baseCenter = CGPoint(x: sourceFrame.maxX + spacing, y: sourceFrame.midY)
        default: baseCenter = sourceView.center
        }

        let firstSlot = connectedChildrenCount(from: sourceView, direction: direction)
        for slot in firstSlot..<(firstSlot + 40) {
            let center = connectedTextCenter(base: baseCenter, direction: direction, slot: slot, size: size)
            let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            if isConnectedTextFrameAvailable(frame, ignoring: sourceView) {
                return frame
            }
        }

        let center = connectedTextCenter(base: baseCenter, direction: direction, slot: firstSlot, size: size)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func connectedChildrenCount(from sourceView: UIView, direction: Int) -> Int {
        connections.filter { conn in
            conn.from === sourceView && connectionDirection(from: sourceView.frame, to: conn.to.frame) == direction
        }.count
    }

    private func connectionDirection(from sourceFrame: CGRect, to targetFrame: CGRect) -> Int {
        let dx = targetFrame.midX - sourceFrame.midX
        let dy = targetFrame.midY - sourceFrame.midY

        if abs(dx) >= abs(dy) {
            return dx < 0 ? 2 : 3
        }
        return dy < 0 ? 0 : 1
    }

    private func connectedTextCenter(base: CGPoint, direction: Int, slot: Int, size: CGSize) -> CGPoint {
        let laneStep: CGFloat = (direction == 0 || direction == 1) ? size.width + 48 : size.height + 36
        let lane = (slot + 1) / 2
        let sign: CGFloat = slot == 0 ? 0 : (slot % 2 == 1 ? 1 : -1)
        let offset = CGFloat(lane) * laneStep * sign

        if direction == 0 || direction == 1 {
            return CGPoint(x: base.x + offset, y: base.y)
        }
        return CGPoint(x: base.x, y: base.y + offset)
    }

    private func isConnectedTextFrameAvailable(_ frame: CGRect, ignoring sourceView: UIView) -> Bool {
        guard let container = containerView else { return true }
        let paddedFrame = frame.insetBy(dx: -18, dy: -18)

        for (_, view) in allElementViews {
            guard view !== sourceView,
                  view.superview === container,
                  !view.isHidden,
                  view.alpha > 0.01 else { continue }

            if paddedFrame.intersects(view.frame.insetBy(dx: -8, dy: -8)) {
                return false
            }
        }
        return true
    }

    /// Cria texto conectado numa direção (0=cima, 1=baixo, 2=esquerda, 3=direita)
    private func createConnectedText(from sourceView: UIView, direction: Int) {
        guard containerView != nil else { return }

        let textSize = CGSize(width: 240, height: 60)
        let textFrame = connectedTextFrame(from: sourceView, direction: direction, size: textSize)
        let newCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)

        hideDeleteButton()
        hideConnectionPoints()
        hideDirectionalButtons()
        resignAllTextViews()

        let textView = NonZoomableTextView()
        textView.canvasCoordinator = self
        textView.text = "Toque para digitar"
        textView.font = handwritingFont
        textView.textColor = currentTextColor.withAlphaComponent(0.35)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.frame = textFrame
        textView.layer.cornerRadius = 4
        textView.isUserInteractionEnabled = true
        textView.tintColor = currentTextColor
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [:]
        textView.tag = 999
        textView.delegate = self

        addDragGestures(to: textView)
        addElementToCanvas(textView)

        let item = CanvasTextItem(text: "", position: newCenter)
        allElementViews[item.id] = textView

        createConnection(from: sourceView, to: textView)

        textView.resignBlockedUntil = Date().addingTimeInterval(1.5)
        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
    }

    /// Atalho de teclado: cria texto conectado na direção (chamado pelo ContentView)
    func createConnectedTextFromSelected(direction: Int) {
        guard let target = deleteTargetView, isTextElement(target) else { return }
        createConnectedText(from: target, direction: direction)
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
            hideDirectionalButtons()

        case .cancelled, .failed:
            connectionPreviewLayer?.removeFromSuperlayer()
            connectionPreviewLayer = nil
            hideConnectionPoints()
            hideDirectionalButtons()

        default: break
        }
    }

    private func createConnection(from: UIView, to: UIView) {
        guard let container = containerView else { return }
        pruneStaleConnections()

        // Checar se já existe essa conexão
        if connections.contains(where: { $0.from === from && $0.to === to }) { return }

        let layer = CAShapeLayer()
        layer.name = Self.connectionLayerName
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
        pruneStaleConnections()
        for conn in connections {
            updateConnectionArrow(from: conn.from, to: conn.to, layer: conn.layer)
        }
    }

    private func pruneStaleConnections() {
        guard let container = containerView else { return }
        connections.removeAll { conn in
            let isStale = conn.from.superview !== container ||
                conn.to.superview !== container ||
                conn.layer.superlayer == nil
            if isStale {
                conn.layer.removeFromSuperlayer()
            }
            return isStale
        }
    }

    private func clearConnections() {
        for conn in connections {
            conn.layer.removeFromSuperlayer()
        }
        connections.removeAll()

        containerView?.layer.sublayers?
            .filter { $0.name == Self.connectionLayerName }
            .forEach { $0.removeFromSuperlayer() }
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
            if sibling === activeDeleteButton || sibling === activeHighlightButton { continue }
            if connectionPoints.contains(sibling) { continue }
            if directionalButtons.contains(where: { $0 === sibling }) { continue }
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
            showSelectionUI(for: element)
        } else {
            // Checar se tocou numa seta
            if handleTapOnConnection(at: point) { return }
            // Tap em área vazia — deselecionar tudo
            dismissFloatingEditMenu()
            if !selectedViews.isEmpty { clearSelection() }
            hideDeleteButton()
            hideConnectionPoints()
            hideDirectionalButtons()
            // Resign text editing
            resignAllTextViews()
        }
    }

    @objc private func handleFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let container = containerView else { return }
        let point = gesture.location(in: container)

        if let element = findElement(at: point), isTextElement(element) {
            bringElementToFront(element)
            hideConnectionPoints()
            hideDirectionalButtons()
            activateTextEditing(in: element)
        }
    }

    @objc private func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView else { return }

        switch gesture.state {
        case .began:
            hideDeleteButton()
            hideConnectionPoints()
            hideDirectionalButtons()
            let point = gesture.location(in: container)
            activeDragElement = findElement(at: point)
            if let el = activeDragElement {
                if !selectedViews.isEmpty || selectionBox != nil {
                    clearSelection()
                }
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
            let movedElement = activeDragElement
            movedElement?.layer.shadowOpacity = 0
            activeDragElement = nil
            if movedElement != nil {
                if let movedElement = movedElement, isResizableImageElement(movedElement) {
                    showResizeHandles(for: movedElement)
                }
                saveProject()
            }
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
        dismissFloatingEditMenu()
        guard let container = containerView else { return }
        for view in container.subviews where view !== canvasView {
            if let tv = view as? NonZoomableTextView {
                tv.resignBlockedUntil = .distantPast
                tv.resignFirstResponder()
            }
            for sub in view.subviews {
                if let tv = sub as? NonZoomableTextView {
                    tv.resignBlockedUntil = .distantPast
                    tv.resignFirstResponder()
                }
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
        hideDeleteButton()
        hideConnectionPoints()
        hideDirectionalButtons()
        showResizeHandles(for: imageView)
    }

    // MARK: - Text (handwriting font)

    func addText(at position: CGPoint? = nil) {
        guard let container = containerView else { return }
        let pos = position ?? visibleCenter()

        let textView = NonZoomableTextView()
        textView.canvasCoordinator = self

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
        textView.canvasCoordinator = self

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

    func addMarkdownCard(color: MarkdownCardColor = .blue, at position: CGPoint? = nil) {
        guard containerView != nil else { return }
        let pos = position ?? visibleCenter()
        let card = makeMarkdownCard(
            markdown: "",
            color: color,
            frame: CGRect(x: pos.x - 180, y: pos.y - 120, width: 360, height: 240)
        )

        addDragGestures(to: card)
        addElementToCanvas(card)
        allElementViews[UUID()] = card

        DispatchQueue.main.async {
            card.textView.becomeFirstResponder()
        }
    }

    private func makeMarkdownCard(markdown: String, color: MarkdownCardColor, frame: CGRect) -> MarkdownCardView {
        let card = MarkdownCardView(color: color)
        card.frame = frame
        card.textView.canvasCoordinator = self
        card.textView.delegate = self
        card.setMarkdown(markdown, textColor: currentTextColor)
        return card
    }

    func addPostIt(color: PostItColor = .yellow, at position: CGPoint? = nil) {
        addMarkdownCard(color: MarkdownCardColor(from: color), at: position)
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
        textView.canvasCoordinator = self

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

    @discardableResult
    private func addAudioPlayer(url: URL, duration: TimeInterval, at position: CGPoint? = nil, elementId: String? = nil) -> UIView? {
        guard containerView != nil else { return nil }
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
        let resolvedId = ensureElementID(for: playerView, preferred: elementId ?? item.id.uuidString)
        allElementViews[uuidKey(for: resolvedId)] = playerView
        return playerView
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
        var contentBounds = drawing.bounds

        for (_, view) in imageViews {
            contentBounds = contentBounds.union(view.frame)
        }

        // Posição: centro do conteúdo existente, ou centro da tela visível
        let center: CGPoint
        if contentBounds.isEmpty {
            guard let scroll = scrollView else { return }
            let zoomScale = scroll.zoomScale
            center = CGPoint(
                x: scroll.contentOffset.x / zoomScale + scroll.bounds.width / zoomScale / 2,
                y: scroll.contentOffset.y / zoomScale + scroll.bounds.height / zoomScale / 2
            )
        } else {
            // Posicionar à direita do conteúdo existente
            center = CGPoint(x: contentBounds.maxX + 40, y: contentBounds.midY)
        }

        // Tamanho: proporcional à imagem real, limitado a 600pt
        let imgSize = resultImage.size
        let maxSide: CGFloat = 600
        let scale = min(maxSide / imgSize.width, maxSide / imgSize.height, 1.0)
        let w = imgSize.width * scale
        let h = imgSize.height * scale

        let item = CanvasImageItem(image: resultImage, position: center)

        let imageView = UIImageView(image: resultImage)
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: center.x, y: center.y - h / 2, width: w, height: h)
        imageView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        imageView.layer.borderWidth = 1.5
        imageView.layer.cornerRadius = 4

        addDragGestures(to: imageView)
        addElementToCanvas(imageView)
        imageViews[item.id] = imageView
        allElementViews[item.id] = imageView
        state.images.append(item)
        hideDeleteButton()
        hideConnectionPoints()
        hideDirectionalButtons()
        showResizeHandles(for: imageView)

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

            if let card = sibling as? MarkdownCardView {
                card.updateMarkdownFromEditor()
                let text = card.rawMarkdown
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    elements.append(GeminiService.TextElement(index: index, text: text, type: "markdown"))
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

            if let card = sibling as? MarkdownCardView {
                card.updateMarkdownFromEditor()
                let text = card.rawMarkdown
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let corrected = corrections[index] {
                        card.setMarkdown(corrected, textColor: currentTextColor)
                        flashGreen(card)
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
        var savedElementViews: [(view: UIView, id: String)] = []
        var fileIndex = 0

        for sibling in container.subviews {
            if sibling === canvas || sibling === lassoOverlay || sibling === selectionBox { continue }
            if sibling === activeDeleteButton || sibling === activeHighlightButton { continue }
            if connectionPoints.contains(sibling) { continue }
            if directionalButtons.contains(where: { $0 === sibling }) { continue }
            if sibling.alpha <= 0 || sibling.isHidden { continue }

            let hl = highlightColorName(for: sibling)
            let done = completionColorName(for: sibling)
            let doneStyle = completionStyleName(for: sibling)
            let elementId = ensureElementID(for: sibling)

            if let tv = sibling as? UITextView {
                let text = (tv.tag == Self.placeholderTag) ? "" : (tv.text ?? "")
                elements.append(CanvasElement(id: elementId, type: .text, text: text, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, highlightColor: hl, completionColor: done, completionStyle: doneStyle))
                savedElementViews.append((sibling, elementId))
                continue
            }

            if let card = sibling as? MarkdownCardView {
                card.updateMarkdownFromEditor()
                elements.append(CanvasElement(id: elementId, type: .markdownCard, text: card.rawMarkdown, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, cardColor: card.cardColor, highlightColor: hl, completionColor: done, completionStyle: doneStyle))
                savedElementViews.append((sibling, elementId))
                continue
            }

            if let bgColor = sibling.backgroundColor,
               sibling.subviews.contains(where: { $0 is UITextView }) {
                let textView = sibling.subviews.compactMap { $0 as? UITextView }.first
                let text = (textView?.tag == Self.placeholderTag) ? "" : (textView?.text ?? "")
                let color = PostItColor.from(uiColor: bgColor)
                let rotation = atan2(sibling.transform.b, sibling.transform.a)
                elements.append(CanvasElement(id: elementId, type: .postit, text: text, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.bounds.width, height: sibling.bounds.height, color: color, rotation: rotation, highlightColor: hl, completionColor: done, completionStyle: doneStyle))
                savedElementViews.append((sibling, elementId))
                continue
            }

            if let imgView = sibling as? UIImageView, let image = imgView.image {
                let filename = "img_\(fileIndex).jpg"
                fileIndex += 1
                StorageService.saveImage(image, named: filename, canvasId: projectId)
                elements.append(CanvasElement(id: elementId, type: sibling.tag == 888 ? .strokeGroup : .image, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, file: filename, highlightColor: hl, completionColor: done, completionStyle: doneStyle))
                savedElementViews.append((sibling, elementId))
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
                    elements.append(CanvasElement(id: elementId, type: .audio, x: sibling.frame.origin.x, y: sibling.frame.origin.y, width: sibling.frame.width, height: sibling.frame.height, file: filename, duration: duration, highlightColor: hl, completionColor: done, completionStyle: doneStyle))
                    savedElementViews.append((sibling, elementId))
                }
                continue
            }
        }

        var viewToIndex: [ObjectIdentifier: Int] = [:]
        var viewToId: [ObjectIdentifier: String] = [:]
        for (index, item) in savedElementViews.enumerated() {
            let key = ObjectIdentifier(item.view)
            viewToIndex[key] = index
            viewToId[key] = item.id
        }

        var connectionData: [CanvasConnectionData] = []
        for conn in connections {
            let fromKey = ObjectIdentifier(conn.from)
            let toKey = ObjectIdentifier(conn.to)
            if let fromIdx = viewToIndex[fromKey],
               let toIdx = viewToIndex[toKey] {
                connectionData.append(CanvasConnectionData(
                    fromIndex: fromIdx,
                    toIndex: toIdx,
                    fromId: viewToId[fromKey],
                    toId: viewToId[toKey]
                ))
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
        let localDoc = StorageService.loadDocument(id: projectId)
        if let localDoc {
            restoreDocument(localDoc)
        }

        // Then fetch from cloud, but never replace a newer local edit with stale cloud data.
        Task {
            if let cloudDoc = await SyncService.loadDocument(id: projectId) {
                await MainActor.run {
                    if let newestLocal = StorageService.loadDocument(id: projectId),
                       newestLocal.updatedAt > cloudDoc.updatedAt {
                        restoreDocument(newestLocal)
                    } else {
                        restoreDocument(cloudDoc)
                    }
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

        // Limpar elementos e setas existentes antes de restaurar.
        // O load usa cache local e depois nuvem; sem limpar as layers antigas,
        // as mesmas conexões ficam duplicadas e reaparecem ao mover elementos.
        clearConnections()
        hideConnectionPoints()
        hideDirectionalButtons()
        hideDeleteButton()
        for (_, view) in allElementViews {
            view.removeFromSuperview()
        }
        allElementViews.removeAll()
        imageViews.removeAll()

        // Índices mantêm compatibilidade com projetos antigos; IDs preservam a conexão exata.
        var loadedViews: [UIView?] = []
        var loadedViewsById: [String: UIView] = [:]

        func registerLoadedView(_ view: UIView, from element: CanvasElement) -> (id: String, key: UUID) {
            let id = ensureElementID(for: view, preferred: element.id)
            let key = uuidKey(for: id)
            loadedViewsById[id] = view
            allElementViews[key] = view
            return (id, key)
        }

        // Recriar elementos
        for element in doc.elements {
            let pos = CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)

            switch element.type {
            case .text:
                let textView = NonZoomableTextView()
                textView.canvasCoordinator = self

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
                    // Auto-resize para caber o texto
                    let newSize = textView.sizeThatFits(CGSize(width: textView.frame.width, height: .greatestFiniteMagnitude))
                    if newSize.height > textView.frame.height {
                        var f = textView.frame
                        f.size.height = newSize.height + 8
                        textView.frame = f
                    }
                } else {
                    textView.text = "Toque para digitar"
                    textView.textColor = currentTextColor.withAlphaComponent(0.35)
                    textView.tag = Self.placeholderTag
                }

                addDragGestures(to: textView)
                addElementToCanvas(textView)
                _ = registerLoadedView(textView, from: element)
                restoreVisualMarks(to: textView, from: element)
                loadedViews.append(textView)

            case .markdownCard:
                let color = element.cardColor ?? .crystal
                let card = makeMarkdownCard(
                    markdown: element.text ?? "",
                    color: color,
                    frame: CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
                )
                addDragGestures(to: card)
                addElementToCanvas(card)
                _ = registerLoadedView(card, from: element)
                restoreVisualMarks(to: card, from: element)
                loadedViews.append(card)

            case .postit:
                let color = element.color.map { MarkdownCardColor(from: $0) } ?? .amber
                let card = makeMarkdownCard(
                    markdown: element.text ?? "",
                    color: color,
                    frame: CGRect(x: element.x, y: element.y, width: max(element.width, 280), height: max(element.height, 220))
                )
                addDragGestures(to: card)
                addElementToCanvas(card)
                _ = registerLoadedView(card, from: element)
                restoreVisualMarks(to: card, from: element)
                loadedViews.append(card)

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
                let registered = registerLoadedView(imgView, from: element)
                if element.type == .image {
                    imageViews[registered.key] = imgView
                }
                restoreVisualMarks(to: imgView, from: element)
                loadedViews.append(imgView)

            case .audio:
                guard let filename = element.file else {
                    loadedViews.append(nil)
                    continue
                }
                let url = StorageService.audioFileURL(named: filename, canvasId: projectId)
                let duration = element.duration ?? 0
                if let playerView = addAudioPlayer(url: url, duration: duration, at: pos, elementId: element.id) {
                    let id = ensureElementID(for: playerView, preferred: element.id)
                    loadedViewsById[id] = playerView
                    loadedViews.append(playerView)
                } else {
                    loadedViews.append(nil)
                }
            }
        }

        // Restaurar conexões
        if let connData = doc.connections {
            for conn in connData {
                let idConnection: (UIView, UIView)? = {
                    guard let fromId = conn.fromId,
                          let toId = conn.toId,
                          let fromView = loadedViewsById[fromId],
                          let toView = loadedViewsById[toId] else { return nil }
                    return (fromView, toView)
                }()

                let indexConnection: (UIView, UIView)? = {
                    guard conn.fromIndex < loadedViews.count,
                          conn.toIndex < loadedViews.count,
                          let fromView = loadedViews[conn.fromIndex],
                          let toView = loadedViews[conn.toIndex] else { return nil }
                    return (fromView, toView)
                }()

                guard let (fromView, toView) = idConnection ?? indexConnection else { continue }
                createConnection(from: fromView, to: toView)
            }
        }

        centerViewportOnLoadedContent(from: doc)
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

extension MarkdownCardColor {
    init(from postItColor: PostItColor) {
        switch postItColor {
        case .yellow:
            self = .amber
        case .green:
            self = .green
        case .pink:
            self = .pink
        case .blue, .purple:
            self = .blue
        }
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
        if let card = markdownCard(containing: textView) {
            card.beginMarkdownEditing(textColor: currentTextColor)
            return
        }

        if textView.tag == Self.placeholderTag {
            textView.text = ""
            let color = isInsidePostIt(textView) ? postItTextColor : currentTextColor
            textView.textColor = color
            textView.tag = 0
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        if let card = markdownCard(containing: textView) {
            card.updateMarkdownFromEditor()
            let fixedWidth = textView.frame.width
            let newSize = textView.sizeThatFits(CGSize(width: fixedWidth, height: .greatestFiniteMagnitude))
            let neededHeight = max(newSize.height + 36, 220)
            if neededHeight > card.frame.height + 2 {
                var frame = card.frame
                frame.size.height = neededHeight
                card.frame = frame
                card.setNeedsLayout()
                updateAllConnections()
            }
            return
        }

        let fixedWidth = textView.frame.width
        let newSize = textView.sizeThatFits(CGSize(width: fixedWidth, height: .greatestFiniteMagnitude))
        let newHeight = max(newSize.height, 40)

        if isInsidePostIt(textView) {
            // Post-it: expandir o post-it pai
            guard let postIt = textView.superview else { return }
            let padding: CGFloat = 12
            let minHeight: CGFloat = 200
            let neededHeight = max(newHeight + padding * 2, minHeight)
            if abs(postIt.frame.height - neededHeight) > 2 {
                var frame = postIt.frame
                frame.size.height = neededHeight
                postIt.frame = frame
                textView.frame = postIt.bounds.insetBy(dx: padding, dy: padding)
            }
        } else {
            // Texto avulso: expandir a textView
            let minHeight: CGFloat = 40
            let targetHeight = max(newHeight + 8, minHeight)
            if abs(textView.frame.height - targetHeight) > 2 {
                var frame = textView.frame
                frame.size.height = targetHeight
                textView.frame = frame
            }
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if let card = markdownCard(containing: textView) {
            card.updateMarkdownFromEditor()
            card.renderMarkdown(textColor: currentTextColor)
            return
        }

        if textView.text.isEmpty {
            textView.text = "Toque para digitar"
            let color = isInsidePostIt(textView) ? postItTextColor : currentTextColor
            textView.textColor = color.withAlphaComponent(0.35)
            textView.tag = Self.placeholderTag
        }
    }

    private func markdownCard(containing textView: UITextView) -> MarkdownCardView? {
        var view = textView.superview
        while let current = view {
            if let card = current as? MarkdownCardView { return card }
            view = current.superview
        }
        return nil
    }

    private func isInsidePostIt(_ view: UIView) -> Bool {
        guard let parent = view.superview else { return false }
        if let bg = parent.backgroundColor {
            return PostItColor.allCases.contains(where: { $0.uiColor == bg })
        }
        return false
    }
}
