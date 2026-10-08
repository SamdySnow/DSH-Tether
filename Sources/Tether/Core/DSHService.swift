import Foundation

/// Snapshot of the background service.
enum ServiceStatus: Sendable, Equatable {
    case idle
    case starting
    case running(port: Int)
    case stopping
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Short label for the menu bar and the toolbar badge.
    var label: String {
        self.label(for: AppLanguage.stored)
    }

    func label(for language: AppLanguage) -> String {
        switch self {
        case .idle: L10n.text(.statusStopped, language)
        case .starting: L10n.text(.statusStarting, language)
        case .running(let port): L10n.text(.statusRunningOn, language, [String(port)])
        case .stopping: L10n.text(.statusStopping, language)
        case .failed: L10n.text(.statusFailed, language)
        }
    }

    /// Full description for the console transcript.
    ///
    /// `label` is deliberately terse for the menu bar; losing the reason when the
    /// service fails would leave the log with a bare "Failed" and nothing to act
    /// on, so the detail is kept separately.
    var logDescription: String {
        logDescription(for: AppLanguage.stored)
    }

    func logDescription(for language: AppLanguage) -> String {
        switch self {
        case .failed(let reason):
            L10n.text(.statusFailedWithReason, language, [reason])
        default:
            label(for: language)
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "circle.dashed"
        case .starting: "circle.dotted"
        case .running: "circle.fill"
        case .stopping: "circle.dotted"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// Owns the DSH child process and its output.
///
/// Everything that touches the process lives in this actor so start/stop cannot
/// interleave. Child output is published through an `AsyncStream` that the UI
/// consumes on the main actor.
actor DSHService {

    // MARK: - Public streams

    /// Output lines, in arrival order.
    nonisolated let entries: AsyncStream<LogEntry>
    /// Status transitions.
    nonisolated let statuses: AsyncStream<ServiceStatus>

    private let entryContinuation: AsyncStream<LogEntry>.Continuation
    private let statusContinuation: AsyncStream<ServiceStatus>.Continuation

    // MARK: - State (actor isolated)

    private var process: Process?
    private var outputPumps: [Task<Void, Never>] = []
    private var diagnosticsTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?

    private(set) var status: ServiceStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            statusContinuation.yield(status)
            record(LogEntry(stream: .app, raw: "[app] \(status.logDescription)\n"))
        }
    }

    /// Active port, known once the service is running.
    private(set) var activePort: Int?

    /// Child process id, exposed so the menu can show it.
    private(set) var processIdentifier: pid_t?

    /// Bounded replay buffer, so a window opened late still shows recent output.
    private var recentEntries: [LogEntry] = []
    private static let replayLimit = 4000

    // MARK: - Configuration

    /// Working directory for the child process, i.e. the DSH workspace root.
    private let workspaceRoot: URL
    /// Isolated DSH home so app-managed state never mixes with a user's CLI use.
    private let dshHome: URL
    /// Private npm cache used only by this app.
    ///
    /// Sharing npm's default `~/.npm/_cacache` caused hard failures in the field:
    /// a cache holding entries owned by `root` (from a past `sudo npm`) makes npm
    /// abort with a misleading `EEXIST` / `EACCES: permission denied, mkdir ...`.
    /// That is unrecoverable without `sudo`, so the app no longer touches the
    /// shared cache at all. A private cache is also more predictable, and it keeps
    /// the app from perturbing the user's own npm state.
    private let npmCache: URL
    /// Log file mirroring the console, for post-mortem inspection.
    private let logFileURL: URL

    private var logHandle: FileHandle?

    init() {
        var capturedEntryContinuation: AsyncStream<LogEntry>.Continuation!
        self.entries = AsyncStream(bufferingPolicy: .bufferingNewest(4000)) {
            capturedEntryContinuation = $0
        }
        self.entryContinuation = capturedEntryContinuation

        var capturedStatusContinuation: AsyncStream<ServiceStatus>.Continuation!
        self.statuses = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
            capturedStatusContinuation = $0
        }
        self.statusContinuation = capturedStatusContinuation

        // Adopt data written under the app's previous name before anything reads
        // or creates a directory, so an existing npm cache is not stranded.
        AppPaths.migrateLegacyDataIfNeeded()
        try? FileManager.default.createDirectory(at: AppPaths.supportRoot, withIntermediateDirectories: true)

        self.workspaceRoot = AppPaths.workspace
        self.dshHome = AppPaths.dshHome
        self.npmCache = AppPaths.npmCache
        self.logFileURL = AppPaths.logFile
    }

