#if canImport(UIKit)
import Foundation
import ImageIO

// iOS compatibility shims for ImageIO symbols whose SDK availability is
// iOS 17/18+ while this package keeps an iOS 15 deployment target.
//
// The runtime values of these CFString constants are their own symbol
// names (verified on macOS 27 / iOS 27 SDKs), so mirroring them here is
// byte-identical to what the OS resolves on iOS 18+. On pre-17/18
// devices the corresponding ImageIO APIs treat these as unknown option
// keys and fail gracefully (no aux data, default decode path); actual
// use must stay behind the runtime capability probes.
//
// On macOS these symbols come from ImageIO itself, so the shims are
// compiled out there.
//
// The explicit `as CFString` casts are required: with the colliding
// imported declaration in scope, a plain string literal no longer
// converts implicitly.

let kCGImageAuxiliaryDataTypeISOGainMap = "kCGImageAuxiliaryDataTypeISOGainMap" as CFString

let kCGImageSourceDecodeRequest = "kCGImageSourceDecodeRequest" as CFString

let kCGImageSourceDecodeToSDR = "kCGImageSourceDecodeToSDR" as CFString

let kCGImageDestinationEncodeBaseIsSDR = "kCGImageDestinationEncodeBaseIsSDR" as CFString

let kCGImageDestinationEncodeRequest = "kCGImageDestinationEncodeRequest" as CFString

let kCGImageDestinationEncodeToISOGainmap = "kCGImageDestinationEncodeToISOGainmap" as CFString

let kCGImageDestinationEncodeRequestOptions =
  "kCGImageDestinationEncodeRequestOptions" as CFString

#endif
