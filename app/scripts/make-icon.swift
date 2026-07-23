// Renders the app icon: a continuation chain — two evaluated steps joined
// by a solid segment, a dashed segment leading to the next step, lit.
// Vector-drawn per size so every raster is crisp. Usage:
//   swift make-icon.swift <out-dir>          # writes AppIcon.iconset PNGs

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (pixel size, file name) — the full macOS iconset matrix.
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [r, g, b, a])!
}

func draw(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024.0

    // macOS icon grid: 824pt content, rounded r≈185, centered on 1024.
    let content = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: content, cornerWidth: 185 * s,
                       cornerHeight: 185 * s, transform: nil)
    ctx.addPath(shape)
    ctx.clip()

    // Background: deep indigo falling to near-black.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgba(0.114, 0.129, 0.267), rgba(0.024, 0.031, 0.075)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: content.midX, y: content.maxY),
        end: CGPoint(x: content.midX, y: content.minY), options: [])

    // The chain, rising left→right. y-up coordinates in 1024 space.
    // Small rasters get a bolder, simplified variant or the mark vanishes.
    let boost: CGFloat = size <= 32 ? 2.1 : size <= 64 ? 1.7 : size <= 128 ? 1.25 : 1
    let simplified = size <= 32
    let p1 = CGPoint(x: 330 * s, y: 350 * s)
    let p2 = CGPoint(x: 512 * s, y: 512 * s)
    let p3 = CGPoint(x: 694 * s, y: 674 * s)
    let r1 = 34 * s * boost, r2 = 44 * s * boost, r3 = 58 * s * boost
    let lineWidth = 16 * s * boost

    func segment(_ a: CGPoint, _ b: CGPoint, ra: CGFloat, rb: CGFloat,
                 dashed: Bool) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        let ux = dx / len, uy = dy / len
        let gap = 26 * s
        let start = CGPoint(x: a.x + ux * (ra + gap), y: a.y + uy * (ra + gap))
        let end = CGPoint(x: b.x - ux * (rb + gap), y: b.y - uy * (rb + gap))
        ctx.saveGState()
        ctx.setStrokeColor(rgba(1, 1, 1, dashed ? 0.38 : 0.30))
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        if dashed { ctx.setLineDash(phase: 0, lengths: [30 * s, 34 * s]) }
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.restoreGState()
    }

    segment(p1, p2, ra: r1, rb: r2, dashed: false)
    segment(p2, p3, ra: r2, rb: r3, dashed: !simplified)

    // Evaluated steps: quiet white dots.
    ctx.setFillColor(rgba(1, 1, 1, 0.42))
    ctx.addEllipse(in: CGRect(x: p1.x - r1, y: p1.y - r1, width: 2 * r1, height: 2 * r1))
    ctx.fillPath()
    ctx.setFillColor(rgba(1, 1, 1, 0.62))
    ctx.addEllipse(in: CGRect(x: p2.x - r2, y: p2.y - r2, width: 2 * r2, height: 2 * r2))
    ctx.fillPath()

    // The next step: lit, with a soft halo.
    let halo = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgba(0.298, 0.553, 1, 0.55), rgba(0.298, 0.553, 1, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        halo, startCenter: p3, startRadius: 0,
        endCenter: p3, endRadius: r3 * 2.6, options: [])
    ctx.setFillColor(rgba(0.353, 0.588, 1))
    ctx.addEllipse(in: CGRect(x: p3.x - r3, y: p3.y - r3, width: 2 * r3, height: 2 * r3))
    ctx.fillPath()
    if !simplified {
        ctx.setFillColor(rgba(0.78, 0.87, 1, 0.9))
        let core = r3 * 0.42
        ctx.addEllipse(in: CGRect(x: p3.x - core, y: p3.y + r3 * 0.18,
                                  width: 2 * core, height: 2 * core * 0.72))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

for (size, name) in variants {
    let image = draw(size: size)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(outDir.path)")
