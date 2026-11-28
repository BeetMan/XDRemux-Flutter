#!/usr/bin/env swift
// Render the installer window background for the macOS DMG:
//
//   tools/apple/dmg/background.png     660x564  (1x)
//   tools/apple/dmg/background@2x.png  1320x1128 (Retina)
//
// Follows the light theme of xdremux.app: an off-white surface with soft
// teal, blue and warm horizon glows, the "XDRemux" wordmark in the site's
// blue-grey to purple to orange gradient with its tagline underneath, a dark
// drag arrow between the app icon and the Applications link, and a hairline
// above the row of smaller items (licence files, privacy shortcut).
//
// The canvas stays light. Finder icon labels follow the system appearance
// (near-black in light mode, near-white in dark mode). Instead of heavy bars,
// each label sits inside a tight, cool-slate capsule pill positioned at
// Finder's true rendered label box (`iconCenterY + 58` for `iconSize = 96`,
// leaving clear separation below the icon selection halo) so both Light Mode
// and Dark Mode text remain crisp without clipping icons or thumbnails.
//
// Regenerate default committed assets:
//   swift tools/apple/dmg/gen_background.swift
// Or pass `--app <name> --extras <comma-list> [--out-dir <dir>]` at DMG build time.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 660.0
let contentHeight = 504.0
let height = contentHeight + 60.0

// Icon centres and size shared with settings.py.
let heroY = 212.0
let smallY = 376.0
let smallSpacing = 186.0
let link = (x: 548.0, y: 70.0)
let iconSize = 96.0
let dividerY = 308.0

// Finder draws 12pt labels at iconCenterY + 58 (top of text box) for iconSize = 96.
// Pill pads 4pt vertically above/below the text box so it sits cleanly below
// the 96pt icon & selection halo without touching thumbnails.
let pillTopOffset = iconSize / 2.0 + 6.0  // +54 -> covers +58..+72 (1-line) or +58..+88 (2-line)
let oneLinePillHeight = 22.0
let twoLinePillHeight = 38.0
let wrapThreshold = 165.0

// Cool slate capsule gradient: maintains ~4.0:1 against white labels (Dark Mode)
// and >5:1 against near-black labels (Light Mode).
let pillTopColor = "80848e"
let pillBottomColor = "757983"

// Site palette, light theme (xdremux.app CSS variables).
let fg = "1d1d1f", fgDim = "6e6e73", teal = "0a8a76", blue = "0066cc"
let warm1 = "ffe0b0", warm2 = "ff9a5c", warm3 = "d4577c"

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct Config {
    var outDir: String
    var appName: String
    var extras: [String]
    var websiteName: String
}

