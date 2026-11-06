import Foundation
import Network

/// The name other devices see. Mirrors the Flutter app's rules so a name
/// typed on one platform looks the same on the other.
public enum TransferAlias {
    public static let maxLength = 64

    /// Trims, strips control characters, caps the length; `nil` when
    /// nothing is left (callers fall back to the device name).
    public static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let stripped = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        let trimmed = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
    }
}

/// How LocalSend carries an iPhone Live Photo and how XDRemux sends its own
/// pairs: a still and a `.mov` with the same stem, as two loose files.
public enum LivePhotoPairing {
    public static let stillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
    public static let videoExtensions: Set<String> = ["mov", "mp4"]

    public static func isStill(_ name: String) -> Bool {
        stillExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func stem(_ name: String) -> String {
        ((name as NSString).deletingPathExtension).lowercased()
    }

    /// The `.mov` in `names` that pairs with the still `name`, if any.
    public static func pairedMovie(for name: String, in names: [String]) -> String? {
        guard isStill(name) else { return nil }
        let wanted = stem(name) + ".mov"
        return names.first { $0.lowercased() == wanted }
    }

    /// True when `name` is a `.mov` that a still in `names` claims.
    public static func isPairedMovie(_ name: String, in names: [String]) -> Bool {
        guard name.lowercased().hasSuffix(".mov") else { return false }
        let wanted = stem(name)
        return names.contains { isStill($0) && stem($0) == wanted }
    }
}

/// LocalSend's fallback when multicast finds nothing: knock on every /24
/// neighbour of this device's IPv4 addresses on the LocalSend ports. The
/// responders are then identified with `TransferService.probe`.
public enum SubnetScan {
    public struct Target: Hashable, Sendable {
        public var host: String
        public var port: UInt16
        public var address: String { "\(host):\(port)" }
        public init(host: String, port: UInt16) { self.host = host; self.port = port }
    }

    public static let defaultPorts: [UInt16] = [53319, 53317]

    /// Every host in the /24 of each own address, except the own addresses
    /// themselves, crossed with `ports`. Own addresses that are not dotted
    /// IPv4 are ignored.
    public static func targets(own: [String], ports: [UInt16] = defaultPorts) -> [Target] {
        var prefixes: [String] = []
        for address in own {
            let octets = address.split(separator: ".")
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { continue }
            let prefix = octets.prefix(3).joined(separator: ".")
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        var out: [Target] = []
        for prefix in prefixes {
            for i in 1..<255 {
                let host = "\(prefix).\(i)"
                if own.contains(host) { continue }
                for port in ports { out.append(Target(host: host, port: port)) }
            }
        }
        return out
    }

    /// TCP-connects to each target with `timeout`, at most `concurrency` at
    /// once, and returns the ones that accepted. Order follows `targets`.
    public static func openPorts(_ targets: [Target], timeout: Duration = .milliseconds(600),
                                 concurrency: Int = 128) async -> [Target] {
        var open: [Target] = []
        var index = 0
        while index < targets.count {
            let batch = targets[index..<min(index + concurrency, targets.count)]
            index += concurrency
            let hits = await withTaskGroup(of: Target?.self) { group in
                for target in batch {
                    group.addTask { await accepts(target, timeout: timeout) ? target : nil }
                }
                var found: [Target] = []
                for await hit in group { if let hit { found.append(hit) } }
                return found
            }
            open += batch.filter { hits.contains($0) }
            if Task.isCancelled { break }
        }
        return open
    }

    private static func accepts(_ target: Target, timeout: Duration) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: target.port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let outcome = Outcome()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let finish: @Sendable (Bool) -> Void = { ok in
                    guard outcome.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: ok)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    case .waiting: finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout / .milliseconds(1)))) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static let queue = DispatchQueue(label: "io.github.beetman.xdremux.subnet-scan", attributes: .concurrent)

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
