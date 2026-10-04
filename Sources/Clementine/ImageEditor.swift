import AppKit
import CoreImage

enum EditorMode {
    case crop, adjust, annotate, redact

    var title: String {
        switch self {
        case .crop: return "Crop"
        case .adjust: return "Adjust"
        case .annotate: return "Annotate"
        case .redact: return "Redact"
        }
    }

    var suffix: String {
        switch self {
        case .crop: return "cropped"
        case .adjust: return "adjusted"
        case .annotate: return "annotated"
        case .redact: return "redacted"
        }
    }
}

/// A small window for cropping, adjusting, annotating or redacting one image. Saves a copy beside the original.
final class ImageEditor: NSWindowController, NSWindowDelegate {
    private static var openEditors: [ImageEditor] = []

    private let url: URL
    private let mode: EditorMode
    private let canvas: EditorCanvas
    private var sliders: [NSSlider] = []

    static func open(_ url: URL, mode: EditorMode) {
        if Runtime.isCLI {
            FileHandle.standardError.write(Data("\(mode.title) is interactive and needs the app.\n".utf8))
            JobRunner.cliFailures += 1
            return
        }
        do {
            let image = try ImageTools.load(url)
            let editor = ImageEditor(url: url, image: image, mode: mode)
            openEditors.append(editor)
            NSApp.activate(ignoringOtherApps: true)
            editor.showWindow(nil)
            editor.window?.makeKeyAndOrderFront(nil)
        } catch {
            Prompt.info("Couldn't open the image", error.localizedDescription)
        }
    }

