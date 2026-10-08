import AppKit
import SwiftUI

@main
struct TetherApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // The console window: live output of the background DSH service.
        Window(L10n.text(.appName), id: WindowID.console) {
            ConsoleView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 420)
                .task {
                    // Applies the stored icon override, then auto-starts the
                    // service. Both must happen after the app has launched.
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands { AppCommands(model: model) }

        // Reorderable launch presets. A genuine drag-and-drop list is where
        // macOS 27's `reorderContainer` applies.
        Window(L10n.text(.launchPresetsTitle), id: WindowID.presets) {
            PresetsView()
                .environment(model)
        }
        .defaultSize(width: 460, height: 380)

        // Top-right menu bar item. `.menu` style gives the native pull-down with
        // real menu items, so "Stop Service" is always reachable even when every
        // window is closed.
        MenuBarExtra {
            StatusMenuContent()
                .environment(model)
        } label: {
            // The label is rendered by the system outside the scene's view tree,
            // so it takes the status directly instead of reading the environment.
            StatusMenuLabel(status: model.status)
        }
        .menuBarExtraStyle(.menu)

        // Enables the standard Settings… item (⌘,) and window.
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let console = "dsh.console"
    static let presets = "dsh.presets"
}

/// Performs launch-time setup that has to happen before any window is shown.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is a regular Dock app that also owns a menu bar item, so it
        // must not be treated as an accessory.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Closing the console window must not quit: the menu bar item is the point
    /// of the app, and the service should keep running until explicitly stopped.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click with no visible window reopens the console.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.identifier?.rawValue.contains(WindowID.console) == true }?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }
}

/// Menu commands for the console window.
struct AppCommands: Commands {

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.string(.menuShowConsole)) {
                openWindow(id: WindowID.console)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button(model.string(.commandShowLaunchPresets)) {
                openWindow(id: WindowID.presets)
            }
            .keyboardShortcut("2", modifiers: [.command])
        }

        CommandMenu(model.string(.menuServiceMenu)) {
            Button(model.string(.actionStart)) {
                Task { await model.start() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.status.isRunning || model.status.isBusy)

            Button(model.string(.actionRestart)) {
                Task { await model.restart() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.status.isRunning)

            Button(model.string(.actionStop)) {
                Task { await model.stop() }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!model.status.isRunning && !model.status.isBusy)

            Divider()

            Button(model.string(.menuOpenInBrowser)) {
                model.openInBrowser()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model.runningPort == nil)

            Button(model.string(.menuCopyServiceURL)) {
                model.copyServiceURL()
            }
            .disabled(model.runningPort == nil)

            Divider()

            Button(model.string(.exportConsoleLog)) {
                model.exportTranscript()
            }
            Button(model.string(.menuRevealWorkspace)) {
                model.revealWorkspace()
            }
        }

        CommandGroup(after: .pasteboard) {
            Button(model.string(.copyConsoleTranscript)) {
                model.copyTranscriptToPasteboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(model.string(.clearConsole)) {
                model.clearConsole()
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }
}
