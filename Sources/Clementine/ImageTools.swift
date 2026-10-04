import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageFormat: String, CaseIterable {
    case jpg, png, heic, webp, avif, tiff, bmp, gif, svg, pdf

    var ext: String { rawValue }
    var title: String { rawValue.uppercased() }

    var typeIdentifier: String? {
        switch self {
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .webp: return UTType.webP.identifier
        case .avif: return "public.avif"
        case .tiff: return UTType.tiff.identifier
        case .bmp: return UTType.bmp.identifier
        case .gif: return UTType.gif.identifier
        case .svg, .pdf: return nil
        }
    }

    var supportsAlpha: Bool { self != .jpg && self != .bmp }
    var isLossy: Bool { [.jpg, .heic, .webp, .avif].contains(self) }

    static func from(ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "jpeg", "jpe": return .jpg
        case "tif": return .tiff
        case "heif": return .heic
        default: return ImageFormat(rawValue: ext.lowercased())
        }
    }
}

enum ImageTools {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Whether macOS itself can write this format (otherwise ffmpeg/cwebp is used).
    static func canWrite(_ format: ImageFormat) -> Bool {
        format.typeIdentifier.map { writableTypes.contains($0) } ?? true
    }

    /// Same format as the input when it can be written, else PNG.
    static func sameFormat(_ url: URL) -> ImageFormat {
        if let format = ImageFormat.from(ext: url.normalizedExt), format != .svg, format != .pdf { return format }
        return .png
    }

    // MARK: - Reading

