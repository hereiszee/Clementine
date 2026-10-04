import AppKit

/// Small modal questions ("Trim from – to?"). In CLI mode answers come from `--answer`.
enum Prompt {
    static var cliAnswers: [String] = []

    static func text(_ title: String, _ message: String, placeholder: String = "", initial: String = "",
                     validate: ((String) -> Bool)? = nil) -> String? {
        if Runtime.isCLI {
            return cliAnswers.isEmpty ? initial : cliAnswers.removeFirst()
        }
        var current = initial
        while true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = placeholder
            field.stringValue = current
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if validate?(value) ?? true { return value }
            NSSound.beep()
            current = value
        }
    }

    static func info(_ title: String, _ message: String) {
        if Runtime.isCLI { print("\(title)\n\(message)"); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Shows decoded QR / barcode contents with Copy and Open buttons.
    static func showCodes(_ codes: [String]) {
        if Runtime.isCLI { codes.forEach { print($0) }; return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard !codes.isEmpty else {
            alert.messageText = "No QR code found"
            alert.informativeText = "Clementine couldn't find a QR code or barcode in that image."
            alert.runModal()
            return
        }
        let joined = codes.joined(separator: "\n")
        alert.messageText = codes.count == 1 ? "QR code" : "\(codes.count) codes"
        alert.informativeText = joined
        alert.addButton(withTitle: "Copy")
        let link = codes.compactMap { URL(string: $0) }.first { $0.scheme != nil }
        if link != nil { alert.addButton(withTitle: "Open Link") }
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
        } else if response == .alertSecondButtonReturn, let link {
            NSWorkspace.shared.open(link)
        }
    }
}
