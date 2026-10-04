import AppKit
import QuickLookThumbnailing

enum WheelInteraction {
    /// Shown during a Finder drag: drop a file on a slice.
    case drag
    /// Shown from the menu: click a slice.
    case click
}

/// Owns the floating wheel panel.
final class WheelController {
    private var panel: WheelPanel?
    private var view: WheelView?
    private var files: [URL] = []
    private var interaction: WheelInteraction = .drag
    private var generation = 0
    private var monitors: [Any] = []

    var isVisible: Bool { panel != nil }

    func show(files: [URL], mode: WheelMode, at point: NSPoint, interaction: WheelInteraction) {
        hide()
        generation += 1
        self.files = files
        self.interaction = interaction

        let view = WheelView(files: files)
        view.onSelect = { [weak self] action in self?.perform(action) }
        view.onCancel = { [weak self] in self?.hide() }
        view.configure(actions: ActionCatalog.actions(for: files, mode: mode), mode: mode)

        let size = view.preferredSize
        let panel = WheelPanel(size: size)
        panel.contentView = view
        panel.setFrameOrigin(origin(centeredAt: point, size: size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        self.view = view

        if interaction == .click {
            panel.makeKey()
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.hide() }) {
                monitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
                if event.keyCode == 53 { self?.hide(); return nil }
                return event
            }) {
                monitors.append(m)
            }
        }
    }

    func switchMode(_ mode: WheelMode) {
        guard let panel, let view else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        view.configure(actions: ActionCatalog.actions(for: files, mode: mode), mode: mode)
        let size = view.preferredSize
        panel.setFrame(NSRect(origin: origin(centeredAt: center, size: size), size: size), display: true)
    }

    /// Called when the mouse button goes up after a drag; the drop (if any) has been delivered by then or shortly after.
    func dragEnded() {
        guard interaction == .drag else { return }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        guard let panel else { return }
        self.panel = nil
        self.view = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func perform(_ action: WheelAction) {
        let files = self.files
        hide()
        // Let the drag session finish before any prompt opens.
        DispatchQueue.main.async { action.perform(files) }
    }

    private func origin(centeredAt point: NSPoint, size: NSSize) -> NSPoint {
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        return origin
    }
}

final class WheelPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
}

/// The radial menu: a ring of slices around a preview of the dragged file(s).
final class WheelView: NSView {
    var onSelect: ((WheelAction) -> Void)?
    var onCancel: (() -> Void)?

    private let files: [URL]
    private var actions: [WheelAction] = []
    private var mode: WheelMode = .convert
    private var thumbnail: NSImage?
    private let sizeText: String
    private var trackingArea: NSTrackingArea?
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            if hovered != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    static let innerRadius: CGFloat = 58
    private var outerRadius: CGFloat { max(150, 64 + CGFloat(actions.count) * 13) }
    var preferredSize: NSSize { let d = (outerRadius + 28) * 2; return NSSize(width: d, height: d) }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    init(files: [URL]) {
        self.files = files
        if files.count == 1 {
            sizeText = files[0].isDirectory ? "Folder" : formatBytes(fileSize(files[0]))
        } else {
            sizeText = "\(files.count) files"
        }
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        loadThumbnail()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(actions: [WheelAction], mode: WheelMode) {
        self.actions = actions
        self.mode = mode
        hovered = nil
        needsDisplay = true
    }

    private func loadThumbnail() {
        guard let first = files.first else { return }
        thumbnail = NSWorkspace.shared.icon(forFile: first.path)
        let request = QLThumbnailGenerator.Request(fileAt: first, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                self?.thumbnail = image
                self?.needsDisplay = true
            }
        }
    }

    // MARK: Geometry

    private var step: CGFloat { 360 / CGFloat(max(actions.count, 1)) }

