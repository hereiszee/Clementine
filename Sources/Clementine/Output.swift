import Foundation

/// Picks where converted files go: right beside the original, never overwriting anything.
enum Output {
    private static let lock = NSLock()
    private static var reserved = Set<String>()

    static func directory(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// `photo.png` + "jpg" → `photo.jpg` (or `photo 2.jpg` if taken). A suffix gives `photo compressed.jpg`.
    static func url(for input: URL, ext: String, suffix: String? = nil) -> URL {
        let base = input.baseName + (suffix.map { " " + $0 } ?? "")
        return unique(in: directory(for: input), base: base, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        lock.lock(); defer { lock.unlock() }
        let safeBase = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var n = 1
        while true {
            let name = n == 1 ? safeBase : "\(safeBase) \(n)"
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent(name)
                : dir.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) && !reserved.contains(candidate.path) {
                reserved.insert(candidate.path)
                return candidate
            }
            n += 1
        }
    }

    static func release(_ url: URL) {
        lock.lock(); reserved.remove(url.path); lock.unlock()
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clementine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
