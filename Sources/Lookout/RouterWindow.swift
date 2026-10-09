import AppKit
import Carbon
import SwiftUI

extension EnvironmentValues {
    /// Opens the Router window, on a card if one is given. The app's window controller in the app; a toast in the playground.
    @Entry var openRouter: (String?) -> Void = { _ in }
    /// Picks a card in the Router window (closed or not), after a click on it elsewhere opened its session.
    @Entry var pickRouterCard: (String) -> Void = { _ in }
}

/// The Router's window: a normal titled window (Lookout is otherwise all panels), opened from the bar, its shortcut or a
/// banner. Its content exists only while it is shown, so nothing in it ticks behind a closed window; what you were writing
/// and the card you picked are kept in `model`.
@MainActor
final class RouterWindowController: NSObject, NSWindowDelegate {
    let store: Store
    let model = RouterModel()
    private(set) lazy var keys = RouterKeys(store: store, model: model) { [weak self] in self?.close() }
    private var window: NSWindow?
    private var monitor: Any?
    /// The app in front before the window took it, to hand the keyboard back on close.
    private var previousApp: NSRunningApplication?

    static let autosave = "LookoutRouter"
    static let minSize = NSSize(width: 680, height: 480)

    init(store: Store) {
        self.store = store
    }

    /// Whether the window has the keyboard (no banner then: you are looking at the cards).
    var isKey: Bool { window?.isKeyWindow == true }
    var isVisible: Bool { window?.isVisible == true }

    /// Shows the window in front, on `card` when one is given.
    func show(card: String? = nil) {
        if let card { model.select(card, store: store) }
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentView == nil || !window.isVisible {
            window.contentView = NSHostingView(rootView: RouterView(store: store, model: model) { [weak self] in self?.close() })
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        // An accessory app: the window only comes to the front with the app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        watchKeys()
    }

    func close() { window?.performClose(nil) }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 920, height: 620)),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Router"
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.bg)
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        if !window.setFrameUsingName(Self.autosave) { window.center() }
        window.setFrameAutosaveName(Self.autosave)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.composerFocused = false
        // The content goes with the window: no view, no clock.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            self.window?.contentView = nil
            let app = self.previousApp
            self.previousApp = nil
            if NSApp.isActive, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        }
    }

    /// The window's keys (see `RouterKeys`), only while it is the key window.
    private func watchKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                guard let window = self.window, window.isKeyWindow, event.window === window,
                      !self.store.isRecordingShortcut else { return false }
                return TipCenter.dismissVisible(for: event) || self.keys.key(event)
            }
            return consumed ? nil : event
        }
    }
}

/// The Router window's keys. In the composer: Return sends, ⇧Return starts a new line, ↑↓ pick a card while it is empty;
/// with @ suggestions showing, ↑↓ walk them and Return or Tab picks one; Backspace at the very start takes the last chip off.
/// Elsewhere: ↑↓ pick a card, Space marks it addressed (or open again), Return replies to it, and typing goes to the
/// composer. Esc dismisses the suggestions, then the reply chip, then closes the window.
@MainActor
final class RouterKeys {
    let store: Store
    let model: RouterModel
    let close: () -> Void

    init(store: Store, model: RouterModel, close: @escaping () -> Void) {
        self.store = store
        self.model = model
        self.close = close
    }

    /// Whether the key was handled. `responder`: what has the keyboard (the window's first responder), for tests.
    func key(_ event: NSEvent, responder: NSResponder? = nil) -> Bool {
        let responder = responder ?? event.window?.firstResponder
        // An input method composing: its keys are its own.
        if (responder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let code = Int(event.keyCode)
        // The @ suggestions are the caret's: where it is now decides what the keys do.
        if model.composerFocused, let editor = responder as? NSTextView { model.followCaret(editor) }
        if code == kVK_Escape, flags.isEmpty {
            if model.mention != nil { model.dismissMention() }
            else if model.replyTo != nil { model.replyTo = nil }
            else { close() }
            return true
        }
        let editing = responder is NSText
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter
        if editing {
            guard model.composerFocused else { return false }
            let suggestions = model.suggestions(store)
            if !suggestions.isEmpty, flags.isEmpty {
                if code == kVK_UpArrow || code == kVK_DownArrow {
                    model.moveMention(down: code == kVK_DownArrow, count: suggestions.count)
                    return true
                }
                if isReturn || code == kVK_Tab {
                    model.pickMention(suggestions[min(model.mentionIndex, suggestions.count - 1)].folder)
                    return true
                }
            }
            if code == kVK_Delete, flags.isEmpty, (responder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 0) {
                return model.removeLastChip()
            }
            if isReturn, flags == .shift {
                (responder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if isReturn, flags.isEmpty {
                model.send(store: store)
                return true
            }
            if (code == kVK_UpArrow || code == kVK_DownArrow), flags.isEmpty, model.draft.isEmpty {
                model.move(down: code == kVK_DownArrow, store: store)
                return true
            }
            return false
        }
        // A button or chip the Tab ring is on takes Return and Space itself.
        if flags.isEmpty, responder is NSControl, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(code) { return false }
        if flags.isEmpty {
            if code == kVK_UpArrow || code == kVK_DownArrow {
                model.move(down: code == kVK_DownArrow, store: store)
                return true
            }
            if code == kVK_Space {
                model.toggleAddressed(store: store)
                return true
            }
            if isReturn {
                // Only a card that is listed: the pick follows the list first.
                model.reconcile(store: store)
                if let id = model.selection, model.cards(store).contains(where: { $0.id == id }) {
                    model.reply(to: id, store: store)
                } else {
                    model.reply()
                }
                return true
            }
        }
        // Typing anywhere writes to the Router: the key is handed to the composer, which types it itself.
        if model.canSend(store), flags.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            model.pendingKeys.append(event)
            model.reply()
            return true
        }
        return false
    }
}

/// A banner for each new card that needs you (a question, a plan, a stuck turn), unless notifications are off or snoozed or
/// the Router window has the keyboard. Clicking it opens the window on that card.
@MainActor
enum RouterBanners {
    /// Banner ids: the card's, after this.
    static let prefix = "router#"

    /// Hooks the store's new cards to banners, and banner clicks to `open`.
    static func attach(store: Store, windowIsKey: @escaping () -> Bool, open: @escaping (String) -> Void) {
        store.onNewRouterCards = { cards in post(cards, store: store, windowIsKey: windowIsKey()) }
        let previous = store.notifier.onOpen
        store.notifier.onOpen = { id, url, quiet in
            if id.hasPrefix(prefix) { open(String(id.dropFirst(prefix.count))) } else { previous?(id, url, quiet) }
        }
    }

    static func post(_ cards: [RouterCard], store: Store, windowIsKey: Bool) {
        guard !windowIsKey, store.settings.notifications, !store.isSnoozed else { return }
        for card in cards where card.kind.needsYou {
            let project = store.routerProject(card).name
            store.notifier.post(id: prefix + card.id, title: card.title, subtitle: "\(card.kind.label) · \(project)",
                                body: card.text, quiet: false)
        }
    }
}
