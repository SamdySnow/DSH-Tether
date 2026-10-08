import Darwin
import Foundation

/// Terminates a whole child process tree.
///
/// Launching through `npx` means the process we spawn is only the root of a
/// chain (`env` -> `node`/npx -> `node`/dsh -> the HTTP server). Signalling just
/// the root would leave the actual DSH server listening and holding the port, so
/// every descendant is signalled too.
enum ProcessTree {

    /// Sends `signal` to `root` and all of its descendants.
    static func signalTree(_ root: pid_t, _ signal: Int32) {
        guard root > 1 else { return }

        for child in descendantsPostOrder(of: root) {
            deliver(child, signal)
        }
        deliver(root, signal)
    }

    /// Polite shutdown: `SIGTERM` so the server can close sockets and flush.
    static func terminate(_ root: pid_t) {
        signalTree(root, SIGTERM)
    }

    /// Last resort: `SIGKILL`, which cannot be caught.
    static func forceKill(_ root: pid_t) {
        signalTree(root, SIGKILL)
    }

    /// The full command line of a process, or `nil` when it no longer exists.
    ///
    /// Used to confirm that a process id still belongs to the child this app
    /// spawned. Pids are recycled, so acting on a recorded pid without this check
    /// risks signalling an unrelated process.
    static func commandLine(of pid: pid_t) -> String? {
        guard pid > 1 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", "\(pid)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `true` when `pid` exists.
    static func isAlive(_ pid: pid_t) -> Bool {
        // Signal 0 performs the permission and existence checks without sending
        // anything.
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    /// Process ids currently accepting connections on `port`.
    ///
    /// Needed because the process holding a listening socket is not always the one
    /// this app spawned: npm's exec layer inserts a wrapper and the real server can
    /// be reparented out of that tree, so killing the recorded pid does not
    /// necessarily release the port.
    static func listeners(on port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Parent process id, or `nil` when it cannot be read.
    static func parentPID(of pid: pid_t) -> pid_t? {
        guard pid > 1 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", "\(pid)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text)
    }

    // MARK: - Private

    private static func deliver(_ pid: pid_t, _ signal: Int32) {
        guard pid > 1 else { return }

        // Only address the process group when this process actually leads one.
        // Sending to `-pid` otherwise risks signalling an unrelated group whose
        // id happens to collide with this pid.
        if getpgid(pid) == pid {
            kill(-pid, signal)
        }
        kill(pid, signal)
    }

    /// Depth-first post-order traversal: children are returned before their
    /// parent, which is the safe order for tearing a tree down.
    private static func descendantsPostOrder(of root: pid_t) -> [pid_t] {
        let children = childMap()
        var ordered: [pid_t] = []

        func visit(_ parent: pid_t, depth: Int) {
            // Guard against pathological depth or a cyclic ppid report.
            guard depth < 64 else { return }
            for child in children[parent] ?? [] {
                visit(child, depth: depth + 1)
                ordered.append(child)
            }
        }

        visit(root, depth: 0)
        return ordered
    }

    /// One `ps` call, so the snapshot is internally consistent.
    private static func childMap() -> [pid_t: [pid_t]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var map: [pid_t: [pid_t]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  let pid = pid_t(fields[0]),
                  let parent = pid_t(fields[1]) else { continue }
            map[parent, default: []].append(pid)
        }
        return map
    }
}
