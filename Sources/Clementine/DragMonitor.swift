import AppKit

/// Watches for file drags anywhere on the Mac. While the mouse button is down it polls the
/// system drag pasteboard and the modifier keys; Shift shows the convert wheel, Option+Shift the tools wheel.
/// Mouse-only monitoring doesn't need Accessibility or Input Monitoring permission.
final class DragMonitor {
    var onShow: (([URL], WheelMode, NSPoint) -> Void)?
    var onModeChange: ((WheelMode) -> Void)?
    var onDragEnd: (() -> Void)?
    var isEnabled = true

    private var monitors: [Any] = []
    private var timer: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var files: [URL]?
    private var shownMode: WheelMode?

    func start() {
        baseline = NSPasteboard(name: .drag).changeCount
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.beginPolling() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in self?.beginPolling() }) {
            monitors.append(m)
        }
    }

    private func beginPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endDrag()
            return
        }
        guard isEnabled else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baseline else { return }
        if files == nil {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            files = urls.map(\.standardizedFileURL)
        }
        guard let files, !files.isEmpty else { return }
        let flags = NSEvent.modifierFlags
        guard flags.contains(.shift) else { return }
        let mode: WheelMode = flags.contains(.option) ? .tools : .convert
        if shownMode == nil {
            shownMode = mode
            onShow?(files, mode, NSEvent.mouseLocation)
        } else if shownMode != mode {
            shownMode = mode
            onModeChange?(mode)
        }
    }

    private func endDrag() {
        timer?.invalidate()
        timer = nil
        baseline = NSPasteboard(name: .drag).changeCount
        files = nil
        if shownMode != nil {
            shownMode = nil
            onDragEnd?()
        }
    }
}
