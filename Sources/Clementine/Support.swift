import AppKit
import Foundation

enum Runtime {
    /// True when running as a command-line tool (`Clementine --convert ...`), used by tests.
    static var isCLI = false
}

enum ClementineError: LocalizedError {
    case cancelled
    case missingTool(String, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .missingTool(let tool, let hint): return "\(tool) is needed for this. \(hint)"
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) -> ClementineError { .failed(message) }

/// Unwraps `value` or throws `message`.
func need<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw fail(message) }
    return value
}

func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

/// Runs `body`; if it throws, the half-written `output` is deleted. Returns `output`.
func producing(_ output: URL, _ body: () throws -> Void) throws -> URL {
    do {
        try body()
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw fail("Nothing was written to \(output.lastPathComponent).")
        }
        return output
    } catch {
        try? FileManager.default.removeItem(at: output)
        Output.release(output)
        throw error
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

extension URL {
    var ext: String { pathExtension.lowercased() }

    var isDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// File name without its extension; understands double extensions like `.tar.gz`.
    var baseName: String {
        let name = lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return deletingPathExtension().lastPathComponent
    }

    /// Extension folded to the spelling Clementine uses for formats (jpeg → jpg, tif → tiff…).
    var normalizedExt: String {
        let lower = lastPathComponent.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "tar.gz" }
        switch ext {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif": return "aiff"
        case "htm": return "html"
        case "oga": return "ogg"
        case "markdown": return "md"
        default: return ext
        }
    }
}
