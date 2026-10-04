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
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
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

// MARK: - Global hotkey (⌃⌥Space)

final class HotKey {
    private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4C4B4F54), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
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
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store = Store()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: CommandLine.arguments[i + 1])
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
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            DispatchQueue.main.async { self?.controller.toggle(.inbox) }
        }
        if CommandLine.arguments.contains("--open") {
            controller.toggle(.inbox)
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
