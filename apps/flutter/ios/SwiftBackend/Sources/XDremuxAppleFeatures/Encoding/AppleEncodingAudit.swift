import Foundation
import ImageIO
import XDRemuxCore

enum AppleEncodingAudit {
    static func writeAuxiliaryReferencesIfRequested(
        prefix: String,
        entries: [(name: String, dictionary: CFDictionary)]
    ) throws {
        guard let rootPath = ProcessInfo.processInfo.environment["XDREMUX_ENCODING_AUDIT_DIR"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for entry in entries {
            let object = entry.dictionary as NSDictionary
            guard let data = object[kCGImageAuxiliaryDataInfoData] as? Data,
                  let description = object[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary else {
                throw CLIError.invalidContainer(
                    "encoding audit cannot read raw auxiliary data for \(entry.name)"
                )
            }
            let file = root.appendingPathComponent("\(entry.name).bin")
            try data.write(to: file, options: .atomic)
            manifest.append([
                "name": entry.name,
                "path": file.path,
                "byteCount": data.count,
                "width": (description[kCGImagePropertyWidth] as? NSNumber)?.intValue ?? 0,
                "height": (description[kCGImagePropertyHeight] as? NSNumber)?.intValue ?? 0,
                "bytesPerRow": (description[kCGImagePropertyBytesPerRow] as? NSNumber)?.intValue ?? 0,
                "pixelFormat": (description[kCGImagePropertyPixelFormat] as? NSNumber)?.uint32Value ?? 0,
            ])
        }
        let manifestData = try JSONSerialization.data(
            withJSONObject: ["schema": "xdremux-encoding-audit-v1", "entries": manifest],
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
