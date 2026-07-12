// AgentsClient — the agents plugin's write-side surface, which the meridian
// descriptor can't express: Dispatch isn't a panel at all, and Cancel is a
// bespoke action (its `{run_id}` path segment is substituted per row). All three
// routes are under /api/gw/agents/ and carry the Cognito Bearer; the shell
// gateway resolves the user's connected-GitHub token for the mutating ones.

import Foundation

/// One active coding-agent run (agents plugin ListActive row). snake_case wire.
struct AgentRun: Codable, Identifiable {
    let id: String
    let issueRef: String
    let backend: String
    let state: String
    var dispatchedAt: String?
    var prRef: String?
    var workflowRunURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case issueRef = "issue_ref"
        case backend, state
        case dispatchedAt = "dispatched_at"
        case prRef = "pr_ref"
        case workflowRunURL = "workflow_run_url"
    }

    /// Cancellable only while non-terminal.
    var isActive: Bool { ["dispatched", "working", "review_required"].contains(state) }
}

/// The dispatch backends (values the plugin's parse_agent_backend accepts).
enum AgentBackendOption: String, CaseIterable, Identifiable {
    case claude, copilot, github
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .copilot: return "Copilot Workspaces"
        case .github: return "GitHub Coding Agent"
        }
    }
}

enum AgentsError: Error, CustomStringConvertible {
    case notConnected
    case http(Int, String)

    var description: String {
        switch self {
        case .notConnected: return "Connect GitHub in the web console first (Settings → Connect GitHub)."
        case let .http(code, msg): return msg.isEmpty ? "Request failed (HTTP \(code))." : msg
        }
    }
}

struct AgentsClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    func listActive() async throws -> [AgentRun] {
        let data = try await request("GET", "/api/gw/agents/agents", body: nil)
        struct Resp: Decodable { let runs: [AgentRun]? }
        return (try JSONDecoder().decode(Resp.self, from: data)).runs ?? []
    }

    func dispatch(issueRef: String, backend: AgentBackendOption) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["issue_ref": issueRef, "backend": backend.rawValue])
        _ = try await request("POST", "/api/gw/agents/agents/dispatch", body: body)
    }

    func cancel(runId: String) async throws {
        _ = try await request("POST", "/api/gw/agents/agents/\(pathEscape(runId))/cancel",
                              body: try JSONSerialization.data(withJSONObject: ["reason": ""]))
    }

    // MARK: - Transport

    private func request(_ method: String, _ path: String, body: Data?, retryOn401: Bool = true) async throws -> Data {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = path
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await request(method, path, body: body, retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            let msg = message(data)
            if msg.contains("E_NOT_CONNECTED") { throw AgentsError.notConnected }
            throw AgentsError.http(code, msg)
        }
        return data
    }

    /// Percent-encode a run id for a single path segment (encodes / and #).
    private func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func message(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
        }
        return raw
    }
}
