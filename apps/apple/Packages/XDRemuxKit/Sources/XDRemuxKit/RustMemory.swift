import Foundation
import XDRemuxCoreC

// RAII helpers for memory owned by the Rust core. Every `char *` or by-value
// struct the C ABI hands out is released exactly once here, in the matching
// `xdremux_free_*`, so call sites never see raw pointers
// (docs/architecture/ffi-contract.md §2.2–2.3).

/// Takes ownership of a `char *` returned by Rust and frees it on scope exit.
struct RustString {
    private let pointer: UnsafeMutablePointer<CChar>?

    init(taking pointer: UnsafeMutablePointer<CChar>?) {
        self.pointer = pointer
    }

    /// Copies the C string into a Swift `String`, then releases the Rust buffer.
    /// `nil` when Rust returned a null pointer (allocation failure).
    func consume() -> String? {
        defer { xdremux_free_string(pointer) }
        guard let pointer else { return nil }
        return String(cString: pointer)
    }
}

/// Copies a borrowed `char *` field out of a Rust struct without freeing it;
/// the owning struct's `xdremux_free_*` releases the field later.
@inline(__always)
func borrowedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

/// Runs `body` with a temporary C string for `path`. Rust requires UTF-8 and
/// null-checks; Swift strings are always valid UTF-8.
@inline(__always)
func withCPath<R>(_ path: String, _ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R {
    try path.withCString(body)
}
