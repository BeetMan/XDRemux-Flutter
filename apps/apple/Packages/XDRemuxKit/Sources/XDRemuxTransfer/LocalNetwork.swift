import Foundation

/// IPv4 addresses this device can be reached at on the local network.
public struct LocalInterface: Hashable, Sendable, Identifiable {
    public var name: String
    public var address: String
    public var id: String { address }
}

public enum LocalNetwork {
    /// Non-loopback IPv4 interfaces that are up, Wi-Fi / Ethernet first.
    public static func ipv4Interfaces() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var out: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_RUNNING != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let address = String(cString: host)
            // Link-local and carrier-grade NAT addresses are not where a
            // peer on the same Wi-Fi will find us.
            if address.hasPrefix("169.254.") || address.hasPrefix("100.") { continue }
            out.append(LocalInterface(name: name, address: address))
        }
        // en0 (Wi-Fi on iPhone, first Ethernet/Wi-Fi on Mac) ahead of
        // tunnels and bridges.
        return out.sorted { a, b in
            func rank(_ n: String) -> Int { n.hasPrefix("en") ? 0 : (n.hasPrefix("bridge") ? 2 : 1) }
            return (rank(a.name), a.name) < (rank(b.name), b.name)
        }
    }
}
