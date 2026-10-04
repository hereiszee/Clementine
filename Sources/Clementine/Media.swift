import AVFoundation
import Foundation

/// Video and audio conversion and tools (ffmpeg, with an AVFoundation fallback for the basics).
enum Media {
    static let videoTargets = ["mp4", "mov", "mkv", "avi", "wmv", "webm", "gif", "mp3", "m4a", "wav"]
    static let audioTargets = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    // MARK: - Codecs

    static func h264(crf: Int) -> [String] {
        if FFmpeg.hasEncoder("libx264") {
            return ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
        }
        return ["-c:v", "h264_videotoolbox", "-b:v", crf >= 26 ? "2500k" : "8000k", "-pix_fmt", "yuv420p"]
    }

    static func videoCodec(for ext: String, crf: Int = 23) -> [String] {
        switch ext {
        case "webm":
            if FFmpeg.hasEncoder("libvpx-vp9") {
                return ["-c:v", "libvpx-vp9", "-crf", "\(crf + 10)", "-b:v", "0", "-row-mt", "1",
                        "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
            }
            if FFmpeg.hasEncoder("libsvtav1") {
                return ["-c:v", "libsvtav1", "-crf", "\(crf + 12)", "-preset", "8", "-pix_fmt", "yuv420p"]
            }
            return ["-c:v", "libvpx", "-crf", "10", "-b:v", "2M"]
        case "wmv":
            return ["-c:v", "wmv2", "-b:v", "4M"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "4", "-tag:v", "xvid"]
        default:
            var args = h264(crf: crf)
            if ["mp4", "mov", "m4v"].contains(ext) { args += ["-movflags", "+faststart"] }
            return args
        }
    }

    static func audioCodec(for ext: String, bitrate: String? = nil) throws -> [String] {
        switch ext {
        case "mp3":
            guard FFmpeg.hasEncoder("libmp3lame") else { throw fail("This ffmpeg build can't make MP3s (libmp3lame is missing).") }
            return bitrate.map { ["-c:a", "libmp3lame", "-b:a", $0] } ?? ["-c:a", "libmp3lame", "-q:a", "2"]
        case "wav":
            return ["-c:a", "pcm_s16le"]
        case "aiff":
            return ["-c:a", "pcm_s16be"]
        case "flac":
            return ["-c:a", "flac"]
        case "ogg":
            if FFmpeg.hasEncoder("libvorbis") { return ["-c:a", "libvorbis"] + (bitrate.map { ["-b:a", $0] } ?? ["-q:a", "5"]) }
            if FFmpeg.hasEncoder("libopus") { return ["-c:a", "libopus", "-b:a", bitrate ?? "128k"] }
            return ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", bitrate ?? "160k"]
        case "opus", "webm":
            if FFmpeg.hasEncoder("libopus") { return ["-c:a", "libopus", "-b:a", bitrate ?? "128k"] }
            return ["-c:a", "opus", "-strict", "-2", "-ar", "48000", "-ac", "2", "-b:a", bitrate ?? "128k"]
        case "wmv":
            return ["-c:a", "wmav2", "-b:a", bitrate ?? "192k"]
        case "avi":
            return FFmpeg.hasEncoder("libmp3lame") ? ["-c:a", "libmp3lame", "-b:a", bitrate ?? "192k"] : ["-c:a", "ac3", "-b:a", bitrate ?? "192k"]
        default:
            let encoder = FFmpeg.hasEncoder("aac_at") ? "aac_at" : "aac"
            return ["-c:a", encoder, "-b:a", bitrate ?? "192k"]
        }
    }

    /// Output extension for an edit that keeps the original format where that's sensible.
    static func keptExt(_ url: URL, _ info: FFmpeg.Info) -> String {
        let ext = url.normalizedExt
        if info.hasVideo { return ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv"].contains(ext) ? ext : "mp4" }
        return (audioTargets + ["aac"]).contains(ext) ? ext : "m4a"
    }

    /// Codec arguments for re-encoding `info`'s streams into `ext`, applying optional filters.
    static func encodeArgs(ext: String, info: FFmpeg.Info, crf: Int = 18, vf: [String] = [], af: [String] = [],
                           audioBitrate: String? = nil, keepAudio: Bool = true) throws -> [String] {
        var args: [String] = []
        let videoOut = info.hasVideo && !audioTargets.contains(ext) && ext != "aac"
        if videoOut {
            args += ["-map", "0:v:0"] + videoCodec(for: ext, crf: crf) + ["-vf", (vf + [evenScale]).joined(separator: ",")]
        } else {
            args += ["-vn"]
        }
        if info.hasAudio && keepAudio {
            args += ["-map", "0:a:0"] + (try audioCodec(for: ext, bitrate: audioBitrate))
            if !af.isEmpty { args += ["-af", af.joined(separator: ",")] }
        } else if videoOut {
            args += ["-an"]
        }
        return args
    }

    // MARK: - Convert

    static func convert(_ input: URL, to ext: String, ctx: JobContext) throws -> URL {
        let out = Output.url(for: input, ext: ext)
        return try producing(out) {
            if FFmpeg.path == nil {
                try avFallback(input, out, ext, ctx)
                return
            }
            let info = FFmpeg.info(input)
            if ext == "gif" {
                let filter = "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
                try FFmpeg.run(["-i", input.path, "-vf", filter, "-loop", "0", out.path], duration: info.duration, ctx: ctx)
                return
            }
            if audioTargets.contains(ext) {
                guard info.hasAudio else { throw fail("“\(input.lastPathComponent)” has no audio track.") }
                try FFmpeg.run(["-i", input.path, "-map", "0:a:0", "-vn"] + audioCodec(for: ext) + [out.path],
                               duration: info.duration, ctx: ctx)
                return
            }
            if canRemux(info, to: ext) {
                do {
                    let faststart = ["mp4", "mov"].contains(ext) ? ["-movflags", "+faststart"] : []
                    try FFmpeg.run(["-i", input.path, "-map", "0:v", "-map", "0:a?", "-c", "copy"] + faststart + [out.path],
                                   duration: info.duration, ctx: ctx)
                    return
                } catch {
                    try ctx.check() // otherwise fall through and re-encode
                }
            }
            var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a?"]
            args += videoCodec(for: ext) + ["-vf", evenScale]
            if info.hasAudio { args += try audioCodec(for: ext) }
            args.append(out.path)
            try FFmpeg.run(args, duration: info.duration, ctx: ctx)
        }
    }

    static func canRemux(_ info: FFmpeg.Info, to ext: String) -> Bool {
        guard let video = info.videoCodec else { return false }
        switch ext {
        case "mkv":
            return true
        case "mp4", "mov":
            let audioOK = info.audioCodec.map { ["aac", "mp3", "alac", "ac3"].contains($0) } ?? true
            return ["h264", "hevc", "mpeg4"].contains(video) && audioOK
        default:
            return false
        }
    }

    private static func avFallback(_ input: URL, _ out: URL, _ ext: String, _ ctx: JobContext) throws {
        switch ext {
        case "mp4": try avExport(input, out, .mp4, AVAssetExportPresetHighestQuality, ctx)
        case "mov": try avExport(input, out, .mov, AVAssetExportPresetHighestQuality, ctx)
        case "m4a": try avExport(input, out, .m4a, AVAssetExportPresetAppleM4A, ctx)
        default: throw ClementineError.missingTool("ffmpeg", FFmpeg.installHint)
        }
    }

    private static func avExport(_ input: URL, _ out: URL, _ type: AVFileType, _ preset: String, _ ctx: JobContext) throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: preset) else {
            throw fail("This file can't be exported without ffmpeg. \(FFmpeg.installHint)")
        }
        session.outputURL = out
        session.outputFileType = type
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            ctx.progress(Double(session.progress))
            if ctx.isCancelled { session.cancelExport() }
        }
        try ctx.check()
        guard session.status == .completed else {
            throw fail(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    // MARK: - Shared tools

    static func trim(_ input: URL, start: Double, end: Double, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let ext = keptExt(input, info)
        let out = Output.url(for: input, ext: ext, suffix: "trimmed")
        return try producing(out) {
            try FFmpeg.run(["-ss", seconds(start), "-i", input.path, "-t", seconds(end - start)]
                           + encodeArgs(ext: ext, info: info) + [out.path], duration: end - start, ctx: ctx)
        }
    }

    static func speed(_ input: URL, factor: Double, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let ext = keptExt(input, info)
        let out = Output.url(for: input, ext: ext, suffix: "\(trimNumber(factor))x")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, vf: ["setpts=PTS/\(factor)"], af: [atempo(factor)]) + [out.path],
                           duration: info.duration.map { $0 / factor }, ctx: ctx)
        }
    }

    static func atempo(_ factor: Double) -> String {
        var f = factor
        var parts: [String] = []
        while f > 2 { parts.append("atempo=2.0"); f /= 2 }
        while f < 0.5 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append("atempo=\(f)")
        return parts.joined(separator: ",")
    }

    static func split(_ input: URL, spec: String, ctx: JobContext) throws -> [URL] {
        let info = FFmpeg.info(input)
        guard let duration = info.duration, duration > 0 else { throw fail("Couldn't read the duration.") }
        var length: Double
        if spec.contains(":") {
            length = try need(Parse.time(spec), "Couldn't understand “\(spec)”.")
        } else {
            let parts = try need(Int(spec.trimmingCharacters(in: .whitespaces)), "Enter a number of parts or a length like 0:30.")
            guard parts >= 2 else { throw fail("Split into at least 2 parts.") }
            length = duration / Double(parts)
        }
        guard length > 0.5 else { throw fail("Parts would be too short.") }
        let ext = keptExt(input, info)
        var outputs: [URL] = []
        var start = 0.0
        var index = 1
        let count = Int(ceil(duration / length - 0.01))
        while start < duration - 0.05 {
            let partLength = min(length, duration - start)
            let out = Output.url(for: input, ext: ext, suffix: "part \(index)")
            let lower = Double(index - 1) / Double(count), upper = min(1, Double(index) / Double(count))
            outputs.append(try producing(out) {
                try FFmpeg.run(["-ss", seconds(start), "-i", input.path, "-t", seconds(partLength)]
                               + encodeArgs(ext: ext, info: info) + [out.path],
                               duration: partLength, ctx: ctx, range: lower...max(lower, upper))
            })
            start += length
            index += 1
        }
        return outputs
    }

    static func join(_ inputs: [URL], ctx: JobContext) throws -> URL {
        let infos = inputs.map(FFmpeg.info)
        let total = infos.compactMap(\.duration).reduce(0, +)
        let first = inputs[0]
        let video = infos.allSatisfy(\.hasVideo)
        let ext = video ? "mp4" : keptExt(first, infos[0])
        let out = Output.unique(in: Output.directory(for: first), base: first.baseName + " joined", ext: ext)
        var args: [String] = []
        for url in inputs { args += ["-i", url.path] }
        var filters: [String] = []
        var concatInputs = ""
        var extraIndex = inputs.count
        let width = max(2, (infos[0].width ?? 1920) / 2 * 2), height = max(2, (infos[0].height ?? 1080) / 2 * 2)
        for (i, info) in infos.enumerated() {
            if video {
                filters.append("[\(i):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(i)]")
                concatInputs += "[v\(i)]"
            }
            if info.hasAudio {
                filters.append("[\(i):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(i)]")
            } else {
                args += ["-f", "lavfi", "-t", seconds(info.duration ?? 1), "-i", "anullsrc=r=48000:cl=stereo"]
                filters.append("[\(extraIndex):a]aformat=sample_rates=48000:channel_layouts=stereo[a\(i)]")
                extraIndex += 1
            }
            concatInputs += "[a\(i)]"
        }
        filters.append("\(concatInputs)concat=n=\(inputs.count):v=\(video ? 1 : 0):a=1" + (video ? "[v][a]" : "[a]"))
        args += ["-filter_complex", filters.joined(separator: ";")]
        if video {
            args += ["-map", "[v]", "-map", "[a]"] + h264(crf: 20) + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        } else {
            args += ["-map", "[a]"] + (try audioCodec(for: ext))
        }
        args.append(out.path)
        return try producing(out) { try FFmpeg.run(args, duration: total, ctx: ctx) }
    }

    static func stripMetadata(_ input: URL, ctx: JobContext) throws -> URL {
        let out = Output.url(for: input, ext: input.ext, suffix: "clean")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy",
                            "-fflags", "+bitexact", out.path], duration: FFmpeg.info(input).duration, ctx: ctx)
        }
    }

    static func writeMetadata(_ input: URL, fields: MetadataFields, ctx: JobContext) throws -> URL {
        let out = Output.url(for: input, ext: input.ext, suffix: "edited")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path, "-map", "0", "-c", "copy",
                            "-metadata", "title=\(fields.title)",
                            "-metadata", "artist=\(fields.author)",
                            "-metadata", "comment=\(fields.description)",
                            "-metadata", "copyright=\(fields.copyright)",
                            "-metadata", "keywords=\(fields.keywords)",
                            out.path], ctx: ctx)
        }
    }

    // MARK: - Video tools

    static func compressVideo(_ input: URL, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let out = Output.url(for: input, ext: "mp4", suffix: "compressed")
        var vf = evenScale
        if let w = info.width, let h = info.height, max(w, h) > 1920 {
            vf = "scale='if(gt(iw,ih),1920,-2)':'if(gt(iw,ih),-2,1920)'"
        }
        return try producing(out) {
            var args = ["-i", input.path, "-map", "0:v:0"] + h264(crf: 28) + ["-vf", vf, "-movflags", "+faststart"]
            args += info.hasAudio ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "128k"] : ["-an"]
            try FFmpeg.run(args + [out.path], duration: info.duration, ctx: ctx)
        }
    }

    static func videoToSize(_ input: URL, bytes: Int64, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        guard let duration = info.duration, duration > 0 else { throw fail("Couldn't read the video's duration.") }
        let audioRate = info.hasAudio ? 96_000.0 : 0
        let videoRate = Double(bytes) * 8 * 0.95 / duration - audioRate
        guard videoRate > 40_000 else { throw fail("\(formatBytes(bytes)) is too small for a \(formatDuration(duration)) video.") }
        let maxSide = videoRate < 600_000 ? 854 : videoRate < 1_500_000 ? 1280 : videoRate < 4_000_000 ? 1920 : 0
        var vf = evenScale
        if maxSide > 0, let w = info.width, let h = info.height, max(w, h) > maxSide {
            vf = "scale='if(gt(iw,ih),\(maxSide),-2)':'if(gt(iw,ih),-2,\(maxSide))'"
        }
        let rate = "\(Int(videoRate))"
        let out = Output.url(for: input, ext: "mp4", suffix: formatBytes(bytes))
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audio = info.hasAudio ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "96k"] : ["-an"]
        return try producing(out) {
            if FFmpeg.hasEncoder("libx264") {
                let common = ["-i", input.path, "-map", "0:v:0", "-c:v", "libx264", "-preset", "medium", "-b:v", rate,
                              "-pix_fmt", "yuv420p", "-vf", vf, "-passlogfile", tmp.appendingPathComponent("pass").path]
                try FFmpeg.run(common + ["-pass", "1", "-an", "-f", "null", "/dev/null"], duration: duration, ctx: ctx, range: 0...0.5)
                try FFmpeg.run(common + ["-pass", "2"] + audio + ["-movflags", "+faststart", out.path],
                               duration: duration, ctx: ctx, range: 0.5...1)
            } else {
                try FFmpeg.run(["-i", input.path, "-map", "0:v:0", "-c:v", "h264_videotoolbox", "-b:v", rate,
                                "-maxrate", rate, "-bufsize", "\(Int(videoRate * 2))", "-pix_fmt", "yuv420p", "-vf", vf]
                               + audio + ["-movflags", "+faststart", out.path], duration: duration, ctx: ctx)
            }
        }
    }

    /// `spec` is an aspect ratio ("1:1", "16:9") for a centred crop, or "W:H:X:Y" in pixels.
    static func cropVideo(_ input: URL, spec: String, ctx: JobContext) throws -> URL {
        let numbers = spec.replacingOccurrences(of: " ", with: "").split(whereSeparator: { ":x/".contains($0) }).compactMap { Double($0) }
        let filter: String
        if numbers.count == 4 {
            filter = "crop=\(Int(numbers[0])):\(Int(numbers[1])):\(Int(numbers[2])):\(Int(numbers[3]))"
        } else if numbers.count == 2, numbers[0] > 0, numbers[1] > 0 {
            let ratio = numbers[0] / numbers[1]
            filter = "crop='min(iw,ih*\(ratio))':'min(ih,iw/\(ratio))'"
        } else {
            throw fail("Use an aspect ratio like 1:1 or 9:16, or W:H:X:Y.")
        }
        let info = FFmpeg.info(input)
        let ext = keptExt(input, info)
        let out = Output.url(for: input, ext: ext, suffix: "cropped")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, vf: [filter]) + [out.path],
                           duration: info.duration, ctx: ctx)
        }
    }

    static func rotateVideo(_ input: URL, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let ext = keptExt(input, info)
        let out = Output.url(for: input, ext: ext, suffix: "rotated")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, vf: ["transpose=1"]) + [out.path],
                           duration: info.duration, ctx: ctx)
        }
    }

    static func mute(_ input: URL, ctx: JobContext) throws -> URL {
        let out = Output.url(for: input, ext: input.ext, suffix: "muted")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path, "-map", "0:v", "-c", "copy", "-an", out.path], ctx: ctx)
        }
    }

    static func snapshots(_ input: URL, at time: Double?, ctx: JobContext) throws -> [URL] {
        let duration = FFmpeg.info(input).duration ?? 0
        let times: [Double] = time.map { [$0] } ?? (duration > 0 ? (1...6).map { duration * Double($0) / 7 } : [0])
        var outputs: [URL] = []
        for (i, t) in times.enumerated() {
            let stamp = formatDuration(t).replacingOccurrences(of: ":", with: ".")
            let out = Output.url(for: input, ext: "png", suffix: "at \(stamp)")
            outputs.append(try producing(out) {
                try FFmpeg.run(["-ss", seconds(t), "-i", input.path, "-frames:v", "1", "-update", "1", out.path], ctx: ctx)
            })
            ctx.progress(Double(i + 1) / Double(times.count))
        }
        return outputs
    }

    // MARK: - Audio tools

    static func compressAudio(_ input: URL, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let source = input.normalizedExt
        let (ext, bitrate): (String, String) = {
            switch source {
            case "mp3": return ("mp3", "96k")
            case "opus": return ("opus", "64k")
            case "ogg": return ("ogg", "96k")
            default: return ("m4a", source == "m4a" || source == "aac" ? "96k" : "128k")
            }
        }()
        let out = Output.url(for: input, ext: ext, suffix: "compressed")
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, audioBitrate: bitrate) + [out.path],
                           duration: info.duration, ctx: ctx)
        }
    }

    static func audioToSize(_ input: URL, bytes: Int64, ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        guard let duration = info.duration, duration > 0 else { throw fail("Couldn't read the duration.") }
        let kbps = Int(Double(bytes) * 8 * 0.96 / duration / 1000)
        guard kbps >= 16 else { throw fail("\(formatBytes(bytes)) is too small for \(formatDuration(duration)) of audio.") }
        let ext = input.normalizedExt == "mp3" ? "mp3" : "m4a"
        let out = Output.url(for: input, ext: ext, suffix: formatBytes(bytes))
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, audioBitrate: "\(min(kbps, 320))k") + [out.path],
                           duration: duration, ctx: ctx)
        }
    }

    /// Re-encodes keeping the format, applying audio filters / extra output options.
    static func audioFilter(_ input: URL, suffix: String, af: [String], extra: [String] = [], ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        let ext = keptExt(input, info)
        let out = Output.url(for: input, ext: ext, suffix: suffix)
        return try producing(out) {
            try FFmpeg.run(["-i", input.path] + encodeArgs(ext: ext, info: info, af: af) + extra + [out.path],
                           duration: info.duration, ctx: ctx)
        }
    }

    static func normalize(_ input: URL, ctx: JobContext) throws -> URL {
        let rate = FFmpeg.info(input).sampleRate ?? 48000
        return try audioFilter(input, suffix: "normalized", af: ["loudnorm=I=-16:TP=-1.5:LRA=11"], extra: ["-ar", "\(rate)"], ctx: ctx)
    }

    static func trimSilence(_ input: URL, ctx: JobContext) throws -> URL {
        let edge = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1"
        return try audioFilter(input, suffix: "trimmed", af: [edge, "areverse", edge, "areverse"], ctx: ctx)
    }

    /// Silences the given ranges and lays a 1 kHz beep over them.
    static func bleep(_ input: URL, ranges: [(start: Double, end: Double)], ctx: JobContext) throws -> URL {
        let info = FFmpeg.info(input)
        guard info.hasAudio else { throw fail("No audio to bleep.") }
        let ext = keptExt(input, info)
        let when = ranges.map { "between(t,\(seconds($0.start)),\(seconds($0.end)))" }.joined(separator: "+")
        let graph = "[0:a:0]volume=0:enable='\(when)'[muted];"
            + "sine=frequency=1000:sample_rate=48000,volume=0.3,volume=0:enable='not(\(when))'[tone];"
            + "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
        let out = Output.url(for: input, ext: ext, suffix: "bleeped")
        var args = ["-i", input.path, "-filter_complex", graph]
        if info.hasVideo && !audioTargets.contains(ext) {
            args += ["-map", "0:v:0", "-c:v", "copy"]
        }
        args += ["-map", "[a]"] + (try audioCodec(for: ext)) + [out.path]
        return try producing(out) { try FFmpeg.run(args, duration: info.duration, ctx: ctx) }
    }

    private static func trimNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}
