import Foundation

/// GitHub as the idle gate's polling run meets it (`--demo agents --lifecycle --canned`): the answers of a quiet account, sized
/// as GitHub sizes them (thirty workflow runs, a hundred check runs), each with an ETag, and a 304 for every request that comes
/// back with it. The first poll is the full answers and every later one the 304s, which is what the shipped app does at rest, so
/// the gate measures a poll's own CPU (the requests, the cache, no parsing of what has not changed). Nothing leaves the machine.
enum CannedGitHub {
    static let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        let url = request.url!
        let path = url.path
        func reply(_ status: Int, _ body: String, etag: String? = nil) -> (Data, URLResponse) {
            var headers = ["x-ratelimit-remaining": "4900", "x-ratelimit-resource": "core",
                           "x-ratelimit-reset": String(Int(Date().timeIntervalSince1970) + 3000)]
            if let etag { headers["ETag"] = etag }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        // A request that has an ETag was answered in full before: nothing is built for it again.
        let etag = "\"canned-\(path)\""
        if path != "/graphql", request.value(forHTTPHeaderField: "If-None-Match") == etag { return reply(304, "", etag: etag) }
        guard let body = answer(for: path) else { return reply(404, #"{"message": "Not found"}"#) }
        // The graph is not cacheable by ETag: it is answered in full, as GitHub does.
        return path == "/graphql" ? reply(200, body) : reply(200, body, etag: etag)
    }

    /// What `path` answers, nil for what this account does not have.
    static func answer(for path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if path == "/user" { return #"{"login": "0xpolarzero", "avatar_url": null, "type": "User"}"# }
        if path == "/graphql" { return #"{"data": {}}"# }
        if path == "/search/issues" { return #"{"total_count": 0, "incomplete_results": false, "items": []}"# }
        guard parts.count >= 3, parts[0] == "repos" else { return nil }
        let name = parts[1] + "/" + parts[2]
        switch parts.dropFirst(3).joined(separator: "/") {
        case "": return #"{"full_name": "\#(name)", "default_branch": "main"}"#
        case "issues", "issues/comments", "pulls/comments": return "[]"
        case "actions/runs": return runs()
        case _ where parts.count == 6 && parts[3] == "commits" && parts[5] == "check-runs": return checkRuns(sha: parts[4])
        case _ where parts.count == 6 && parts[3] == "commits" && parts[5] == "status":
            return #"{"state": "success", "total_count": 0, "sha": "\#(parts[4])", "statuses": []}"#
        case _ where parts.count == 5 && parts[3] == "commits": return #"{"commit": {"message": "Release\n\nNotes"}}"#
        default: return nil
        }
    }

    private static let sha = String(repeating: "c", count: 40)

    /// Thirty runs, each with what GitHub sends besides what Lookout reads.
    private static func runs() -> String {
        let run = { (i: Int) in
            """
            {"id": \(9000 + i), "name": "CI", "node_id": "WFR_\(i)", "head_branch": "main", "head_sha": "\(sha)", "path": ".github/workflows/ci.yml",
             "run_number": \(i), "event": "push", "status": "completed", "conclusion": "success", "workflow_id": \(i % 3), "check_suite_id": \(5000 + i),
             "url": "https://api.github.com/repos/o/r/actions/runs/\(i)", "html_url": "https://github.com/o/r/actions/runs/\(i)",
             "display_title": "Release 0.\(i)", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:05:00Z",
             "actor": {"login": "someone", "id": 1, "avatar_url": "https://avatars.githubusercontent.com/u/1", "type": "User", "site_admin": false},
             "head_commit": {"id": "\(sha)", "message": "Release 0.\(i)", "timestamp": "2026-01-01T00:00:00Z",
                             "author": {"name": "Someone", "email": "someone@example.com"}},
             "repository": {"id": 1, "full_name": "o/r", "private": false, "html_url": "https://github.com/o/r", "fork": false}}
            """
        }
        return #"{"total_count": 30, "workflow_runs": ["# + (0..<30).map(run).joined(separator: ",") + "]}"
    }

    /// A hundred check runs of one commit.
    private static func checkRuns(sha: String) -> String {
        let run = { (i: Int) in
            """
            {"id": \(7000 + i), "name": "job \(i)", "head_sha": "\(sha)", "status": "completed", "conclusion": "success",
             "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:05:00Z", "external_id": "x\(i)",
             "html_url": "https://github.com/o/r/runs/\(i)", "details_url": "https://github.com/o/r/actions/runs/1/job/\(i)",
             "output": {"title": null, "summary": null, "text": null, "annotations_count": 0},
             "check_suite": {"id": 5000}, "app": {"id": 15368, "slug": "github-actions", "name": "GitHub Actions", "owner": {"login": "github"}}}
            """
        }
        return #"{"total_count": 100, "check_runs": ["# + (0..<100).map(run).joined(separator: ",") + "]}"
    }
}
