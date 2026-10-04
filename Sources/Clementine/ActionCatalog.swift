import AppKit

enum WheelMode {
    case convert, tools
}

struct WheelAction {
    let title: String
    let symbol: String?
    let perform: ([URL]) -> Void
}

/// Decides which slices the wheel shows for the dragged files, and what each one does.
enum ActionCatalog {
    static func actions(for files: [URL], mode: WheelMode) -> [WheelAction] {
        guard !files.isEmpty else { return [] }
        let kind = FileKind.group(files)
        return mode == .convert ? convertActions(files, kind) : toolActions(files, kind)
    }

    // MARK: - Builders

    /// One background job per file. `ask` runs first (on the main thread); returning nil cancels.
    static func each(_ title: String, _ symbol: String? = nil, ask: (([URL]) -> String?)? = nil,
                     _ work: @escaping (URL, String, JobContext) throws -> [URL]) -> WheelAction {
        WheelAction(title: title, symbol: symbol) { files in
            var answer = ""
            if let ask {
                guard let value = ask(files) else { return }
                answer = value
            }
            for file in files {
                JobRunner.run(title, detail: file.lastPathComponent) { ctx in try work(file, answer, ctx) }
            }
        }
    }

    /// A single background job over all files.
    static func batch(_ title: String, _ symbol: String? = nil, ask: (([URL]) -> String?)? = nil,
                      _ work: @escaping ([URL], String, JobContext) throws -> [URL]) -> WheelAction {
        WheelAction(title: title, symbol: symbol) { files in
            var answer = ""
            if let ask {
                guard let value = ask(files) else { return }
                answer = value
            }
            let detail = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            JobRunner.run(title, detail: detail) { ctx in try work(files, answer, ctx) }
        }
    }

    static func label(_ ext: String) -> String {
        switch ext {
        case "tar.gz": return "TAR.GZ"
        case "md": return "Markdown"
        default: return ext.uppercased()
        }
    }

    // MARK: - Convert wheel

    static func convertActions(_ files: [URL], _ kind: FileKind) -> [WheelAction] {
        let exts = Set(files.map(\.normalizedExt))
        func except(_ list: [String]) -> [String] { exts.count == 1 ? list.filter { !exts.contains($0) } : list }

        switch kind {
        case .image:
            var list = ["jpg", "png", "heic", "webp", "avif", "tiff", "bmp", "gif", "svg", "pdf", "txt"]
            if exts == ["gif"] {
                list.removeAll { $0 == "txt" }
                list.insert(contentsOf: ["mp4", "webm"], at: 0)
            }
            return except(list).map { target in
                each(target == "txt" ? "Text (OCR)" : label(target)) { url, _, ctx in
                    switch target {
                    case "txt": return [try ImageTools.ocr(url, ctx: ctx)]
                    case "mp4", "webm": return [try Media.convert(url, to: target, ctx: ctx)]
                    default: return [try ImageTools.convert(url, to: ImageFormat.from(ext: target)!, ctx: ctx)]
                    }
                }
            }
        case .video:
            return except(Media.videoTargets).map { target in
                each(label(target)) { url, _, ctx in [try Media.convert(url, to: target, ctx: ctx)] }
            }
        case .audio:
            return except(Media.audioTargets).map { target in
                each(label(target)) { url, _, ctx in [try Media.convert(url, to: target, ctx: ctx)] }
            }
        case .pdf:
            return ["jpg", "png", "tiff", "txt", "docx", "rtf", "html", "epub"].map { target in
                each(label(target)) { url, _, ctx in
                    if let format = ImageFormat.from(ext: target) { return try PDFTools.toImages(url, format: format, ctx: ctx) }
                    return [try DocTools.convert(url, to: target, ctx: ctx)]
                }
            }
        case .document:
            return except(DocTools.targets).map { target in
                each(label(target)) { url, _, ctx in [try DocTools.convert(url, to: target, ctx: ctx)] }
            }
        case .iwork:
            let targets = exts.count == 1 ? IWork.targets(for: exts.first!) : ["pdf"]
            return targets.map { target in
                each(label(target)) { url, _, ctx in [try DocTools.convert(url, to: target, ctx: ctx)] }
            }
        case .subtitle:
            return except(["srt", "vtt", "txt"]).map { target in
                each(label(target)) { url, _, ctx in [try Subtitles.convert(url, to: target, ctx: ctx)] }
            }
        case .archive:
            return [each("Extract", "arrow.up.bin") { url, _, ctx in [try Archive.extract(url, ctx: ctx)] }]
                + except(["zip", "tar", "tar.gz"]).map { target in
                    each(label(target)) { url, _, ctx in [try Archive.convert(url, to: target, ctx: ctx)] }
                }
        case .folder:
            var list = ["zip", "tar", "tar.gz"]
            if files.count == 1 { list.append("dmg") }
            return list.map { target in
                each(label(target)) { url, _, ctx in [try Archive.create([url], format: target, ctx: ctx)] }
            }
        case .mixed, .other:
            return ["zip", "tar", "tar.gz"].map { target in
                batch(label(target)) { urls, _, ctx in [try Archive.create(urls, format: target, ctx: ctx)] }
            }
        }
    }

