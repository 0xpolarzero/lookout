import SwiftUI

struct SettingsView: View {
    @Bindable var store: Store
    @State private var token = ""
    @State private var botInput = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                account
                notifications
                bots
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
                    Text("until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(Theme.purple)
                    Button("Resume") { store.snooze(for: nil) }.controlSize(.small)
                } else {
                    Menu("Pause…") {
                        Button("30 minutes") { store.snooze(for: 1800) }
                        Button("1 hour") { store.snooze(for: 3600) }
                        Button("3 hours") { store.snooze(for: 3 * 3600) }
                        Button("Until tomorrow 9:00") { store.snoozeUntilTomorrow() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
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
                        HStack(spacing: 4) {
                            Text("@\(handle)")
                            Button { store.removeBot(handle) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.tertiary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                }
            }
            hint("Bot comments still arrive, but silently and in their own Bots tab.")
        }
    }

    private var general: some View {
        section("General") {
            HStack {
                Text("Check every").font(.system(size: 12.5))
                Spacer()
                Picker("", selection: $store.settings.pollInterval) {
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
            HStack {
                Text("Toggle panel").font(.system(size: 12.5))
                Spacer()
                Text("⌃ ⌥ Space")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
            }
            HStack {
                hint("Drag the handle on top of the pill to move it to either edge.")
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

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 12.5))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func hint(_ text: String) -> some View {
        Text(.init(text))
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
