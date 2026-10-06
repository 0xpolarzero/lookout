import SwiftUI
import ApplicationServices

/// The panes of Settings (DESIGN.md 5.8). Which one is open lives with whoever draws the page header: they pass a
/// binding to `SettingsView` and put `SettingsPaneTabs` in the header. Without one, `SettingsView` keeps the choice
/// itself and shows the tabs above the form.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications, shortcuts, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .claude: "Claude"
        }
    }
}

/// General | Notifications | Shortcuts | Claude, the selected one picked.
struct SettingsPaneTabs: View {
    @Binding var pane: SettingsPane

    var body: some View {
        Tabs(label: "Settings pane", tabs: SettingsPane.allCases.map { Tabs.Tab(id: $0, title: $0.title) }, selection: pane) { pane = $0 }
    }
}

/// What a screenshot asks of the Settings and Repositories pages, which have no other way to be put in a state a
/// pointer or the keyboard would: the pane, a revealed field, a repository's Custom open, text in the add field.
struct PagePreview: Equatable {
    var pane: SettingsPane?
    /// General: "Use a token…" already pressed.
    var revealsToken = false
    /// Shortcuts: whether Accessibility is granted, instead of asking the system.
    var accessibilityTrusted: Bool?
    /// General: the Launch at login row after the system refused, with its message.
    var launchError: String?
    /// Claude: whether the Claude app is installed, instead of looking for it.
    var claudeInstalled: Bool?
    /// Shortcuts: the action whose recorder is waiting for keys, and the error it shows (a conflict, say).
    var recording: ShortcutAction?
    var recorderError: String?
    /// Repositories: the repository whose Custom choices are open.
    var expandedRepo: String?
    /// Repositories: text typed in the add field, with its suggestions showing and the row `addHighlight` picked.
    var addQuery: String?
    var addHighlight: Int?
    /// Repositories: what the last Add said went wrong (the suggestions stay hidden while it shows).
    var addError: String?
    /// What that Add was for when it was not the text in the field (a suggestion that was picked).
    var addSubmitted: String?
    /// Repositories: the repository a drag is over, and the one whose Retry has the keyboard focus.
    var dropTarget: String?
    var retryFocused: String?
}

extension EnvironmentValues {
    @Entry var pagePreview = PagePreview()
}

/// Why Lookout isn't signed in to GitHub, as a sentence for the account row. `Store.authError` keeps what failed (a
/// missing token, or the system's or GitHub's own wording); that is for a tooltip and VoiceOver's value, and this is
/// what the row says, in the pane that has the token button next to it.
enum SignInFailure {
    /// What `Store.authenticate` sets when neither `gh` nor the Keychain has a token.
    static let missingToken = "No GitHub token found"

    static func sentence(_ reason: String) -> String {
        if reason == missingToken { return "Run gh auth login in Terminal, or use a token." }
        return switch RepoFailure(reason: reason) {
        case .badToken: "GitHub rejected your token."
        case .unreachable: "Couldn't reach GitHub."
        default: "Couldn't sign in to GitHub."
        }
    }
}

/// What the gear's badge is about, in the GitHub group: the fault, when the last check got through and a way to check
/// again. Nothing while syncing is healthy (a sign-in problem is the account row's own).
private struct SyncStatusRow: View {
    let store: Store

    var body: some View {
        Ticking(coarse: true) { now in
            if let fault = store.syncFault(stale: store.isStale(at: now), ciStale: store.isCIStale(at: now)), fault != .signIn {
                FormDivider()
                FormRow(label: fault.phrase, control: {
                    BorderedButton("Check now") { store.refreshNow() }.disabled(store.isSyncing)
                }, detail: {
                    Text(detail(fault))
                })
            }
        }
    }

