import Foundation

/// Sends Wake-on-LAN magic packets so an asleep host can be woken from the couch.
///
/// Strategy mirrors moonlight-qt's proven `NvComputer::wake()`: shotgun the
/// payload at EVERY plausible destination × port, because any single path can
/// be dead — routers drop 255.255.255.255, ARP entries for a sleeping host
/// expire (so unicast dies), VPNs carry only unicast (so broadcast dies), and
/// WoL relays listen on odd ports. Targets:
/// - addresses: global broadcast, each up interface's IPv4 subnet broadcast
///   (e.g. 192.168.50.255), and every known host address — hostnames resolved
///   via DNS, numeric literals fast-pathed
/// - ports: 9 (standard WoL), 47009 (Moonlight Internet Hosting Tool relay),
///   and the GFE/Sunshine service ports offset by the host's HTTP base port
///   (47998 / 47999 / 48000 / 48002 / 48010 for the default 47989)
/// UDP is fire-and-forget cheap; a few dozen 102-byte packets is the reliable play.
enum WakeOnLAN {
    enum WOLError: Error, LocalizedError {
        case invalidMAC
        case socketFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidMAC: "Host has no valid MAC address stored."
            case .socketFailed(let errno): "Could not send wake packet (errno \(errno))."
            }
        }
    }

    /// Standard WoL listeners, sent to every target address.
    private static let staticPorts: [UInt16] = [9, 47009]
    /// GameStream service ports as offsets from the HTTP base port (47989).
    private static let dynamicPortOffsets: [Int] = [9, 10, 11, 13, 21]

    /// Magic packet: 6×0xFF followed by the MAC repeated 16 times.
    static func magicPacket(mac: Data) -> Data? {
        guard mac.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(mac) }
        return packet
    }

    /// Sends one full burst to every (address × port) combination.
    /// `targets` are the host's known addresses with their HTTP base ports.
    static func wake(mac: Data, targets: [(host: String, port: Int)]) throws {
        guard let packet = magicPacket(mac: mac) else { throw WOLError.invalidMAC }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WOLError.socketFailed(errno) }
        defer { close(fd) }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        // Every base port we know of — broadcast targets try dynamic ports for
        // all of them (we can't know which address the sleeping host had).
        let basePorts = Set(targets.map { $0.port == 0 ? 47989 : $0.port })

        // (in_addr, basePort) destinations. basePort 0 = broadcast-style target
        // (gets dynamic ports for every known base).
        var destinations: [(addr: in_addr, basePort: Int)] = []

        if let bcast = parseIPv4("255.255.255.255") {
            destinations.append((bcast, 0))
        }
        for bcast in interfaceBroadcastAddresses() {
            destinations.append((bcast, 0))
        }
        for target in targets {
            for addr in resolveIPv4(target.host) {
                destinations.append((addr, target.port == 0 ? 47989 : target.port))
            }
        }

        var lastErrno: Int32 = 0
        var anySent = false
        for dest in destinations {
            var ports = staticPorts.map(Int.init)
            let bases = dest.basePort == 0 ? Array(basePorts) : [dest.basePort]
            for base in bases {
                ports.append(contentsOf: dynamicPortOffsets.map { base + $0 })
            }
            for port in ports where port > 0 && port <= 65535 {
                var sin = sockaddr_in()
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_port = UInt16(port).bigEndian
                sin.sin_addr = dest.addr
                let sent = packet.withUnsafeBytes { raw in
                    withUnsafePointer(to: &sin) { sinPtr in
                        sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, raw.baseAddress, packet.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent == packet.count { anySent = true } else { lastErrno = errno }
            }
        }
        guard anySent else { throw WOLError.socketFailed(lastErrno) }
    }

    // MARK: - Address gathering

    private static func parseIPv4(_ s: String) -> in_addr? {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1 ? addr : nil
    }

    /// The host's addresses may be hostnames (mDNS names, Tailscale MagicDNS) —
    /// resolve them; numeric literals skip DNS entirely (moonlight-qt learned
    /// that lesson: reverse lookups stall the wake path).
    private static func resolveIPv4(_ host: String) -> [in_addr] {
        if let literal = parseIPv4(host) { return [literal] }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [in_addr] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let cur = node {
            if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    out.append($0.pointee.sin_addr)
                }
            }
            node = cur.pointee.ai_next
        }
        return out
    }

    /// IPv4 subnet-broadcast address of every up, non-loopback interface —
    /// routers that drop 255.255.255.255 usually still deliver these, and they
    /// re-reach hosts whose ARP entries have expired.
    private static func interfaceBroadcastAddresses() -> [in_addr] {
        var out: [in_addr] = []
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return out }
        defer { freeifaddrs(first) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = node {
            defer { node = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  flags & IFF_BROADCAST != 0,
                  let bcast = cur.pointee.ifa_dstaddr,
                  bcast.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                out.append($0.pointee.sin_addr)
            }
        }
        return out
    }
}