    /// Slice `i` is centred at 12 o'clock and continues clockwise.
    private func midAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * step }

    private func index(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard !actions.isEmpty, distance > Self.innerRadius, distance < outerRadius + 40 else { return nil }
        var clockwise = 90 - atan2(dy, dx) * 180 / .pi
        clockwise = clockwise.truncatingRemainder(dividingBy: 360)
        if clockwise < 0 { clockwise += 360 }
        return Int((clockwise + step / 2) / step) % actions.count
    }

    private func slicePath(_ i: Int) -> NSBezierPath {
        let r0 = Self.innerRadius + 4, r1 = outerRadius
        let gap: CGFloat = 2.5
        let outerGap = gap / r1 * 180 / .pi, innerGap = gap / r0 * 180 / .pi
        let start = midAngle(i) - step / 2, end = midAngle(i) + step / 2
        let path = NSBezierPath()
        if actions.count == 1 {
            path.appendOval(in: NSRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
            path.appendOval(in: NSRect(x: center.x - r0, y: center.y - r0, width: r0 * 2, height: r0 * 2))
            path.windingRule = .evenOdd
            return path
        }
        path.appendArc(withCenter: center, radius: r1, startAngle: start + outerGap, endAngle: end - outerGap, clockwise: false)
        path.appendArc(withCenter: center, radius: r0, startAngle: end - innerGap, endAngle: start + innerGap, clockwise: true)
        path.close()
        return path
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r1 = outerRadius

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        (dark ? NSColor(white: 0.1, alpha: 0.8) : NSColor(white: 1, alpha: 0.6)).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r1 - 5, y: center.y - r1 - 5, width: (r1 + 5) * 2, height: (r1 + 5) * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let base = dark ? NSColor(srgbRed: 0.24, green: 0.2, blue: 0.18, alpha: 0.96) : NSColor(srgbRed: 1, green: 0.94, blue: 0.9, alpha: 0.97)
        let hot = NSGradient(starting: NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1),
                             ending: NSColor(srgbRed: 0.98, green: 0.4, blue: 0.12, alpha: 1))!
        let labelRadius = (Self.innerRadius + r1) / 2 + 4
        let chord = 2 * labelRadius * sin(step / 2 * .pi / 180)
        let labelWidth = min(chord * 0.86, (r1 - Self.innerRadius) * 1.05)

        for (i, action) in actions.enumerated() {
            let path = slicePath(i)
            let isHot = hovered == i
            if isHot { hot.draw(in: path, angle: -90) } else { base.setFill(); path.fill() }
            let angle = midAngle(i) * .pi / 180
            let point = NSPoint(x: center.x + labelRadius * cos(angle), y: center.y + labelRadius * sin(angle))
            drawLabel(action, at: point, width: actions.count == 1 ? 140 : labelWidth, color: isHot ? .white : (dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.2, alpha: 1)))
        }

        drawCenter(dark: dark)
    }

    private func drawLabel(_ action: WheelAction, at point: NSPoint, width: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let fontSize: CGFloat = action.symbol == nil ? (action.title.count > 6 ? 10.5 : 13) : 9
        let text = NSAttributedString(string: action.title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: 0.3,
        ])
        let textHeight = ceil(text.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height)
        var icon: NSImage?
        if let name = action.symbol,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            icon = tinted(symbol, color)
        }
        let iconHeight = icon.map { $0.size.height + 4 } ?? 0
        var top = point.y + (textHeight + iconHeight) / 2
        if let icon {
            top -= icon.size.height
            icon.draw(in: NSRect(x: point.x - icon.size.width / 2, y: top, width: icon.size.width, height: icon.size.height))
            top -= 4
        }
        text.draw(with: NSRect(x: point.x - width / 2, y: top - textHeight, width: width, height: textHeight), options: [.usesLineFragmentOrigin])
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func drawCenter(dark: Bool) {
        let r = Self.innerRadius
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 1, alpha: 0.97)).setFill()
        disc.fill()

        let modeLabel = NSAttributedString(string: mode == .convert ? "CONVERT" : "TOOLS", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: NSColor(srgbRed: 0.98, green: 0.45, blue: 0.1, alpha: 1),
            .kern: 1,
        ])
        let modeSize = modeLabel.size()
        modeLabel.draw(at: NSPoint(x: center.x - modeSize.width / 2, y: center.y + 34))

        if let thumbnail {
            let side: CGFloat = 50
            let size = thumbnail.size
            let scale = min(side / max(size.width, 1), side / max(size.height, 1))
            let w = size.width * scale, h = size.height * scale
            let rect = NSRect(x: center.x - w / 2, y: center.y - 14 + (side - h) / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            thumbnail.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        let sizeLabel = NSAttributedString(string: sizeText, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.3, alpha: 1),
        ])
        let s = sizeLabel.size()
        sizeLabel.draw(at: NSPoint(x: center.x - s.width / 2, y: center.y - 32))
    }

    // MARK: Drop target (drag interaction)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateHover(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateHover(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    private func updateHover(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        index(at: convert(sender.draggingLocation, from: nil)) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let action = actions[i]
        DispatchQueue.main.async { [weak self] in self?.onSelect?(action) }
        return true
    }

    // MARK: Mouse (click interaction)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            onSelect?(actions[i])
        } else {
            onCancel?()
        }
    }
}
