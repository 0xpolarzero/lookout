import AppKit
import Carbon
import ServiceManagement
import UserNotifications

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click: the item id, and the page the notification is about (for when the item is gone).
    var onOpen: ((_ id: String, _ url: String?) -> Void)?
    /// Tests: every post and withdrawal, whether or not the system would show it.
    var onPost: ((String) -> Void)?
    var onRemove: (([String]) -> Void)?
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(id: String, title: String, subtitle: String, body: String, quiet: Bool, url: URL? = nil) {
        onPost?(id)
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.userInfo = ["id": id, "url": url?.absoluteString ?? ""]
        content.threadIdentifier = quiet ? "bots" : "main"
        if quiet {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: id.isEmpty ? UUID().uuidString : id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Withdraws banners for items that were read, discarded or filtered out.
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        onRemove?(ids)
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// CI banners are identified by their commit page, which says which repo they belong to.
    nonisolated static func isCI(_ identifier: String, of repo: String) -> Bool {
        identifier.hasPrefix("https://github.com/\(repo)/commit/")
    }

    /// Withdraws a repo's CI banners (the ones that can't be looked up by item).
    func removeCI(of repo: String) {
        guard available else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { [self] delivered in
            remove(delivered.map(\.request.identifier).filter { Self.isCI($0, of: repo) })
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String ?? ""
        let url = info["url"] as? String
        DispatchQueue.main.async { self.onOpen?(id, url) }
        completionHandler()
    }
}

// MARK: - Global hotkeys

/// System-wide shortcuts, one registration per id. Matched by key position, so any keyboard layout works.
/// Key combinations go through Carbon hot keys; lone modifier taps (e.g. right ⌘) through event monitors,
/// which need Accessibility access to see the keys typed in other apps.
final class HotKeys {
    static let debug = ProcessInfo.processInfo.environment["LOOKOUT_DEBUG"] != nil
    private static var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var taps: [UInt32: (key: UInt16, handler: () -> Void)] = [:]
    /// Mouse button shortcuts, caught (and kept from the app under the pointer) by an event tap.
    private var buttons: [UInt32: (button: Int, flags: NSEvent.ModifierFlags, handler: () -> Void)] = [:]
    private var buttonTap: CFMachPort?
    /// Buttons whose press was a shortcut: their release is kept from the app under the pointer too.
    private var swallowedUps: Set<Int> = []
    private var tap = ModifierTap()
    private var monitors: [Any] = []
    /// When the held modifier went down (event timestamps, i.e. system uptime), to ask whether anything else happened since.
    private var heldSince: TimeInterval?
    /// Taps are ignored while this is true (e.g. while a shortcut is being recorded).
    var paused: () -> Bool = { false }

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeys.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// `nil` unregisters.
    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void = {}) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        HotKeys.handlers[id] = nil
        taps[id] = nil
        buttons[id] = nil
        defer { updateMonitors(); updateButtonTap() }
        guard let shortcut else { return }
        if let button = shortcut.mouseButton {
            buttons[id] = (button, shortcut.flags, handler)
            return
        }
        if shortcut.isModifierTap {
            taps[id] = (shortcut.keyCode, handler)
            return
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: OSType(0x4C4B4F54), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            HotKeys.handlers[id] = handler
        } else {
            NSLog("Lookout: global shortcut \(shortcut.display) unavailable (\(status))")
        }
    }

    private func updateMonitors() {
        if taps.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            heldSince = nil
            return
        }
        guard monitors.isEmpty else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Only modifier changes are watched; whether anything else happened during a tap is asked on release.
        let events: NSEvent.EventTypeMask = [.flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    /// Whether a key, click or scroll happened since the modifier went down: the window server remembers, so
    /// nothing has to watch those events (and wake the app) while typing or scrolling.
    private func interrupted(since start: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < elapsed }
    }

    /// A session event tap for the mouse buttons in use: it sees them in every app and can keep a shortcut's click
    /// from also going back in a browser. It needs Accessibility access, like modifier taps.
    private func updateButtonTap() {
        if buttons.isEmpty {
            if let tap = buttonTap { CGEvent.tapEnable(tap: tap, enable: false) }
            buttonTap = nil
            return
        }
        guard buttonTap == nil else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotKeys>.fromOpaque(info).takeUnretainedValue().button(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Lookout: can't watch mouse buttons (Accessibility access?)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        buttonTap = tap
    }

    /// Runs on the main run loop. Returns nil to keep the click from the app under the pointer.
    private func button(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = buttonTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseUp { return swallowedUps.remove(number) == nil ? Unmanaged.passUnretained(event) : nil }
        guard !paused() else { return Unmanaged.passUnretained(event) }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(Shortcut.relevant)
        guard let match = buttons.values.first(where: { $0.button == number && $0.flags == flags }) else {
            return Unmanaged.passUnretained(event)
        }
        swallowedUps.insert(number)
        DispatchQueue.main.async { match.handler() }
        return nil
    }

    private func handle(_ event: NSEvent) {
        if Self.debug {
            NSLog("Lookout keys: flagsChanged %d flags %lx trusted %d", event.keyCode, event.modifierFlags.rawValue, AXIsProcessTrusted() ? 1 : 0)
        }
        let held = UInt(event.modifierFlags.rawValue) & Shortcut.sideBits != 0
        let since = heldSince
        if held { if heldSince == nil { heldSince = event.timestamp } } else { heldSince = nil }
        // Without Accessibility the keys typed elsewhere are invisible, so right ⌘ + C would look like a tap.
        guard let key = tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue),
              !paused(), AXIsProcessTrusted() else { return }
        if let since, interrupted(since: since) { return }
        for entry in taps.values where entry.key == key { entry.handler() }
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var hub: HubController?
    private lazy var hotKeys = HotKeys()
    private var playground: Playground?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        handleSigterm()
        store = Store()
        if let i = CommandLine.arguments.firstIndex(of: "--playground-shots"), i + 1 < CommandLine.arguments.count {
            PlaygroundShots.run(to: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--playground") {
            playground = Playground()
            playground?.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--update"), i + 1 < CommandLine.arguments.count {
            UpdateCheck.run(as: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--claude") {
            ClaudeCheck.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--check"), i + 1 < CommandLine.arguments.count {
            Check.run(store: store, repo: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo") {
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            Demo.populate(store, Demo.Scenario(rawValue: name) ?? .busy)
        } else {
            store.start()
        }
        hub = HubController(store: store, demo: CommandLine.arguments.contains("--demo"))
        // Demo: the keep-open key on right ⌘ (not saved), to try tap and double-tap.
        if CommandLine.arguments.contains("--demo"), hub != nil {
            store.settings.shortcuts = [ShortcutAction.togglePanel.rawValue: Shortcut(keyCode: 54)]
        }
        hotKeys.paused = { [weak self] in self?.store.isRecordingShortcut ?? false }
        // Default ⌃⌥L: ⌃⌥Space is macOS's "next input source".
        registerHotKey(.togglePanel)
        registerHotKey(.sessionSwitcher)
        store.onGlobalShortcutChange = { [weak self] action, _ in self?.registerHotKey(action) }
        store.onAgentsEnabledChange = { [weak self] _ in
            self?.registerHotKey(.sessionSwitcher)
        }
        if CommandLine.arguments.contains("--open") {
            hub?.toggleShortcut()
        }
    }

    /// SIGTERM would skip `applicationWillTerminate` and lose a pending save.
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushSave()
    }

    /// The session switcher only grabs its keys while the Claude extension is on.
    private func registerHotKey(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            hotKeys.set(1, store.shortcut(action)) { [weak self] in
                DispatchQueue.main.async {
                    self?.hub?.toggleShortcut()
                }
            }
        case .sessionSwitcher:
            hotKeys.set(2, store.agents.enabled ? store.shortcut(action) : nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.hub?.showSessions()
                }
            }
        default:
            break
        }
    }

    /// Accessory apps have no visible menu bar, but key equivalents (⌘C/⌘V/⌘A) still route through the main menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lookout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
