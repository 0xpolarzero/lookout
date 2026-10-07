import AppKit
import MachO

/// What a test run must never reach: the user's Keychain, their saved state, banners, the login item, `gh`, links opened
/// in other apps and the network. Each of those asks here before it touches the real thing, and under a test it stops the
/// run, naming what was reached (a test stands something in for each of them: see `Keychain.backend`, `Store.stateFile`,
/// `Network.session` and the closures the stores and the updater have).
enum UnderTest {
    /// Whether this process is a test run: the test bundle is loaded in it, whichever runner started it.
    static let isRunning: Bool = (0..<_dyld_image_count()).contains { index in
        _dyld_get_image_name(index).map { String(cString: $0).contains(".xctest/") } ?? false
    }

    /// What reaching the real thing does. Only the test of this guard replaces it, to see that it was reached.
    nonisolated(unsafe) static var onReach: (String) -> Void = { what in
        fatalError("A test reached \(what). It must stand something in for it, or the code under test must not go there.")
    }

    /// True, once `onReach` has said so, when this is a test run: the caller then leaves the real thing alone.
    static func refuses(_ what: String) -> Bool {
        guard isRunning else { return false }
        onReach(what)
        return true
    }
}

/// The network, which a test run is never given: the tests answer for GitHub, TypeSafe and the releases themselves.
enum Network {
    /// The system's shared session, or one that stops the run on its first request when the process is a test.
    static var session: URLSession { UnderTest.isRunning ? refused : .shared }

    private static let refused: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Refused.self]
        return URLSession(configuration: config)
    }()

    private final class Refused: URLProtocol {
        /// A file on this disk is not the network (the updater's tests hand it a checksum that way).
        override class func canInit(with request: URLRequest) -> Bool { request.url?.isFileURL != true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            _ = UnderTest.refuses("the network (\(request.url?.absoluteString ?? "a request"))")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }
}

/// A link opened in the app that handles it (the browser, Claude): never from a test.
enum Link {
    static func open(_ url: URL) {
        guard !UnderTest.refuses("another app, opening \(url.absoluteString)") else { return }
        NSWorkspace.shared.open(url)
    }
}
