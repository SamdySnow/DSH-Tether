import AppKit
import Observation
import SwiftUI

/// A launch target shown in the Presets window.
struct LaunchPreset: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Open the DSH web UI in the default browser.
        case openWebUI
        /// Reveal the DSH workspace folder in Finder.
        case revealWorkspace
        /// Reveal the app's DSH home directory.
        case revealHome
        /// Copy the service URL.
        case copyServiceURL
        /// Restart the service.
        case restartService
    }

    let kind: Kind
    var id: Kind { kind }

    /// Localization key for the preset's title.
    var titleKey: Loc {
        switch kind {
        case .openWebUI: .presetOpenWebUI
        case .revealWorkspace: .presetRevealWorkspace
        case .revealHome: .presetRevealDshHome
        case .copyServiceURL: .presetCopyServiceURL
        case .restartService: .presetRestartService
        }
    }

    var systemImage: String {
        switch kind {
        case .openWebUI: "safari"
        case .revealWorkspace: "folder"
        case .revealHome: "house"
        case .copyServiceURL: "doc.on.doc"
        case .restartService: "arrow.clockwise"
        }
    }

    /// Whether the preset can run right now.
    ///
    /// A method rather than a stored closure: the answer depends on main-actor
    /// state on `AppModel`, which a `nonisolated` closure property could not read.
    @MainActor
    func isEnabled(in model: AppModel) -> Bool {
        switch kind {
        // These only make sense once the server is up.
        case .openWebUI, .copyServiceURL: model.runningPort != nil
        case .restartService: model.status.isRunning
        case .revealWorkspace, .revealHome: true
        }
    }

    /// Every preset, in the default order used before the user rearranges them.
    static let all: [LaunchPreset] = [
        LaunchPreset(kind: .openWebUI),
        LaunchPreset(kind: .copyServiceURL),
        LaunchPreset(kind: .revealWorkspace),
        LaunchPreset(kind: .revealHome),
        LaunchPreset(kind: .restartService),
    ]

    static let defaultOrder = all.map(\.kind.rawValue).joined(separator: ",")
}

/// Persisted, user-arrangeable order of `LaunchPreset` items.
@MainActor
@Observable
final class PresetStore {

    private static let orderKey = "dsh.presetOrder"

    private var storedOrder: String

    var order: [LaunchPreset] {
        get { Self.decode(storedOrder) }
        set {
            storedOrder = newValue.map(\.kind.rawValue).joined(separator: ",")
            UserDefaults.standard.set(storedOrder, forKey: Self.orderKey)
        }
    }

    init() {
        storedOrder = UserDefaults.standard.string(forKey: Self.orderKey) ?? LaunchPreset.defaultOrder
    }

    /// Rebuilds the list from stored ids, dropping unknown entries and appending
    /// any preset that is missing so new presets still show up.
    private static func decode(_ storage: String) -> [LaunchPreset] {
        let known = Dictionary(uniqueKeysWithValues: LaunchPreset.all.map { ($0.kind.rawValue, $0) })
        var seen = Set<String>()
        var result: [LaunchPreset] = []

        for raw in storage.split(separator: ",") {
            let key = String(raw)
            guard let preset = known[key], seen.insert(key).inserted else { continue }
            result.append(preset)
        }
        for preset in LaunchPreset.all where seen.insert(preset.kind.rawValue).inserted {
            result.append(preset)
        }
        return result
    }

    func resetOrder() {
        order = LaunchPreset.all
    }
}

/// Presets window, demonstrating a genuinely reorderable surface.
///
/// This is where macOS 27's `reorderContainer` is used: a real drag-and-drop
/// list. Availability is checked at runtime (rather than annotated) so the same
/// view degrades to a non-reorderable list on older systems instead of failing
/// to load.
struct PresetsView: View {

    @Environment(AppModel.self) private var model
    @State private var store = PresetStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            presetList
        }
        .frame(minWidth: 420, minHeight: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.string(.launchPresetsTitle))
                    .font(.headline)
                Text(reorderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.string(.resetOrder)) { store.resetOrder() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var reorderHint: String {
        if #available(macOS 27.0, *) {
            model.string(.reorderHint)
        } else {
            model.string(.reorderHintUnavailable)
        }
    }

    @ViewBuilder
    private var presetList: some View {
        if #available(macOS 27.0, *) {
            reorderableList
        } else {
            plainList
        }
    }

    /// macOS 27 path: drag-and-drop reordering via `reorderContainer`.
    @available(macOS 27.0, *)
    private var reorderableList: some View {
        List {
            ForEach(store.order) { preset in
                PresetRow(preset: preset)
            }
        }
        .listStyle(.inset)
        // The closure hands us the drag difference; folding it into `store.order`
        // persists the new arrangement.
        .reorderContainer(for: LaunchPreset.self) { difference in
            apply(difference)
        }
    }

    private var plainList: some View {
        List {
            ForEach(store.order) { preset in
                PresetRow(preset: preset)
            }
        }
        .listStyle(.inset)
    }

    /// Resolves a drag difference into a new ordering.
    ///
    /// `ReorderDifference` is available on macOS 27 only and is not `Sendable`, so
    /// it is consumed synchronously inside this annotation-gated function.
    @available(macOS 27.0, *)
    private func apply(
        _ difference: ReorderDifference<LaunchPreset.Kind, ReorderableSingleCollectionIdentifier>
    ) {
        let current = store.order
        let moving = Set(difference.sources)
        let moved = current.filter { moving.contains($0.id) }
        var remaining = current.filter { !moving.contains($0.id) }

        switch difference.destination.position {
        case .before(let anchor):
            if let index = remaining.firstIndex(where: { $0.id == anchor }) {
                remaining.insert(contentsOf: moved, at: index)
            } else {
                remaining.append(contentsOf: moved)
            }
        case .end:
            remaining.append(contentsOf: moved)
        }

        store.order = remaining
    }
}

/// One row in the presets list.
private struct PresetRow: View {

    @Environment(AppModel.self) private var model
    let preset: LaunchPreset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset.systemImage)
                .frame(width: 20)
                .foregroundStyle(.tint)

            Text(model.string(preset.titleKey))

            Spacer()

            Button(model.string(.actionRun)) { perform() }
                .controlSize(.small)
                .disabled(!preset.isEnabled(in: model))
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        // Double-click is the keyboard-free way to run the focused row.
        .onTapGesture(count: 2) { perform() }
    }

    private func perform() {
        guard preset.isEnabled(in: model) else { return }
        switch preset.kind {
        case .openWebUI: model.openInBrowser()
        case .copyServiceURL: model.copyServiceURL()
        case .revealWorkspace: model.revealWorkspace()
        case .revealHome: model.revealDSHHome()
        case .restartService: Task { await model.restart() }
        }
    }
}