func parseConfig() -> Config {
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    var outDir = scriptDir
    var appName = "XDRemux Flutter.app"
    var extras = [
        "LICENSE.txt",
        "LICENSING.md",
        "打开隐私与安全性 (Privacy & Security).inetloc",
    ]
    var websiteName = "官网 xdremux.app.webloc"

    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--out-dir":
            if i + 1 < args.count { outDir = args[i + 1]; i += 1 }
        case "--app":
            if i + 1 < args.count { appName = args[i + 1]; i += 1 }
        case "--extras":
            if i + 1 < args.count {
                let raw = args[i + 1]
                extras = raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
                i += 1
            }
        case "--website":
            if i + 1 < args.count { websiteName = args[i + 1]; i += 1 }
        default:
            if !args[i].hasPrefix("-") && i == 1 {
                outDir = args[i]
            }
        }
        i += 1
    }
    return Config(outDir: outDir, appName: appName, extras: extras, websiteName: websiteName)
}

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let v = UInt32(hex, radix: 16)!
    return CGColor(
        srgbRed: CGFloat((v >> 16) & 0xff) / 255,
        green: CGFloat((v >> 8) & 0xff) / 255,
        blue: CGFloat(v & 0xff) / 255,
        alpha: alpha
    )
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ hex: String, alpha: CGFloat) {
    let g = CGGradient(
        colorsSpace: sRGB,
        colors: [color(hex, alpha), color(hex, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        g,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: []
    )
}

func makeLine(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let ns = NSAttributedString(string: string, attributes: [.font: font])
    return CTLineCreateWithAttributedString(ns as CFAttributedString)
}

func measureFinderTextWidth(_ string: String) -> CGFloat {
    let bounds = CTLineGetBoundsWithOptions(makeLine(string, size: 12.0, weight: .regular), .useOpticalBounds)
    return ceil(bounds.width)
}

func drawGlyphs(_ ctx: CGContext, _ line: CTLine, x: CGFloat, y: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func text(_ ctx: CGContext, _ string: String, x: CGFloat, baseline y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, fill: CGColor) {
    ctx.saveGState()
    ctx.setFillColor(fill)
    drawGlyphs(ctx, makeLine(string, size: size, weight: weight), x: x, y: y)
    ctx.restoreGState()
}

func gradientText(_ ctx: CGContext, _ string: String, x: CGFloat, baseline y: CGFloat, size: CGFloat,
                  weight: NSFont.Weight, stops: [String], at locations: [CGFloat]) {
    let line = makeLine(string, size: size, weight: weight)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let pad: CGFloat = 8
    let w = Int(ceil(bounds.width)) + 2 * Int(pad), h = Int(ceil(bounds.height)) + 2 * Int(pad)
    guard let mask = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    mask.setFillColor(.black)
    mask.textMatrix = .identity
    mask.textPosition = CGPoint(x: pad - bounds.minX, y: pad + bounds.minY)
    CTLineDraw(line, mask)
    mask.setBlendMode(.sourceIn)
    let g = CGGradient(colorsSpace: sRGB, colors: stops.map { color($0) } as CFArray, locations: locations)!
    mask.drawLinearGradient(g, start: CGPoint(x: pad, y: 0), end: CGPoint(x: pad + bounds.width, y: 0), options: [])
    guard let image = mask.makeImage() else { return }
    let top = y + bounds.minY - CGFloat(h) + pad
    ctx.saveGState()
    ctx.translateBy(x: 0, y: top + CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: x - pad, y: 0, width: CGFloat(w), height: CGFloat(h)))
    ctx.restoreGState()
}

/// Draw a subtle capsule / rounded pill centred under a Finder label.
func drawLabelPill(_ ctx: CGContext, centerX: CGFloat, top: CGFloat, label: String, minWidth: CGFloat = 92.0) {
    let textW = measureFinderTextWidth(label)
    let twoLines = textW > wrapThreshold
    let pillW = twoLines ? 186.0 : max(textW + 24.0, minWidth)
    let pillH = twoLines ? twoLinePillHeight : oneLinePillHeight
    let radius = twoLines ? 11.5 : pillH / 2.0
    let rect = CGRect(x: centerX - pillW / 2.0, y: top, width: pillW, height: pillH)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Subtle soft ambient drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color("000000", 0.08))
    ctx.addPath(path)
    ctx.setFillColor(color(pillTopColor))
    ctx.fillPath()
    ctx.restoreGState()

    // Crisp cool-slate vertical gradient fill.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(
        colorsSpace: sRGB,
        colors: [color(pillTopColor), color(pillBottomColor)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.restoreGState()

    // Hairline highlight rim.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(1, radius - 0.5), cornerHeight: max(1, radius - 0.5), transform: nil))
    ctx.setStrokeColor(color("ffffff", 0.22))
    ctx.setLineWidth(1.0)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(scale: Int, config: Config) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: Int(width) * scale,
        height: Int(height) * scale,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Top-left coordinate system in points.
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    // Off-white surface matching xdremux.app light theme.
    let k = contentHeight / height
    let base = CGGradient(
        colorsSpace: sRGB,
        colors: [color("ffffff"), color("f5f5f7"), color("ececf0")] as CFArray,
        locations: [0, 0.6 * k, k]
    )!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])

    // Ambient glows.
    glow(ctx, center: CGPoint(x: 110, y: 150), radius: 300, teal, alpha: 0.11)
    glow(ctx, center: CGPoint(x: 560, y: 120), radius: 300, blue, alpha: 0.09)
    glow(ctx, center: CGPoint(x: 330, y: contentHeight + 40), radius: 330, warm2, alpha: 0.17)
    glow(ctx, center: CGPoint(x: 330, y: contentHeight + 60), radius: 200, warm3, alpha: 0.09)
    glow(ctx, center: CGPoint(x: 330, y: 210), radius: 320, warm1, alpha: 0.16)

    // Individual tight label pills aligned to Finder's real rendered positions.
    drawLabelPill(ctx, centerX: 170, top: heroY + pillTopOffset, label: config.appName, minWidth: 100.0)
    drawLabelPill(ctx, centerX: 490, top: heroY + pillTopOffset, label: "Applications", minWidth: 96.0)
    if !config.websiteName.isEmpty {
        drawLabelPill(ctx, centerX: link.x, top: link.y + pillTopOffset, label: config.websiteName, minWidth: 126.0)
    }

    let count = config.extras.count
    if count > 0 {
        let spacing = count < 2
            ? smallSpacing
            : min(smallSpacing, (width - 120.0) / CGFloat(count - 1))
        for (index, name) in config.extras.enumerated() {
            let x = CGFloat(Int(width / 2.0 + (CGFloat(index) - CGFloat(count - 1) / 2.0) * spacing))
            drawLabelPill(ctx, centerX: x, top: smallY + pillTopOffset, label: name, minWidth: 94.0)
        }
    }

    // Wordmark and tagline, top-left.
    gradientText(
        ctx,
        "XDRemux",
        x: 48,
        baseline: 82,
        size: 40,
        weight: .bold,
        stops: ["5d86c4", "8b6aa8", "d07a4c"],
        at: [0, 0.45, 1]
    )
    text(ctx, "让照片跨越设备，也保留继续创作的可能。", x: 50, baseline: 110, size: 13, fill: color(fgDim))

    // Hairline between drag row and bottom row.
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

let config = parseConfig()
try FileManager.default.createDirectory(atPath: config.outDir, withIntermediateDirectories: true)
guard let lo = render(scale: 1, config: config), let hi = render(scale: 2, config: config) else {
    fatalError("cannot render")
}
write(lo, to: "\(config.outDir)/background.png")
write(hi, to: "\(config.outDir)/background@2x.png")
