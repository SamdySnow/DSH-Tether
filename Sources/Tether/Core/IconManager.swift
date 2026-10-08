import AppKit
import Foundation
import UniformTypeIdentifiers

/// Manages the user-chosen application icon.
///
/// macOS draws the Dock and application-switcher icon from the bundle's
/// `CFBundleIconFile`, which cannot be rewritten inside a signed bundle at
/// runtime. `NSApplication.applicationIconImage` *can* be replaced at runtime,
/// and that is the supported path for user-selectable icons, but the override is
/// not persisted by the system. An explicit security-scoped bookmark is stored so
/// the choice survives relaunches, and the image is re-applied on every launch.
@MainActor
@Observable
final class IconManager {

    /// Path of the currently applied custom icon, or `nil` for the app default.
    private(set) var customIconURL: URL?
    private(set) var customIconName: String?
    private(set) var lastError: String?

    /// Build-time default icon. `nil` when running straight from `swift build`
    /// with no bundle resources, in which case the default is used unchanged.
    private let defaultIcon: NSImage?

    private static let defaults = UserDefaults.standard

    init() {
        self.defaultIcon = Self.loadDefaultIcon()
        restoreStoredSelection()
    }

    var isUsingCustomIcon: Bool { customIconURL != nil }

    // MARK: - Applying

    /// Applies the user's stored choice, or the built-in icon if there is none.
    /// Called once at launch.
    func applyStoredIcon() {
        guard let url = customIconURL else {
            NSApplication.shared.applicationIconImage = defaultIcon
            return
        }
        do {
            let image = try Self.loadImage(at: url)
            NSApplication.shared.applicationIconImage = image
        } catch {
            // The file may have moved or the bookmark may have gone stale. Fall
            // back rather than leaving the app icon-less.
            lastError = error.localizedDescription
            customIconURL = nil
            customIconName = nil
            clearStoredSelection()
            NSApplication.shared.applicationIconImage = defaultIcon
        }
    }

    /// Adopts an image file chosen in Settings.
    func setCustomIcon(from url: URL) {
        do {
            let image = try Self.loadImage(at: url)
            NSApplication.shared.applicationIconImage = image

            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            Self.defaults.set(bookmark, forKey: DefaultsKey.iconBookmarkData)
            Self.defaults.set(url.lastPathComponent, forKey: DefaultsKey.iconDisplayName)

            customIconURL = url
            customIconName = url.lastPathComponent
            lastError = nil
        } catch {
            lastError = L10n.text(.iconUseFailed, [error.localizedDescription])
        }
    }

    /// Removes the custom icon and restores the app default. The bundle itself is
    /// never modified — only the runtime icon override is dropped.
    func resetToDefault() {
        NSApplication.shared.applicationIconImage = defaultIcon
        customIconURL = nil
        customIconName = nil
        lastError = nil
        clearStoredSelection()
    }

    /// Preview image for the settings pane.
    var previewImage: NSImage? {
        guard let url = customIconURL else { return defaultIcon }
        return try? Self.loadImage(at: url)
    }

    // MARK: - Persistence

    private func restoreStoredSelection() {
        guard let bookmark = Self.defaults.data(forKey: DefaultsKey.iconBookmarkData) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            clearStoredSelection()
            return
        }
        // A stale bookmark still resolves; re-saving it keeps the reference alive
        // across moves of the original file.
        if isStale,
           let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            Self.defaults.set(refreshed, forKey: DefaultsKey.iconBookmarkData)
        }
        customIconURL = url
        customIconName = Self.defaults.string(forKey: DefaultsKey.iconDisplayName) ?? url.lastPathComponent
    }

    private func clearStoredSelection() {
        Self.defaults.removeObject(forKey: DefaultsKey.iconBookmarkData)
        Self.defaults.removeObject(forKey: DefaultsKey.iconDisplayName)
    }

    // MARK: - Loading

    /// Reads an image file, optionally resolving a security-scoped bookmark.
    private static func loadImage(at url: URL) throws -> NSImage {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let image = NSImage(contentsOf: url) else {
            throw IconError.unreadable
        }
        return image
    }

    /// Loads `AppIcon.icns` / `AppIcon.png` from the bundle, if bundled.
    private static func loadDefaultIcon() -> NSImage? {
        for candidate in ["icns", "png"] {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: candidate),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    enum IconError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: L10n.text(.iconUnreadable)
            }
        }
    }
}

/// File types offered by the icon picker.
enum IconFileTypes {
    static let allowed: [UTType] = [.icns, .png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
}
