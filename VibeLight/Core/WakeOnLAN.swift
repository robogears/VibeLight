import Foundation

/// Sends a Wake-on-LAN magic packet so an asleep host can be woken from the couch.
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

    /// Magic packet: 6×0xFF followed by the MAC repeated 16 times.
    static func magicPacket(mac: Data) -> Data? {
        guard mac.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(mac) }
        return packet
    }

    /// Broadcasts the wake packet on the standard WoL ports. Also unicasts to
    /// known host addresses — some networks (VPN/Tailscale) don't carry broadcast.
    static func wake(mac: Data, unicastAddresses: [String] = []) throws {
        guard let packet = magicPacket(mac: mac) else { throw WOLError.invalidMAC }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WOLError.socketFailed(errno) }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var targets: [(String, UInt16)] = [("255.255.255.255", 9), ("255.255.255.255", 7)]
        for addr in unicastAddresses {
            targets.append((addr, 9))
        }

        var lastErrno: Int32 = 0
        var anySent = false
        for (address, port) in targets {
            var sin = sockaddr_in()
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { continue }
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &sin) { sinPtr in
                    sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count { anySent = true } else { lastErrno = errno }
        }
        guard anySent else { throw WOLError.socketFailed(lastErrno) }
    }
}
