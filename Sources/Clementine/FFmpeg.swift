import AVFoundation
import Foundation

enum FFmpeg {
    static let installHint = "Install it with Homebrew:  brew install ffmpeg"

    static var path: String? { Shell.which("ffmpeg") }
    static var probePath: String? { Shell.which("ffprobe") }

    static func require() throws -> String {
        guard let path else { throw ClementineError.missingTool("ffmpeg", installHint) }
        return path
    }

    private static let encoderLock = NSLock()
    private static var encoders: Set<String>?

    static func hasEncoder(_ name: String) -> Bool {
        encoderLock.lock(); defer { encoderLock.unlock() }
        if encoders == nil, let exe = path, let out = try? Shell.run(exe, ["-hide_banner", "-encoders"]) {
            encoders = Set(out.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[0].count == 6 else { return nil }
                return String(parts[1])
            })
        }
        return encoders?.contains(name) ?? false
    }

    struct Info {
        var duration: Double?
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?
        var sampleRate: Int?
        var tags: [String: String] = [:]
        var raw: [String: Any] = [:]
        var hasVideo: Bool { videoCodec != nil }
        var hasAudio: Bool { audioCodec != nil }
    }

    static func info(_ url: URL) -> Info {
        var info = Info()
        if let probe = probePath,
           let out = try? Shell.run(probe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path]),
           let json = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] {
            info.raw = json
            if let format = json["format"] as? [String: Any] {
                info.duration = (format["duration"] as? String).flatMap(Double.init)
                for (key, value) in format["tags"] as? [String: Any] ?? [:] { info.tags[key.lowercased()] = "\(value)" }
            }
            for stream in json["streams"] as? [[String: Any]] ?? [] {
                let type = stream["codec_type"] as? String
                let attachedPicture = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
                if type == "video", !attachedPicture, info.videoCodec == nil {
                    info.videoCodec = stream["codec_name"] as? String ?? "unknown"
                    info.width = stream["width"] as? Int
                    info.height = stream["height"] as? Int
                    if info.duration == nil { info.duration = (stream["duration"] as? String).flatMap(Double.init) }
                }
                if type == "audio", info.audioCodec == nil {
                    info.audioCodec = stream["codec_name"] as? String ?? "unknown"
                    info.sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init)
                    if info.duration == nil { info.duration = (stream["duration"] as? String).flatMap(Double.init) }
                }
            }
        } else {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite, seconds > 0 { info.duration = seconds }
            if let track = asset.tracks(withMediaType: .video).first {
                info.videoCodec = "video"
                info.width = Int(abs(track.naturalSize.width))
                info.height = Int(abs(track.naturalSize.height))
            }
            if !asset.tracks(withMediaType: .audio).isEmpty { info.audioCodec = "audio" }
        }
        return info
    }

    /// Runs ffmpeg, reporting progress (mapped into `range`) when the duration is known.
    static func run(_ args: [String], duration: Double? = nil, ctx: JobContext?, range: ClosedRange<Double> = 0...1) throws {
        let exe = try require()
        let base = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]
        try Shell.run(exe, base + args, ctx: ctx) { line in
            guard let ctx, let duration, duration > 0 else { return }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "out_time_us" || parts[0] == "out_time_ms",
                  let micros = Double(parts[1]) else { return }
            let fraction = min(1, max(0, micros / 1_000_000 / duration))
            ctx.progress(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
        }
    }
}

func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
