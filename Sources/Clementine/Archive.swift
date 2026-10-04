import Foundation

/// ZIP / TAR / TAR.GZ / DMG creation and extraction of ZIP, TAR(.GZ/.BZ2/.XZ), GZ, RAR, 7Z…
enum Archive {
    static let exts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "rar", "7z", "cpio", "xar"]

    static func isArchive(_ url: URL) -> Bool {
        exts.contains(url.ext) && !url.isDirectory
    }

    /// Extracts into a fresh folder beside the archive; a lone top-level item is moved up.
    static func extract(_ url: URL, ctx: JobContext) throws -> URL {
        let dir = Output.directory(for: url)
        let dest = Output.unique(in: dir, base: url.baseName, ext: "")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try extractRaw(url, into: dest, ctx: ctx)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            Output.release(dest)
            throw error
        }
        let items = contents(of: dest)
        guard items.count == 1 else { return dest }
        let item = items[0]
        let parked = dir.appendingPathComponent(".clementine-" + UUID().uuidString)
        try FileManager.default.moveItem(at: item, to: parked)
        try FileManager.default.removeItem(at: dest)
        Output.release(dest)
        let final = Output.unique(in: dir, base: item.deletingPathExtension().lastPathComponent, ext: item.pathExtension)
        try FileManager.default.moveItem(at: parked, to: final)
        return final
    }

    static func extractRaw(_ url: URL, into dest: URL, ctx: JobContext) throws {
        let lower = url.lastPathComponent.lowercased()
        let isTarball = lower.contains(".tar.") || ["tgz", "tbz", "tbz2", "txz", "tar"].contains(url.ext)
        if url.ext == "zip" {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path], ctx: ctx)
        } else if ["gz", "bz2", "xz"].contains(url.ext) && !isTarball {
            let tool = url.ext == "gz" ? "/usr/bin/gzip" : url.ext == "bz2" ? "/usr/bin/bzip2" : (Shell.which("xz") ?? "/usr/bin/xz")
            let copy = dest.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            try Shell.run(tool, ["-d", "-f", copy.path], ctx: ctx)
        } else {
            try Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path], ctx: ctx)
        }
        try? FileManager.default.removeItem(at: dest.appendingPathComponent("__MACOSX"))
    }

    static func contents(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != "__MACOSX" }
    }

    /// Packs `names` (relative to `parent`) into `out`.
    static func pack(_ names: [String], parent: URL, format: String, to out: URL, ctx: JobContext) throws {
        let env = ["COPYFILE_DISABLE": "1"]
        switch format {
        case "zip":
            try Shell.run("/usr/bin/zip", ["-r", "-y", "-q", out.path] + names + ["-x", "*.DS_Store", "__MACOSX/*"], cwd: parent, ctx: ctx)
        case "tar":
            try Shell.run("/usr/bin/tar", ["--exclude", ".DS_Store", "-cf", out.path, "-C", parent.path] + names, environment: env, ctx: ctx)
        case "tar.gz":
            try Shell.run("/usr/bin/tar", ["--exclude", ".DS_Store", "-czf", out.path, "-C", parent.path] + names, environment: env, ctx: ctx)
        case "dmg":
            guard names.count == 1 else { throw fail("Disk images are made from a single folder.") }
            let source = parent.appendingPathComponent(names[0])
            try Shell.run("/usr/bin/hdiutil", ["create", "-volname", source.lastPathComponent, "-srcfolder", source.path,
                                               "-ov", "-format", "UDZO", out.path], ctx: ctx)
        default:
            throw fail("Can't create \(format.uppercased()) archives.")
        }
    }

    /// One archive containing all `items`.
    static func create(_ items: [URL], format: String, ctx: JobContext) throws -> URL {
        let first = items[0]
        let parent = first.deletingLastPathComponent()
        let base = items.count == 1 ? first.lastPathComponent : "Archive"
        let out = Output.unique(in: Output.directory(for: first), base: base, ext: format)
        let sameParent = items.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }
        let names = sameParent ? items.map(\.lastPathComponent) : items.map(\.path)
        return try producing(out) { try pack(names, parent: sameParent ? parent : URL(fileURLWithPath: "/"), format: format, to: out, ctx: ctx) }
    }

    /// Re-packs an archive in another format, keeping its internal layout.
    static func convert(_ url: URL, to format: String, ctx: JobContext) throws -> URL {
        let tmp = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extractRaw(url, into: tmp, ctx: ctx)
        let names = contents(of: tmp).map(\.lastPathComponent)
        guard !names.isEmpty else { throw fail("The archive is empty.") }
        let out = Output.unique(in: Output.directory(for: url), base: url.baseName, ext: format)
        return try producing(out) { try pack(names, parent: tmp, format: format, to: out, ctx: ctx) }
    }
}
