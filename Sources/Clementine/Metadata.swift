import AppKit
import ImageIO

struct MetadataFields {
    var title = ""
    var author = ""
    var description = ""
    var copyright = ""
    var keywords = ""
}

enum MetadataTools {
    static func canEdit(_ url: URL) -> Bool {
        switch FileKind.of(url) {
        case .image: return ImageTools.canWrite(ImageTools.sameFormat(url)) && ImageFormat.from(ext: url.normalizedExt) != nil
        case .video, .audio: return FFmpeg.path != nil
        case .pdf: return true
        default: return false
        }
    }

    static func fields(_ url: URL) -> MetadataFields {
        var f = MetadataFields()
        switch FileKind.of(url) {
        case .image:
            let props = ImageTools.properties(url)
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            f.title = iptc[kCGImagePropertyIPTCObjectName as String] as? String ?? ""
            f.author = tiff[kCGImagePropertyTIFFArtist as String] as? String
                ?? (iptc[kCGImagePropertyIPTCByline as String] as? [String])?.first ?? ""
            f.description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String
                ?? iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String ?? ""
            f.copyright = tiff[kCGImagePropertyTIFFCopyright as String] as? String ?? ""
            f.keywords = (iptc[kCGImagePropertyIPTCKeywords as String] as? [String])?.joined(separator: ", ") ?? ""
        case .video, .audio:
            let tags = FFmpeg.info(url).tags
            f.title = tags["title"] ?? ""
            f.author = tags["artist"] ?? tags["author"] ?? ""
            f.description = tags["comment"] ?? tags["description"] ?? ""
            f.copyright = tags["copyright"] ?? ""
            f.keywords = tags["keywords"] ?? ""
        case .pdf:
            f = PDFTools.fields(url)
        default:
            break
        }
        return f
    }

    static func save(_ url: URL, fields: MetadataFields, removeGPS: Bool, ctx: JobContext) throws -> URL {
        switch FileKind.of(url) {
        case .image: return try ImageTools.writeMetadata(url, fields: fields, removeGPS: removeGPS, ctx: ctx)
        case .video, .audio: return try Media.writeMetadata(url, fields: fields, ctx: ctx)
        case .pdf: return try PDFTools.writeMetadata(url, fields: fields, ctx: ctx)
        default: throw fail("Metadata for this kind of file can't be edited.")
        }
    }

    /// A clean copy: embedded metadata removed and macOS extended attributes (download source, tags…) cleared.
    static func strip(_ url: URL, ctx: JobContext) throws -> URL {
        let out: URL
        switch FileKind.of(url) {
        case .image:
            out = try ImageTools.stripMetadata(url, ctx: ctx)
        case .video, .audio:
            out = try Media.stripMetadata(url, ctx: ctx)
        case .pdf:
            out = try PDFTools.stripMetadata(url, ctx: ctx)
        default:
            let target = url.isDirectory
                ? Output.unique(in: Output.directory(for: url), base: url.lastPathComponent + " clean", ext: "")
                : Output.url(for: url, ext: url.pathExtension, suffix: "clean")
            out = try producing(target) { try FileManager.default.copyItem(at: url, to: target) }
        }
        try? Shell.run("/usr/bin/xattr", ["-cr", out.path])
        return out
    }

    static func describe(_ url: URL) -> String {
        var sections: [String] = []
        switch FileKind.of(url) {
        case .image:
            sections.append("IMAGE\n" + pretty(ImageTools.properties(url)))
        case .video, .audio:
            let info = FFmpeg.info(url)
            if !info.raw.isEmpty { sections.append("MEDIA\n" + pretty(info.raw)) }
        case .pdf:
            sections.append("PDF\n" + PDFTools.describe(url))
        default:
            break
        }
        if let spotlight = try? Shell.run("/usr/bin/mdls", [url.path]), !spotlight.isEmpty {
            sections.append("SPOTLIGHT\n" + spotlight)
        }
        if let xattrs = try? Shell.run("/usr/bin/xattr", ["-l", url.path]), !xattrs.isEmpty {
            sections.append("EXTENDED ATTRIBUTES\n" + xattrs)
        }
        return sections.isEmpty ? "No metadata found." : sections.joined(separator: "\n\n")
    }

