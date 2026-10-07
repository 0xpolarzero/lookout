import Foundation
import Security

// MARK: - API types

struct GHUser: Codable, Hashable {
    let login: String
    let avatarUrl: URL?
    let type: String?

    var isApp: Bool { type == "Bot" || login.hasSuffix("[bot]") }
}

struct GHIssue: Decodable {
    struct PRLink: Decodable { let url: URL? }
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let user: GHUser?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let pullRequest: PRLink?
    let repositoryUrl: URL?
}

struct GHComment: Decodable {
    let id: Int
    let body: String?
    let user: GHUser?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let issueUrl: URL?
    let pullRequestUrl: URL?
    let inReplyToId: Int?
    let path: String?
}

struct GHRepo: Decodable {
    let fullName: String
    let defaultBranch: String
}

struct GHSearch<T: Decodable>: Decodable {
    let items: [T]
    let totalCount: Int?
    /// GitHub gave up before searching everything: `items` may be missing some matches.
    let incompleteResults: Bool?
}

struct GHWorkflowRuns: Decodable {
    struct Run: Decodable {
        let name: String
        let workflowId: Int
        let headSha: String
        let displayTitle: String?
        let updatedAt: Date?
        let status: String
        let conclusion: String?
    }
    let workflowRuns: [Run]
}

struct GHCheckRuns: Decodable {
    struct App: Decodable { let slug: String? }
    struct Run: Decodable {
        let app: App?
        let name: String
        let status: String
        let conclusion: String?
        let headSha: String
    }
    let totalCount: Int
    let checkRuns: [Run]
}

struct GHCombinedStatus: Decodable {
    struct Status: Decodable {
        let context: String
        let state: String
    }
    let state: String
    let totalCount: Int
    let sha: String
    let statuses: [Status]
}

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

/// Thin REST/GraphQL client. Remembers ETags so unchanged polls come back as 304s, which don't count against the rate limit.
final class GitHubClient: @unchecked Sendable {
    /// A different token is a different account: its quota and the answers it was given are not this one's.
    var token: String? {
        didSet {
            lock.withLock {
                generation += 1
                rejected = false
                guard token != oldValue else { return }
                coreRemaining = nil
                coreResetsAt = nil
                gqlRemaining = nil
                etags = [:]
            }
        }
    }
    /// GitHub answered 401 since the token was last set: it was revoked or has expired.
    var tokenRejected: Bool { lock.withLock { rejected } }
    private var rejected = false
    /// Counts token changes. What a request sent under an older one brings back (a 401, the quota, the ETag) is dropped,
    /// so it can't discard or overwrite what belongs to the newer token.
    private var generation = 0
    /// Swapped for a stub in tests.
    var session = URLSession.shared
    /// Remaining calls in the core (REST) and GraphQL buckets.
    var rateRemaining: Int? { lock.withLock { coreRemaining } }
    var graphqlRemaining: Int? { lock.withLock { gqlRemaining } }
    /// When the core bucket refills.
    var rateResetsAt: Date? { lock.withLock { coreResetsAt } }
    private var coreResetsAt: Date?
    private var coreRemaining: Int?
    private var gqlRemaining: Int?
    /// What an answer GitHub gave is remembered by: its ETag, its body and, once decoded, the value (a 304 returns that
    /// value without parsing the body again).
    private struct Remembered {
        var etag: String
        var data: Data
        var used: Int
        /// The decoded body and the type it was decoded as.
        var decoded: (value: Any, type: ObjectIdentifier)?
        /// What a commit's answers share across commits (`/repos/o/r/commits/{sha}/status`): a newer commit supersedes them.
        var family: String?
    }
    private var etags: [String: Remembered] = [:]
    private var etagClock = 0
    /// Most responses remembered; the least recently used go first. A watched repository takes about eight (see `reserveETags`).
    private var etagLimit = GitHubClient.etagFloor
    private static let etagFloor = 200
    private let lock = NSLock()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Room for every repository's answers at once: a poll visits each in turn, and a cache smaller than that cycle evicts each
    /// answer just before it is asked for again, so every poll becomes full 200s against the rate limit. Per repository: issues,
    /// issue comments and review comments, actions runs, check runs and status, and a few spare for the review search.
    func reserveETags(forRepositories count: Int) {
        lock.withLock { etagLimit = max(Self.etagFloor, 8 * count + 40) }
    }

