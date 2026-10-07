import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @Bindable var store: Store
    let hub: HubState
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var token = ""
    @State private var botInput = ""
    @State private var typesafeKey = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var restoreError: String?
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var notificationsBlocked = false

    static let updatesID = "updates"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    account
                    notifications
                    bots
                    extensions
                    shortcuts
                    updates.id(Self.updatesID)
                    general
                }
                .padding(Theme.Space.lg)
            }
            .scrollIndicators(.never)
            // Check for Updates asked for its section: the page was just opened, or was open and scrolled elsewhere.
            .onAppear { Task { scroll(proxy, animated: false) } }
            .onChange(of: hub.settingsScroll) { scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = hub.settingsScroll?.id else { return }
        hub.settingsScroll = nil
        if animated { withAnimation(Theme.Motion.hover.resolved(reduce: reduce)) { proxy.scrollTo(id, anchor: .top) } }
        else { proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: Sections

    private var account: some View {
        section("GitHub") {
            HStack(spacing: 10) {
                Avatar(url: store.me?.avatarUrl, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.me.map { "@\($0.login)" } ?? "Not connected").font(Theme.Typography.title)
                    Text(store.unreachable ? "Couldn't reach GitHub" : store.tokenSource.map { "Token from \($0.rawValue)" } ?? (store.authError ?? ""))
                        .font(Theme.Typography.meta)
                        .foregroundStyle(store.unreachable ? Theme.amber : store.authError == nil ? Theme.tertiary : Theme.red)
                        .lineLimit(2)
                }
                Spacer()
                if store.authError != nil {
                    ActionButton("Retry") { store.refreshNow() }
                }
                if store.tokenSource == .keychain {
                    ActionButton("Use gh CLI") { store.setToken(nil) }
                }
            }
            HStack(spacing: 6) {
                SecureField("Paste a personal access token (optional)", text: $token).fieldStyle()
                    .onSubmit(saveToken)
                ActionButton("Save", height: Theme.Metrics.field, action: saveToken)
                    .disabled(token.isEmpty)
            }
            hint("Uses `gh auth token` by default. A pasted token is kept in the Keychain and needs `repo` scope for private repos.")
        }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        store.setToken(token)
        token = ""
    }

    private func saveTypesafeKey() {
        guard !typesafeKey.isEmpty else { return }
        store.setTypesafeKey(typesafeKey)
        typesafeKey = ""
    }

    private var notifications: some View {
        let blocked = store.settings.notifications && notificationsBlocked
        return section("Notifications") {
            toggle("Desktop notifications", isOn: $store.settings.notifications)
            if blocked {
                HStack(spacing: 8) {
                    Text("macOS is blocking Lookout's notifications. Allow them in System Settings › Notifications.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ActionButton("Open Settings") {
                        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            toggle("Review requests from any repo", isOn: $store.settings.reviewRequests)
            HStack {
                Text("Snooze").font(Theme.Typography.body)
                Spacer()
                if store.isSnoozed, let until = store.settings.snoozeUntil {
                    Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.control).foregroundStyle(Theme.purple)
                    ActionButton("Resume") { store.snooze(for: nil) }
                } else {
                    Menu("Off") {
                        Button("30 minutes") { store.snooze(for: 1800) }
                        Button("1 hour") { store.snooze(for: 3600) }
                        Button("3 hours") { store.snooze(for: 3 * 3600) }
                        Button("Until tomorrow 9:00") { store.snoozeUntilTomorrow() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Snooze")
                    .accessibilityValue("Off")
                }
            }
            hint("Snoozing silences banners; the inbox keeps filling up.")
        }
        // What the system says is read when Settings opens and when the app comes back from System Settings, where it changes.
        .task { notificationsBlocked = await Notifier.isBlocked() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationsBlocked = await Notifier.isBlocked() }
        }
        // The notice that appears is said, once.
        .onChange(of: blocked, initial: true) { _, now in
            if now { Announce.say("Notifications are blocked in System Settings") }
        }
    }

    private var bots: some View {
        section("Bots") {
            toggle("Treat GitHub Apps (…[bot]) as bots", isOn: $store.settings.treatAppsAsBots)
            HStack(spacing: 6) {
                TextField("Add a handle, e.g. vercel", text: $botInput)
                    .fieldStyle()
                    .onSubmit(addBot)
                ActionButton("Add", height: Theme.Metrics.field, action: addBot).disabled(botInput.isEmpty)
            }
            if !store.settings.botHandles.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(store.settings.botHandles, id: \.self) { handle in
                        RemovableTag(text: "@\(handle)", removeLabel: "Remove @\(handle)") { store.removeBot(handle) }
                    }
                }
            }
            hint("Bot comments still arrive, but silently and in their own Bots tab.")
        }
    }

    private var shortcuts: some View {
        section("Shortcuts") {
            ForEach(ShortcutAction.allCases.filter { !$0.isAgents || store.agents.enabled }) { action in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(Theme.Typography.body)
                        if action.isGlobal {
                            Text("Works from any app").font(Theme.Typography.caption).foregroundStyle(Theme.tertiary)
                            if (store.shortcut(action).isModifierTap || store.shortcut(action).mouseButton != nil) && !accessibilityTrusted {
                                Text("Needs Accessibility access (System Settings › Privacy & Security)")
                                    .font(Theme.Typography.caption).foregroundStyle(Theme.amber)
                            }
                        }
                    }
                    Spacer()
                    ShortcutRecorder(action: action, store: store)
                }
            }
            HStack(spacing: Theme.Space.md) {
                Spacer()
                if let restoreError {
                    Text(restoreError).font(Theme.Typography.caption).foregroundStyle(Theme.amber)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                ActionButton("Restore defaults") {
                    // Beside the button, and said at each attempt, a repeated one too.
                    restoreError = store.restoreDefaultShortcuts()?.message
                    if let restoreError { Announce.say(restoreError) }
                }
                .disabled(!store.hasCustomShortcuts)
            }
            .onChange(of: store.hasCustomShortcuts) { restoreError = nil }
            hint("Click a shortcut, then press the new keys (Esc cancels, Delete clears). App-wide ones also accept a single modifier tapped alone, like right ⌘. In the inbox, ↑↓ or hovering picks the row they act on.")
        }
        // Granted in System Settings, which Lookout comes back from.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private var extensions: some View {
        section("Extensions") {
            let installed = Claude.isInstalled
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "asterisk").font(Theme.Typography.glyph(10, .bold)).foregroundStyle(Theme.claude)
                        Text("Claude sessions").font(Theme.Typography.body)
                    }
                    Text("Extension for the Claude desktop app")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Toggle("Claude sessions", isOn: Binding(get: { store.agents.enabled }, set: { store.setAgentsEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!installed && !store.agents.enabled)
            }
            if !installed && !store.agents.enabled {
                hint("Needs the Claude desktop app, with Claude Code sessions.")
            } else if store.agents.enabled {
                mutedFolders
                Hairline()
                sessionIcons
                Hairline()
                hint("Your Claude Code sessions on the bar: what is working, done or waiting. "
                     + "Sessions with new activity arrive as pending; keep the ones you use. Read-only: Lookout never writes to the app.")
            } else {
                hint("Your Claude Code sessions on the bar, to see which are working, done or waiting, and jump between them.")
            }
        }
    }

    @ViewBuilder private var sessionIcons: some View {
        toggle("Icons picked for you", detail: "By Jev, from TypeSafe",
               isOn: Binding(get: { store.agents.iconsEnabled }, set: { store.setIconsEnabled($0) }))
        if store.agents.iconsEnabled {
            if store.hasTypesafeKey {
                HStack {
                    Label("TypeSafe API key saved in the Keychain", systemImage: "key.fill")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    ActionButton("Remove") { store.setTypesafeKey(nil) }
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("Paste a TypeSafe API key", text: $typesafeKey).fieldStyle()
                        .onSubmit(saveTypesafeKey)
                    ActionButton("Save", height: Theme.Metrics.field, action: saveTypesafeKey)
                        .disabled(typesafeKey.isEmpty)
                }
            }
            if let error = store.iconError {
                Text(error).font(Theme.Typography.meta).foregroundStyle(Theme.amber)
            }
            hint("Each session in your list gets an icon instead of letters. Its title, project name and first message go to "
                 + "TypeSafe (api.typesafe.ai), whose Jev model picks what kind of icon fits (code, debugging, data, people…), "
                 + "then one of that kind not already on screen, from \(SessionIcons.drawable.count) in all. Two small requests, "
                 + "about $0.0002 a session. Keys come from console.typesafe.ai.")
        }
    }

    @ViewBuilder private var mutedFolders: some View {
        let muted = store.agents.mutedFolders
        let unmuted = store.knownFolders.filter { !muted.contains($0) }
        HStack {
            Text("Muted folders").font(Theme.Typography.body)
            Spacer()
            Menu(muted.isEmpty ? "None" : plural(muted.count, "folder")) {
                ForEach(unmuted, id: \.self) { folder in
                    Button(folderName(folder)) { store.setFolderMuted(folder, true) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Muted folders")
            .accessibilityValue(muted.isEmpty ? "None" : plural(muted.count, "folder"))
            .disabled(unmuted.isEmpty)
        }
        if !muted.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(muted, id: \.self) { folder in
                    RemovableTag(text: folderName(folder), removeLabel: "Unmute \(folderName(folder))",
                                 tip: folder.isEmpty ? "Chats not tied to a folder" : folder) {
                        store.setFolderMuted(folder, false)
                    }
                }
            }
        }
    }

    private func folderName(_ folder: String) -> String {
        folder.isEmpty ? "Scratch chats" : URL(fileURLWithPath: folder).lastPathComponent
    }

    private var updates: some View {
        let updater = store.updater
        return section("Updates") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lookout \(updater.current)").font(Theme.Typography.body)
                    Ticking(coarse: true) { now in
                        Text(updateStatus(now)).font(Theme.Typography.meta).foregroundStyle(updateStatusColor)
                    }
                }
                Spacer()
                if updater.isRelease { updateButton }
            }
            if updater.isRelease {
                toggle("Check for updates automatically", isOn: Binding(
                    get: { store.settings.checkUpdates ?? true },
                    set: { store.settings.checkUpdates = $0 }
                ))
            }
        }
    }

    @ViewBuilder private var updateButton: some View {
        let updater = store.updater
        switch updater.phase {
        case .available, .failed:
            ActionButton(updater.phase == .available ? "Download & install" : "Try again") { updater.advance() }
        case .ready:
            ActionButton("Restart to update") { updater.install() }
        case .downloading, .installing:
            EmptyView()
        case .idle:
            ActionButton(updater.checking ? "Checking…" : "Check now") {
                store.settings.skippedVersion = nil
                Task { await updater.check(manual: true) }
            }
            .disabled(updater.checking)
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

    private var updateStatusColor: Color {
        switch store.updater.phase {
        case .failed: Theme.red
        case .available, .ready: Theme.green
        default: store.updater.checkError == nil ? Theme.tertiary : Theme.red
        }
    }

    private var general: some View {
        section("General") {
            HStack {
                Text("Check every").font(Theme.Typography.body)
                Spacer()
                Picker("Check every", selection: $store.settings.pollInterval) {
                    Text("30s").tag(30.0)
                    Text("1m").tag(60.0)
                    Text("2m").tag(120.0)
                    Text("5m").tag(300.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: store.settings.pollInterval) { store.restartPolling() }
            }
            toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = error.localizedDescription }
                }
            if let launchError { Text(launchError).font(Theme.Typography.meta).foregroundStyle(Theme.red) }
            toggle("Keep the bar centered on its edge", isOn: Binding(
                get: { store.settings.centerPill ?? false },
                set: { store.settings.centerPill = $0 }
            ))
            HStack {
                hint(store.settings.centerPill == true
                     ? "Drag the bar to any screen edge; it stays at the middle."
                     : "Drag the bar to any screen edge.")
                Spacer()
                ActionButton("Quit Lookout") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Helpers

    private func addBot() {
        store.addBot(botInput)
        botInput = ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Eyebrow(title)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Label on the left, switch on the trailing edge: the same in every section.
    private func toggle(_ label: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: detail == nil ? .center : .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Typography.body)
                if let detail { Text(detail).font(Theme.Typography.caption).foregroundStyle(Theme.tertiary) }
            }
            Spacer(minLength: 8)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(.init(text))
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A capsule with a label and a small remove button.
private struct RemovableTag: View {
    let text: String
    let removeLabel: String
    var tip: String? = nil
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: remove) {
                Image(systemName: "xmark").font(Theme.Typography.glyph(8, .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(HoverFillButtonStyle(shape: Circle()))
            .foregroundStyle(Theme.tertiary)
            .accessibilityLabel(removeLabel)
            .tip(removeLabel)
        }
        .font(Theme.Typography.control)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(Capsule().fill(Theme.Fill.hover))
        .modifier(OptionalTip(title: tip))
    }
}

private struct OptionalTip: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.tip(title) } else { content }
    }
}

/// A small bordered text button: reads as a button at rest, brightens on hover, fades only when disabled.
/// `height` matches the field it sits beside (`Theme.Metrics.field`) or a row's controls (`Theme.Metrics.chip`).
struct ActionButton: View {
    let title: String
    var height: CGFloat = Theme.Metrics.chip
    let action: () -> Void

    init(_ title: String, height: CGFloat = Theme.Metrics.chip, action: @escaping () -> Void) {
        self.title = title
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: height)
                .overlay(Theme.Radius.shape(Theme.Radius.md).strokeBorder(Theme.stroke))
        }
        .buttonStyle(HoverFillButtonStyle(rest: Theme.Fill.field, hover: Theme.Fill.selected, pressed: Theme.Fill.pressed))
    }
}
