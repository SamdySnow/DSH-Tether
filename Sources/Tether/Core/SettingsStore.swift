import Foundation
import Observation

/// One-time adoption of preferences written under the app's previous bundle
/// identifier.
///
/// Changing the bundle identifier gives the app a brand-new `UserDefaults`
/// domain, so without this the user's port, language, icon choice, and window
/// positions would silently reset. Values are copied (not moved) into the current
/// domain, and the legacy domain is left untouched so a rollback still finds them.
enum PreferencesMigration {

    /// Bundle identifiers this app used previously, newest first.
    private static let legacyBundleIdentifiers = ["dev.deepseek.dshharness"]

    /// Preferences keys owned by this app. Copied explicitly rather than wholesale
    /// so AppKit's own window/frame bookkeeping is not dragged across.
    private static let ownedKeys = [
        DefaultsKey.port,
        DefaultsKey.automaticallyStartsService,
        DefaultsKey.packageSpecifier,
        DefaultsKey.iconBookmarkData,
        DefaultsKey.iconDisplayName,
        DefaultsKey.language,
        DefaultsKey.lastChildPID,
        DefaultsKey.lastChildCommand,
    ]

    private static let migrationFlag = "tether.preferencesMigrated"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard

        // Runs once. Re-running would overwrite choices the user has since made in
        // the new domain with whatever the old domain happened to hold.
        guard !defaults.bool(forKey: migrationFlag) else { return }
        defer { defaults.set(true, forKey: migrationFlag) }

        for identifier in legacyBundleIdentifiers {
            guard let legacy = UserDefaults(suiteName: identifier) else { continue }
            // A domain that was never written to reads back empty; skip it.
            guard !legacy.dictionaryRepresentation().isEmpty else { continue }

            for key in ownedKeys {
                // Already set in the new domain: the user's current choice wins.
                guard defaults.object(forKey: key) == nil,
                      let value = legacy.object(forKey: key) else { continue }
                defaults.set(value, forKey: key)
            }
            return
        }
    }
}

/// User-facing preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class SettingsStore {

    /// Ports below 1024 require root, so the picker starts at 1024.
    static let portRange = 1024...65535
    static let defaultPort = 8787

    private var storedPort: Int
    private var storedPackageSpecifier: String

    /// Port the DSH server should listen on. Clamped to a usable range on write.
    var port: Int {
        get { storedPort }
        set {
            let clamped = min(max(newValue, Self.portRange.lowerBound), Self.portRange.upperBound)
            guard clamped != storedPort else { return }
            storedPort = clamped
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.port)
        }
    }

    /// Launch the service when the app opens.
    var automaticallyStartsService: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyStartsService, forKey: DefaultsKey.automaticallyStartsService)
        }
    }

    /// npm specifier for the DSH CLI. An empty value restores the default.
    var packageSpecifier: String {
        get { storedPackageSpecifier }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != storedPackageSpecifier else { return }
            storedPackageSpecifier = trimmed
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.packageSpecifier)
        }
    }

    /// Interface language.
    ///
    /// Stored as a concrete language rather than a "follow system" flag: the picker
    /// always shows which language is actually in effect, and resolving the
    /// default once at first launch avoids the interface changing underneath the
    /// user if they later switch their system language.
    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.language)
        }
    }

    /// Specifier actually passed to npx.
    var effectivePackageSpecifier: String {
        storedPackageSpecifier.isEmpty ? DSHConfiguration.defaultPackageSpecifier : storedPackageSpecifier
    }

    var isUsingDefaultPackageSpecifier: Bool { storedPackageSpecifier.isEmpty }

    init() {
        PreferencesMigration.migrateIfNeeded()
        let defaults = UserDefaults.standard

        let rawPort = defaults.object(forKey: DefaultsKey.port) as? Int ?? Self.defaultPort
        storedPort = min(max(rawPort, Self.portRange.lowerBound), Self.portRange.upperBound)

        automaticallyStartsService =
            defaults.object(forKey: DefaultsKey.automaticallyStartsService) as? Bool ?? true

        storedPackageSpecifier = defaults.string(forKey: DefaultsKey.packageSpecifier) ?? ""

        // Seed from the system on first launch, then persist the resolved choice.
        let storedLanguage = defaults.string(forKey: DefaultsKey.language)
            .flatMap(AppLanguage.init(rawValue:))
        language = storedLanguage ?? AppLanguage.systemDefault
        if storedLanguage == nil {
            defaults.set(language.rawValue, forKey: DefaultsKey.language)
        }
    }

    /// Restores the default package specifier.
    func resetPackageSpecifier() {
        packageSpecifier = ""
    }
}
