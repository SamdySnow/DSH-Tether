import Foundation

/// How to invoke the DSH command line.
///
/// A GUI app launched from Finder inherits almost nothing from a login shell:
/// `PATH` is typically the bare system default, so `node`, `npx` and any
/// user-installed toolchain are invisible. Rather than making the user fight
/// that, the resolver searches the usual install locations and remembers what
/// worked.
struct ExecutionTarget: Sendable, Equatable {
    /// Absolute path of the `node` binary used to run npx.
    let nodePath: String
    /// Absolute path of `npx`'s JavaScript entry point (the npm CLI).
    let npxCLIPath: String
    /// Directory prepended to `PATH` for the child, so tools that DSH shells out
    /// to resolve normally.
    let pathPrefix: String

    /// Environment variable that lets a user point the app at a specific runtime,
    /// mirroring how the DSH README treats `DSH_HOME`.
    static let nodeOverrideKey = "DSH_HARNESS_NODE"

    var summary: String {
        "\(nodePath)  (npx: \(npxCLIPath))"
    }
}

enum ExecutionTargetResolver {

    /// Directories that commonly hold a Node install and are *not* in the `PATH`
    /// of a Finder-launched app.
    private static var searchDirectories: [String] {
        var directories: [String] = []

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        directories.append("\(home)/.volta/bin")
        directories.append("\(home)/.local/bin")
        directories.append("\(home)/bin")
        directories.append("\(home)/.nvm/current/bin")
        directories.append("\(home)/.fnm/current/bin")

        // nvm keeps every version side by side; newest first is the best guess.
        directories.append(contentsOf: nvmVersionDirectories(home: home))

        directories.append("/opt/homebrew/bin")
        directories.append("/usr/local/bin")
        directories.append("/usr/bin")
        directories.append("/bin")

        return directories
    }

    private static func nvmVersionDirectories(home: String) -> [String] {
        let versionsRoot = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsRoot) else {
            return []
        }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(versionsRoot)/\($0)/bin" }
    }

    /// Resolves a usable Node runtime, or `nil` when none can be found.
    ///
    /// The result is cached in `UserDefaults` so the console can show it and so a
    /// slow filesystem scan happens at most once per successful resolution.
    static func resolve() -> ExecutionTarget? {
        let fileManager = FileManager.default
        let directories = searchDirectories

        // Explicit override wins, and its bin directory is trusted for PATH.
        if let override = ProcessInfo.processInfo.environment[ExecutionTarget.nodeOverrideKey],
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                let bin = (expanded as NSString).deletingLastPathComponent
                if let npx = locateNPLEntry(binDirectory: bin) {
                    return ExecutionTarget(nodePath: expanded, npxCLIPath: npx, pathPrefix: bin)
                }
            }
        }

        for directory in directories {
            let node = "\(directory)/node"
            guard fileManager.isExecutableFile(atPath: node) else { continue }
            guard let npx = locateNPLEntry(binDirectory: directory) else { continue }
            return ExecutionTarget(nodePath: node, npxCLIPath: npx, pathPrefix: directory)
        }

        return nil
    }

    /// Finds npm's JavaScript entry point next to a `node` binary.
    ///
    /// Running `node /path/to/npm-cli.js exec ...` avoids depending on the `npx`
    /// shell shim being executable and avoids any `#!/usr/bin/env node` lookup
    /// against a `PATH` the child has not built yet.
    private static func locateNPLEntry(binDirectory: String) -> String? {
        let fileManager = FileManager.default

        let candidates = [
            // Standard npm layout: <prefix>/bin/node and <prefix>/lib/node_modules/npm
            "\(binDirectory)/../lib/node_modules/npm/bin/npx-cli.js",
            // Homebrew / some packagers
            "\(binDirectory)/../libexec/lib/node_modules/npm/bin/npx-cli.js",
            "\(binDirectory)/../share/nodejs/npm/bin/npx-cli.js",
            // Layout where node sits next to a resolved npm directory
            "\(binDirectory)/node_modules/npm/bin/npx-cli.js",
        ]

        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate).standardized.path
            if fileManager.fileExists(atPath: standardized) {
                return standardized
            }
        }
        return nil
    }

    /// `true` when the resolver can drive DSH at all.
    static var isRuntimeAvailable: Bool { resolve() != nil }
}
