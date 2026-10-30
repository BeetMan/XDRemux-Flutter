import Foundation
import XDRemuxCoreC
import XDRemuxModel

extension XDRemuxEngine: WritebackBackend {
    /// `xdremux_writeback_returned_photo`. Mode byte: 0 = Apple 标准, 1 = OPPO 兼容
    /// (same as the Dart binding).
    public func writebackReturnedPhoto(original: String?, returned: String, output: String,
                                       outputMode: OutputMode, restoreWatermark: Bool) async throws -> WritebackReport {
        let mode: UInt8 = outputMode == .oppo ? 1 : 0
        let watermark: UInt8 = restoreWatermark ? 1 : 0
        let report: JSONReport = try await runOnQueue {
            try withCPath(returned) { r in
                try withCPath(output) { o in
                    if let original {
                        return try withCPath(original) { d in
                            try JSONReport(consuming: RustString(taking: xdremux_writeback_returned_photo(d, r, o, mode, watermark)))
                        }
                    }
                    return try JSONReport(consuming: RustString(taking: xdremux_writeback_returned_photo(nil, r, o, mode, watermark)))
                }
            }
        }
        return try report.decode()
    }
}
