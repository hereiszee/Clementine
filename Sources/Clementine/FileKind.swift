import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, iwork, subtitle, archive, folder, other, mixed

    static let imageExts: Set<String> = ["jpg", "jpeg", "jpe", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
                                         "svg", "avif", "ico", "icns", "psd", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "jp2", "tga"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts", "ogv", "vob"]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "aac", "wma", "caf", "alac", "amr"]
    static let documentExts: Set<String> = ["txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.ext
        if ["pages", "key", "numbers"].contains(ext) { return .iwork }
        if ext == "rtfd" { return .document }
        if url.isDirectory { return .folder }
        if Archive.isArchive(url) { return .archive }
        if imageExts.contains(ext) { return .image }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if documentExts.contains(ext) { return .document }
        if ext == "srt" || ext == "vtt" { return .subtitle }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }

    static func group(_ files: [URL]) -> FileKind {
        let kinds = Set(files.map(of))
        return kinds.count == 1 ? kinds.first! : .mixed
    }
}