    /// How many answers are remembered (the tests count them).
    var remembered: Int { lock.withLock { etags.count } }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        let answer = try await exchange(path, query)
        if answer.notModified, let value = answer.decoded?.value as? T, answer.decoded?.type == ObjectIdentifier(T.self) { return value }
        let value: T
        do {
            value = try decoder.decode(T.self, from: answer.data)
        } catch {
            throw GitHubError(message: "Unexpected response from \(path)")
        }
        // Kept with the ETag that goes with the body it was made from.
        if let key = answer.key, let etag = answer.etag {
            lock.withLock {
                if etags[key]?.etag == etag { etags[key]?.decoded = (value, ObjectIdentifier(T.self)) }
            }
        }
        return value
    }

    func raw(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        try await exchange(path, query).data
    }

    private struct Answer {
        let data: Data
        /// Where it is remembered, and by what ETag (nil when GitHub gave none).
        var key: String?
        var etag: String?
        var notModified = false
        var decoded: (value: Any, type: ObjectIdentifier)?
    }

    private func exchange(_ path: String, _ query: [String: String]) async throws -> Answer {
        // Out of calls: GitHub asks that nothing is sent until the reset. Search has a budget of its own, which this one's end leaves.
        if !path.hasPrefix("/search/"), let reset = lock.withLock({ coreRemaining == 0 ? coreResetsAt : nil }), reset > Date() {
            throw GitHubError(message: "API rate limit exceeded, waiting for the reset")
        }
        var comps = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let url = comps.url!
        var (req, sent) = request(url)
        // Without the moving `since` cursor: each poll replaces the entry instead of adding one (a changed query
        // that returns the same body still gets its 304).
        var keyed = comps
        keyed.queryItems = comps.queryItems?.filter { $0.name != "since" }
        let key = keyed.url!.absoluteString
        let cached = lock.withLock { () -> Remembered? in
            guard var hit = etags[key] else { return nil }
            etagClock += 1
            hit.used = etagClock
            etags[key] = hit
            return hit
        }
        if let cached { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }

        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        trackRate(http, sent: sent)
        if http.statusCode == 304, let cached {
            return Answer(data: cached.data, key: key, etag: cached.etag, notModified: true, decoded: cached.decoded)
        }
        try check(http, data, sent: sent)
        guard let etag = http.value(forHTTPHeaderField: "ETag") else { return Answer(data: data) }
        lock.withLock {
            guard generation == sent else { return }
            etagClock += 1
            let family = Self.family(of: key)
            // A newer commit's answers replace the older commit's: those are never asked for again.
            if let family { etags = etags.filter { $0.key == key || $0.value.family != family } }
            etags[key] = Remembered(etag: etag, data: data, used: etagClock, decoded: nil, family: family)
            while etags.count > etagLimit, let oldest = etags.min(by: { $0.value.used < $1.value.used })?.key { etags[oldest] = nil }
        }
        return Answer(data: data, key: key, etag: etag)
    }

    /// `…/commits/<40 hex digits>/…` with the sha taken out, for the answers that are about one commit; nil for the others.
    private static func family(of key: String) -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard let at = parts.firstIndex(of: "commits"), parts.indices.contains(at + 1) else { return nil }
        let sha = parts[at + 1]
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
        var rest = parts
        rest[at + 1] = "{sha}"
        return rest.joined(separator: "/")
    }

    func graphql(_ query: String) async throws -> [String: Any] {
        var (req, sent) = request(URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        trackRate(http, sent: sent)
        try check(http, data, sent: sent)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(message: "Bad GraphQL response")
        }
        return json
    }

    private func request(_ url: URL) -> (URLRequest, generation: Int) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Lookout", forHTTPHeaderField: "User-Agent")
        // Token and generation read together, so they describe the same credential.
        let (current, sent) = lock.withLock { (token, generation) }
        if let current { req.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization") }
        return (req, sent)
    }

    private func trackRate(_ http: HTTPURLResponse, sent: Int) {
        guard let r = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init) else { return }
        switch http.value(forHTTPHeaderField: "x-ratelimit-resource") {
        case "core":
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            lock.withLock {
                guard generation == sent else { return }
                coreRemaining = r
                coreResetsAt = reset
            }
        case "graphql": lock.withLock { if generation == sent { gqlRemaining = r } }
        default: break
        }
    }

    private func check(_ http: HTTPURLResponse, _ data: Data, sent: Int) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        switch http.statusCode {
        case 401:
            lock.withLock { if generation == sent { rejected = true } }
            throw GitHubError(message: "GitHub rejected the token")
        case 404: throw GitHubError(message: "Not found (or no access)")
        default: throw GitHubError(message: message ?? "GitHub error \(http.statusCode)")
        }
    }
}

// MARK: - Token

enum TokenSource: String {
    case keychain = "Keychain"
    case environment = "environment"
    case ghCLI = "gh CLI"
}

enum TokenProvider {
    static func resolve() -> (String, TokenSource)? {
        if let t = Keychain.read(), !t.isEmpty { return (t, .keychain) }
        let env = ProcessInfo.processInfo.environment
        if let t = env["GH_TOKEN"] ?? env["GITHUB_TOKEN"], !t.isEmpty { return (t, .environment) }
        if let t = ghCLIToken(), !t.isEmpty { return (t, .ghCLI) }
        return nil
    }

    private static func ghCLIToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Keychain {
    static let github = "github-token"
    static let typesafe = "typesafe-key"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.polarzero.lookout",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String = github) -> String? {
        guard !Store.isDemo else { return nil }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String, _ account: String = github) {
        delete(account)
        var q = base(account)
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String = github) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
