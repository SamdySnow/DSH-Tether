import Foundation
import Observation
import ServiceManagement

/// Launch-at-login control backed by `SMAppService`.
///
/// `SMAppService.mainApp` requires the code to run from a real `.app` bundle;
/// when the binary is executed straight from `.build/debug`, registration fails
/// and the reason is surfaced instead of being swallowed.
@MainActor
@Observable
final class LaunchAtLogin {

    private(set) var isEnabled = false
    private(set) var lastError: String?

    /// `false` when the app is not running from a bundle and the toggle cannot work.
    let isSupported: Bool

    init() {
        let bundlePath = Bundle.main.bundlePath
        isSupported = bundlePath.hasSuffix(".app")
        refresh()
    }

    func refresh() {
        guard isSupported else { return }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    var statusDescription: String {
        guard isSupported else {
            return L10n.text(.loginItemNeedsBundle)
        }
        switch SMAppService.mainApp.status {
        case .enabled: return L10n.text(.loginItemEnabled)
        case .notRegistered: return L10n.text(.loginItemNotRegistered)
        case .notFound: return L10n.text(.loginItemNotFound)
        case .requiresApproval: return L10n.text(.loginItemRequiresApproval)
        @unknown default: return L10n.text(.loginItemUnknown)
        }
    }
}
