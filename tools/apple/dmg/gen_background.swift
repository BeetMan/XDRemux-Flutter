#!/usr/bin/env swift
// Render the installer window background for the macOS DMG:
//
//   tools/apple/dmg/background.png     660x530  (1x)
//   tools/apple/dmg/background@2x.png  1320x1060 (Retina)
//
// Follows the light theme of xdremux.app: an off-white surface with soft
// teal, blue and warm horizon glows, the "XDRemux" wordmark in the site's
// blue-grey to purple to orange gradient with its tagline underneath, a dark
// drag arrow between the app icon and the Applications link, and a hairline
// above the row of smaller items (licence files, privacy shortcut).
//
// Deliberately light, not the site's black: Finder draws icon labels in the
// system appearance's colour, which is near-black in light mode and would
// vanish on a dark picture.
//
// The picture is drawn 470 points tall like the window's content area, plus
// 60 points of spare background underneath: Finder crops the picture at the
// bottom of the content area, whose height depends on the title bar.
// The window size and the icon positions live in settings.py; keep the
// numbers here in step with them.
//
// Regenerate:  swift tools/apple/dmg/gen_background.swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 660.0
let contentHeight = 470.0
let height = contentHeight + 60.0

// Icon centres from settings.py.
let heroY = 172.0
let dividerY = 286.0

// Site palette, light theme (xdremux.app CSS variables).
let fg = "1d1d1f", fgDim = "6e6e73", teal = "0a8a76", blue = "0066cc"
let warm1 = "ffe0b0", warm2 = "ff9a5c", warm3 = "d4577c"

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let v = UInt32(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ hex: String, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: sRGB, colors: [color(hex, alpha), color(hex, 0)] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

func makeLine(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let ns = NSAttributedString(string: string, attributes: [.font: font])
    return CTLineCreateWithAttributedString(ns as CFAttributedString)
}

/// Draw glyphs upright with their baseline at (x, y) in top-left coordinates.
func drawGlyphs(_ ctx: CGContext, _ line: CTLine, x: CGFloat, y: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: -1)   // undo the flipped context for CoreText
    ctx.textMatrix = .identity
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// One line of text in a solid colour.
func text(_ ctx: CGContext, _ string: String, x: CGFloat, baseline y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, fill: CGColor) {
    ctx.saveGState()
    ctx.setFillColor(fill)
    drawGlyphs(ctx, makeLine(string, size: size, weight: weight), x: x, y: y)
    ctx.restoreGState()
}

/// One line of text filled with a horizontal gradient: the glyphs are drawn
/// into an offscreen bitmap as a mask and the gradient is painted through
/// them with sourceIn; the result is composited onto the background.
func gradientText(_ ctx: CGContext, _ string: String, x: CGFloat, baseline y: CGFloat, size: CGFloat,
                  weight: NSFont.Weight, stops: [String], at locations: [CGFloat]) {
    let line = makeLine(string, size: size, weight: weight)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let pad: CGFloat = 8
    let w = Int(ceil(bounds.width)) + 2 * Int(pad), h = Int(ceil(bounds.height)) + 2 * Int(pad)
    guard let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    // The bitmap is y-up; the baseline sits pad above the bottom of the glyph box.
    mask.setFillColor(.black)
    mask.textMatrix = .identity
    mask.textPosition = CGPoint(x: pad - bounds.minX, y: pad + bounds.minY)
    CTLineDraw(line, mask)
    mask.setBlendMode(.sourceIn)
    let g = CGGradient(colorsSpace: sRGB, colors: stops.map { color($0) } as CFArray,
                       locations: locations)!
    mask.drawLinearGradient(g, start: CGPoint(x: pad, y: 0), end: CGPoint(x: pad + bounds.width, y: 0),
                            options: [])
    guard let image = mask.makeImage() else { return }
    // The context is flipped (y down) and would mirror the bitmap, so undo
    // the flip for this draw; the baseline lands on y.
    let top = y + bounds.minY - CGFloat(h) + pad
    ctx.saveGState()
    ctx.translateBy(x: 0, y: top + CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: x - pad, y: 0, width: CGFloat(w), height: CGFloat(h)))
    ctx.restoreGState()
}

func render(scale: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale,
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Work in points with the origin at the top-left corner.
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    // Off-white surface, a touch cooler towards the bottom like the site.
    let k = contentHeight / height
    let base = CGGradient(colorsSpace: sRGB,
                          colors: [color("ffffff"), color("f5f5f7"), color("ececF0")] as CFArray,
                          locations: [0, 0.6 * k, k])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])

    // Glows: teal left, blue right, a warm horizon at the bottom centre.
    glow(ctx, center: CGPoint(x: 110, y: 150), radius: 300, teal, alpha: 0.11)
    glow(ctx, center: CGPoint(x: 560, y: 120), radius: 300, blue, alpha: 0.09)
    glow(ctx, center: CGPoint(x: 330, y: contentHeight + 40), radius: 330, warm2, alpha: 0.17)
    glow(ctx, center: CGPoint(x: 330, y: contentHeight + 60), radius: 200, warm3, alpha: 0.09)
    glow(ctx, center: CGPoint(x: 330, y: 190), radius: 320, warm1, alpha: 0.16)

    // Wordmark and tagline, top-left.
    gradientText(ctx, "XDRemux", x: 48, baseline: 78, size: 40, weight: .bold,
                 stops: ["5d86c4", "8b6aa8", "d07a4c"], at: [0, 0.45, 1])
    text(ctx, "让照片跨越设备，也保留继续创作的可能。", x: 50, baseline: 104, size: 13, fill: color(fgDim))

    // Hairline between the drag row and the small print.
    ctx.setStrokeColor(color("000000", 0.10))
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 48, y: dividerY))
    ctx.addLine(to: CGPoint(x: width - 48, y: dividerY))
    ctx.strokePath()

    // Drag arrow.
    ctx.setStrokeColor(color(fg))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 296, y: heroY))
    ctx.addLine(to: CGPoint(x: 366, y: heroY))
    ctx.move(to: CGPoint(x: 350, y: heroY - 14))
    ctx.addLine(to: CGPoint(x: 366, y: heroY))
    ctx.addLine(to: CGPoint(x: 350, y: heroY + 14))
    ctx.strokePath()

    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(path)") }
    print("wrote \(path)")
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

guard let lo = render(scale: 1), let hi = render(scale: 2) else { fatalError("cannot render") }
write(lo, to: "\(outDir)/background.png")
write(hi, to: "\(outDir)/background@2x.png")
