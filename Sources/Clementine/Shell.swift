import Foundation

/// Runs command-line tools (ffmpeg, zip, tar, textutil…).
enum Shell {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static var found: [String: String] = [:]
    private static let lock = NSLock()

    /// Finds an executable; also looks in the app bundle's Resources/bin so tools can be bundled.
    static func which(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let path = found[name] { return path }
        var dirs = searchPaths
        if let resources = Bundle.main.resourcePath { dirs.insert(resources + "/bin", at: 0) }
        guard let path = dirs.map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        found[name] = path
        return path
    }

    @discardableResult
    static func run(_ executable: String,
                    _ arguments: [String],
                    cwd: URL? = nil,
                    environment: [String: String] = [:],
                    ctx: JobContext? = nil,
                    onLine: ((String) -> Void)? = nil) throws -> String {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        try ctx?.check()
        do {
            try process.run()
        } catch {
            throw fail("Couldn't start \(name): \(error.localizedDescription)")
        }
        ctx?.attach(process)
        process.waitUntilExit()
        ctx?.attach(nil)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
        collector.flush()

        try ctx?.check()
        if process.terminationStatus != 0 {
            throw fail("\(name) failed: \(collector.errorTail)")
        }
        return collector.outString
    }
}

private final class OutputCollector {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pending = ""
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        out.append(data)
        var lines: [String] = []
        if onLine != nil, let text = String(data: data, encoding: .utf8) {
            pending += text
            while let idx = pending.firstIndex(of: "\n") {
                lines.append(String(pending[..<idx]))
                pending = String(pending[pending.index(after: idx)...])
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); err.append(data); lock.unlock()
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    var outString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var errorTail: String {
        lock.lock(); defer { lock.unlock() }
        var text = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.isEmpty { return "unknown error" }
        return text.count > 600 ? "…" + String(text.suffix(600)) : text
    }
}
