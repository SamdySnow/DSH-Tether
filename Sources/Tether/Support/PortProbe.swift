import Darwin
import Foundation

/// Answers "is this TCP port free?" without shelling out, so the app can fail
/// fast with a useful message instead of letting the DSH server crash on bind.
enum PortProbe {

    /// Binds `0.0.0.0:<port>` for real. Binding the wildcard address fails when
    /// *any* interface address already has that port taken (including a listener
    /// on `127.0.0.1`), which is exactly the conflict we want to detect.
    ///
    /// `SO_REUSEADDR` is deliberately not set, because it would mask conflicts.
    static func isAvailable(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Restore blocking behaviour for the (unused) connect path; binding is
        // what matters here.
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return bound == 0
    }

    /// Number of ports to scan when the configured one is busy.
    static let scanWindow = 64

    /// Returns the first free port at or after `preferred`.
    static func firstAvailable(atOrAfter preferred: Int) -> Int? {
        let start = max(1, preferred)
        let end = min(65535, start + scanWindow)
        guard start <= end else { return nil }
        for candidate in start...end where isAvailable(candidate) {
            return candidate
        }
        return nil
    }

    /// Polls until `port` is free or `timeout` elapses. Used after stopping the
    /// service so an immediate restart does not trip the availability check while
    /// the old listener is still tearing down.
    static func waitUntilAvailable(_ port: Int, timeout: Duration = .seconds(6)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isAvailable(port) { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return isAvailable(port)
    }

    /// `true` when something is listening on `127.0.0.1:<port>`.
    ///
    /// Used to decide when the DSH server is ready. A plain blocking connect is
    /// safe here because loopback connections are answered immediately: either
    /// the handshake succeeds or the kernel returns ECONNREFUSED.
    static func isAcceptingConnections(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Never let a half-open peer stall the readiness poll.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return outcome == 0
    }
}
