import Foundation

/// Decides where a conversion writes and what the published file is called.
/// Pure functions so the rules are testable without a file system.
///
/// Rules follow the Flutter app: `<stem><suffix>.heic`, optionally under a
/// per-mode folder ("OPPO 兼容" / "Apple 标准") when `categorizeOutputByMode`
/// is on; JPEG inputs keep their stem (the Flutter app writes `name.jpg_iso.heic`
/// only in the organize page, which is out of scope here).
public enum OutputPlanner {
    public static func publishedFileName(forInput inputName: String, config: ConversionConfig) -> String {
        let stem = (inputName as NSString).deletingPathExtension
        return "\(stem)\(config.fileNameSuffix).heic"
    }

    public static func modeFolderName(_ mode: OutputMode) -> String {
        switch mode {
        case .oppo: return "OPPO 兼容"
        case .apple: return "Apple 标准"
        }
    }

    /// Final location inside `outputRoot` (the user's chosen directory or the
    /// app's own `outputs/` folder).
    public static func publishedURL(forInput inputName: String, config: ConversionConfig, outputRoot: URL) -> URL {
        var dir = outputRoot
        if config.categorizeOutputByMode {
            dir.appendPathComponent(modeFolderName(config.outputMode), isDirectory: true)
        }
        return dir.appendingPathComponent(publishedFileName(forInput: inputName, config: config))
    }

    /// Task-private scratch path; a conversion writes here and is published
    /// only after verification (plan §3 P1).
    public static func temporaryURL(forInput inputName: String, config: ConversionConfig, scratchRoot: URL, token: UUID = UUID()) -> URL {
        scratchRoot
            .appendingPathComponent(token.uuidString, isDirectory: true)
            .appendingPathComponent(publishedFileName(forInput: inputName, config: config))
    }

    /// Appends ` (2)`, ` (3)`, … before the extension until `exists` is false.
    public static func uniqueURL(_ url: URL, exists: (URL) -> Bool) -> URL {
        guard exists(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
