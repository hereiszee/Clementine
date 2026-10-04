import AppKit

/// The citrus-slice artwork, drawn in code so there are no image assets to ship.
enum Icons {
    private static func wedge(center c: NSPoint, radius: CGFloat, from a0: CGFloat, to a1: CGFloat, offset: CGFloat) -> NSBezierPath {
        let mid = (a0 + a1) / 2 * .pi / 180
        let origin = NSPoint(x: c.x + offset * cos(mid), y: c.y + offset * sin(mid))
        let path = NSBezierPath()
        path.move(to: origin)
        path.appendArc(withCenter: origin, radius: radius, startAngle: a0, endAngle: a1)
        path.close()
        return path
    }

    static func statusBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 7.6
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 1.5
            ring.stroke()
            for i in 0..<8 {
                let a0 = CGFloat(i) * 45 + 5, a1 = CGFloat(i + 1) * 45 - 5
                wedge(center: c, radius: r - 2.6, from: a0, to: a1, offset: 0.9).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func appIcon(size s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            let body = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
            let tile = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSColor.white.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.9, alpha: 1))!.draw(in: tile, angle: -90)

            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = body.width * 0.36
            NSColor(srgbRed: 1, green: 0.52, blue: 0.08, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            let pith = r * 0.9
            NSColor(srgbRed: 1, green: 0.93, blue: 0.82, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - pith, y: c.y - pith, width: pith * 2, height: pith * 2)).fill()
            let flesh = NSGradient(starting: NSColor(srgbRed: 1, green: 0.74, blue: 0.3, alpha: 1),
                                   ending: NSColor(srgbRed: 1, green: 0.55, blue: 0.12, alpha: 1))!
            for i in 0..<8 {
                let a0 = CGFloat(i) * 45 + 4, a1 = CGFloat(i + 1) * 45 - 4
                flesh.draw(in: wedge(center: c, radius: r * 0.8, from: a0, to: a1, offset: r * 0.07), relativeCenterPosition: .zero)
            }
            return true
        }
    }

    static func writeAppIconPNG(size: Int, to path: String) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw fail("Couldn't allocate the icon.") }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appIcon(size: CGFloat(size)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let png = try need(rep.representation(using: .png, properties: [:]), "Couldn't encode the icon.")
        try png.write(to: URL(fileURLWithPath: path))
    }
}