    // MARK: - Tools wheel

    enum Symbol {
        static let compress = "arrow.down.right.and.arrow.up.left"
        static let target = "scope"
        static let resize = "arrow.up.left.and.arrow.down.right"
        static let crop = "crop"
        static let adjust = "slider.horizontal.3"
        static let annotate = "pencil.tip"
        static let redact = "eye.slash"
        static let removeBG = "person.crop.rectangle"
        static let addBG = "square.fill"
        static let metadata = "info.circle"
        static let strip = "xmark.seal"
        static let qr = "qrcode.viewfinder"
        static let pdf = "doc.richtext"
        static let collage = "square.grid.2x2"
        static let trim = "scissors"
        static let speed = "speedometer"
        static let split = "square.split.2x1"
        static let join = "plus.rectangle.on.rectangle"
        static let snapshot = "camera"
        static let mute = "speaker.slash"
        static let rotate = "rotate.right"
        static let normalize = "waveform"
        static let silence = "waveform.path"
        static let bleep = "exclamationmark.bubble"
        static let mono = "speaker"
        static let stereo = "speaker.wave.2"
        static let reorder = "arrow.up.arrow.down"
        static let zip = "doc.zipper"
    }

    static func toolActions(_ files: [URL], _ kind: FileKind) -> [WheelAction] {
        let single = files.count == 1
        let metadata = WheelAction(title: "Metadata", symbol: Symbol.metadata) { MetadataWindow.show($0[0]) }
        let strip = each("Strip Metadata", Symbol.strip) { url, _, ctx in [try MetadataTools.strip(url, ctx: ctx)] }
        let zip = batch("Zip", Symbol.zip) { urls, _, ctx in [try Archive.create(urls, format: "zip", ctx: ctx)] }

        switch kind {
        case .image:
            var list: [WheelAction] = [
                each("Compress", Symbol.compress) { url, _, ctx in [try ImageTools.compress(url, ctx: ctx)] },
                each("Target Size", Symbol.target, ask: askSize) { url, answer, ctx in
                    [try ImageTools.toSize(url, bytes: try need(Parse.byteSize(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Resize", Symbol.resize, ask: askResize) { url, answer, ctx in
                    [try ImageTools.resize(url, spec: try need(ImageTools.parseResize(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
            ]
            if single {
                list += [
                    WheelAction(title: "Crop", symbol: Symbol.crop) { ImageEditor.open($0[0], mode: .crop) },
                    WheelAction(title: "Adjust", symbol: Symbol.adjust) { ImageEditor.open($0[0], mode: .adjust) },
                    WheelAction(title: "Annotate", symbol: Symbol.annotate) { ImageEditor.open($0[0], mode: .annotate) },
                    WheelAction(title: "Redact", symbol: Symbol.redact) { ImageEditor.open($0[0], mode: .redact) },
                ]
            }
            list += [
                each("Remove BG", Symbol.removeBG) { url, _, ctx in [try ImageTools.removeBackground(url, ctx: ctx)] },
                each("Add BG", Symbol.addBG, ask: askColor) { url, answer, ctx in
                    [try ImageTools.addBackground(url, color: Parse.color(answer) ?? .white, ctx: ctx)]
                },
            ]
            if single { list.append(metadata) }
            list += [
                strip,
                batch("Read QR", Symbol.qr) { urls, _, _ in
                    let codes = try urls.flatMap { try ImageTools.readCodes($0) }
                    if Runtime.isCLI { Prompt.showCodes(codes) } else { DispatchQueue.main.async { Prompt.showCodes(codes) } }
                    return []
                },
            ]
            if !single {
                list += [
                    batch("Make PDF", Symbol.pdf) { urls, _, ctx in [try ImageTools.makePDF(urls, ctx: ctx)] },
                    batch("Collage", Symbol.collage) { urls, _, ctx in [try ImageTools.collage(urls, ctx: ctx)] },
                ]
            }
            return list

        case .video:
            var list: [WheelAction] = [
                each("Compress", Symbol.compress) { url, _, ctx in [try Media.compressVideo(url, ctx: ctx)] },
                each("Target Size", Symbol.target, ask: askSize) { url, answer, ctx in
                    [try Media.videoToSize(url, bytes: try need(Parse.byteSize(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Trim", Symbol.trim, ask: askRange) { url, answer, ctx in
                    let r = try need(Parse.range(answer), "Couldn't understand “\(answer)”.")
                    return [try Media.trim(url, start: r.start, end: r.end, ctx: ctx)]
                },
                each("Crop", Symbol.crop, ask: askVideoCrop) { url, answer, ctx in [try Media.cropVideo(url, spec: answer, ctx: ctx)] },
                each("Speed", Symbol.speed, ask: askSpeed) { url, answer, ctx in
                    [try Media.speed(url, factor: try need(speedFactor(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Split", Symbol.split, ask: askSplit) { url, answer, ctx in try Media.split(url, spec: answer, ctx: ctx) },
                each("Snapshot", Symbol.snapshot, ask: askSnapshot) { url, answer, ctx in
                    try Media.snapshots(url, at: answer.isEmpty ? nil : Parse.time(answer), ctx: ctx)
                },
                each("Mute", Symbol.mute) { url, _, ctx in [try Media.mute(url, ctx: ctx)] },
                each("Rotate", Symbol.rotate) { url, _, ctx in [try Media.rotateVideo(url, ctx: ctx)] },
            ]
            if single { list.append(metadata) }
            list.append(strip)
            if !single { list.append(batch("Join", Symbol.join) { urls, _, ctx in [try Media.join(urls, ctx: ctx)] }) }
            return list

        case .audio:
            var list: [WheelAction] = [
                each("Compress", Symbol.compress) { url, _, ctx in [try Media.compressAudio(url, ctx: ctx)] },
                each("Target Size", Symbol.target, ask: askSize) { url, answer, ctx in
                    [try Media.audioToSize(url, bytes: try need(Parse.byteSize(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Normalize", Symbol.normalize) { url, _, ctx in [try Media.normalize(url, ctx: ctx)] },
                each("Trim", Symbol.trim, ask: askRange) { url, answer, ctx in
                    let r = try need(Parse.range(answer), "Couldn't understand “\(answer)”.")
                    return [try Media.trim(url, start: r.start, end: r.end, ctx: ctx)]
                },
                each("Trim Silence", Symbol.silence) { url, _, ctx in [try Media.trimSilence(url, ctx: ctx)] },
                each("Bleep", Symbol.bleep, ask: askBleep) { url, answer, ctx in
                    [try Media.bleep(url, ranges: try need(Parse.ranges(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Speed", Symbol.speed, ask: askSpeed) { url, answer, ctx in
                    [try Media.speed(url, factor: try need(speedFactor(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
                each("Mono", Symbol.mono) { url, _, ctx in [try Media.audioFilter(url, suffix: "mono", af: [], extra: ["-ac", "1"], ctx: ctx)] },
                each("Stereo", Symbol.stereo) { url, _, ctx in [try Media.audioFilter(url, suffix: "stereo", af: [], extra: ["-ac", "2"], ctx: ctx)] },
            ]
            if single { list.append(metadata) }
            list.append(strip)
            if !single { list.append(batch("Join", Symbol.join) { urls, _, ctx in [try Media.join(urls, ctx: ctx)] }) }
            return list

        case .pdf:
            var list: [WheelAction] = [
                each("Compress", Symbol.compress) { url, _, ctx in [try PDFTools.compress(url, ctx: ctx)] },
                each("Target Size", Symbol.target, ask: askSize) { url, answer, ctx in
                    [try PDFTools.toSize(url, bytes: try need(Parse.byteSize(answer), "Couldn't understand “\(answer)”."), ctx: ctx)]
                },
            ]
            if single {
                list += [
                    each("Split", Symbol.split, ask: askPDFSplit) { url, answer, ctx in
                        let count = try PDFTools.open(url).pageCount
                        let groups: [[Int]]? = try answer.isEmpty ? nil : need(Parse.pageGroups(answer, count: count), "Couldn't understand “\(answer)”.")
                        return try PDFTools.split(url, groups: groups, ctx: ctx)
                    },
                    each("Reorder", Symbol.reorder, ask: askPDFOrder) { url, answer, ctx in
                        let count = try PDFTools.open(url).pageCount
                        let order: [Int] = try answer.lowercased() == "reverse"
                            ? Array((0..<count).reversed())
                            : need(Parse.pages(answer, count: count), "Couldn't understand “\(answer)”.")
                        return [try PDFTools.reorder(url, order: order, ctx: ctx)]
                    },
                ]
            }
            list.append(each("Rotate", Symbol.rotate) { url, _, ctx in [try PDFTools.rotate(url, ctx: ctx)] })
            if single { list.append(metadata) }
            list.append(strip)
            if !single { list.append(batch("Merge", Symbol.join) { urls, _, ctx in [try PDFTools.merge(urls, ctx: ctx)] }) }
            return list

        case .mixed:
            let kinds = Set(files.map(FileKind.of))
            if kinds.isSubset(of: [.image, .pdf]) {
                return [batch("Merge PDF", Symbol.pdf) { urls, _, ctx in [try PDFTools.merge(urls, ctx: ctx)] }, zip, strip]
            }
            return [zip, strip]

        case .document, .iwork, .subtitle, .archive, .other, .folder:
            return single ? [metadata, strip, zip] : [strip, zip]
        }
    }

    // MARK: - Questions

    private static func askSize(_ files: [URL]) -> String? {
        let current = files.count == 1 ? "It's \(formatBytes(fileSize(files[0]))) now." : "Each file is processed separately."
        return Prompt.text("Target Size", "How big should the result be? \(current)", placeholder: "e.g. 2 MB or 500 KB",
                           validate: { Parse.byteSize($0) != nil })
    }

    private static func askResize(_ files: [URL]) -> String? {
        Prompt.text("Resize", "Enter a percentage (50%), a longest side in pixels (1920), or a box to fit inside (1920x1080).",
                    placeholder: "50%", validate: { ImageTools.parseResize($0) != nil })
    }

    private static func askColor(_ files: [URL]) -> String? {
        Prompt.text("Add Background", "Background colour for transparent areas: a name (white, black) or hex (#FF8800).",
                    initial: "white", validate: { Parse.color($0) != nil })
    }

    private static func durationNote(_ files: [URL]) -> String {
        guard files.count == 1, let d = FFmpeg.info(files[0]).duration else { return "" }
        return " It's \(formatDuration(d)) long."
    }

    private static func askRange(_ files: [URL]) -> String? {
        Prompt.text("Trim", "Keep from – to (minutes:seconds).\(durationNote(files))", placeholder: "0:05 - 1:20",
                    validate: { Parse.range($0) != nil })
    }

    private static func askVideoCrop(_ files: [URL]) -> String? {
        Prompt.text("Crop Video", "Aspect ratio for a centred crop (1:1, 4:5, 9:16, 16:9) or exact pixels as W:H:X:Y.",
                    initial: "1:1", validate: { !$0.isEmpty })
    }

    static func speedFactor(_ raw: String) -> Double? {
        let value = Double(raw.lowercased().replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces))
        guard let value, value >= 0.1, value <= 16 else { return nil }
        return value
    }

    private static func askSpeed(_ files: [URL]) -> String? {
        Prompt.text("Change Speed", "Playback speed, e.g. 2 for twice as fast or 0.5 for half speed.", initial: "2",
                    validate: { speedFactor($0) != nil })
    }

    private static func askSplit(_ files: [URL]) -> String? {
        Prompt.text("Split", "Number of equal parts (e.g. 3), or the length of each part (e.g. 0:30).\(durationNote(files))",
                    initial: "2", validate: { !$0.isEmpty })
    }

    private static func askSnapshot(_ files: [URL]) -> String? {
        Prompt.text("Snapshot", "Time of the frame to save (e.g. 0:12). Leave empty to save 6 frames spread across the video.\(durationNote(files))",
                    placeholder: "0:12", validate: { $0.isEmpty || Parse.time($0) != nil })
    }

    private static func askBleep(_ files: [URL]) -> String? {
        Prompt.text("Bleep", "Time ranges to bleep, separated by commas.\(durationNote(files))", placeholder: "0:12-0:13, 1:05-1:06",
                    validate: { Parse.ranges($0) != nil })
    }

    private static func pageCount(_ files: [URL]) -> Int { files.first.flatMap { PDFTools.pageCountOrNil($0) } ?? 0 }

    private static func askPDFSplit(_ files: [URL]) -> String? {
        let count = pageCount(files)
        return Prompt.text("Split PDF", "Page ranges for each new PDF, e.g. 1-3, 4-6. Leave empty for one PDF per page. (\(count) pages)",
                           placeholder: "1-3, 4-\(max(count, 4))", validate: { $0.isEmpty || Parse.pageGroups($0, count: count) != nil })
    }

    private static func askPDFOrder(_ files: [URL]) -> String? {
        let count = pageCount(files)
        return Prompt.text("Reorder Pages", "New page order, e.g. 3, 1, 2, 4-\(max(count, 4)). Pages you leave out are removed. Type “reverse” to flip the order. (\(count) pages)",
                           placeholder: "reverse", validate: { $0.lowercased() == "reverse" || Parse.pages($0, count: count) != nil })
    }
}

extension PDFTools {
    static func pageCountOrNil(_ url: URL) -> Int? { (try? open(url))?.pageCount }
}
