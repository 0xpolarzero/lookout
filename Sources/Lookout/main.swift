import AppKit

// Claude Code runs this binary as its form hook (see `FormHook`): no app, nothing on stdout but the hook's decision.
if CommandLine.arguments.dropFirst().first == "--form-hook" { FormHook.main() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
