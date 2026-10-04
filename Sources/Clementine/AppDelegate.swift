import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let wheel = WheelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Icons.statusBarImage()
        statusItem.button?.toolTip = "Clementine"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.isEnabled = !UserDefaults.standard.bool(forKey: "paused")
        monitor.onShow = { [weak self] files, mode, point in self?.wheel.show(files: files, mode: mode, at: point, interaction: .drag) }
        monitor.onModeChange = { [weak self] mode in self?.wheel.switchMode(mode) }
        monitor.onDragEnd = { [weak self] in self?.wheel.dragEnded() }
        monitor.start()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showHowItWorks() }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Hold ⇧ while dragging files to convert", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let header2 = NSMenuItem(title: "Hold ⌥⇧ while dragging for tools", action: nil, keyEquivalent: "")
        header2.isEnabled = false
        menu.addItem(header2)
        menu.addItem(.separator())

        menu.addItem(item("Convert Files…", #selector(chooseForConvert), key: "o"))
        menu.addItem(item("Tools for Files…", #selector(chooseForTools), key: "t"))
        menu.addItem(.separator())

        let enabled = item("Watch for Drags", #selector(toggleEnabled))
        enabled.state = monitor.isEnabled ? .on : .off
        menu.addItem(enabled)
        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = item("Open at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        if let ffmpeg = FFmpeg.path {
            let found = NSMenuItem(title: "ffmpeg: \(ffmpeg)", action: nil, keyEquivalent: "")
            found.isEnabled = false
            menu.addItem(found)
        } else {
            menu.addItem(item("Install ffmpeg for Video & Audio…", #selector(showFFmpegHelp)))
        }
        menu.addItem(.separator())
        menu.addItem(item("How It Works…", #selector(showHowItWorks)))
        menu.addItem(item("Quit Clementine", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func chooseForConvert() { choose(mode: .convert) }
    @objc private func chooseForTools() { choose(mode: .tools) }

    private func choose(mode: WheelMode) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = mode == .convert ? "Convert" : "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        wheel.show(files: panel.urls, mode: mode, at: NSPoint(x: screen.midX, y: screen.midY), interaction: .click)
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        UserDefaults.standard.set(!monitor.isEnabled, forKey: "paused")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Prompt.info("Couldn't change login item", error.localizedDescription)
        }
    }

    @objc private func showFFmpegHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install ffmpeg"
        alert.informativeText = """
        Clementine uses ffmpeg for most video and audio work (images, PDFs, documents and archives work without it).

        With Homebrew installed (brew.sh), run this in Terminal:

            brew install ffmpeg

        Clementine finds it automatically — no restart needed.
        """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
        }
    }

    @objc private func showHowItWorks() {
        Prompt.info("Clementine is running in your menu bar", """
        • Start dragging any file in Finder, then hold ⇧ Shift — a wheel of formats appears around the pointer. Drop the file on a format and the converted copy is saved right beside the original.

        • Hold ⌥ Option + ⇧ Shift instead for tools: compress, target size, trim, crop, redact, metadata and more.

        • Drag several files at once to process them together. Drop in the middle of the wheel to cancel.

        • Everything happens on your Mac — nothing is uploaded.

        You can also pick files from the 🍊 menu bar icon.
        """)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