    static func pretty(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().map { key -> String in
                let v = dict[key]!
                if v is [String: Any] || ((v as? [Any])?.contains { $0 is [String: Any] } ?? false) {
                    return "\(pad)\(key):\n" + pretty(v, indent: indent + 1)
                }
                return "\(pad)\(key): \(inline(v))"
            }.joined(separator: "\n")
        }
        if let array = value as? [Any] {
            return array.enumerated().map { "\(pad)[\($0.offset)]\n" + pretty($0.element, indent: indent + 1) }.joined(separator: "\n")
        }
        return pad + inline(value)
    }

    private static func inline(_ value: Any) -> String {
        if let array = value as? [Any] { return array.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }
}

/// Shows everything known about a file, with a few editable fields.
final class MetadataWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: [MetadataWindow] = []

    private let url: URL
    private let textView = NSTextView()
    private let titleField = NSTextField()
    private let authorField = NSTextField()
    private let descriptionField = NSTextField()
    private let copyrightField = NSTextField()
    private let keywordsField = NSTextField()
    private let gpsCheckbox = NSButton(checkboxWithTitle: "Remove location (GPS)", target: nil, action: nil)

    static func show(_ url: URL) {
        if Runtime.isCLI {
            print(MetadataTools.describe(url))
            return
        }
        let controller = MetadataWindow(url: url)
        openWindows.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Metadata — \(url.lastPathComponent)"
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        textView.string = "Loading…"
        let target = url
        DispatchQueue.global(qos: .userInitiated).async {
            let text = MetadataTools.describe(target)
            DispatchQueue.main.async { [weak self] in self?.textView.string = text }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeAll { $0 === self }
    }

    private func build() {
        guard let window else { return }
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        var rows: [NSView] = [scroll]
        let editable = MetadataTools.canEdit(url)
        if editable {
            let current = MetadataTools.fields(url)
            titleField.stringValue = current.title
            authorField.stringValue = current.author
            descriptionField.stringValue = current.description
            copyrightField.stringValue = current.copyright
            keywordsField.stringValue = current.keywords
            keywordsField.placeholderString = "comma, separated"
            var gridRows: [[NSView]] = [
                [label("Title"), titleField],
                [label(FileKind.of(url) == .pdf ? "Author" : "Author / Artist"), authorField],
                [label("Description"), descriptionField],
            ]
            if FileKind.of(url) != .pdf { gridRows.append([label("Copyright"), copyrightField]) }
            gridRows.append([label("Keywords"), keywordsField])
            if FileKind.of(url) == .image { gridRows.append([NSView(), gpsCheckbox]) }
            let grid = NSGridView(views: gridRows)
            grid.column(at: 0).xPlacement = .trailing
            grid.rowSpacing = 8
            grid.columnSpacing = 10
            rows.append(grid)
        }

        let strip = NSButton(title: "Remove All Metadata", target: self, action: #selector(stripAll))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        var buttons: [NSView] = [strip, NSView(), close]
        if editable {
            let save = NSButton(title: "Save Copy", target: self, action: #selector(saveCopy))
            save.keyEquivalent = "\r"
            buttons.append(save)
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttons[1].setContentHuggingPriority(.init(1), for: .horizontal)
        rows.append(buttonRow)

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(column)
        var constraints = [
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttonRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
        ]
        for field in [titleField, authorField, descriptionField, copyrightField, keywordsField] {
            constraints.append(field.widthAnchor.constraint(greaterThanOrEqualToConstant: 380))
        }
        NSLayoutConstraint.activate(constraints)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = root
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    @objc private func saveCopy() {
        let fields = MetadataFields(title: titleField.stringValue, author: authorField.stringValue,
                                    description: descriptionField.stringValue, copyright: copyrightField.stringValue,
                                    keywords: keywordsField.stringValue)
        let removeGPS = gpsCheckbox.state == .on
        let target = url
        JobRunner.run("Save metadata", detail: target.lastPathComponent) { ctx in
            [try MetadataTools.save(target, fields: fields, removeGPS: removeGPS, ctx: ctx)]
        }
        window?.close()
    }

    @objc private func stripAll() {
        let target = url
        JobRunner.run("Strip metadata", detail: target.lastPathComponent) { ctx in [try MetadataTools.strip(target, ctx: ctx)] }
        window?.close()
    }

    @objc private func closeWindow() { window?.close() }
}
