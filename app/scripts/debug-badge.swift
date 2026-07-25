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

/// The artwork's bounding box — the icon tile, inside the canvas margins.
func tileBounds(of rep: NSBitmapImageRep) -> NSRect {
    let width = rep.pixelsWide, height = rep.pixelsHigh
    func opaque(_ x: Int, _ y: Int) -> Bool {
        (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
    }
    var minX = 0
    while minX < width, !(0..<height).contains(where: { opaque(minX, $0) }) { minX += 1 }
    var maxX = width - 1
    while maxX > minX, !(0..<height).contains(where: { opaque(maxX, $0) }) { maxX -= 1 }
    var minY = 0
    while minY < height, !(0..<width).contains(where: { opaque($0, minY) }) { minY += 1 }
    var maxY = height - 1
    while maxY > minY, !(0..<width).contains(where: { opaque($0, maxY) }) { maxY -= 1 }
    return NSRect(x: minX, y: minY,
                  width: maxX - minX + 1, height: maxY - minY + 1)
}

for file in files {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: file)) else { continue }
    let width = rep.pixelsWide, height = rep.pixelsHigh
    let size = CGFloat(min(width, height))
    let tile = tileBounds(of: rep)
    let tileSize = min(tile.width, tile.height)
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

    // Stripes over the whole canvas first.
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

    // Both ring edges follow the icon's continuous-corner curve: the outer
    // edge is the icon's own silhouette; the inner edge is that same
    // silhouette scaled inward by the band, so the corners stay aligned
    // with the system icon shape. Band thickness: tile size × 0.09 —
    // scaling the whole canvas moves the tile edge by inset × tile/canvas,
    // hence the inverse factor on the inset.
    source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    let band = tileSize * 0.09
    let inset = band * size / tileSize
    source.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero,
                operation: .destinationOut, fraction: 1)

    // The icon itself sits under the ring.
    source.draw(in: rect, from: .zero, operation: .destinationOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    if let png = canvas.representation(using: .png, properties: [:]) {
        try png.write(to: file)
    }
}
