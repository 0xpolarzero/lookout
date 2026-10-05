import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @Bindable var store: Store
    @State private var token = ""
    @State private var botInput = ""
    @State private var typesafeKey = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                account
                notifications
                bots
                extensions
                shortcuts
                updates
                general
            }
            .padding(12)
        }
        .scrollIndicators(.never)
    }

    // MARK: Sections

    private var account: some View {
        section("GitHub") {
            HStack(spacing: 10) {
                Avatar(url: store.me?.avatarUrl, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.me.map { "@\($0.login)" } ?? "Not connected").font(.system(size: 13, weight: .semibold))
                    Text(store.tokenSource.map { "Token from \($0.rawValue)" } ?? (store.authError ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(store.authError == nil ? Theme.tertiary : Theme.red)
                        .lineLimit(2)
                }
                Spacer()
                if store.tokenSource == .keychain {
                    Button("Use gh CLI") { store.setToken(nil) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                SecureField("Paste a personal access token (optional)", text: $token).fieldStyle()
                Button("Save") {
                    store.setToken(token)
                    token = ""
                }
                .controlSize(.small)
                .disabled(token.isEmpty)
            }
            hint("Uses `gh auth token` by default. A pasted token is kept in the Keychain and needs `repo` scope for private repos.")
        }
    }

    private var notifications: some View {
        section("Notifications") {
            toggle("Desktop notifications", isOn: $store.settings.notifications)
            toggle("Review requests from any repo", isOn: $store.settings.reviewRequests)
            HStack {
                Text("Snooze").font(.system(size: 12.5))
                Spacer()
                if store.isSnoozed, let until = store.settings.snoozeUntil {
                    Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(Theme.purple)
                    Button("Resume") { store.snooze(for: nil) }.controlSize(.small)
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
    }

    private var bots: some View {
        section("Bots") {
            toggle("Treat GitHub Apps (…[bot]) as bots", isOn: $store.settings.treatAppsAsBots)
            HStack(spacing: 6) {
                TextField("Add a handle, e.g. vercel", text: $botInput)
                    .fieldStyle()
                    .onSubmit(addBot)
                Button("Add", action: addBot).controlSize(.small).disabled(botInput.isEmpty)
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
                        Text(action.title).font(.system(size: 12.5))
                        if action.isGlobal {
                            Text("Works from any app").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                            if (store.shortcut(action).isModifierTap || store.shortcut(action).mouseButton != nil) && !AXIsProcessTrusted() {
                                Text("Needs Accessibility access (System Settings › Privacy & Security)")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                            }
                        }
                    }
                    Spacer()
                    ShortcutRecorder(action: action, store: store)
                }
            }
            hint("Click a shortcut, then press the new keys (Esc cancels). App-wide ones also accept a single modifier tapped alone, like right ⌘. In the inbox, ↑↓ or hovering picks the row they act on.")
        }
    }

    private var extensions: some View {
        section("Extensions") {
            let installed = Claude.isInstalled
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "asterisk").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.claude)
                        Text("Claude sessions").font(.system(size: 12.5))
                    }
                    Text("Extension for the Claude desktop app")
                        .font(.system(size: 10.5))
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
                Divider().opacity(0.4)
                sessionIcons
                Divider().opacity(0.4)
                hint("Your Claude Code sessions on the bar: what's working, done or waiting for you. "
                     + "Sessions with new activity arrive as pending; keep the ones you use. Read-only: Lookout never writes to the app.")
            } else {
                hint("Your Claude Code sessions on the bar, to see which agents are done or waiting and jump between them.")
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
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Remove") { store.setTypesafeKey(nil) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("Paste a TypeSafe API key", text: $typesafeKey).fieldStyle()
                    Button("Save") {
                        store.setTypesafeKey(typesafeKey)
                        typesafeKey = ""
                    }
                    .controlSize(.small)
                    .disabled(typesafeKey.isEmpty)
                }
            }
            if let error = store.iconError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber)
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
            Text("Muted folders").font(.system(size: 12.5))
            Spacer()
            Menu(muted.isEmpty ? "None" : "\(muted.count) folder\(muted.count == 1 ? "" : "s")") {
                ForEach(unmuted, id: \.self) { folder in
                    Button(folderName(folder)) { store.setFolderMuted(folder, true) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Muted folders")
            .accessibilityValue(muted.isEmpty ? "None" : "\(muted.count) folder\(muted.count == 1 ? "" : "s")")
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
                    Text("Lookout \(updater.current)").font(.system(size: 12.5))
                    Ticking(coarse: true) { now in
                        Text(updateStatus(now)).font(.system(size: 11)).foregroundStyle(updateStatusColor)
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
            Button(updater.phase == .available ? "Download & install" : "Try again") { updater.advance() }.controlSize(.small)
        case .ready:
            Button("Restart to update") { updater.install() }.controlSize(.small)
        case .downloading, .installing:
            EmptyView()
        case .idle:
            Button(updater.checking ? "Checking…" : "Check now") {
                store.settings.skippedVersion = nil
                Task { await updater.check(manual: true) }
            }
            .controlSize(.small)
            .disabled(updater.checking)
        }
    }

    private func updateStatus(_ now: Date) -> String {
        let updater = store.updater
        guard updater.isRelease else { return "Development build: updates come from git" }
        let version = updater.release?.version ?? ""
        switch updater.phase {
        case .available: return "Version \(version) is available"
        case .downloading(let fraction): return "Downloading \(version)… \(Int(fraction * 100))%"
        case .ready: return "Version \(version) is ready to install"
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle:
            if let error = updater.checkError { return error }
            guard let last = updater.lastCheck else { return "Not checked yet" }
            return "Up to date · checked \(checkedPhrase(last, now: now))"
        }
    }

    private func checkedPhrase(_ date: Date, now: Date) -> String {
        let ago = shortAgo(date, now: now)
        if ago == "now" { return "just now" }
        return now.timeIntervalSince(date) < 7 * 86400 ? "\(ago) ago" : "on \(ago)"
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
                Text("Check every").font(.system(size: 12.5))
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
            if let launchError { Text(launchError).font(.system(size: 11)).foregroundStyle(Theme.red) }
            toggle("Keep the bar centered on its edge", isOn: Binding(
                get: { store.settings.centerPill ?? false },
                set: { store.settings.centerPill = $0 }
            ))
            HStack {
                hint(store.settings.centerPill == true
                     ? "Drag the bar to any screen edge; it stays at the middle."
                     : "Drag the bar to any screen edge.")
                Spacer()
                Button("Quit Lookout") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }

    // MARK: Helpers

    private func addBot() {
        store.addBot(botInput)
        botInput = ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Label on the left, switch on the trailing edge: the same in every section.
    private func toggle(_ label: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: detail == nil ? .center : .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12.5))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
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
            .font(.system(size: 11))
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
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .accessibilityLabel(removeLabel)
            .tip(removeLabel)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .modifier(OptionalTip(title: tip))
    }
}

private struct OptionalTip: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.tip(title) } else { content }
    }
}