    // MARK: - Lifecycle

    /// Launches DSH if it is not already running.
    func start(port: Int) async {
        guard !status.isBusy else { return }

        // A child that already exited leaves bookkeeping behind but no usable
        // process. Clear it so Start works again after a failure, instead of
        // silently doing nothing because `process` is still non-nil.
        if let existing = process, !existing.isRunning {
            process = nil
            processIdentifier = nil
            activePort = nil
        }

        // Still alive from a previous attempt: nothing to do.
        guard process == nil else { return }

        // Open the log before anything can fail or emit a message. Previously this
        // happened much later, so a start that bailed out early — a port conflict,
        // for instance — was reported in the console but left no trace in the log
        // file, which is the artefact used for post-mortem inspection.
        openLogFile()

        // Free the port before anything else can fail on it.
        //
        // Order matters here and was previously wrong: the reap sets a flag that
        // `releasePortIfStillHeld` then cleared on its way out, so the wait below
        // never ran and the port check failed against a socket the app had just
        // asked the OS to close. A process that has been signalled is not the same
        // as a socket that has been released, so the wait has to happen after both
        // steps, with no flag in between.
        await reapOrphanedChild(port: port)
        await releasePortIfStillHeld(port: port)
        _ = await PortProbe.waitUntilAvailable(port, timeout: .seconds(10))

        // Only report when the port is still held. Port handling is the least
        // predictable part of startup, and this distinguishes "genuinely taken by
        // something we must not touch" from "our own leftover" — which otherwise
        // look identical from the outside.
        if !PortProbe.isAvailable(port) {
            let holders = ProcessTree.listeners(on: port).map(String.init).joined(separator: ",")
            record(LogEntry(
                stream: .app,
                raw: "[app] port \(port) still held; listeners: \(holders.isEmpty ? "unknown" : holders)\n"
            ))
        }

        guard let target = ExecutionTargetResolver.resolve() else {
            status = .failed(L10n.text(.svcNodeNotFound, [ExecutionTarget.nodeOverrideKey]))
            return
        }

        let fileManager = FileManager.default
        // First run of a profile can be slow (template copy + package install), so
        // report progress before any blocking work.
        status = .starting
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcRuntime, [target.summary]) + "\n"))
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcWorkspace, [workspaceRoot.path]) + "\n"))
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcDshHome, [dshHome.path]) + "\n"))

        // The first launch has to resolve and download the DSH package tree before
        // the server exists. Say so, rather than leaving the user staring at an
        // apparently idle console.
        if npmCacheIsEmpty() {
            record(LogEntry(
                stream: .app,
                raw: "[app] " + L10n.text(.svcFirstRun) + "\n"
            ))
        }

        try? fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: dshHome, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: npmCache, withIntermediateDirectories: true)
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcNpmCache, [npmCache.path]) + "\n"))

        // Fail fast with a clear message rather than letting the server die on bind.
        guard PortProbe.isAvailable(port) else {
            status = .failed(L10n.text(.svcPortInUse, [String(port)]))
            return
        }

        // A previous run that was killed mid-resolution leaves an advisory lock
        // behind, which makes the next start fail with ECOMPROMISED. The app owns
        // this process tree and is not running one right now, so any lock present
        // is abandoned and safe to clear.
        let cleared = NpxLock.clearStaleLocks()
        if cleared > 0 {
            record(LogEntry(
                stream: .app,
                raw: "[app] " + L10n.text(.svcClearedLocks, [String(cleared)]) + "\n"
            ))
        }

        guard let executable = resolvedExecutable(for: target, port: port) else {
            status = .failed(L10n.text(.svcRuntimeMissing))
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: target.nodePath)
        child.arguments = executable.arguments
        child.currentDirectoryURL = workspaceRoot
        child.environment = environment(for: target)

        let standardOutput = Pipe()
        let standardError = Pipe()
        child.standardOutput = standardOutput
        child.standardError = standardError
        // Give the child its own process group so the whole tree can be signalled
        // as a unit during shutdown.
        child.qualityOfService = .userInitiated

        // Report a crash that happens outside our own start/stop bookkeeping.
        child.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            let reason = terminated.terminationReason
            Task { [weak self] in
                await self?.handleUnexpectedExit(code: code, reason: reason)
            }
        }

        do {
            try child.run()
        } catch {
            status = .failed(L10n.text(.svcLaunchFailed, [error.localizedDescription]))
            return
        }

        process = child
        processIdentifier = child.processIdentifier
        rememberChildForRecovery(pid: child.processIdentifier, command: executable.displayCommand)
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.pidFormat, [String(child.processIdentifier)]) + "\n"))
        record(LogEntry(stream: .app, raw: "[app] $ \(executable.displayCommand)\n"))

        startPumps(stdout: standardOutput, stderr: standardError)
        await waitForReadiness(port: port)
    }

    /// Stops the service, escalating to `SIGKILL` if it does not exit in time.
    func stop() async {
        guard let child = process, child.isRunning else {
            process = nil
            processIdentifier = nil
            activePort = nil
            status = .idle
            return
        }

        status = .stopping
        readinessTask?.cancel()
        readinessTask = nil

        let root = child.processIdentifier
        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcSendingSigterm, [String(root)]) + "\n"))
        ProcessTree.terminate(root)

        let cooperated = await waitForExit(child, timeout: .seconds(8))
        if !cooperated {
            record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcSendingSigkill) + "\n"))
            ProcessTree.forceKill(root)
            _ = await waitForExit(child, timeout: .seconds(4))
        }

        if let port = activePort {
            // The socket may take a moment to be released; the next start would
            // otherwise trip the availability check for no real reason.
            _ = await PortProbe.waitUntilAvailable(port)
        }

        process = nil
        processIdentifier = nil
        activePort = nil
        // Clean shutdown: nothing left to reap on the next launch.
        forgetChildForRecovery()
        await stopPumps()
        closeLogFile()
        status = .idle
    }

    /// Stops, then starts again on `port`.
    func restart(port: Int) async {
        await stop()
        await start(port: port)
    }

    // MARK: - Queries

    /// Replay buffer, for a console window that opens after output has arrived.
    func history() -> [LogEntry] { recentEntries }

    /// Full transcript with escape sequences stripped.
    func transcript() -> String {
        recentEntries.map(\.plain).joined()
    }

    // MARK: - Launch plan

    private struct LaunchPlan {
        let arguments: [String]
        let displayCommand: String
    }

    /// Builds the argv for `npx --yes --package=<spec> -- dsh web --port <port>`.
    ///
    /// The explicit `--package` form is used instead of `npx <spec> <args>` so
    /// argument routing cannot be misread as options for npm itself.
    private func resolvedExecutable(for target: ExecutionTarget, port: Int) -> LaunchPlan? {
        var arguments = [
            target.npxCLIPath,
            "--yes",
            "--package=\(DSHConfiguration.packageSpecifier)",
            "--",
            "dsh",
            "web",
            "--port",
            "\(port)",
        ]
        arguments.append(contentsOf: DSHConfiguration.extraArguments)

        let display = ([target.nodePath] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        return LaunchPlan(arguments: arguments, displayCommand: display)
    }

    private func environment(for target: ExecutionTarget) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(target.pathPrefix):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["DSH_HOME"] = dshHome.path
        // Keep the app's package resolution entirely inside its own cache; see the
        // comment on `npmCache` for why the shared cache is unusable.
        environment["npm_config_cache"] = npmCache.path
        // Keep npm non-interactive; a prompt would hang the child forever.
        environment["CI"] = "1"
        // Ask for colour explicitly. `NO_COLOR` is deliberately *not* set here:
        // tools disagree on whether an empty value means "colour allowed" or
        // "colour disabled", so leaving it unset avoids the ambiguity.
        environment["TERM"] = "xterm-256color"
        environment["FORCE_COLOR"] = "1"
        environment["npm_config_yes"] = "true"
        environment["npm_config_update_notifier"] = "false"
        environment["npm_config_fund"] = "false"
        environment["npm_config_audit"] = "false"
        return environment
    }

    // MARK: - Output plumbing

    private func startPumps(stdout: Pipe, stderr: Pipe) {
        outputPumps = [
            Task { [weak self] in
                await self?.pump(stdout.fileHandleForReading, as: .standardOutput)
            },
            Task { [weak self] in
                await self?.pump(stderr.fileHandleForReading, as: .standardError)
            },
        ]
    }

    private func stopPumps() async {
        for pump in outputPumps { pump.cancel() }
        outputPumps.removeAll()
    }

    private func pump(_ handle: FileHandle, as stream: LogEntry.Stream) async {
        do {
            for try await line in handle.bytes.lines {
                record(LogEntry(stream: stream, raw: line + "\n"))
            }
        } catch {
            // A closed pipe during shutdown is expected, not worth reporting.
        }
    }

    /// Appends to the replay buffer, the live stream and the log file.
    private func record(_ entry: LogEntry) {
        recentEntries.append(entry)
        if recentEntries.count > Self.replayLimit {
            recentEntries.removeFirst(recentEntries.count - Self.replayLimit)
        }
        entryContinuation.yield(entry)

        if let logHandle, let data = entry.raw.data(using: .utf8) {
            try? logHandle.write(contentsOf: data)
        }
    }

    // MARK: - Readiness

    /// Polls until the HTTP server accepts connections, then reports running.
    private func waitForReadiness(port: Int) async {
        activePort = port

        // `self` is captured strongly on purpose. A weak capture would make the
        // `self?` checks below fail silently and the loop would spin on its sleep
        // forever; the service outlives the task anyway.
        readinessTask = Task {
            // A cold `npx` run downloads the whole DSH package tree before the
            // server exists. That is minutes of network work, so the deadline has
            // to be generous; progress is reported by the live console output
            // rather than by a spinner.
            let deadline = ContinuousClock.now.advanced(by: .seconds(Self.readinessTimeoutSeconds))
            while ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                if PortProbe.isAcceptingConnections(port) {
                    markRunning(port: port)
                    return
                }
                // If the child died during boot there is nothing left to wait for.
                if !isChildAlive() { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
            markReadinessTimedOut()
        }
    }

    /// How long to wait for the server to start listening.
    ///
    /// Measured against the real package: `@deepseek-ai/dsh` pulls a tree of 300+
    /// packages, and npm issues well over a thousand manifest requests during
    /// resolution before it downloads a single tarball. On a cold cache that is
    /// many minutes of pure network work, so this is deliberately generous rather
    /// than "responsive". The console streams every line as it arrives, and the UI
    /// shows elapsed time, so a long wait is still legible.
    private static let readinessTimeoutSeconds = 1800

    private func isChildAlive() -> Bool {
        process?.isRunning ?? false
    }

    private func markRunning(port: Int) {
        guard status == .starting else { return }
        status = .running(port: port)
        record(LogEntry(stream: .app, raw: "[app] http://127.0.0.1:\(port)/\n"))
    }

    private func markReadinessTimedOut() {
        guard status == .starting else { return }
        status = .failed(
            L10n.text(.svcReadinessTimeout, [String(Self.readinessTimeoutSeconds)])
        )
    }

    private func handleUnexpectedExit(code: Int32, reason: Process.TerminationReason) {
        // Ignore exits that our own stop() is driving.
        guard status != .stopping, status != .idle else { return }

        readinessTask?.cancel()
        readinessTask = nil

        let description = reason == .uncaughtSignal
            ? L10n.text(.svcTerminatedBySignal, [String(code)])
            : L10n.text(.svcExitedWithCode, [String(code)])

        record(LogEntry(stream: .app, raw: "[app] " + L10n.text(.svcProcessEnded, [description]) + "\n"))
        process = nil
        processIdentifier = nil

        // A clean exit is not a failure. Something stopped the server without it
        // crashing — often the user, or a signal sent from outside — and reporting
        // that as "Failed" would be misleading.
        if reason == .exit && code == 0 {
            status = .idle
        } else {
            status = .failed(L10n.text(.svcStartFailed, [description]))
        }
    }

    private func waitForExit(_ child: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !child.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return !child.isRunning
    }

    // MARK: - Orphan recovery

    /// Records the child so a future launch can clean up after an abrupt exit.
    ///
    /// `Process.terminationHandler` and `stop()` both run only while the app is
    /// alive. If the app is killed outright — a force quit, a crash, or a signal —
    /// the DSH tree is reparented to `launchd` and keeps running, holding its port.
    /// Nothing in-process can prevent that, so the pid is persisted and the next
    /// launch reaps it.
    private func rememberChildForRecovery(pid: pid_t, command: String) {
        let defaults = UserDefaults.standard
        defaults.set(Int(pid), forKey: DefaultsKey.lastChildPID)
        defaults.set(command, forKey: DefaultsKey.lastChildCommand)
    }

    private func forgetChildForRecovery() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.lastChildPID)
        defaults.removeObject(forKey: DefaultsKey.lastChildCommand)
    }

    /// Terminates a DSH tree left behind by a previous, uncleanly-exited run.
    ///
    /// Two independent checks guard against signalling an unrelated process, since
    /// process ids are recycled and killing the wrong thing is far worse than
    /// leaking one:
    ///
    /// 1. **Orphaned.** The process must have been reparented (`ppid == 1`). If it
    ///    still has a live parent, it belongs to a running app and is not ours to
    ///    reap.
    /// 2. **Shape.** Its command line must look like a DSH web launch for the port
    ///    recorded alongside the pid.
    ///
    /// The recorded command line cannot be compared verbatim: npm's exec layer
    /// rewrites the child's argv, so the process is reported as
    /// `npm exec dsh web --port <n>` rather than the `node …/npx-cli.js …` form
    /// that was actually launched.
    private func reapOrphanedChild(port: Int) async {
        guard process == nil else { return }

        let defaults = UserDefaults.standard
        guard let recorded = defaults.object(forKey: DefaultsKey.lastChildPID) as? Int,
              recorded > 1 else { return }

        let pid = pid_t(recorded)
        defer { forgetChildForRecovery() }

        guard ProcessTree.isAlive(pid) else { return }

        guard ProcessTree.parentPID(of: pid) == 1 else {
            // Still parented: another instance, or our own live child.
            return
        }

        guard let command = ProcessTree.commandLine(of: pid),
              command.contains("dsh"),
              command.contains("web"),
              command.contains("--port"),
              command.contains("\(port)") else {
            return
        }

        record(LogEntry(
            stream: .app,
            raw: "[app] " + L10n.text(.svcTerminatingOrphan, [String(pid)]) + "\n"
        ))
        ProcessTree.terminate(pid)
        _ = await waitForProcessExit(pid, timeout: .seconds(5))
        if ProcessTree.isAlive(pid) {
            ProcessTree.forceKill(pid)
            _ = await waitForProcessExit(pid, timeout: .seconds(2))
        }
    }

    /// Frees `port` when a leftover DSH process is still listening on it.
    ///
    /// The process holding a listening socket is not necessarily the one this app
    /// spawned: npm's exec layer runs a wrapper, and the real `dsh web` server can
    /// end up outside the tree rooted at the recorded pid. Terminating that pid
    /// then leaves the port held by a process that was never tracked, and the next
    /// launch reports a port conflict the user cannot resolve.
    ///
    /// Only listeners that actually look like DSH are signalled. A user may
    /// deliberately be running `dsh web` in their own terminal, and killing another
    /// tool that happens to hold the port would be worse than reporting the
    /// conflict — so a non-DSH listener is left alone and surfaced to the user.
    private func releasePortIfStillHeld(port: Int) async {
        guard !PortProbe.isAvailable(port) else { return }

        let allListeners = ProcessTree.listeners(on: port)
        guard !allListeners.isEmpty else {
            // Held by something this process cannot inspect; the port check reports
            // it plainly rather than guessing.
            return
        }

        let dshListeners = allListeners.filter { pid in
            guard let command = ProcessTree.commandLine(of: pid) else { return false }
            return command.contains("dsh")
        }

        guard dshListeners.count == allListeners.count else {
            record(LogEntry(
                stream: .app,
                raw: "[app] " + L10n.text(.svcPortHeldByNonDsh, [String(port)]) + "\n"
            ))
            return
        }

        record(LogEntry(
            stream: .app,
            raw: "[app] " + L10n.text(.svcPortStillHeld, [String(port), String(dshListeners.count)]) + "\n"
        ))

        for pid in dshListeners {
            ProcessTree.terminate(pid)
        }

        var released = await PortProbe.waitUntilAvailable(port, timeout: .seconds(6))
        if !released {
            for pid in dshListeners where ProcessTree.isAlive(pid) {
                ProcessTree.forceKill(pid)
            }
            released = await PortProbe.waitUntilAvailable(port, timeout: .seconds(3))
        }

        if !released {
            record(LogEntry(
                stream: .app,
                raw: "[app] " + L10n.text(.svcPortReleaseFailed, [String(port)]) + "\n"
            ))
        }
    }

    private func waitForProcessExit(_ pid: pid_t, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !ProcessTree.isAlive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return !ProcessTree.isAlive(pid)
    }

    // MARK: - Log file

    /// `true` when npm has nothing cached, i.e. the next run must download the
    /// package tree from the network.
    private func npmCacheIsEmpty() -> Bool {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_cacache", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: cache.path)
        return (contents?.isEmpty ?? true)
    }

    private func openLogFile() {
        // Safe to call more than once: a second call must not leak the first
        // handle, or interleave two writers over the same file.
        closeLogFile()

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logFileURL)
        // Append rather than truncate across runs.
        _ = try? logHandle?.seekToEnd()
    }

    private func closeLogFile() {
        try? logHandle?.close()
        logHandle = nil
    }
}
