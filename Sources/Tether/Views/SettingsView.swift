import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sections of the Settings window.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, icon, diagnostics

    var id: String { rawValue }

    /// Localization key for the pane's title. Resolved by the view so the label
    /// follows the selected language.
    var titleKey: Loc {
        switch self {
        case .general: .paneGeneral
        case .icon: .paneIcon
        case .diagnostics: .paneDiagnostics
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .icon: "app.dashed"
        case .diagnostics: "stethoscope"
        }
    }
}

/// Settings window (⌘,) with general options, appearance and icon control.
///
/// The panes read `AppModel` from the environment, which the `Settings` scene
/// injects once for the whole window.
struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane = .general

    var body: some View {
        VStack(spacing: 0) {
            paneSelector
            Divider()
            activePane
        }
        .frame(width: 580, height: 500)
    }

    /// macOS 27's `TabsPickerStyle`, used as a section switcher.
    ///
    /// `PickerStyle.tabs` is available on macOS 27.0 only, so older systems fall
    /// back to a segmented control.
    @ViewBuilder
    private var paneSelector: some View {
        if #available(macOS 27.0, *) {
            picker.pickerStyle(.tabs)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker(model.string(.paneGeneral), selection: $pane) {
            ForEach(SettingsPane.allCases) { candidate in
                Label(model.string(candidate.titleKey), systemImage: candidate.systemImage)
                    .tag(candidate)
            }
        }
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var activePane: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .icon: IconSettingsPane()
        case .diagnostics: DiagnosticsSettingsPane()
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {

    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section(model.string(.sectionLanguage)) {
                Picker(model.string(.sectionLanguage), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        // Language names are shown in their own script, which is the
                        // convention for language pickers.
                        Text(language.endonym).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Text(model.string(.languageNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(model.string(.sectionService)) {
                LabeledContent(model.string(.port)) {
                    HStack(spacing: 8) {
                        TextField(model.string(.port), value: $settings.port, format: .number.grouping(.never))
                            .frame(width: 84)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())

                        Button(model.string(.pickFreePort)) {
                            if let free = PortProbe.firstAvailable(atOrAfter: settings.port + 1) {
                                settings.port = free
                            }
                        }
                    }
                }

                Text(model.string(
                    .portRangeNote,
                    String(SettingsStore.portRange.lowerBound),
                    String(SettingsStore.portRange.upperBound)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(model.string(.toggleStartOnLaunch), isOn: $settings.automaticallyStartsService)

                Button(model.string(.applyPortAndRestart)) {
                    Task { await model.applyPortAndRestartIfRunning() }
                }
                .disabled(!model.status.isRunning && !model.status.isBusy)

                Text(model.string(.servesAt, model.serviceURLString))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section(model.string(.sectionPackage)) {
                TextField(model.string(.npmSpecifier), text: $settings.packageSpecifier)
                    .font(.body.monospaced())

                HStack {
                    Text(model.string(.inUse, settings.effectivePackageSpecifier))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.string(.useDefault)) {
                        settings.resetPackageSpecifier()
                    }
                    .disabled(settings.isUsingDefaultPackageSpecifier)
                }

                Text(model.string(.packageNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(model.string(.sectionStartup)) {
                Toggle(
                    model.string(.launchAtLogin),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .disabled(!launchAtLogin.isSupported)

                Text(launchAtLogin.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = launchAtLogin.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

// MARK: - Icon

private struct IconSettingsPane: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    IconPreview(image: model.icons.previewImage)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.icons.customIconName ?? model.string(.defaultApplicationIcon))
                            .font(.headline)

                        Text(model.icons.isUsingCustomIcon
                             ? model.string(.iconCustomInUse)
                             : model.string(.iconChoosePrompt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(model.string(.chooseImage)) { chooseIcon() }
                                .buttonStyle(.borderedProminent)

                            Button(model.string(.useDefault)) { model.icons.resetToDefault() }
                                .disabled(!model.icons.isUsingCustomIcon)
                        }
                    }
                }
            }

            Section(model.string(.sectionNotes)) {
                // Being explicit here avoids a "why did my icon not change" report.
                Text(model.string(.iconNoteSignature))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(model.string(.iconNoteFormats))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.icons.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = model.string(.chooseImage)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = IconFileTypes.allowed

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.icons.setCustomIcon(from: url)
    }
}

/// Rounded, shadowed icon preview that mirrors how macOS draws app icons.
private struct IconPreview: View {

    let image: NSImage?

    private let size: CGFloat = 128

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(28)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: size * 0.22))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsPane: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section(model.string(.sectionRuntime)) {
                LabeledContent(model.string(.labelStatus)) {
                    ServiceStatusBadge(status: model.status)
                }
                LabeledContent(model.string(.labelServiceURL)) {
                    Text(model.serviceURLString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent(model.string(.labelProcess)) {
                    Text(model.processIdentifier.map { String($0) } ?? model.string(.placeholderValue))
                        .font(.body.monospacedDigit())
                }
                LabeledContent(model.string(.labelNodeRuntime)) {
                    Text(ExecutionTargetResolver.resolve()?.summary ?? model.string(.notFound))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section(model.string(.sectionFiles)) {
                Button(model.string(.openDshWorkspace)) { model.revealWorkspace() }
                Button(model.string(.revealLogFile)) { model.revealLogFile() }
                    .disabled(model.logFileURL == nil)
                Button(model.string(.exportConsoleLog)) { model.exportTranscript() }
            }

            Section {
                Text(model.string(.diagnosticsNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
