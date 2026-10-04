import AppKit
import PDFKit

/// Text documents: TXT, Markdown, RTF, DOC/DOCX, ODT, HTML, PDF, EPUB.
enum DocTools {
    static let targets = ["pdf", "docx", "txt", "rtf", "html", "odt", "epub", "md"]
    private static let plainExts: Set<String> = ["txt", "md", "markdown", "csv", "srt", "vtt", "log", "json", "xml"]

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.ext
        if ext == "pdf" {
            let doc = try PDFTools.open(url)
            let result = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.attributedString {
                    result.append(page)
                    result.append(NSAttributedString(string: "\n\n"))
                }
            }
            return result
        }
        if plainExts.contains(ext) {
            return NSAttributedString(string: try readText(url), attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "html", "htm": options[.documentType] = NSAttributedString.DocumentType.html
        case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
        default: break
        }
        return try onMain { try NSAttributedString(url: url, options: options, documentAttributes: nil) }
    }

    static func write(_ text: NSAttributedString, to url: URL, format: String, title: String, ctx: JobContext?) throws {
        switch format {
        case "txt", "md":
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try renderPDF(text, to: url)
        case "epub":
            try EPUB.write(title: title, text: text.string, to: url, ctx: ctx)
        default:
            let type: NSAttributedString.DocumentType
            switch format {
            case "docx": type = .officeOpenXML
            case "rtf": type = .rtf
            case "html": type = .html
            case "odt": type = .openDocument
            default: throw fail("Can't write \(format.uppercased()) documents.")
            }
            let data = try onMain {
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            }
            try data.write(to: url)
        }
    }

    static func convert(_ url: URL, to format: String, ctx: JobContext) throws -> URL {
        let out = Output.url(for: url, ext: format)
        return try producing(out) {
            if FileKind.of(url) == .iwork {
                try IWork.export(url, to: out, format: format, ctx: ctx)
                return
            }
            let text = try read(url)
            guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || format == "pdf" else {
                throw fail("No text found in “\(url.lastPathComponent)”.")
            }
            try write(text, to: out, format: format, title: url.baseName, ctx: ctx)
        }
    }

    /// Paginates rich text onto US Letter pages using the print system.
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        try onMain {
            let paper = NSSize(width: 612, height: 792)
            let margin: CGFloat = 54
            let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: url])
            info.jobDisposition = .save
            info.paperSize = paper
            info.topMargin = margin
            info.bottomMargin = margin
            info.leftMargin = margin
            info.rightMargin = margin
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - margin * 2, height: paper.height - margin * 2))
            view.appearance = NSAppearance(named: .aqua)
            view.isEditable = false
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.textStorage?.setAttributedString(text)
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            view.sizeToFit()

            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            guard operation.run() else { throw fail("Couldn't create the PDF.") }
        }
    }
}

// MARK: - EPUB

enum EPUB {
    static func write(title: String, text: String, to url: URL, ctx: JobContext?) throws {
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        let metaInf = tmp.appendingPathComponent("META-INF"), oebps = tmp.appendingPathComponent("OEBPS")
        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)
        try "application/epub+zip".write(to: tmp.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let chunks = stride(from: 0, to: max(paragraphs.count, 1), by: 250).map {
            Array(paragraphs[$0..<min($0 + 250, paragraphs.count)])
        }
        let safeTitle = escape(title)
        var manifest = "", spine = "", nav = ""
        for (i, chunk) in chunks.enumerated() {
            let name = "chapter\(i + 1).xhtml"
            let heading = chunks.count == 1 ? safeTitle : "\(safeTitle) — Part \(i + 1)"
            let body = chunk.map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(heading)</title></head>
            <body><h1>\(heading)</h1>
            \(body)
            </body></html>
            """.write(to: oebps.appendingPathComponent(name), atomically: true, encoding: .utf8)
            manifest += "<item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            nav += "<li><a href=\"\(name)\">\(heading)</a></li>\n"
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(safeTitle)</title></head>
        <body><nav epub:type="toc"><h1>Contents</h1><ol>
        \(nav)</ol></nav></body></html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        let modified = ISO8601DateFormatter().string(from: Date())
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(safeTitle)</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)
          </manifest>
          <spine>
            \(spine)
          </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // The mimetype entry must come first and be stored uncompressed.
        try Shell.run("/usr/bin/zip", ["-X0", "-q", url.path, "mimetype"], cwd: tmp, ctx: ctx)
        try Shell.run("/usr/bin/zip", ["-Xr9Dq", url.path, "META-INF", "OEBPS"], cwd: tmp, ctx: ctx)
    }

    static func escape(_ s: String) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0 == "\t" || $0 == "\n" || $0 == "\r" || ($0.value >= 0x20 && $0.value != 0xFFFE && $0.value != 0xFFFF)
        }))
        return cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Pages, Keynote, Numbers

enum IWork {
    static func targets(for ext: String) -> [String] {
        switch ext {
        case "pages": return ["pdf", "docx", "txt", "rtf", "epub"]
        case "key": return ["pdf", "pptx"]
        case "numbers": return ["pdf", "xlsx", "csv"]
        default: return ["pdf"]
        }
    }

    static func export(_ url: URL, to out: URL, format: String, ctx: JobContext?) throws {
        let (app, bundleID): (String, String) = {
            switch url.ext {
            case "key": return ("Keynote", "com.apple.iWork.Keynote")
            case "numbers": return ("Numbers", "com.apple.iWork.Numbers")
            default: return ("Pages", "com.apple.iWork.Pages")
            }
        }()
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw fail("\(app) needs to be installed to convert .\(url.ext) files (it's free on the Mac App Store).")
        }
        let asType: String
        switch format {
        case "pdf": asType = "PDF"
        case "docx": asType = "Microsoft Word"
        case "txt": asType = "unformatted text"
        case "rtf": asType = "formatted text"
        case "epub": asType = "EPUB"
        case "pptx": asType = "Microsoft PowerPoint"
        case "xlsx": asType = "Microsoft Excel"
        case "csv": asType = "CSV"
        default: throw fail("\(app) can't export \(format.uppercased()).")
        }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = """
        set inFile to POSIX file \(quoted(url.path))
        set outFile to POSIX file \(quoted(out.path))
        tell application "\(app)"
            set theDoc to open inFile
            export theDoc to outFile as \(asType)
            close theDoc saving no
        end tell
        """
        try Shell.run("/usr/bin/osascript", ["-e", script], ctx: ctx)
    }
}

// MARK: - Subtitles

enum Subtitles {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[index].components(separatedBy: "-->")
            let endToken = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" : ""
            guard parts.count == 2, let start = Parse.time(parts[0]), let end = Parse.time(endToken) else { continue }
            cues.append(Cue(start: start, end: end, text: lines[(index + 1)...].joined(separator: "\n")))
        }
        return cues
    }

    static func stamp(_ t: Double, separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60)
            + separator + String(format: "%03d", ms % 1000)
    }

    static func convert(_ url: URL, to format: String, ctx: JobContext) throws -> URL {
        let cues = parse(try DocTools.readText(url))
        guard !cues.isEmpty else { throw fail("No subtitles found in “\(url.lastPathComponent)”.") }
        let output: String
        switch format {
        case "srt":
            output = cues.enumerated().map { i, cue in
                "\(i + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            output = "WEBVTT\n\n" + cues.map { cue in
                "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        default:
            output = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        let out = Output.url(for: url, ext: format)
        return try producing(out) { try output.write(to: out, atomically: true, encoding: .utf8) }
    }
}
