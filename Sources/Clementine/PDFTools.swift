import AppKit
import PDFKit

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw fail("Couldn't open “\(url.lastPathComponent)” as a PDF.") }
        if doc.isLocked { throw fail("“\(url.lastPathComponent)” is password-protected.") }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let ok = options.map { doc.write(to: url, withOptions: $0) } ?? doc.write(to: url)
        guard ok else { throw fail("Couldn't save the PDF.") }
    }

    /// Renders a page (honouring its rotation) on white.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let box = ref.getBoxRect(.mediaBox)
        let rotated = ref.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = ImageTools.context(w, h) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }

    static func toImages(_ url: URL, format: ImageFormat, ctx: JobContext) throws -> [URL] {
        let doc = try open(url)
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            try ctx.check()
            guard let page = doc.page(at: i), let image = render(page, dpi: 200) else { continue }
            let out = doc.pageCount == 1 ? Output.url(for: url, ext: format.ext) : Output.url(for: url, ext: format.ext, suffix: "page \(i + 1)")
            outputs.append(try producing(out) { try ImageTools.write(image, to: out, format: format, quality: 0.9, ctx: ctx) })
            ctx.progress(Double(i + 1) / Double(doc.pageCount))
        }
        return outputs
    }

    // MARK: - Compression

    private static func compress(_ input: URL, into output: URL, preset: String, ctx: JobContext) throws {
        if let gs = Shell.which("gs") {
            try Shell.run(gs, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dPDFSETTINGS=\(preset)", "-dNOPAUSE",
                               "-dQUIET", "-dBATCH", "-sOutputFile=\(output.path)", input.path], ctx: ctx)
        } else {
            if #available(macOS 13.4, *) {
                try save(try open(input), to: output, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            } else {
                try save(try open(input), to: output)
            }
        }
    }

    static func compress(_ url: URL, ctx: JobContext) throws -> URL {
        let out = Output.url(for: url, ext: "pdf", suffix: "compressed")
        return try producing(out) { try compress(url, into: out, preset: "/ebook", ctx: ctx) }
    }

    static func toSize(_ url: URL, bytes: Int64, ctx: JobContext) throws -> URL {
        let out = Output.url(for: url, ext: "pdf", suffix: formatBytes(bytes))
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try producing(out) {
            // 1. Try normal compression (text stays selectable).
            let presets = Shell.which("gs") != nil ? ["/ebook", "/screen"] : ["/ebook"]
            for (i, preset) in presets.enumerated() {
                let candidate = tmp.appendingPathComponent("c\(i).pdf")
                try compress(url, into: candidate, preset: preset, ctx: ctx)
                if fileSize(candidate) <= bytes {
                    try FileManager.default.moveItem(at: candidate, to: out)
                    return
                }
            }
            // 2. Rasterize pages to JPEG, searching for the best quality that fits.
            let doc = try open(url)
            var step = 0
            for dpi in [150, 110, 80, 60] as [CGFloat] {
                let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0).flatMap { render($0, dpi: dpi) } }
                var low = 0.05, high = 0.9
                var best: URL?
                for _ in 0..<6 {
                    try ctx.check()
                    step += 1
                    ctx.progress(min(0.95, Double(step) / 24))
                    let q = (low + high) / 2
                    let candidate = tmp.appendingPathComponent("r\(step).pdf")
                    try rasterize(pages, dpi: dpi, quality: q, to: candidate)
                    if fileSize(candidate) <= bytes { best = candidate; low = q } else { high = q }
                }
                if let best {
                    try FileManager.default.moveItem(at: best, to: out)
                    return
                }
            }
            throw fail("Couldn't get this PDF under \(formatBytes(bytes)).")
        }
    }

    private static func rasterize(_ pages: [CGImage], dpi: CGFloat, quality: Double, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw fail("Couldn't create the PDF.") }
        for image in pages {
            guard let jpeg = ImageTools.encode(image, format: .jpg, quality: quality),
                  let provider = CGDataProvider(data: jpeg as CFData),
                  let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(jpegImage, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: - Pages

    private static func copyPage(_ doc: PDFDocument, _ index: Int) -> PDFPage? {
        doc.page(at: index)?.copy() as? PDFPage
    }

    /// Merges PDFs and images (in the given order) into one PDF.
    static func merge(_ urls: [URL], ctx: JobContext) throws -> URL {
        let merged = PDFDocument()
        for (n, url) in urls.enumerated() {
            try ctx.check()
            if url.ext == "pdf" {
                let doc = try open(url)
                for i in 0..<doc.pageCount {
                    if let page = copyPage(doc, i) { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                let image = try ImageTools.load(url, maxPixel: 3000)
                let scale = min(1, 1190 / CGFloat(max(image.width, image.height)))
                let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
                if let page = PDFPage(image: nsImage) { merged.insert(page, at: merged.pageCount) }
            }
            ctx.progress(Double(n + 1) / Double(urls.count))
        }
        guard merged.pageCount > 0 else { throw fail("Nothing to merge.") }
        let out = Output.unique(in: Output.directory(for: urls[0]), base: "Merged", ext: "pdf")
        return try producing(out) { try save(merged, to: out) }
    }

    /// `groups` nil → one PDF per page.
    static func split(_ url: URL, groups: [[Int]]?, ctx: JobContext) throws -> [URL] {
        let doc = try open(url)
        let parts = groups ?? (0..<doc.pageCount).map { [$0] }
        var outputs: [URL] = []
        for (n, group) in parts.enumerated() {
            try ctx.check()
            let part = PDFDocument()
            for index in group {
                if let page = copyPage(doc, index) { part.insert(page, at: part.pageCount) }
            }
            let label = group.count == 1 ? "page \(group[0] + 1)" : "pages \(group[0] + 1)-\(group[group.count - 1] + 1)"
            let out = Output.url(for: url, ext: "pdf", suffix: label)
            outputs.append(try producing(out) { try save(part, to: out) })
            ctx.progress(Double(n + 1) / Double(parts.count))
        }
        return outputs
    }

    static func reorder(_ url: URL, order: [Int], ctx: JobContext) throws -> URL {
        let doc = try open(url)
        let result = PDFDocument()
        for index in order {
            if let page = copyPage(doc, index) { result.insert(page, at: result.pageCount) }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: "reordered")
        return try producing(out) { try save(result, to: out) }
    }

    static func rotate(_ url: URL, ctx: JobContext) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: "rotated")
        return try producing(out) { try save(doc, to: out) }
    }

    // MARK: - Metadata

    static func fields(_ url: URL) -> MetadataFields {
        guard let attrs = PDFDocument(url: url)?.documentAttributes else { return MetadataFields() }
        var fields = MetadataFields()
        fields.title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        fields.author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        fields.description = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            fields.keywords = keywords.joined(separator: ", ")
        } else {
            fields.keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        }
        return fields
    }

    static func writeMetadata(_ url: URL, fields: MetadataFields, ctx: JobContext) throws -> URL {
        let doc = try open(url)
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.titleAttribute] = fields.title
        attrs[PDFDocumentAttribute.authorAttribute] = fields.author
        attrs[PDFDocumentAttribute.subjectAttribute] = fields.description
        attrs[PDFDocumentAttribute.keywordsAttribute] = fields.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        doc.documentAttributes = attrs
        let out = Output.url(for: url, ext: "pdf", suffix: "edited")
        return try producing(out) { try save(doc, to: out) }
    }

    static func stripMetadata(_ url: URL, ctx: JobContext) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = Output.url(for: url, ext: "pdf", suffix: "clean")
        return try producing(out) { try save(doc, to: out) }
    }

    static func describe(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "Unreadable PDF" }
        var lines = ["Pages: \(doc.pageCount)", "PDF version: \(doc.majorVersion).\(doc.minorVersion)", "Encrypted: \(doc.isEncrypted)"]
        for (key, value) in (doc.documentAttributes ?? [:]).sorted(by: { "\($0.key)" < "\($1.key)" }) {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }
}
