import CoreFoundation
import Testing

/// The test runner drives the main actor from a bare `CFRunLoopRun`, and exits 0 as soon as that returns. Once a window is on
/// screen, AppKit's event thread stops the main run loop each time the window server sends the process an event, to wake the
/// event loop it expects there. A test spinning the run loop itself takes that stop for its own loop; one landing while the
/// main thread had nothing to do ended the runner's loop, so a parallel run stopped partway through, as a pass.
///
/// Holding the main thread in a loop of our own beneath everything else gives those stops somewhere harmless to land: the loop
/// starts again whenever it's stopped, and the run still ends the usual way, when the runner exits.
@MainActor
enum EventLoop {
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static var observer: CFRunLoopObserver?

    /// Returns once the main thread is in the held loop.
    static func hold() async {
        if held { return }
        await withCheckedContinuation { waiting.append($0); watch() }
    }

    /// The held loop can only start from the runner's own loop: one a test is spinning runs inside a main-actor job, and the
    /// main actor would never get its turn again. The observer counts the loops run inside the runner's and starts the held
    /// one the next time the runner's own loop does any work.
    private static func watch() {
        if observer != nil { return }
        var nested = 0
        let activities: CFRunLoopActivity = [.entry, .exit, .beforeTimers, .beforeSources, .beforeWaiting]
        let watching = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                switch activity {
                case .entry: nested += 1
                case .exit: nested -= 1
                default: if nested == 0 && !held { run() }
                }
            }
        }
        observer = watching
        CFRunLoopAddObserver(CFRunLoopGetMain(), watching, .commonModes)
    }

    private static func run() -> Never {
        held = true
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        waiting.forEach { $0.resume() }
        waiting = []
        while true { CFRunLoopRun() }
    }
}

/// For suites that put windows on screen: their tests start once the main thread is in `EventLoop`'s held loop.
struct HostsWindows: SuiteTrait, TestTrait {
    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        await EventLoop.hold()
    }
}

extension Trait where Self == HostsWindows {
    static var hostsWindows: Self { Self() }
}
