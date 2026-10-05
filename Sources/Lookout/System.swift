import AppKit
import Carbon
import ServiceManagement
import UserNotifications

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(id: String, title: String, subtitle: String, body: String, quiet: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.userInfo = ["id": id]
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
        guard available, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? ""
        DispatchQueue.main.async { self.onOpen?(id) }
        completionHandler()
    }
}

// MARK: - Global hotkeys

/// System-wide shortcuts, one registration per id. Matched by key position, so any keyboard layout works.
/// Key combinations go through Carbon hot keys; lone modifier taps (e.g. right ⌘) through event monitors,
/// which need Accessibility access to see the keys typed in other apps.
final class HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var taps: [UInt32: (key: UInt16, handler: () -> Void)] = [:]
    private var tap = ModifierTap()
    private var monitors: [Any] = []
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
        defer { updateMonitors() }
        guard let shortcut else { return }
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
            return
        }
        guard monitors.isEmpty else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return tap.interrupt() }
        // Without Accessibility the keys typed elsewhere are invisible, so right ⌘ + C would look like a tap.
        guard let key = tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue),
              !paused(), AXIsProcessTrusted() else { return }
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
    private var controller: UIController!
    private lazy var hotKeys = HotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store = Store()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: CommandLine.arguments[i + 1])
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
        controller = UIController(store: store)
        hotKeys.paused = { [weak self] in self?.store.isRecordingShortcut ?? false }
        // Default ⌃⌥L: ⌃⌥Space is macOS's "next input source".
        registerHotKey(.togglePanel)
        registerHotKey(.sessionSwitcher)
        store.onGlobalShortcutChange = { [weak self] action, _ in self?.registerHotKey(action) }
        store.onAgentsEnabledChange = { [weak self] _ in
            self?.registerHotKey(.sessionSwitcher)
            self?.controller.agentsChanged()
        }
        if CommandLine.arguments.contains("--open") {
            controller.toggle(.inbox)
        }
    }

    /// The session switcher only grabs its keys while the Claude extension is on.
    private func registerHotKey(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            hotKeys.set(1, store.shortcut(action)) { [weak self] in
                DispatchQueue.main.async { self?.controller.toggle(.inbox) }
            }
        case .sessionSwitcher:
            hotKeys.set(2, store.agents.enabled ? store.shortcut(action) : nil) { [weak self] in
                DispatchQueue.main.async { self?.controller.showSwitcher() }
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
