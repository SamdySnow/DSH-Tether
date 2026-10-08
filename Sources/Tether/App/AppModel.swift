import AppKit
import Foundation
import Observation

/// Main-actor view model: bridges the `DSHService` actor to SwiftUI.
@MainActor
@Observable
final class AppModel {

    // MARK: - Collaborators

    let settings: SettingsStore
    let icons: IconManager
    let service = DSHService()

    // MARK: - Published state

    private(set) var status: ServiceStatus = .idle
    private(set) var processIdentifier: pid_t?
    private(set) var isConsoleFollowingOutput = true

    /// Wall-clock time since the current start attempt began, for the UI.
    ///
    /// A cold DSH start spends minutes resolving a 300+ package tree before the
    /// server exists. Without a visible elapsed time that is indistinguishable
    /// from a hang, so the toolbar shows it while starting.
    private(set) var elapsedWhileStarting: Duration?

    private var startTimestamp: ContinuousClock.Instant?
    private var elapsedTimer: Task<Void, Never>?

    /// Console search text. Filtering happens against the plain-text form so a
    /// query that spans a colour change still matches.
    var searchText = ""

    /// Transcript shown in the console, including app-generated notices.
    private(set) var entries: [LogEntry] = []
    private static let entryLimit = 6000

    /// The authenticated URL DSH announced, captured from its startup output.
    ///
    /// Held separately from the transcript so it survives "Clear Console" and so
    /// the browser and clipboard actions can use it.
    private(set) var announcedURLString: String?

    /// Entries matching `searchText`, or all entries when the query is empty.
    var visibleEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.plain.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Private

    private var consumptionTasks: [Task<Void, Never>] = []
    private var seenEntryIDs = Set<UUID>()
    private var didPerformInitialStart = false

    init() {
        self.settings = SettingsStore()
        self.icons = IconManager()
        startConsumingServiceStreams()
    }

    // MARK: - Stream consumption