    private init(url: URL, image: CGImage, mode: EditorMode) {
        self.url = url
        self.mode = mode
        canvas = EditorCanvas(image: image, mode: mode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(mode.title) — \(url.lastPathComponent)"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let bar = makeToolbar()
        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 30),
        ])
        window.contentView = root
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }

    private func makeToolbar() -> NSStackView {
        var views: [NSView] = []
        switch mode {
        case .crop:
            let aspect = NSSegmentedControl(labels: ["Free", "1:1", "4:3", "3:2", "16:9", "9:16"], trackingMode: .selectOne,
                                            target: self, action: #selector(aspectChanged(_:)))
            aspect.selectedSegment = 0
            views = [aspect, hint("Drag on the image to choose the area")]
        case .annotate:
            let tools = NSSegmentedControl(labels: ["Pen", "Box", "Arrow", "Text"], trackingMode: .selectOne,
                                           target: self, action: #selector(toolChanged(_:)))
            tools.selectedSegment = 0
            let well = NSColorWell()
            well.color = .systemRed
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([well.widthAnchor.constraint(equalToConstant: 44), well.heightAnchor.constraint(equalToConstant: 24)])
            views = [tools, well, button("Undo", #selector(undo))]
        case .redact:
            let style = NSSegmentedControl(labels: ["Black Box", "Pixelate"], trackingMode: .selectOne,
                                           target: self, action: #selector(redactStyleChanged(_:)))
            style.selectedSegment = 0
            views = [style, button("Undo", #selector(undo)), hint("Drag over anything you want hidden")]
        case .adjust:
            views = [
                slider("Brightness", min: -0.4, max: 0.4, value: 0, tag: 0),
                slider("Contrast", min: 0.5, max: 1.5, value: 1, tag: 1),
                slider("Saturation", min: 0, max: 2, value: 1, tag: 2),
                button("↺", #selector(rotateLeft)),
                button("↻", #selector(rotateRight)),
                button("Reset", #selector(resetAdjustments)),
            ]
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancel = button("Cancel", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save Copy", #selector(save))
        save.keyEquivalent = "\r"
        let stack = NSStackView(views: views + [spacer, cancel, save])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func slider(_ title: String, min: Double, max: Double, value: Double, tag: Int) -> NSView {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
        s.tag = tag
        s.isContinuous = true
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 110).isActive = true
        sliders.append(s)
        let stack = NSStackView(views: [NSTextField(labelWithString: title), s])
        stack.spacing = 4
        return stack
    }

    @objc private func aspectChanged(_ sender: NSSegmentedControl) {
        let ratios: [CGFloat?] = [nil, 1, 4.0 / 3, 3.0 / 2, 16.0 / 9, 9.0 / 16]
        canvas.aspect = ratios[sender.selectedSegment]
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.tool = AnnotationTool(rawValue: sender.selectedSegment) ?? .pen
    }

    @objc private func colorChanged(_ sender: NSColorWell) { canvas.color = sender.color }
    @objc private func redactStyleChanged(_ sender: NSSegmentedControl) { canvas.pixelate = sender.selectedSegment == 1 }
    @objc private func undo() { canvas.undo() }
    @objc private func rotateLeft() { canvas.rotate(clockwise: false) }
    @objc private func rotateRight() { canvas.rotate(clockwise: true) }

    @objc private func sliderChanged(_ sender: NSSlider) {
        switch sender.tag {
        case 0: canvas.brightness = sender.doubleValue
        case 1: canvas.contrast = sender.doubleValue
        default: canvas.saturation = sender.doubleValue
        }
        canvas.refreshAdjusted()
    }

    @objc private func resetAdjustments() {
        canvas.brightness = 0
        canvas.contrast = 1
        canvas.saturation = 1
        for s in sliders { s.doubleValue = s.tag == 0 ? 0 : 1 }
        canvas.refreshAdjusted()
    }

    @objc private func cancel() { window?.close() }

    @objc private func save() {
        guard let output = canvas.renderOutput() else {
            NSSound.beep()
            return
        }
        let source = url, mode = self.mode
        window?.close()
        JobRunner.run(mode.title, detail: source.lastPathComponent) { ctx in
            let format = ImageTools.sameFormat(source)
            let out = Output.url(for: source, ext: format.ext, suffix: mode.suffix)
            let metadata = mode == .redact ? [:] : ImageTools.metadata(source)
            return [try producing(out) { try ImageTools.write(output, to: out, format: format, quality: 0.92, metadata: metadata, ctx: ctx) }]
        }
    }
}

enum AnnotationTool: Int { case pen, box, arrow, text }

enum Mark {
    case pen([CGPoint], NSColor, CGFloat)
    case box(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
    case redact(CGRect, Bool)
}

/// Shows the image fitted in the view; all marks are stored in image pixel coordinates.
final class EditorCanvas: NSView {
    let mode: EditorMode
    private(set) var source: CGImage
    private var previewBase: CGImage
    private var previewAdjusted: CGImage?
    private var marks: [Mark] = []
    private var current: Mark?
    private var dragStart: CGPoint?
    private var cropRect: CGRect?
    private let ciContext = CIContext()

    var aspect: CGFloat?
    var tool: AnnotationTool = .pen
    var color: NSColor = .systemRed
    var pixelate = false
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0

    init(image: CGImage, mode: EditorMode) {
        self.source = image
        self.mode = mode
        self.previewBase = ImageTools.downscaled(image, maxSide: 1600)
        super.init(frame: .zero)
        if mode == .adjust { previewAdjusted = previewBase }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageSize: CGSize { CGSize(width: source.width, height: source.height) }

    private var fitRect: CGRect {
        let area = bounds.insetBy(dx: 20, dy: 20)
        guard area.width > 0, area.height > 0 else { return .zero }
        let s = min(area.width / imageSize.width, area.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    private var viewScale: CGFloat { max(fitRect.width / imageSize.width, 0.0001) }
    private var strokeWidth: CGFloat { max(3, max(imageSize.width, imageSize.height) / 250) }

    private func toImage(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let r = fitRect, s = viewScale
        return CGPoint(x: min(max((p.x - r.minX) / s, 0), imageSize.width),
                       y: min(max((p.y - r.minY) / s, 0), imageSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = fitRect
        ctx.interpolationQuality = .high
        ctx.draw(mode == .adjust ? (previewAdjusted ?? previewBase) : source, in: r)

        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        drawMarks(marks + (current.map { [$0] } ?? []), in: ctx)
        ctx.restoreGState()

        if mode == .crop, let c = cropRect, c.width > 0, c.height > 0 {
            let s = viewScale
            let vr = CGRect(x: r.minX + c.minX * s, y: r.minY + c.minY * s, width: c.width * s, height: c.height * s)
            let dim = NSBezierPath(rect: r)
            dim.append(NSBezierPath(rect: vr))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            let border = NSBezierPath(rect: vr)
            border.lineWidth = 1.5
            border.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()
            let label = NSAttributedString(string: " \(Int(c.width)) × \(Int(c.height)) ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6),
            ])
            label.draw(at: NSPoint(x: vr.minX + 4, y: vr.maxY + 4))
        }
    }

    private func drawMarks(_ marks: [Mark], in ctx: CGContext) {
        for mark in marks {
            switch mark {
            case .pen(let points, let color, let width):
                guard let first = points.first else { continue }
                let path = NSBezierPath()
                path.move(to: first)
                points.dropFirst().forEach { path.line(to: $0) }
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                color.setStroke()
                path.stroke()
            case .box(let rect, let color, let width):
                let path = NSBezierPath(rect: rect)
                path.lineWidth = width
                color.setStroke()
                path.stroke()
            case .arrow(let a, let b, let color, let width):
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x), head = width * 5
                for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                    path.move(to: b)
                    path.line(to: CGPoint(x: b.x + head * cos(angle + offset), y: b.y + head * sin(angle + offset)))
                }
                path.lineWidth = width
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
            case .text(let string, let point, let color, let size):
                NSAttributedString(string: string, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: color,
                ]).draw(at: point)
            case .redact(let rect, let pixelated):
                if pixelated, let result = pixelate(rect) {
                    ctx.draw(result.image, in: result.area)
                } else {
                    NSColor.black.setFill()
                    NSBezierPath(rect: rect).fill()
                }
            }
        }
    }

    private func pixelate(_ rect: CGRect) -> (image: CGImage, area: CGRect)? {
        let area = rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard area.width >= 1, area.height >= 1, let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: source).clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(8, max(area.width, area.height) / 10), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: area.minX, y: area.minY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: area),
              let image = ciContext.createCGImage(output, from: area) else { return nil }
        return (image, area)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = toImage(event)
        dragStart = p
        switch mode {
        case .crop: cropRect = CGRect(origin: p, size: .zero)
        case .redact: current = .redact(CGRect(origin: p, size: .zero), pixelate)
        case .annotate:
            switch tool {
            case .pen: current = .pen([p], color, strokeWidth)
            case .box: current = .box(CGRect(origin: p, size: .zero), color, strokeWidth)
            case .arrow: current = .arrow(p, p, color, strokeWidth)
            case .text: break
            }
        case .adjust: break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = toImage(event)
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        switch mode {
        case .crop:
            cropRect = constrained(from: start, to: p)
        case .redact:
            current = .redact(rect, pixelate)
        case .annotate:
            switch current {
            case .pen(var points, let c, let w)?:
                points.append(p)
                current = .pen(points, c, w)
            case .box(_, let c, let w)?:
                current = .box(rect, c, w)
            case .arrow(let a, _, let c, let w)?:
                current = .arrow(a, p, c, w)
            default:
                break
            }
        case .adjust:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .annotate, tool == .text, let p = dragStart {
            if let text = Prompt.text("Add Text", "What should it say?"), !text.isEmpty {
                marks.append(.text(text, p, color, strokeWidth * 7))
            }
        } else if let mark = current, isMeaningful(mark) {
            marks.append(mark)
        }
        current = nil
        dragStart = nil
        needsDisplay = true
    }

    private func isMeaningful(_ mark: Mark) -> Bool {
        switch mark {
        case .box(let r, _, _), .redact(let r, _): return r.width > 2 && r.height > 2
        case .arrow(let a, let b, _, _): return hypot(b.x - a.x, b.y - a.y) > 4
        default: return true
        }
    }

    private func constrained(from a: CGPoint, to b: CGPoint) -> CGRect {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let ratio = aspect {
            if w / max(h, 1) > ratio { w = h * ratio } else { h = w / ratio }
        }
        let x = b.x >= a.x ? a.x : a.x - w
        let y = b.y >= a.y ? a.y : a.y - h
        return CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: imageSize))
    }

    // MARK: Editing

    func undo() {
        if !marks.isEmpty { marks.removeLast() }
        needsDisplay = true
    }

    func rotate(clockwise: Bool) {
        source = ImageTools.rotated(source, clockwise: clockwise)
        previewBase = ImageTools.rotated(previewBase, clockwise: clockwise)
        refreshAdjusted()
    }

    func refreshAdjusted() {
        previewAdjusted = adjusted(previewBase)
        needsDisplay = true
    }

    private func adjusted(_ image: CGImage) -> CGImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        let input = CIImage(cgImage: image)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return image }
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// The full-resolution result, or nil if there's nothing to save yet.
    func renderOutput() -> CGImage? {
        switch mode {
        case .crop:
            guard let c = cropRect?.integral, c.width >= 2, c.height >= 2 else { return nil }
            // CGImage cropping uses a top-left origin.
            return source.cropping(to: CGRect(x: c.minX, y: imageSize.height - c.maxY, width: c.width, height: c.height))
        case .adjust:
            return adjusted(source)
        case .annotate, .redact:
            guard !marks.isEmpty, let ctx = ImageTools.context(source.width, source.height) else { return nil }
            ctx.draw(source, in: CGRect(origin: .zero, size: imageSize))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            drawMarks(marks, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
    }
}
