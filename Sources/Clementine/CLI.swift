import AppKit

/// Command-line entry point, mainly for automated tests:
///   Clementine --convert PNG photo.jpg
///   Clementine --tool "Target Size" --answer "200 KB" photo.jpg
///   Clementine --list file…
///   Clementine --render-icon 512 icon.png
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        _ = NSApplication.shared
        Runtime.isCLI = true

        var mode: WheelMode?
        var name = ""
        var files: [URL] = []
        var answers: [String] = []
        var list = false
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--convert":
                mode = .convert
                name = next() ?? ""
            case "--tool":
                mode = .tools
                name = next() ?? ""
            case "--answer":
                answers.append(next() ?? "")
            case "--list":
                list = true
            case "--render-icon":
                guard let size = next().flatMap(Int.init), let path = next() else { return usage() }
                do {
                    try Icons.writeAppIconPNG(size: size, to: path)
                    return 0
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    return 1
                }
            case "--help", "-h":
                _ = usage()
                return 0
            default:
                files.append(URL(fileURLWithPath: arg).standardizedFileURL)
            }
            i += 1
        }

        guard !files.isEmpty else { return usage() }
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            FileHandle.standardError.write(Data("No such file: \(file.path)\n".utf8))
            return 2
        }
        if list {
            print("Convert:", ActionCatalog.actions(for: files, mode: .convert).map(\.title).joined(separator: ", "))
            print("Tools:  ", ActionCatalog.actions(for: files, mode: .tools).map(\.title).joined(separator: ", "))
            return 0
        }
        guard let mode else { return usage() }
        Prompt.cliAnswers = answers
        let key = normalized(name)
        let actions = ActionCatalog.actions(for: files, mode: mode)
        guard let action = actions.first(where: { normalized($0.title) == key }) else {
            FileHandle.standardError.write(Data("No “\(name)” action for these files. Available: \(actions.map(\.title).joined(separator: ", "))\n".utf8))
            return 2
        }
        action.perform(files)
        return JobRunner.cliFailures == 0 ? 0 : 1
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func usage() -> Int32 {
        print("""
        Usage:
          Clementine                                   run the menu bar app
          Clementine --convert FORMAT FILE…            e.g. --convert PNG photo.heic
          Clementine --tool NAME [--answer TEXT]… FILE… e.g. --tool "Target Size" --answer "500 KB" photo.jpg
          Clementine --list FILE…                      show what the wheels offer for these files
        """)
        return 2
    }
}
