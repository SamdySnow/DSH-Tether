import SwiftUI

/// The desktop window that shows the background service's terminal output.
struct ConsoleView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ConsoleToolbar()
            Divider()
            ConsoleTranscript()
        }
        .navigationTitle(model.string(.appName))
        // No status badge in the title bar: the toolbar strip below already shows
        // the same badge plus the controls, so a second copy only added noise.
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: model.string(.searchConsolePrompt)
        )
        .confirmationDialog(
            model.string(.nodeMissingTitle),
            isPresented: $model.isNodeInstallPromptPresented,
            titleVisibility: .visible
        ) {
            Button(model.string(.nodeInstallAction)) {
                Task { await model.installNode() }
            }
            Button(model.string(.nodeInstallFromWebsite)) {
                model.openNodeWebsite()
            }
            Button(model.string(.notNow), role: .cancel) {}
        } message: {
            Text(model.string(.nodeMissingMessage))
        }
        .alert(item: $model.nodeSetupAlert) { alert in
            switch alert {
            case .homebrewMissing:
                Alert(
                    title: Text(model.string(.homebrewMissingTitle)),
                    message: Text(model.string(.homebrewMissingMessage)),
                    dismissButton: .default(Text(model.string(.openHomebrewWebsite))) {
                        model.openHomebrewWebsite()
                    }
                )
            case .installed:
                Alert(
                    title: Text(model.string(.nodeInstalledTitle)),
                    message: Text(model.string(.nodeInstalledMessage)),
                    dismissButton: .default(Text(model.string(.ok)))
                )
            case .installFailed(let details):
                Alert(
                    title: Text(model.string(.nodeInstallFailedTitle)),
                    message: Text(model.string(.nodeInstallFailedMessage, details)),
                    dismissButton: .default(Text(model.string(.ok)))
                )
            }
        }
    }
}

