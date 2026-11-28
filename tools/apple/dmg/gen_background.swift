#!/usr/bin/env swift
// Render the installer window background for the macOS DMG:
//
//   tools/apple/dmg/background.png     660x530  (1x)
//   tools/apple/dmg/background@2x.png  1320x1060 (Retina)
//
// Light surface with a faint curved grid (the lines bow away from the
// centre), an arrow between the app icon and the Applications link, and a
// hairline above the row of smaller items (licence files, privacy shortcut).
// The picture is drawn 470 points tall like the window's content area, plus
// 60 points of plain grid underneath: Finder crops the picture at the bottom
// of the content area, whose height depends on the title bar, and a little
// spare pattern keeps that edge invisible on every macOS version.
// The window size and the icon positions live in settings.py; keep the
// numbers here in step with them.
//
// Regenerate:  swift tools/apple/dmg/gen_background.swift

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 660.0
let contentHeight = 470.0
let height = contentHeight + 60.0

// Icon centres from settings.py.
let appX = 170.0, linkX = 490.0, heroY = 172.0
let dividerY = 286.0
let arrowY = heroY

// Bow the grid outward: zero at the centre, about 18% at the corners.
func warp(_ x: Double, _ y: Double) -> (Double, Double) {
    let nx = (x - width / 2) / (width / 2)
    let ny = (y - contentHeight / 2) / (contentHeight / 2)
    let f = 1.0 + 0.09 * (nx * nx + ny * ny)
    return (width / 2 + (x - width / 2) * f, height / 2 + (y - height / 2) * f)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func render(scale: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Work in points with the origin at the top-left corner.
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    // Surface: almost white at the top, a touch cooler at the bottom.
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0xfcfcfd), color(0xf1f1f4), color(0xf1f1f4)] as CFArray,
                              locations: [0, 1, 1].map { CGFloat($0) * contentHeight / height })!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])

    // Curved grid.
    ctx.setStrokeColor(color(0x000000, 0.075))
    ctx.setLineWidth(1)
    let step = 48.0, margin = 60.0, sample = 4.0
    func samples(from start: Double, to end: Double) -> [Double] {
        stride(from: start, through: end, by: sample).map { $0 }
    }
    for x in stride(from: step, to: width, by: step) {
        ctx.move(to: CGPoint(x: x, y: -margin))
        for y in samples(from: -margin, to: height + margin) {
            let p = warp(x, y)
            ctx.addLine(to: CGPoint(x: p.0, y: p.1))
        }
    }
    for y in stride(from: step, to: height, by: step) {
        ctx.move(to: CGPoint(x: -margin, y: y))
        for x in samples(from: -margin, to: width + margin) {
            let p = warp(x, y)
            ctx.addLine(to: CGPoint(x: p.0, y: p.1))
        }
    }
    ctx.strokePath()

    // Hairline between the drag row and the small print.
    ctx.setStrokeColor(color(0x000000, 0.08))
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 48, y: dividerY))
    ctx.addLine(to: CGPoint(x: width - 48, y: dividerY))
    ctx.strokePath()

    // Drag arrow.
    ctx.setStrokeColor(color(0x1d1d1f))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 296, y: arrowY))
    ctx.addLine(to: CGPoint(x: 366, y: arrowY))
    ctx.move(to: CGPoint(x: 350, y: arrowY - 14))
    ctx.addLine(to: CGPoint(x: 366, y: arrowY))
    ctx.addLine(to: CGPoint(x: 350, y: arrowY + 14))
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
