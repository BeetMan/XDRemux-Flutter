#!/usr/bin/env swift
// Extract a multi-resolution .icns icon from an installed macOS .app bundle
// using AppKit (NSWorkspace) and iconutil, so DMG shortcuts work across macOS
// versions even when system apps store icons in Assets.car instead of loose
// .icns files.
//
// Usage: swift extract_app_icon.swift <App.app> <output.icns>

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: extract_app_icon.swift <App.app> <output.icns>\n", stderr)
    exit(2)
}

let appPath = CommandLine.arguments[1]
let outIcns = CommandLine.arguments[2]
guard FileManager.default.fileExists(atPath: appPath) else {
    fputs("missing app: \(appPath)\n", stderr)
    exit(1)
}

let icon = NSWorkspace.shared.icon(forFile: appPath)
let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("xdremux-iconset-\(UUID().uuidString)")
let iconsetDir = tempRoot.appendingPathComponent("AppIcon.iconset")

defer {
    try? FileManager.default.removeItem(at: tempRoot)
}

do {
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    let sizes = [16, 32, 128, 256]
    for size in sizes {
        for scale in [1, 2] {
            let px = size * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: px,
                pixelsHigh: px,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw NSError(domain: "extract_app_icon", code: 1)
            }
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(
                in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            NSGraphicsContext.restoreGraphicsState()
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "extract_app_icon", code: 2)
            }
            let suffix = scale == 2 ? "@2x" : ""
            let file = iconsetDir.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
            try pngData.write(to: file)
        }
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outIcns]
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        fputs("iconutil exited with \(proc.terminationStatus)\n", stderr)
        exit(proc.terminationStatus)
    }
} catch {
    fputs("failed to extract icon for \(appPath): \(error)\n", stderr)
    exit(1)
}
