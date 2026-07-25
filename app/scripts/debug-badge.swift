import AppKit

// Overlay a hazard-stripe border — yellow/black construction diagonals —
// on every PNG of an iconset. The debug build's icon badge: the build
// identity lives on the icon, never as text inside the app.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: debug-badge.swift <iconset>\n".utf8))
    exit(1)
}
let dir = URL(fileURLWithPath: arguments[1])
let files = try FileManager.default
    .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }

for file in files {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: file)) else { continue }
    let width = rep.pixelsWide, height = rep.pixelsHigh
    let size = CGFloat(min(width, height))
    let source = NSImage(size: NSSize(width: width, height: height))
    source.addRepresentation(rep)

    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: canvas) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    source.draw(in: rect)

    // The stripe ring hugs the squircle, not the canvas: macOS icon art
    // sits inside ~10% transparent margins.
    NSGraphicsContext.saveGraphicsState()
    let margin = size * 0.085
    let band = size * 0.09
    let outer = rect.insetBy(dx: margin, dy: margin)
    let ring = NSBezierPath(rect: outer)
    ring.appendRect(outer.insetBy(dx: band, dy: band))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.05, alpha: 1).setFill()
    rect.fill()
    NSColor.black.setFill()
    let stripe = size * 0.11
    var x = -CGFloat(height)
    while x < CGFloat(width) + CGFloat(height) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x + stripe, y: 0))
        path.line(to: NSPoint(x: x + stripe + CGFloat(height), y: CGFloat(height)))
        path.line(to: NSPoint(x: x + CGFloat(height), y: CGFloat(height)))
        path.close()
        path.fill()
        x += stripe * 2
    }
    NSGraphicsContext.restoreGraphicsState()

    // Clip the stripes to the icon's own silhouette (rounded corners etc.).
    source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    if let png = canvas.representation(using: .png, properties: [:]) {
        try png.write(to: file)
    }
}
