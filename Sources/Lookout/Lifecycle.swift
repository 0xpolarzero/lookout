import AppKit

/// `--lifecycle`: tooling only (`scripts/idle-cpu.sh`). Says on stdout what the idle gate needs to know to trust a number:
/// the sessions, how many work, how many rings have their loop attached, whether a window is showing and whether Reduce
/// Motion is on. Said after a few seconds, and again whenever it changes (a ring starting or stopping), once each, so a
/// covered window, a locked screen or Reduce Motion shows in the output. Nothing runs without the flag.
@MainActor
enum Lifecycle {
    static let flag = "--lifecycle"

    private static var said = ""
    private static var pending = false

    static func line(_ store: Store) -> String {
        let rows = store.allAgentRows
        // The ones that pulse: working and not waiting on you (see `AgentTile`).
        let working = rows.filter { $0.group == .working }.count
        let showing = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        return "lifecycle: sessions=\(rows.count) working=\(working) rings=\(PulseView.looping) "
            + "showing=\(showing ? 1 : 0) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0)\n"
    }

    static func start(_ store: Store) {
        PulseView.onLoopingChange = {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { MainActor.assumeIsolated { say(store) } }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            say(store)
        }
    }

    private static func say(_ store: Store) {
        pending = false
        let text = line(store)
        if text != said {
            said = text
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
}
