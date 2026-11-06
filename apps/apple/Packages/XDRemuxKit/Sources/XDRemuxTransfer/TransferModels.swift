import Foundation

// Mirrors crates/xdremux-transfer/src/model.rs (serde snake_case).

public struct TransferPeer: Codable, Hashable, Sendable {
    /// `IP:port`.
    public var address: String
    /// SHA-256 of the peer certificate, 64 hex digits. Display and confirm
    /// before sending; it is the only identity the core pins.
    public var fingerprint: String

    public init(address: String, fingerprint: String) {
        self.address = address
        self.fingerprint = fingerprint
    }

    /// `AB12 CD34 …` for reading aloud across the room.
    public var groupedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 4).map { i in
            let s = fingerprint.index(fingerprint.startIndex, offsetBy: i)
            let e = fingerprint.index(s, offsetBy: min(4, fingerprint.count - i))
            return String(fingerprint[s..<e])
        }.joined(separator: " ")
    }

    /// First and last four digits, for list rows.
    public var shortFingerprint: String {
        guard fingerprint.count >= 8 else { return fingerprint }
        return "\(fingerprint.prefix(4))…\(fingerprint.suffix(4))"
    }
}

public struct DiscoveredPeer: Codable, Hashable, Sendable, Identifiable {
    public var alias: String
    public var address: String
    public var fingerprint: String
    public var id: String { fingerprint }
    public var peer: TransferPeer { TransferPeer(address: address, fingerprint: fingerprint) }
    public init(alias: String, address: String, fingerprint: String) {
        self.alias = alias; self.address = address; self.fingerprint = fingerprint
    }
}

public struct DiscoverySnapshot: Codable, Sendable {
    public var enabled: Bool
    public var error: String?
    public var peers: [DiscoveredPeer]
}

public struct OfferedFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: UInt64
    public var sha256: String?
}

public struct TransferOffer: Codable, Hashable, Sendable, Identifiable {
    public var sessionId: String
    public var alias: String
    public var peerFingerprint: String
    public var files: [OfferedFile]
    public var id: String { sessionId }
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
}

public struct TransferReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var fileId: String
    public var name: String
    public var size: UInt64
    public var sha256: String
    public var peerHashPresent: Bool
}

public struct SentFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: UInt64
    public var sha256: String
}

public struct SendReport: Codable, Sendable {
    public var files: [SentFile]
    public var error: String?
}

public enum TransferDirection: String, Codable, Sendable { case send, receive }
public enum TransferPhase: String, Codable, Sendable {
    case preparing, pending, accepted, transferring, completed, failed
    public var isTerminal: Bool { self == .completed || self == .failed }
}
public enum TransferFilePhase: String, Codable, Sendable { case waiting, transferring, sent, committed, failed }

public struct TransferSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var direction: TransferDirection
    public var phase: TransferPhase
    public var fileCount: Int
    public var error: String?
    public var alias: String?
    public var peerFingerprint: String?
    public var retryAvailable: Bool?
}

public struct TransferFileState: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: UInt64
    public var sha256: String?
    public var bytes: UInt64
    public var phase: TransferFilePhase
    public var error: String?
    public var receiptId: String?
}

public struct TransferSnapshotPage: Codable, Sendable {
    public var instanceId: String
    public var sequence: UInt64
    public var evicted: UInt64
    public var transfers: [TransferSummary]
    public var next: String?
}

public struct TransferDetail: Codable, Sendable {
    public var instanceId: String
    public var sequence: UInt64
    public var transfer: TransferSummary
    public var files: [TransferFileState]
    public var next: String?
}

public struct ReceiptLease: Codable, Sendable {
    public var leaseId: UInt64
    public var path: String
    public var receipt: TransferReceipt
}

/// What `ready` reports once the listener is up.
public struct TransferReady: Codable, Sendable {
    public var address: String
    public var fingerprint: String
    public var coreInstanceId: String
}

/// One core event (`{kind:"event",event:{…}}`), flattened: only the fields
/// each kind carries are set. Kinds: send_started, file_sent,
/// receipt_deleted, offer, accepted, progress, committed, failed,
/// session_ended, sent, prepared, stopped.
public struct TransferEvent: Codable, Sendable {
    public var kind: String
    public var instanceId: String?
    public var sequence: UInt64?
    public var transferId: String?
    public var sessionId: String?
    public var fileId: String?
    public var receiptId: String?
    public var fileCount: Int?
    public var bytes: UInt64?
    public var total: UInt64?
    public var code: String?
    public var offer: TransferOffer?
    public var receipt: TransferReceipt?
    public var report: SendReport?
    public var files: [SentFile]?
    public var file: SentFile?
}

enum TransferJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
