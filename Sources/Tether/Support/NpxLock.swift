import Foundation

/// Repairs stale `npx` state before launch.
///
/// `npx --package=<spec>` resolves the package under `~/.npm/_npx/<hash>/` and
/// guards that directory with an advisory lock implemented by
/// `libnpmexec/lib/with-lock.js`. That lock is a directory whose modification
/// time is refreshed once a second, and it is considered stale after 60s.
///
/// If a previous `npx` run is killed (or its process tree is torn down) while it
/// holds the lock, the next run fails immediately and confusingly:
///
///     npm error code ECOMPROMISED
///     npm error Lock compromised
///
/// Because the app owns its own process tree and guarantees it is not running
/// when it launches, any lock directory it finds is by definition abandoned, and
/// clearing it is the same recovery npm performs on its own stale locks.
enum NpxLock {

    /// Removes lock directories left behind by a previous, killed run.
    ///
    /// - Returns: the number of stale locks removed.
    @discardableResult
    static func clearStaleLocks() -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var removed = 0
        for entry in entries {
            let lock = entry.appendingPathComponent("concurrency.lock")
            guard FileManager.default.fileExists(atPath: lock.path) else { continue }
            if (try? FileManager.default.removeItem(at: lock)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Recognises the failure signature in captured output, so the service can
    /// retry instead of reporting an opaque npm error.
    static func indicatesCompromisedLock(_ text: String) -> Bool {
        text.contains("ECOMPROMISED") || text.contains("Lock compromised")
    }
}