    /// Mirrors the service's output and status streams into observable state.
    ///
    /// The replay buffer is read *after* subscription is established, and entries
    /// are de-duplicated by id, so no line can be lost in the window between
    /// subscribing and fetching history.
    private func startConsumingServiceStreams() {
        let entryStream = service.entries
        consumptionTasks.append(Task { @MainActor [weak self] in
            for await entry in entryStream {
                self?.append(entry)
            }
        })

        let statusStream = service.statuses
        consumptionTasks.append(Task { @MainActor [weak self] in
            for await newStatus in statusStream {
                self?.apply(newStatus)
            }
        })

        consumptionTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            for entry in await service.history() {
                self.append(entry)
            }
            // Route through `apply` so the elapsed-time readout is set up if the
            // service was already starting when the model came online.
            self.apply(await service.status)
            self.processIdentifier = await service.processIdentifier
        })
    }

    private func append(_ entry: LogEntry) {
        captureAnnouncedURL(from: entry)

        guard seenEntryIDs.insert(entry.id).inserted else { return }
        entries.append(entry)
        if entries.count > Self.entryLimit {
            let overflow = entries.count - Self.entryLimit
            for removed in entries.prefix(overflow) {
                seenEntryIDs.remove(removed.id)
            }
            entries.removeFirst(overflow)
        }
    }

    /// Records the authenticated URL DSH prints at startup.
    ///
    /// Only scans app-bound lines that could contain it, and never clears a URL
    /// already known, so a later log line cannot drop the credential.
    private func captureAnnouncedURL(from entry: LogEntry) {
        guard announcedURLString == nil else { return }
        guard entry.plain.contains("http://") || entry.plain.contains("https://") else { return }
        guard let url = ServiceEndpoint.extract(from: entry.plain) else { return }
        announcedURLString = url.absoluteString
    }

    /// Applies a status change and keeps the elapsed-time readout in sync with it.
    private func apply(_ newStatus: ServiceStatus) {
        status = newStatus

        switch newStatus {
        case .starting:
            beginElapsedTimer()
        default:
            endElapsedTimer()
        }
    }

    private func beginElapsedTimer() {
        guard elapsedTimer == nil else { return }
        let began = ContinuousClock.now
        startTimestamp = began
        elapsedWhileStarting = .zero

        elapsedTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.startTimestamp else { return }
                self.elapsedWhileStarting = ContinuousClock.now - start
            }
        }
    }

    private func endElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
        startTimestamp = nil
        elapsedWhileStarting = nil
    }

    /// Refreshes the process id shown in the UI from the actor.
    private func refreshProcessIdentifier() async {
        processIdentifier = await service.processIdentifier
    }

    // MARK: - Localization

    /// Interface language, proxied from settings so views can observe it here.
    var language: AppLanguage { settings.language }

    /// Localized text for a key.
    ///
    /// Views read strings through this method rather than calling `L10n` directly:
    /// `settings.language` is observable, so touching it here is what makes the
    /// whole interface re-render when the language changes.
    func string(_ key: Loc) -> String {
        L10n.text(key, settings.language)
    }

    /// Localized text with `%@` / `%d` substitutions.
    func string(_ key: Loc, _ arguments: CVarArg...) -> String {
        L10n.text(key, settings.language, arguments)
    }

    /// Launch-time setup that must run once the app is fully up.
    ///
    /// The runtime icon override is applied here rather than in `init`: during App
    /// initialisation the process has not finished launching, and the bundle icon
    /// would overwrite anything set that early. This was previously never called,
    /// so a custom icon chosen in Settings did not survive a relaunch.
    func bootstrap() async {
        icons.applyStoredIcon()
        await performInitialStartIfNeeded()
    }

    /// Kicks off the automatic launch exactly once per app run.
    func performInitialStartIfNeeded() async {
        guard !didPerformInitialStart else { return }
        didPerformInitialStart = true

        startConsumingServiceStreamsIfNeeded()

        guard settings.automaticallyStartsService else {
            append(LogEntry(stream: .app, raw: "[app] \(L10n.text(.appAutoStartDisabled))\n"))
            return
        }
        await start()
    }

    private func startConsumingServiceStreamsIfNeeded() {
        if consumptionTasks.isEmpty { startConsumingServiceStreams() }
    }

    // MARK: - Commands

    func start() async {
        await service.start(port: settings.port)
        await refreshProcessIdentifier()
    }

    func stop() async {
        await service.stop()
        await refreshProcessIdentifier()
    }

    func restart() async {
        await service.restart(port: settings.port)
        await refreshProcessIdentifier()
    }

    /// Stops the service and terminates the app.
    func quit() async {
        await service.stop()
        NSApplication.shared.terminate(nil)
    }

    /// Relaunches on the current settings, after making sure the port is free.
    func applyPortAndRestartIfRunning() async {
        guard status.isRunning || status.isBusy else { return }
        await restart()
    }

    // MARK: - Console helpers

    func clearConsole() {
        entries.removeAll()
        seenEntryIDs.removeAll()
    }

    /// Copies the whole transcript (escape sequences stripped) to the pasteboard.
    func copyTranscriptToPasteboard() {
        let text = entries.map(\.plain).joined()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Writes the transcript to a user-chosen file.
    func exportTranscript() {
        let panel = NSSavePanel()
        panel.title = L10n.text(.exportLogPanelTitle)
        panel.nameFieldStringValue = "dsh-web.log"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = entries.map(\.plain).joined()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Opens the running server in the default browser.
    ///
    /// Uses the URL DSH announced, which carries its `token` query item. Falling
    /// back to the bare loopback address would open an unauthenticated request.
    func openInBrowser() {
        guard let url = announcedURL ?? runningPort.flatMap(ServiceEndpoint.loopback) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyServiceURL() {
        guard let url = announcedURL ?? runningPort.flatMap(ServiceEndpoint.loopback) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// Authenticated URL announced by DSH, once it has been seen in the output.
    var announcedURL: URL? {
        announcedURLString.flatMap(URL.init(string:))
    }

    var hasAuthenticatedURL: Bool { announcedURL != nil }

    var runningPort: Int? {
        if case .running(let port) = status { return port }
        return nil
    }

    /// Display form of the service address.
    ///
    /// Deliberately excludes the `token` query item: this string is shown in the
    /// toolbar and menu, and the token is a credential. The URL actually handed to
    /// the browser (`announcedURL`) does include it.
    var serviceURLString: String {
        guard let port = runningPort else { return "—" }
        return "http://127.0.0.1:\(port)/"
    }

    var logFileURL: URL? {
        let url = AppPaths.logFile
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func revealLogFile() {
        guard let logFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    /// Opens the DSH workspace folder, i.e. the child process's working directory.
    func revealWorkspace() {
        let workspace = AppPaths.workspace
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        NSWorkspace.shared.open(workspace)
    }

    /// Opens the app-managed DSH home directory.
    func revealDSHHome() {
        let home = AppPaths.dshHome
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        NSWorkspace.shared.open(home)
    }
}
