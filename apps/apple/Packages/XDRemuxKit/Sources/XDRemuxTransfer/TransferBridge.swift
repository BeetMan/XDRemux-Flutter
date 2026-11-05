import Foundation
import XDRemuxTransferCore

/// Thin, synchronous wrapper over the transfer C ABI (crates/xdremux-transfer-ffi,
/// `include/xdremux_transfer.h`). One instance owns one native handle. All
/// calls are brief: the native side runs its own Tokio runtime and this
/// layer only hands JSON across. `TransferService` adds the poll loop.
public enum TransferError: Error, Equatable, Sendable {
    /// A non-zero ABI status: 1 invalid input, 2 invalid handle, 3 busy,
    /// 4 closed, 5 output too small, 6 internal.
    case status(Int32)
    /// A stable snake_case error code from the core (never a path or a
    /// remote exception string).
    case code(String)
    /// The library's ABI major differs or its minor is below 3.
    case unsupportedABI(UInt32)
    /// The service stopped before the command had a result.
    case closed
    /// Native JSON did not have the documented shape.
    case malformed
    /// The core's startup failed (`start_failed` record), with its code.
    case startFailed(String)
}

final class TransferBridge: @unchecked Sendable {
    static let requiredMajor: UInt32 = 1
    static let requiredMinor: UInt32 = 3

    private(set) var handle: UInt64 = 0

    /// `0x00010003` → major 1, minor 3.
    static func abiVersion() -> (major: UInt32, minor: UInt32) {
        let v = xdremux_transfer_abi_version()
        return (v >> 16, v & 0xFFFF)
    }

    static func checkABI() throws {
        let v = abiVersion()
        guard v.major == requiredMajor, v.minor >= requiredMinor else {
            throw TransferError.unsupportedABI(xdremux_transfer_abi_version())
        }
    }

    func create(configJSON: Data) throws {
        try Self.checkABI()
        var h: UInt64 = 0
        let status = configJSON.withUnsafeBytes { buf in
            xdremux_transfer_create(buf.bindMemory(to: UInt8.self).baseAddress, buf.count, &h)
        }
        guard status == 0 else { throw TransferError.status(status) }
        handle = h
    }

    /// Queues a command; the result arrives later as a `result` record
    /// tagged with the returned operation ID.
    func submit(_ json: Data) throws -> UInt64 {
        var op: UInt64 = 0
        let status = json.withUnsafeBytes { buf in
            xdremux_transfer_submit(handle, buf.bindMemory(to: UInt8.self).baseAddress, buf.count, &op)
        }
        guard status == 0 else { throw TransferError.status(status) }
        return op
    }

    /// Drains up to `maxEvents` whole records (≤ `maxBytes` of JSON).
    func poll(maxEvents: UInt32 = 64, maxBytes: UInt32 = 1 << 20) throws -> Data {
        var out: UnsafeMutablePointer<CChar>?
        let status = xdremux_transfer_poll(handle, maxEvents, maxBytes, &out)
        guard status == 0, let out else { throw TransferError.status(status) }
        defer { _ = xdremux_transfer_free_string(out) }
        return Data(bytes: out, count: strlen(out))
    }

    /// Idempotent. Poll until `phase == 3`, then `release()`.
    func stop() {
        _ = xdremux_transfer_stop(handle)
    }

    func release() {
        guard handle != 0 else { return }
        _ = xdremux_transfer_release(handle)
        handle = 0
    }
}
