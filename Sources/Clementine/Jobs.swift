import AppKit

/// Handed to every job: reports progress and lets the user cancel (which kills any running tool).
final class JobContext {
    let title: String
    var progressHandler: ((Double?) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    init(title: String) { self.title = title }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process?) {
        lock.lock()
        self.process = process
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled, let process, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func check() throws {
        if isCancelled { throw ClementineError.cancelled }
    }

    /// 0…1, or nil for "busy".
    func progress(_ value: Double?) {
        guard let handler = progressHandler else { return }
        if Thread.isMainThread { handler(value) } else { DispatchQueue.main.async { handler(value) } }
    }
}

enum JobRunner {
    static var cliFailures = 0

    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Runs `work` in the background with a small progress card. `work` returns the files it created.
    static func run(_ title: String, detail: String, work: @escaping (JobContext) throws -> [URL]) {
        let ctx = JobContext(title: title)
        if Runtime.isCLI {
            do {
                let outputs = try work(ctx)
                outputs.forEach { print("✓ \($0.path)") }
                if outputs.isEmpty { print("✓ \(title): \(detail)") }
            } catch {
                cliFailures += 1
                FileHandle.standardError.write(Data("✗ \(title) — \(detail): \(error.localizedDescription)\n".utf8))
            }
            return
        }
        let card = ProgressHUD.shared.add(title: title, detail: detail, ctx: ctx)
        queue.addOperation {
            do {
                let outputs = try work(ctx)
                DispatchQueue.main.async { card.finish(outputs: outputs) }
            } catch {
                var cancelled = ctx.isCancelled
                if case .cancelled? = error as? ClementineError { cancelled = true }
                let wasCancelled = cancelled
                DispatchQueue.main.async {
                    if wasCancelled { card.remove() } else { card.fail(error) }
                }
            }
        }
    }
}

// MARK: - Progress cards

final class ProgressHUD {
    static let shared = ProgressHUD()
    private var panel: NSPanel?
    private let stack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .trailing
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    func add(title: String, detail: String, ctx: JobContext) -> JobCard {
        let card = JobCard(title: title, detail: detail, ctx: ctx)
        stack.addArrangedSubview(card)
        show()
        return card
    }

    func remove(_ card: JobCard) {
        stack.removeArrangedSubview(card)
        card.removeFromSuperview()
        if stack.arrangedSubviews.isEmpty { panel?.orderOut(nil) } else { layout() }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let content = NSView()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            p.contentView = content
            panel = p
        }
        layout()
        panel?.orderFrontRegardless()
    }

    func layout() {
        guard let panel else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16,
                              width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

final class JobCard: NSVisualEffectView {
    private let jobTitle: String
    private let ctx: JobContext
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let closeButton = NSButton()
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private var outputs: [URL] = []
    private var finished = false

    init(title: String, detail: String, ctx: JobContext) {
        self.jobTitle = title
        self.ctx = ctx
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 5
        detailLabel.preferredMaxLayoutWidth = 276

        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Cancel"

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.isHidden = true

        let header = NSStackView(views: [titleLabel, closeButton])
        header.orientation = .horizontal
        header.spacing = 6
        let column = NSStackView(views: [header, detailLabel, bar, revealButton])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 300),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
        ])

        ctx.progressHandler = { [weak self] value in self?.update(value) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update(_ value: Double?) {
        guard !finished else { return }
        if let value {
            if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
            bar.doubleValue = value
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func finish(outputs: [URL]) {
        finished = true
        self.outputs = outputs
        bar.isHidden = true
        titleLabel.stringValue = "✓ " + jobTitle
        switch outputs.count {
        case 0: detailLabel.stringValue = "Done"
        case 1: detailLabel.stringValue = "Saved “\(outputs[0].lastPathComponent)”"
        default: detailLabel.stringValue = "Saved \(outputs.count) files"
        }
        revealButton.isHidden = outputs.isEmpty
        closeButton.toolTip = "Close"
        ProgressHUD.shared.layout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.remove() }
    }

    func fail(_ error: Error) {
        finished = true
        bar.isHidden = true
        titleLabel.stringValue = "Couldn’t " + jobTitle.lowercased()
        titleLabel.textColor = .systemRed
        detailLabel.stringValue = error.localizedDescription
        closeButton.toolTip = "Close"
        ProgressHUD.shared.layout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.remove() }
    }

    func remove() {
        guard superview != nil else { return }
        ProgressHUD.shared.remove(self)
    }

    @objc private func closeTapped() {
        if !finished { ctx.cancel() }
        remove()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        remove()
    }
}
