import Foundation

/// `UserDefaults` keys shared by the settings store and the service layer.
enum DefaultsKey {
    static let port = "dsh.port"
    static let automaticallyStartsService = "dsh.autoStart"
    static let packageSpecifier = "dsh.packageSpecifier"
    static let iconBookmarkData = "dsh.iconBookmarkData"
    static let iconDisplayName = "dsh.iconDisplayName"
    /// Interface language. Absent means "follow the system", resolved at read time.
    static let language = "dsh.language"
    /// Process id of the running DSH child, recorded so a later launch can reap it
    /// if the app died without stopping the service.
    static let lastChildPID = "dsh.lastChildPID"
    /// Command line of that child, used to confirm the pid was not recycled.
    static let lastChildCommand = "dsh.lastChildCommand"
}

/// Filesystem layout owned by the app.
///
/// Previously these paths were spelled out in four places (the service plus three
/// accessors on the model), which meant a rename had to be applied consistently by
/// hand or the app would read from one location and write to another. They live
/// here so there is a single source of truth.
enum AppPaths {

    /// Directory under `~/Library/Application Support` holding everything the app
    /// manages. Also used as the *pre-rename* name when migrating existing data.
    static let folderName = "Tether"

    /// Legacy directory names, newest first, that should be migrated on first run.
    static let legacyFolderNames = ["DSHHarness"]

    static var supportRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static var workspace: URL {
        supportRoot.appendingPathComponent("Workspace", isDirectory: true)
    }

    static var dshHome: URL {
        supportRoot.appendingPathComponent("DSHHome", isDirectory: true)
    }

    static var npmCache: URL {
        supportRoot.appendingPathComponent("NpmCache", isDirectory: true)
    }

    static var logFile: URL {
        supportRoot.appendingPathComponent("dsh-web.log")
    }

    /// Moves data from any legacy location into the current one, once.
    ///
    /// Renaming the folder would otherwise strand the npm cache — over a gigabyte
    /// on a warm install — and force a full re-download on the next launch.
    /// A move (not a copy) is used because the cache can be large and the two
    /// locations are on the same volume.
    static func migrateLegacyDataIfNeeded() {
        let fileManager = FileManager.default

        // Nothing to do if the current location already exists and is populated.
        if fileManager.fileExists(atPath: supportRoot.path) { return }

        for legacyName in legacyFolderNames {
            let legacy = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }

            do {
                try fileManager.moveItem(at: legacy, to: supportRoot)
            } catch {
                // A failed move must not stop the app: it will simply start with a
                // cold cache, which is recoverable.
                return
            }
            return
        }
    }
}

/// How the `dsh` package itself is selected.
enum DSHConfiguration {
    /// Default npm specifier for the DSH CLI.
    ///
    /// `@latest` is intentional: the app should pick up new releases without an
    /// app update. Users who want reproducible launches (or a faster start on a
    /// cold cache) can pin an exact version in Settings, for example
    /// `@deepseek-ai/dsh@0.2.0-rc.2`.
    static let defaultPackageSpecifier = "@deepseek-ai/dsh@latest"

    /// Specifier currently in effect.
    static var packageSpecifier: String {
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.packageSpecifier) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultPackageSpecifier : trimmed
    }

    /// Extra arguments appended after `dsh web --port <port>`.
    ///
    /// Read from `DSH_HARNESS_EXTRA_ARGS` (whitespace separated) so the app can be
    /// pointed at profile patches or a different workspace without a rebuild.
    static var extraArguments: [String] {
        guard let raw = ProcessInfo.processInfo.environment["DSH_HARNESS_EXTRA_ARGS"] else {
            return []
        }
        return raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