    /// Which repositories, or why, then the last time anything got through.
    private func detail(_ fault: SyncFault) -> String {
        let reason = switch fault {
        case .partial: store.repoErrors.keys.sorted().joined(separator: ", ")
        case .reviewRequests: store.reviewRequestsError ?? ""
        case .reviewRequestsCut: "GitHub cut the search for them short"
        case .rateLimited: store.rateResetsAt.map { "Checking again at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
        case .ciStale: store.ciFreshness.map { "CI last checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        default: ""
        }
        let last = store.lastSync.map { "Last checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not checked yet"
        return [reason, last].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct SettingsView: View {
    @Bindable var store: Store
    /// The open pane, when the page header owns it.
    var pane: Binding<SettingsPane>? = nil
    /// Where the bar rests, for the controls that place it as dragging does.
    var ui: UIState? = nil
    /// The Repositories row.
    var openRepos: () -> Void = {}
    @Environment(\.pagePreview) private var preview
    @State private var ownPane = SettingsPane.general
    @State private var token = ""
    @State private var revealToken = false
    @State private var tokenError: String?
    @State private var botInput = ""
    @State private var typesafeKey = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @FocusState private var botFocused: Bool

    private var current: Binding<SettingsPane> { pane ?? $ownPane }

    var body: some View {
        VStack(spacing: 0) {
            if pane == nil {
                SettingsPaneTabs(pane: $ownPane)
                    .padding(.leading, Theme.Metrics.contentEdge - 10)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.pitch, alignment: .leading)
                Hairline()
            }
            ScrollView {
                Group {
                    switch current.wrappedValue {
                    case .general: general
                    case .notifications: notifications
                    case .shortcuts: shortcuts
                    case .claude: claude
                    }
                }
                .id(current.wrappedValue)
                .transition(.opacity)
                .padding(.horizontal, Theme.Metrics.inset)
                .padding(.vertical, Theme.Space.md)
            }
            // Muting a folder here offers its undo where it was done.
            if current.wrappedValue == .claude, let undo = store.undoStack.visible(in: .agents) {
                UndoLine(message: undo.message) { store.undoLast() }
                    .padding(.horizontal, Theme.Metrics.inset)
                    .padding(.bottom, Theme.Metrics.inset)
            }
        }
        .motion(Theme.Motion.fade, value: current.wrappedValue)
        .motion(Theme.Motion.fade, value: store.undoStack.visibleID)
        .onAppear {
            if let pane = preview.pane { ownPane = pane }
            revealToken = preview.revealsToken
            launchError = preview.launchError
        }
    }

    private func paneStack<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl + Theme.Space.xs) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The pane's title is the selected tab above; the heading VoiceOver's heading navigation finds is this one,
            // at the top of the pane, which draws nothing and takes no room.
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }

    // MARK: General

    private var general: some View {
        paneStack("General") {
            FormGroup(title: "GitHub") {
                account
                if revealToken {
                    FormDivider()
                    tokenField
                }
                SyncStatusRow(store: store)
                FormDivider()
                FormButtonRow(action: openRepos) {
                    HStack(spacing: Theme.Space.md) {
                        Text("Repositories").font(Theme.Typography.body).foregroundStyle(Theme.text)
                        Spacer(minLength: Theme.Space.md)
                        Text("Watching \(store.repos.count)").font(Theme.Typography.body).foregroundStyle(Theme.secondary)
                        Image(systemName: "chevron.right").font(Theme.Typography.glyph(11)).foregroundStyle(Theme.tertiary)
                    }
                }
                .accessibilityLabel("Repositories")
                .accessibilityValue("Watching \(store.repos.count)")
                FormDivider()
                checkEvery
            }
            FormGroup(title: "Lookout") {
                FormToggle(label: "Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let launchError {
                    FormDivider()
                    // The switch went back to what is, so what was wanted is the other way. The system's reason is for a
                    // tooltip and VoiceOver, not the line: it is not a sentence about this.
                    let wanted = !launchAtLogin
                    let title = "Couldn't turn \(wanted ? "on" : "off") Launch at login"
                    FormRow(title) {
                        BorderedButton("Try again") { setLaunchAtLogin(wanted) }
                    }
                    .help(launchError)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(title)
                    .accessibilityValue(launchError)
                }
            }
            if let ui { FormGroup(title: "Bar") { placement(ui) } }
            FormGroup(title: "Updates") { updates }
            FormGroup {
                FormButtonRow(action: { NSApp.terminate(nil) }) {
                    Text("Quit Lookout").font(Theme.Typography.body).foregroundStyle(Theme.text)
                }
            }
        }
    }

    @ViewBuilder private var account: some View {
        HStack(spacing: Theme.Space.lg) {
            if let me = store.me {
                Avatar(url: me.avatarUrl, size: 22, name: me.login)
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text("@\(me.login)").font(Theme.Typography.body).foregroundStyle(Theme.text)
                    Text(store.tokenSource.map { "Token from \($0.rawValue)" } ?? "").font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                }
            } else {
                Image(systemName: "exclamationmark.circle.fill").font(Theme.Typography.glyph(16, .regular)).foregroundStyle(Theme.red)
                    .frame(width: 22, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text("Not signed in").font(Theme.Typography.body).foregroundStyle(Theme.text)
                    if let error = store.authError {
                        let sentence = SignInFailure.sentence(error)
                        Text(verbatim: sentence).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // What failed, for whoever wants it: the missing token is the sentence already.
                            .help(error == SignInFailure.missingToken ? "" : error)
                            .accessibilityValue(error == SignInFailure.missingToken ? "" : error)
                    }
                }
            }
            Spacer(minLength: Theme.Space.md)
            if !revealToken {
                if store.tokenSource == .keychain { BorderedButton("Use gh CLI") { store.setToken(nil) } }
                BorderedButton("Use a token…") { revealToken = true }
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: Theme.Metrics.formRow)
        .accessibilityElement(children: .contain)
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SecretField(prompt: "Paste a personal access token", text: $token, autofocus: true, cancel: cancelToken, save: saveToken)
            Text("Return saves it in the Keychain, Esc cancels. Private repositories need the repo scope.")
                .font(Theme.Typography.meta).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            // A refusal keeps the field and what was typed; it is said where it shows.
            if let tokenError {
                Text(tokenError).font(Theme.Typography.meta).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.md)
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        guard store.setToken(token) else {
            let refusal = "Couldn't save the token in the Keychain"
            tokenError = refusal
            Announce.say(refusal)
            return
        }
        cancelToken()
    }

    private func cancelToken() {
        token = ""
        tokenError = nil
        revealToken = false
    }

    /// Where the bar rests, without dragging it (WCAG 2.5.7): its display, its edge, and where along the edge, which
    /// centring takes over.
    @ViewBuilder private func placement(_ ui: UIState) -> some View {
        let screens = DisplayChoice.connected
        let centred = store.settings.centerPill == true
        if screens.count > 1 {
            FormRow("Display") {
                PopUp(label: "Display", value: screens.first { $0.id == ui.display }?.title ?? "", room: screens.map(\.title)) {
                    Picker("Display", selection: Binding(get: { ui.display }, set: { ui.place(BarPlacement(display: $0)) })) {
                        ForEach(screens, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            FormDivider()
        }
        FormRow("Edge") {
            PopUp(label: "Edge", value: ui.edge.title, room: DockEdge.allCases.map(\.title)) {
                Picker("Edge", selection: Binding(get: { ui.edge }, set: { ui.place(BarPlacement(edge: $0)) })) {
                    ForEach(DockEdge.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        FormDivider()
        FormRow("Position", detail: centred ? "Centred, as set below" : nil) {
            let spots = EdgeSnap.spots(ui.edge)
            let nearest = spots.min { abs($0.position - ui.position) < abs($1.position - ui.position) }
            PopUp(label: "Position along the \(ui.edge.rawValue) edge", value: nearest?.title ?? "", room: spots.map(\.title)) {
                ForEach(spots, id: \.title) { spot in
                    Button(spot.title) { ui.place(BarPlacement(position: spot.position)) }
                }
            }
            .disabled(centred)
        }
        FormDivider()
        FormToggle(label: "Keep the bar centred", isOn: Binding(
            get: { store.settings.centerPill ?? false },
            set: { store.settings.centerPill = $0 }
        ))
    }

    private var checkEvery: some View {
        let seconds = store.settings.pollInterval
        return FormRow("Check every", detail: seconds < 60 ? "Checking more than once a minute uses more of GitHub's rate limit." : nil) {
            PopUp(label: "Check every", value: Self.intervalTitle(seconds)) {
                Picker("Check every", selection: $store.settings.pollInterval) {
                    ForEach(Self.intervals, id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .onChange(of: store.settings.pollInterval) { store.restartPolling() }
    }

    private static let intervals: [Double] = [30, 60, 120, 300]

    private static func intervalTitle(_ seconds: Double) -> String {
        switch seconds {
        case 30: "Every 30 seconds"
        case 60: "Every minute"
        case 120: "Every 2 minutes"
        case 300: "Every 5 minutes"
        default: "Every \(Int(seconds)) seconds"
        }
    }

    /// Off to on and back; a refusal puts the switch back and says so, with a way to try again.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchAtLogin = on
            launchError = nil
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchError = error.localizedDescription
            Announce.say("Couldn't turn \(on ? "on" : "off") Launch at login")
        }
    }

    // MARK: Updates

    @ViewBuilder private var updates: some View {
        let updater = store.updater
        FormRow(label: "Lookout \(updater.current)", control: { updateControl }, detail: {
            Ticking(coarse: true) { now in
                Text(updateStatus(now)).foregroundStyle(updateStatusColor)
            }
        })
        // A failure is said when it appears, as the other errors of a form are.
        .onChange(of: updateError) { _, now in if let now { Announce.say(now) } }
        if updater.isRelease {
            FormDivider()
            FormToggle(label: "Check for updates automatically", isOn: Binding(
                get: { store.settings.checkUpdates ?? true },
                set: { store.settings.checkUpdates = $0 }
            ))
        }
    }

    @ViewBuilder private var updateControl: some View {
        let updater = store.updater
        if updater.isRelease {
            switch updater.phase {
            case .available, .failed:
                BorderedButton(updater.phase == .available ? "Download and install" : "Try again") { updater.advance() }
            case .ready:
                BorderedButton("Restart to update") { updater.install() }
            case .downloading:
                DownloadBar(fraction: updater.fraction)
            case .installing:
                EmptyView()
            case .idle:
                BorderedButton(updater.checking ? "Checking…" : "Check now") {
                    store.settings.skippedVersion = nil
                    Task { await updater.check(manual: true) }
                }
                .disabled(updater.checking)
            }
        }
    }

    private func updateStatus(_ now: Date) -> String {
        let updater = store.updater
        guard updater.isRelease else { return "Development build: updates come from git" }
        let version = updater.release?.version ?? ""
        switch updater.phase {
        case .available: return "Version \(version) is available"
        case .downloading: return "Downloading \(version)… \(Int(updater.fraction * 100))%"
        case .ready: return "Version \(version) is ready to install"
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle:
            if let error = updater.checkError { return error }
            guard let last = updater.lastCheck else { return "Not checked yet" }
            return "Up to date · checked \(agoPhrase(last, now: now))"
        }
    }

    /// The failure the update row shows, if it shows one: a download that failed, or a check that did.
    private var updateError: String? {
        if case .failed(let message) = store.updater.phase { return message }
        return store.updater.phase == .idle ? store.updater.checkError : nil
    }

    private var updateStatusColor: AnyShapeStyle {
        switch store.updater.phase {
        case .failed: AnyShapeStyle(Theme.red)
        case .available, .ready: AnyShapeStyle(Theme.accentText)
        default: store.updater.checkError == nil ? AnyShapeStyle(Theme.secondary) : AnyShapeStyle(Theme.red)
        }
    }

    // MARK: Notifications

    private var notifications: some View {
        paneStack("Notifications") {
            FormGroup {
                FormToggle(label: "Desktop notifications", isOn: $store.settings.notifications)
                FormDivider()
                FormToggle(label: "Review requests", detail: "From any repository, watched or not", isOn: $store.settings.reviewRequests)
                FormDivider()
                snooze
            }
            FormGroup(title: "Bots") {
                FormToggle(label: "Treat GitHub Apps as bots", detail: "Their comments arrive silently, in the Bots tab",
                           isOn: $store.settings.treatAppsAsBots)
                FormDivider()
                bots
            }
        }
    }

    private var snooze: some View {
        FormRow("Snooze", detail: store.isSnoozed ? nil : "Silences banners; the inbox keeps filling up") {
            if store.isSnoozed, let until = store.settings.snoozeUntil {
                HStack(spacing: Theme.Space.md) {
                    Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.control).foregroundStyle(Theme.secondary)
                    BorderedButton("Resume") { store.snooze(for: nil) }
                }
            } else {
                PopUp(label: "Snooze", value: "Off") {
                    Button("30 minutes") { store.snooze(for: 1800) }
                    Button("1 hour") { store.snooze(for: 3600) }
                    Button("3 hours") { store.snooze(for: 3 * 3600) }
                    Button("Until tomorrow 9:00") { store.snoozeUntilTomorrow() }
                }
            }
        }
    }

    private var bots: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if !store.settings.botHandles.isEmpty {
                FlowLayout(spacing: Theme.Space.sm) {
                    ForEach(store.settings.botHandles, id: \.self) { handle in
                        RemovableTag(text: "@\(handle)", removeLabel: "Remove @\(handle)") { store.removeBot(handle) }
                    }
                }
            }
            HStack(spacing: Theme.Space.sm) {
                TextField("Add a handle, e.g. vercel", text: $botInput)
                    .fieldStyle(focused: botFocused)
                    .focused($botFocused)
                    .onSubmit(addBot)
                    .accessibilityLabel("Add a bot handle")
                if !botInput.isEmpty { BorderedButton("Add", action: addBot) }
            }
        }
        .padding(.vertical, Theme.Space.md)
    }

    private func addBot() {
        store.addBot(botInput)
        botInput = ""
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        let visible = ShortcutAction.allCases.filter { !$0.isAgents || store.agents.enabled }
        let anywhere = visible.filter(\.isGlobal)
        let needsAccess = anywhere.contains { store.shortcut($0).isModifierTap || store.shortcut($0).mouseButton != nil }
            && !(preview.accessibilityTrusted ?? AXIsProcessTrusted())
        return paneStack("Shortcuts") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                FormGroup(title: "Anywhere") { shortcutRows(anywhere) }
                Text("A single modifier tapped alone works too, like right ⌘, and so does a mouse button.")
                    .font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, Theme.Metrics.rowPadding).fixedSize(horizontal: false, vertical: true)
                if needsAccess {
                    StatusBanner(symbol: "exclamationmark.circle.fill", tint: AnyShapeStyle(Theme.amber),
                                 message: "Needs Accessibility access") {
                        BorderedButton("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            FormGroup(title: "In Lookout") { shortcutRows(visible.filter { !$0.isGlobal }) }
            HStack {
                Spacer()
                BorderedButton("Restore defaults") { store.restoreDefaultShortcuts() }
                    .disabled(!store.hasCustomShortcuts)
            }
            .padding(.horizontal, Theme.Metrics.rowPadding)
        }
        // The notice that appears is said, once.
        .onChange(of: needsAccess, initial: true) { _, now in if now { Announce.say("Needs Accessibility access") } }
    }

    private func shortcutRows(_ actions: [ShortcutAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            if index > 0 { FormDivider() }
            FormRow(action.title) { ShortcutRecorder(action: action, store: store) }
        }
    }

    // MARK: Claude

    private var claude: some View {
        let installed = preview.claudeInstalled ?? Claude.isInstalled
        let on = store.agents.enabled
        return paneStack("Claude") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // Without the Claude app the switch is off and unavailable, and the reason is the row's detail line.
                let blocked = !installed && !on
                Toggle(isOn: Binding(get: { on }, set: { store.setAgentsEnabled($0) })) {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "asterisk").font(Theme.Typography.glyph(14, .bold)).foregroundStyle(Theme.claude)
                            .frame(width: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Space.hair) {
                            Text("Claude sessions").font(Theme.Typography.title).foregroundStyle(Theme.text)
                            Text(blocked ? "Needs the Claude desktop app, with Claude Code sessions" : "Shows your Claude Code sessions on the bar")
                                .font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, Theme.Space.sm)
                    }
                }
                .toggleStyle(SwitchStyle())
                .disabled(blocked)
                .padding(.horizontal, Theme.Metrics.contentEdge)
                if on {
                    FormGroup {
                        mutedFolders
                        FormDivider()
                        sessionIcons
                    }
                    .padding(.leading, Theme.Metrics.rowPadding)
                }
            }
        }
    }

    @ViewBuilder private var mutedFolders: some View {
        let muted = store.agents.mutedFolders
        let unmuted = store.knownFolders.filter { !muted.contains($0) }
        FormRow("Muted folders") {
            PopUp(label: "Muted folders", value: muted.isEmpty ? "None" : plural(muted.count, "folder")) {
                Section("Mute a folder") {
                    ForEach(unmuted, id: \.self) { folder in
                        Button(folderName(folder)) { store.muteFolder(folder) }
                    }
                }
            }
            .disabled(unmuted.isEmpty)
        }
        if !muted.isEmpty {
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(muted, id: \.self) { folder in
                    RemovableTag(text: folderName(folder), removeLabel: "Unmute \(folderName(folder))",
                                 tip: folder.isEmpty ? "Chats not tied to a folder" : folder) {
                        store.setFolderMuted(folder, false)
                    }
                }
            }
            .padding(.bottom, Theme.Space.md)
        }
    }

    private func folderName(_ folder: String) -> String {
        folder.isEmpty ? "Scratch chats" : URL(fileURLWithPath: folder).lastPathComponent
    }

    @ViewBuilder private var sessionIcons: some View {
        FormToggle(label: "Icons picked for you", detail: "Sends session titles and first messages to typesafe.ai",
                   isOn: Binding(get: { store.agents.iconsEnabled }, set: { store.setIconsEnabled($0) }))
        if store.agents.iconsEnabled {
            if store.hasTypesafeKey {
                FormRow("TypeSafe key", detail: "Saved in the Keychain") {
                    BorderedButton("Remove") { store.setTypesafeKey(nil) }
                }
            } else {
                // Icons are on and can't pick without a key: setting it is the one thing left to do, so it says how it is saved.
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.sm) {
                        SecretField(prompt: "Paste a TypeSafe API key", text: $typesafeKey, save: saveTypesafeKey)
                        if !typesafeKey.isEmpty { BorderedButton("Save", action: saveTypesafeKey) }
                    }
                    Text("Icons need a key. Save it, or press Return: it is kept in the Keychain.")
                        .font(Theme.Typography.meta).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Theme.Space.md)
            }
            if let error = store.iconError {
                Text(error).font(Theme.Typography.meta).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, Theme.Space.md)
                    .onChange(of: error, initial: true) { _, now in Announce.say(now) }
            }
        }
    }

    /// Saved and said only once the Keychain has it; a refusal keeps what was typed (the error is announced where it shows).
    private func saveTypesafeKey() {
        let key = typesafeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, store.setTypesafeKey(key) else { return }
        typesafeKey = ""
        Announce.say("TypeSafe key saved")
    }
}

/// A determinate bar for the download, drawn here: the system's greys out while the panel is not the key window,
/// which is most of the time Settings is in view. Accent on the neutral tile fill.
private struct DownloadBar: View {
    let fraction: Double
    @Environment(\.resolved) private var resolved

    var body: some View {
        Capsule().fill(resolved.fill(Theme.Fill.tile))
            .frame(width: 96, height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Theme.accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
