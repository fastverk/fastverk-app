// FleetClient — the "fleet" plugin's read surface (botnoc-fleet, a web-first
// plugin with no gRPC/describe). It exposes the coordination-CR list endpoints
// (agents / tasks / builds / prompts) as one-shot JSON, and the live agent/build
// transcript as SSE. All calls go through the console gateway `/api/gw/fleet/…`
// with the Cognito Bearer; the gateway injects X-Fastverk-User-Sub server-side.
//
// The transcript SSE (`/view/<kind>/<name>`) is a durable JetStream replay + live
// tail; `<name>` is the fleet Agent CR name (from `agents()`), NOT an AgentRun.id
// (that's the separate `agents` dispatch plugin). Each `data:` frame is one
// Claude Code stream-json line — decoded by TranscriptFrame. Rows are decoded
// defensively via JSONValue (the backend shapes carry nested objects), the same
// way the web's fleet.js reads them.

import Foundation
import MeridianUI

/// A fleet Agent CR row — the transcript subject key + a short status line.
struct FleetAgent: Identifiable, Hashable {
    let name: String
    let phase: String
    let focus: String
    let updatedAt: String
    var id: String { name }
}

/// An AgentTask CR row (the provenance/DAG surface).
struct FleetTask: Identifiable, Hashable {
    let name: String
    let phase: String
    let agent: String
    let title: String
    let createdAt: String
    var id: String { name }
}

/// A BuildRun CR row — drills into build logs (kind=build) rather than agent JSON.
struct FleetBuild: Identifiable, Hashable {
    let name: String
    let phase: String
    let repo: String
    let updatedAt: String
    var id: String { name }
}

/// A HumanPrompt CR row — an operator question awaiting an answer.
struct FleetPrompt: Identifiable, Hashable {
    let name: String
    let phase: String
    let question: String
    var id: String { name }
}

struct FleetClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    // MARK: - List endpoints (one-shot JSON, poll-only)

    func agents() async throws -> [FleetAgent] {
        let json = try await getJSON("/api/gw/fleet/agents")
        return json.rows("agents").map { a in
            FleetAgent(
                name: a["name"].asString ?? "",
                phase: a["phase"].asString ?? "Unknown",
                focus: focusText(a["focus"]),
                updatedAt: a["updatedAt"].asString ?? a.get("focus.updatedAt").asString ?? ""
            )
        }.filter { !$0.name.isEmpty }
    }

    func tasks() async throws -> [FleetTask] {
        let json = try await getJSON("/api/gw/fleet/tasks")
        return json.rows("tasks").map { t in
            FleetTask(
                name: t["name"].asString ?? "",
                phase: t["phase"].asString ?? "Unknown",
                agent: t["agent"].asString ?? "",
                title: t["title"].asString ?? "",
                createdAt: t["createdAt"].asString ?? ""
            )
        }.filter { !$0.name.isEmpty }
    }

    func builds() async throws -> [FleetBuild] {
        let json = try await getJSON("/api/gw/fleet/builds")
        return json.rows("builds").map { b in
            FleetBuild(
                name: b["name"].asString ?? "",
                phase: b["phase"].asString ?? "Unknown",
                repo: b["repo"].asString ?? b["source"].asString ?? "",
                updatedAt: b["updatedAt"].asString ?? ""
            )
        }.filter { !$0.name.isEmpty }
    }

    func prompts() async throws -> [FleetPrompt] {
        let json = try await getJSON("/api/gw/fleet/prompts")
        return json.rows("prompts").map { p in
            FleetPrompt(
                name: p["name"].asString ?? "",
                phase: p["phase"].asString ?? "Unknown",
                question: p["question"].asString ?? p["prompt"].asString ?? p["title"].asString ?? ""
            )
        }.filter { !$0.name.isEmpty }
    }

    // MARK: - Live transcript (SSE)

    /// Open the durable transcript for a workload. `kind` is "agent" (stream-json)
    /// or "build" (plain log lines); `name` is the CR name. `lastEventID` resumes
    /// after a JetStream sequence on reconnect.
    func transcript(kind: String, name: String, lastEventID: String? = nil)
        -> AsyncThrowingStream<SSEEvent, Error>
    {
        EventStream(base: base, auth: auth)
            .events(path: "/api/gw/fleet/view/\(kind)/\(pathEscape(name))", lastEventID: lastEventID)
    }

    // MARK: - Transport

    private func getJSON(_ path: String, retryOn401: Bool = true) async throws -> JSONValue {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = path
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await getJSON(path, retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSEError.transport(body.isEmpty ? "Fleet request failed (HTTP \(code))." : body)
        }
        return try JSONValue.parse(data)
    }

    /// A short status line from the Agent's `focus` (a string or a nested object).
    private func focusText(_ v: JSONValue) -> String {
        if let s = v.asString { return s }
        for key in ["summary", "message", "detail", "text", "phase"] {
            if let s = v[key].asString, !s.isEmpty { return s }
        }
        return ""
    }

    private func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