/// Header strip with the service controls and live state.
private struct ConsoleToolbar: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ServiceStatusBadge(status: model.status)
                .controlSize(.large)

            // A cold start resolves a 300+ package tree before the server exists.
            // Showing elapsed time makes a long wait legible instead of looking
            // like a hang.
            if let elapsed = model.elapsedWhileStarting {
                Text(Self.format(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(model.string(.elapsedHelp))
            }

            if let pid = model.processIdentifier, model.status.isRunning {
                Text(model.string(.pidFormat, String(pid)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(model.string(.pidHelp))
            }

            Spacer()

            if model.isNodeInstalling {
                ProgressView()
                    .controlSize(.small)
                Text(model.string(.nodeInstalling))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PortStepperField(settings: model.settings) {
                Task { await model.applyPortAndRestartIfRunning() }
            }

            Divider().frame(height: 18)

            ServiceControlButtons()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Renders an elapsed duration as `m:ss` (or `h:mm:ss` past an hour).
    private static func format(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Start / restart / stop / open controls.
private struct ServiceControlButtons: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.start() }
            } label: {
                Label(model.string(.actionStart), systemImage: "play.fill")
            }
            .disabled(model.status.isRunning || model.status.isBusy)
            .help(model.string(.actionStartHelp))

            Button {
                Task { await model.restart() }
            } label: {
                Label(model.string(.actionRestart), systemImage: "arrow.clockwise")
            }
            .disabled(!model.status.isRunning && !model.status.isBusy)
            .help(model.string(.actionRestartHelp))

            Button {
                Task { await model.stop() }
            } label: {
                Label(model.string(.actionStop), systemImage: "stop.fill")
            }
            .disabled(!model.status.isRunning && !model.status.isBusy)
            .help(model.string(.actionStopHelp))

            Divider().frame(height: 18)

            Button {
                model.openInBrowser()
            } label: {
                Label(model.string(.actionOpen), systemImage: "safari")
            }
            .disabled(model.runningPort == nil)
            .help(model.serviceURLString)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
    }
}

/// Scrollable, colour-rendered transcript.
private struct ConsoleTranscript: View {

    @Environment(AppModel.self) private var model

    /// `nil` while the view is not scrolled to the bottom.
    @State private var isPinnedToBottom = true

    private var scrollerID: String { "console.bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.visibleEntries) { entry in
                        ConsoleLine(entry: entry)
                    }
                    // Zero-height sentinel used to detect whether the user is at
                    // the bottom.
                    Color.clear
                        .frame(height: 1)
                        .id(scrollerID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .background(ConsoleTheme.background)
            .onChange(of: model.visibleEntries.count) {
                guard isPinnedToBottom else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(scrollerID, anchor: .bottom)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Distance from the bottom of the content to the bottom of the
                // viewport; a small threshold keeps the pin from flickering.
                let distanceFromBottom =
                    geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                return distanceFromBottom < 48
            } action: { _, pinned in
                // Only an explicit user scroll should unpin, and re-pinning is the
                // only way to resume following.
                if pinned != isPinnedToBottom {
                    isPinnedToBottom = pinned
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    FollowOutputButton {
                        isPinnedToBottom = true
                        withAnimation(.linear(duration: 0.12)) {
                            proxy.scrollTo(scrollerID, anchor: .bottom)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

/// One transcript line, rendered from its pre-computed styled form.
private struct ConsoleLine: View {

    let entry: LogEntry

    var body: some View {
        Text(entry.styled)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 0.5)
            .padding(.horizontal, 4)
            .background(entry.stream == .standardError ? ConsoleTheme.error.opacity(0.07) : .clear)
            .overlay(alignment: .leading) {
                // A hairline gutter distinguishes stderr and app notices without
                // tinting the text itself.
                if entry.stream != .standardOutput {
                    Rectangle()
                        .fill(entry.stream == .standardError
                              ? ConsoleTheme.error.opacity(0.55)
                              : ConsoleTheme.info.opacity(0.55))
                        .frame(width: 2)
                }
            }
    }
}

/// Floating affordance to resume auto-scrolling.
private struct FollowOutputButton: View {

    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(model.string(.followOutput), systemImage: "arrow.down.to.line")
                .font(.callout)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(.capsule)
        .shadow(radius: 6, y: 2)
        .help(model.string(.followOutputHelp))
    }
}

/// Compact status pill with a coloured indicator.
struct ServiceStatusBadge: View {

    @Environment(AppModel.self) private var model
    let status: ServiceStatus

    var body: some View {
        HStack(spacing: 7) {
            // A pulsing dot while busy makes "starting" obviously in-progress.
            if status.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.symbolName)
                    .foregroundStyle(tint)
                    .imageScale(.small)
            }
            Text(status.label(for: model.language))
                .font(.callout.weight(.medium))
                .foregroundStyle(status.isRunning ? tint : .primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .help(tooltip)
        .animation(.default, value: status)
    }

    private var tint: Color {
        switch status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var tooltip: String {
        switch status {
        case .running(let port): model.string(.statusRunningTooltip, String(port))
        case .starting: model.string(.statusStartingTooltip)
        case .stopping: model.string(.statusStoppingTooltip)
        // A failed status carries an already-localized reason from the service.
        case .failed(let reason): reason
        case .idle: model.string(.statusStoppedTooltip)
        }
    }
}

/// Port entry that is always visible in the toolbar.
///
/// Clicking the target icon asks the system for a free port instead of guessing,
/// which is the common case when the configured port is occupied.
struct PortStepperField: View {

    @Bindable var settings: SettingsStore
    /// Called after a committed change so the caller can restart the service.
    var onCommit: () -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .imageScale(.small)

            TextField("Port", text: $draft)
                .frame(width: 62)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }

            // Stepper needs a numeric binding; the text field keeps the raw
            // draft so an in-progress edit is not clobbered mid-typing.
            Stepper("Port", value: portBinding, step: 1)
                .labelsHidden()

            Button {
                suggestFreePort()
            } label: {
                Image(systemName: "wand.and.sparkles")
            }
            .buttonStyle(.borderless)
            // This view is driven by `settings` rather than the model, and
            // `settings.language` is observable, so reading it here still
            // re-renders on a language change.
            .help(L10n.text(.pickFreePortAutomaticallyHelp, settings.language))
        }
        .onAppear { draft = String(settings.port) }
        .onChange(of: settings.port) { _, newValue in
            if !isFocused { draft = String(newValue) }
        }
    }

    /// Numeric view of the draft, used by the stepper.
    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(draft) ?? settings.port },
            set: { newValue in
                draft = String(newValue)
                commit()
            }
        )
    }

    /// Validates and applies the draft, then notifies the caller.
    private func commit() {
        guard let parsed = Int(draft), SettingsStore.portRange.contains(parsed) else {
            // Reject silently by snapping back to the stored value.
            draft = String(settings.port)
            return
        }
        guard parsed != settings.port else { return }
        settings.port = parsed
        draft = String(settings.port)
        onCommit()
    }

    private func suggestFreePort() {
        guard let free = PortProbe.firstAvailable(atOrAfter: settings.port + 1) else { return }
        draft = String(free)
        settings.port = free
        onCommit()
    }
}