    /// Loads an image at full resolution with its EXIF orientation applied.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? Int.max, max(width, height)),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) { return image }
        }
        if let image = NSImage(contentsOf: url), let cg = render(image, longestSide: maxPixel ?? 2048) { return cg }
        if let cg = try? quickLookRender(url, size: maxPixel ?? 2048) { return cg }
        throw fail("Couldn't read “\(url.lastPathComponent)” as an image.")
    }

    static func render(_ image: NSImage, longestSide: Int) -> CGImage? {
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = CGFloat(longestSide) / max(size.width, size.height)
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let ctx = context(w, h) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func quickLookRender(_ url: URL, size: Int) throws -> CGImage {
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run("/usr/bin/qlmanage", ["-t", "-s", "\(size)", "-o", tmp.path, url.path])
        let png = tmp.appendingPathComponent(url.lastPathComponent + ".png")
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw fail("Preview failed.") }
        return image
    }

    /// EXIF/GPS/IPTC/TIFF metadata to carry over to a converted copy (minus orientation, which is baked in).
    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            if var dict = props[key] as? [CFString: Any] {
                dict.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                result[key] = dict
            }
        }
        return result
    }

    static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
    }

    // MARK: - Pixels

    static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func flatten(_ image: CGImage, color: CGColor = CGColor(gray: 1, alpha: 1), force: Bool = false) -> CGImage {
        guard force || hasAlpha(image),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard let ctx = context(max(1, width), max(1, height)) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)))
        return ctx.makeImage() ?? image
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        return resized(image, width: Int(Double(image.width) * scale), height: Int(Double(image.height) * scale))
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = context(h, w) else { return image }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Writing

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double? = nil, metadata: [CFString: Any] = [:]) -> Data? {
        guard let type = format.typeIdentifier, canWrite(format) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var props = metadata
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality ?? 0.85 }
        CGImageDestinationAddImage(dest, format.supportsAlpha ? image : flatten(image), props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double? = nil,
                      metadata: [CFString: Any] = [:], ctx: JobContext? = nil) throws {
        switch format {
        case .svg:
            try writeSVG(image, to: url)
        case .pdf:
            try writePDF([image], to: url)
        default:
            if let data = encode(image, format: format, quality: quality, metadata: metadata) {
                try data.write(to: url)
            } else {
                try encodeWithTools(image, to: url, format: format, quality: quality, ctx: ctx)
            }
        }
    }

    /// For formats ImageIO can't write on this Mac (usually WebP/AVIF): cwebp/avifenc/ffmpeg.
    private static func encodeWithTools(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double?, ctx: JobContext?) throws {
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let png = tmp.appendingPathComponent("frame.png")
        try need(encode(image, format: .png), "Couldn't encode the image.").write(to: png)
        let q = quality ?? 0.85
        if format == .webp, let cwebp = Shell.which("cwebp") {
            try Shell.run(cwebp, ["-quiet", "-q", "\(Int(q * 100))", png.path, "-o", url.path], ctx: ctx)
            return
        }
        if format == .avif, let avifenc = Shell.which("avifenc") {
            try Shell.run(avifenc, ["-q", "\(Int(q * 100))", png.path, url.path], ctx: ctx)
            return
        }
        guard FFmpeg.path != nil else {
            throw ClementineError.missingTool("ffmpeg", "\(format.title) export on this Mac uses ffmpeg. \(FFmpeg.installHint)")
        }
        var args = ["-i", png.path]
        switch format {
        case .webp:
            args += ["-c:v", "libwebp", "-quality", "\(Int(q * 100))"]
        case .avif:
            let crf = "\(Int((1 - q) * 45) + 12)"
            if FFmpeg.hasEncoder("libaom-av1") {
                args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf, "-cpu-used", "6"]
            } else if FFmpeg.hasEncoder("libsvtav1") {
                args += ["-c:v", "libsvtav1", "-crf", crf]
            } else {
                throw fail("This ffmpeg build has no AV1 encoder for AVIF.")
            }
            args += ["-pix_fmt", "yuv420p", "-vf", Media.evenScale]
        default:
            break
        }
        try FFmpeg.run(args + [url.path], ctx: ctx)
    }

    private static func writeSVG(_ image: CGImage, to url: URL) throws {
        let png = try need(encode(image, format: .png), "Couldn't encode the image.")
        let w = image.width, h = image.height
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
          <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(png.base64EncodedString())"/>
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One page per image; pages are sized to the image (capped around A3) with full resolution kept.
    static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw fail("Couldn't create the PDF.") }
        for image in images {
            let scale = min(1, 1190 / CGFloat(max(image.width, image.height)))
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: - Convert & tools

    static func convert(_ url: URL, to format: ImageFormat, ctx: JobContext) throws -> URL {
        let image = try load(url)
        let out = Output.url(for: url, ext: format.ext)
        return try producing(out) { try write(image, to: out, format: format, metadata: metadata(url), ctx: ctx) }
    }

    static func compress(_ url: URL, ctx: JobContext) throws -> URL {
        let source = ImageFormat.from(ext: url.normalizedExt)
        if source == .png, let pngquant = Shell.which("pngquant") {
            let out = Output.url(for: url, ext: "png", suffix: "compressed")
            return try producing(out) {
                try Shell.run(pngquant, ["--quality=55-85", "--speed", "3", "--strip", "--force", "--output", out.path, url.path], ctx: ctx)
            }
        }
        var image = try load(url)
        let format: ImageFormat
        if let source, source.isLossy, canWrite(source) {
            format = source
        } else if hasAlpha(image) {
            format = canWrite(.heic) ? .heic : .png
        } else {
            format = .jpg
        }
        image = downscaled(image, maxSide: 4096)
        let out = Output.url(for: url, ext: format.ext, suffix: "compressed")
        let compressed = image
        return try producing(out) { try write(compressed, to: out, format: format, quality: 0.6, metadata: metadata(url), ctx: ctx) }
    }

    /// Finds the best quality (shrinking if necessary) that fits under `bytes`.
    static func toSize(_ url: URL, bytes: Int64, ctx: JobContext) throws -> URL {
        var image = try load(url)
        let source = ImageFormat.from(ext: url.normalizedExt)
        let format: ImageFormat
        if let source, source.isLossy, canWrite(source) { format = source }
        else { format = hasAlpha(image) && canWrite(.heic) ? .heic : .jpg }
        var best: Data?
        for attempt in 0..<8 {
            try ctx.check()
            ctx.progress(Double(attempt) / 8)
            var low = 0.02, high = 0.95
            var found: Data?
            for _ in 0..<7 {
                let q = (low + high) / 2
                let data = try need(encode(image, format: format, quality: q), "Couldn't encode \(format.title).")
                if Int64(data.count) <= bytes { found = data; low = q } else { high = q }
            }
            if let found { best = found; break }
            image = resized(image, width: Int(Double(image.width) * 0.7), height: Int(Double(image.height) * 0.7))
        }
        let data = try need(best, "Couldn't get the image under \(formatBytes(bytes)).")
        let out = Output.url(for: url, ext: format.ext, suffix: formatBytes(bytes))
        return try producing(out) { try data.write(to: out) }
    }

    enum ResizeSpec { case percent(Double), longest(Int), box(Int, Int) }

    static func parseResize(_ raw: String) -> ResizeSpec? {
        let t = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "px", with: "")
        if t.hasSuffix("%"), let p = Double(t.dropLast()), p > 0 { return .percent(p / 100) }
        let parts = t.split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 { return .box(w, h) }
        if let n = Int(t), n > 0 { return .longest(n) }
        return nil
    }

    static func resize(_ url: URL, spec: ResizeSpec, ctx: JobContext) throws -> URL {
        let image = try load(url)
        let w = Double(image.width), h = Double(image.height)
        let scale: Double
        switch spec {
        case .percent(let p): scale = p
        case .longest(let n): scale = Double(n) / max(w, h)
        case .box(let bw, let bh): scale = min(Double(bw) / w, Double(bh) / h)
        }
        let nw = max(1, Int((w * scale).rounded())), nh = max(1, Int((h * scale).rounded()))
        let result = resized(image, width: nw, height: nh)
        let format = sameFormat(url)
        let out = Output.url(for: url, ext: format.ext, suffix: "\(nw)x\(nh)")
        return try producing(out) { try write(result, to: out, format: format, metadata: metadata(url), ctx: ctx) }
    }

    static func removeBackground(_ url: URL, ctx: JobContext) throws -> URL {
        guard #available(macOS 14.0, *) else { throw fail("Background removal needs macOS 14 Sonoma or later.") }
        let image = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw fail("Couldn't find a subject in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        let cut = try need(CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: sRGB),
                           "Couldn't render the cut-out.")
        let out = Output.url(for: url, ext: "png", suffix: "no background")
        return try producing(out) { try write(cut, to: out, format: .png, ctx: ctx) }
    }

    static func addBackground(_ url: URL, color: NSColor, ctx: JobContext) throws -> URL {
        let image = try load(url)
        let cgColor = color.usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1)
        let flat = flatten(image, color: cgColor, force: true)
        let format = sameFormat(url)
        let out = Output.url(for: url, ext: format.ext, suffix: "background")
        return try producing(out) { try write(flat, to: out, format: format, metadata: metadata(url), ctx: ctx) }
    }

    static func stripMetadata(_ url: URL, ctx: JobContext) throws -> URL {
        let image = try load(url)
        let format = sameFormat(url)
        let out = Output.url(for: url, ext: format.ext, suffix: "clean")
        return try producing(out) { try write(image, to: out, format: format, quality: 0.95, ctx: ctx) }
    }

    static func writeMetadata(_ url: URL, fields: MetadataFields, removeGPS: Bool, ctx: JobContext) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw fail("Couldn't read the image.")
        }
        let existing = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var tiff = existing[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var iptc = existing[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var exif = existing[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        func set(_ dict: inout [CFString: Any], _ key: CFString, _ value: Any?) {
            if let value, !((value as? String)?.isEmpty ?? false), !((value as? [String])?.isEmpty ?? false) {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
        }
        let keywords = fields.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set(&tiff, kCGImagePropertyTIFFImageDescription, fields.description)
        set(&tiff, kCGImagePropertyTIFFArtist, fields.author)
        set(&tiff, kCGImagePropertyTIFFCopyright, fields.copyright)
        set(&iptc, kCGImagePropertyIPTCObjectName, fields.title)
        set(&iptc, kCGImagePropertyIPTCByline, fields.author.isEmpty ? nil : [fields.author])
        set(&iptc, kCGImagePropertyIPTCCopyrightNotice, fields.copyright)
        set(&iptc, kCGImagePropertyIPTCCaptionAbstract, fields.description)
        set(&iptc, kCGImagePropertyIPTCKeywords, keywords)
        set(&exif, kCGImagePropertyExifUserComment, fields.description)
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyIPTCDictionary: iptc,
            kCGImagePropertyExifDictionary: exif,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        if removeGPS { props[kCGImagePropertyGPSDictionary] = kCFNull }
        let out = Output.url(for: url, ext: url.pathExtension.isEmpty ? "jpg" : url.ext, suffix: "edited")
        return try producing(out) {
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw fail("Can't write this image type.") }
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw fail("Couldn't save the image.") }
        }
    }

    static func collage(_ urls: [URL], ctx: JobContext) throws -> URL {
        let images = try urls.map { try load($0, maxPixel: 1600) }
        let n = images.count
        let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
        let cell: CGFloat = 800, gap: CGFloat = 16
        let width = CGFloat(cols) * cell + CGFloat(cols + 1) * gap
        let height = CGFloat(rows) * cell + CGFloat(rows + 1) * gap
        let ctxImage = try need(context(Int(width), Int(height)), "Couldn't create the collage.")
        ctxImage.setFillColor(CGColor(gray: 1, alpha: 1))
        ctxImage.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctxImage.interpolationQuality = .high
        for (i, image) in images.enumerated() {
            let col = CGFloat(i % cols), row = CGFloat(i / cols)
            let rect = CGRect(x: gap + col * (cell + gap), y: height - (row + 1) * (cell + gap), width: cell, height: cell)
            let s = max(cell / CGFloat(image.width), cell / CGFloat(image.height))
            let dw = CGFloat(image.width) * s, dh = CGFloat(image.height) * s
            ctxImage.saveGState()
            ctxImage.clip(to: rect)
            ctxImage.draw(image, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
            ctxImage.restoreGState()
            ctx.progress(Double(i + 1) / Double(n))
        }
        let result = try need(ctxImage.makeImage(), "Couldn't create the collage.")
        let out = Output.unique(in: Output.directory(for: urls[0]), base: "Collage", ext: "jpg")
        return try producing(out) { try write(result, to: out, format: .jpg, quality: 0.9) }
    }

    static func makePDF(_ urls: [URL], ctx: JobContext) throws -> URL {
        var images: [CGImage] = []
        for (i, url) in urls.enumerated() {
            try ctx.check()
            images.append(try load(url, maxPixel: 3000))
            ctx.progress(Double(i + 1) / Double(urls.count))
        }
        let base = urls.count == 1 ? urls[0].baseName : "Images"
        let out = Output.unique(in: Output.directory(for: urls[0]), base: base, ext: "pdf")
        return try producing(out) { try writePDF(images, to: out) }
    }

    /// Text recognition (OCR) to a .txt file.
    static func ocr(_ url: URL, ctx: JobContext) throws -> URL {
        let image = try load(url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw fail("No text found in “\(url.lastPathComponent)”.") }
        let out = Output.url(for: url, ext: "txt")
        return try producing(out) { try text.write(to: out, atomically: true, encoding: .utf8) }
    }

    /// QR codes and barcodes.
    static func readCodes(_ url: URL) throws -> [String] {
        let image = try load(url)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
