import Foundation

/// The Claude Code processes running now, as each registers itself in `~/.claude/sessions/<pid>.json`. A session with one is
/// a peer: the Router can message it by its name.
enum ClaudePeers {
    struct Peer: Hashable {
        /// What `SendMessage` takes as `to`: the session's title.
        var name: String
        /// `busy` or `idle`, as the process says.
        var status: String
        var pid: Int32
    }

    /// By the desktop app's session id (`hostSessionId`, `local_…`). Files of processes that are gone are skipped.
    static func read(dir: URL, alive: (Int32) -> Bool = FormBridge.processAlive) -> [String: Peer] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var peers: [String: Peer] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = obj["hostSessionId"] as? String, !host.isEmpty,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value ?? Int32(url.deletingPathExtension().lastPathComponent),
                  alive(pid) else { continue }
            peers[host] = Peer(name: obj["name"] as? String ?? "", status: obj["status"] as? String ?? "", pid: pid)
        }
        return peers
    }

    /// One live process as Claude Code registers it: the session it runs now, and when it started.
    struct Registered: Hashable, Sendable {
        var sessionID: String
        var startedAt: Int64?
    }

    /// Every live process in the registry, by pid (what Lookout's plugin binds its presence to). A pid has one entry in
    /// Claude Code's own registry; all are kept in case two files name it.
    static func registry(dir: URL, alive: (Int32) -> Bool = FormBridge.processAlive) -> [Int32: [Registered]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var found: [Int32: [Registered]] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, let session = obj["sessionId"] as? String, alive(pid)
            else { continue }
            found[pid, default: []].append(Registered(sessionID: session, startedAt: (obj["startedAt"] as? NSNumber)?.int64Value))
        }
        return found
    }
}
