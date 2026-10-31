import SwiftUI
import UniformTypeIdentifiers

/// Plain-text payload for `fileExporter` (the Flutter checkpoint JSONL).
struct TextFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json, .data]
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
