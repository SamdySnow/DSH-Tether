import AppKit
import SwiftUI

/// Menu bar item label.
///
/// Only glyph-level views render reliably in the menu bar, so this stays to a
/// template image plus, while the service is up, the port it is serving.
///
/// The status is passed in rather than read from the environment: the system
/// renders this label outside the scene's view tree.
struct StatusMenuLabel: View {

    let status: ServiceStatus

    var body: some View {
        // The icon doubles as a state indicator, which is the fastest read of the
        // service state when the console window is closed.
        switch status {
        case .running(let port):
            HStack(spacing: 3) {
                Image(systemName: "terminal.fill")
                Text(String(port))
                    .font(.system(size: 11, design: .monospaced))
            }
        case .starting, .stopping:
            Image(systemName: "terminal")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            Image(systemName: "terminal")
        }
    }
}

/// Pull-down menu shown when the menu bar item is clicked.
///
/// The accent colour is irrelevant to readability here; the ordering is not, so
/// stopping the service is reachable in one click without traversing submenus.
struct StatusMenuContent: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var settings = model.settings

        // Status line. Disabled so it reads as a label rather than an action.
        Text(stateHeadline)

        if let pid = model.processIdentifier, model.status.isRunning {
            Text(model.string(.pidFormat, String(pid)))
        }

        Divider()

        Button(model.string(.menuShowConsole)) {
            showConsole()
        }
        .keyboardShortcut("1")

        if model.status.isRunning {
            Button(model.string(.menuOpenInBrowser)) {
                model.openInBrowser()
            }
            Button(model.string(.menuCopyServiceURL)) {
                model.copyServiceURL()
            }
        }

        Divider()

        // ---- Service control: the primary reason to open this menu ----
        if model.status.isRunning {
            Button(model.string(.menuRestartService)) {
                Task { await model.restart() }
            }
            Button(model.string(.menuStopService)) {
                Task { await model.stop() }
            }
        } else {
            Button(model.string(.menuStartService)) {
                Task { await model.start() }
            }
            .disabled(model.status.isBusy)
        }

        Divider()

        Menu(model.string(.menuPort)) {
            Text(model.string(.menuCurrentPort, String(settings.port)))
            Divider()
            Button(model.string(.menuPickFreePort)) {
                if let free = PortProbe.firstAvailable(atOrAfter: settings.port + 1) {
                    settings.port = free
                    Task { await model.applyPortAndRestartIfRunning() }
                }
            }
            Divider()
            // Common choices as a shortcut for the frequent case.
            ForEach([3000, 5173, 8000, 8080, 8787, 9000], id: \.self) { candidate in
                Button("\(candidate)") {
                    settings.port = candidate
                    Task { await model.applyPortAndRestartIfRunning() }
                }
            }
        }

        Toggle(model.string(.menuStartWithApp), isOn: $settings.automaticallyStartsService)

        Divider()

        // ---- Settings: opened via the `openSettings` environment action rather
        // than `SettingsLink`. A `.menu`-style MenuBarExtra hands the click to the
        // system menu, so the app is not frontmost when it fires; opening the
        // Settings window without activating first can leave it behind other apps
        // or not appear at all. Activating explicitly, then opening, is reliable.
        Button(model.string(.menuSettings)) {
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button(model.string(.menuRevealWorkspace)) {
            model.revealWorkspace()
        }

        Divider()

        // ---- Shutdown: also stops the background service, so quitting never
        // leaves an orphaned server holding the port. ----
        Button(model.string(.menuQuitAndStop)) {
            Task { await model.quit() }
        }
        .keyboardShortcut("q")
    }

    private var stateHeadline: String {
        switch model.status {
        case .running(let port): model.string(.statusRunningTooltip, String(port))
        case .starting: model.string(.statusStartingTooltip)
        case .stopping: model.string(.statusStoppingTooltip)
        case .failed(let reason): reason
        case .idle: model.string(.serviceStoppedHeadline)
        }
    }

    private func showConsole() {
        openWindow(id: WindowID.console)
        NSApplication.shared.activate()
    }
}