// EventStream — a minimal Server-Sent Events reader over URLSession.bytes.
//
// iOS ships no `EventSource`, so this parses the text/event-stream framing
// itself: `field: value` lines, a blank line dispatches the accumulated event,
// consecutive `data:` lines join with "\n", and `:`-comment / `retry:` lines are
// ignored (matching the browser EventSource the web console uses). It carries the
// Cognito Bearer id_token and, on an initial 401, refreshes once and reconnects.
// Shared by the live agent-transcript viewer (Phase B) and chat (Phase C).

import Foundation

/// One dispatched SSE event: its `event:` name (default "message") and the joined
/// `data:` payload (the text accumulated between two blank lines).
struct SSEEvent: Sendable {
    var event: String
    var data: String
    var id: String?
}

enum SSEError: Error, CustomStringConvertible {
    case unauthorized
    case http(Int)
    case transport(String)

    var description: String {
        switch self {
        case .unauthorized: return "Session expired — sign in again."
        case let .http(code): return "Stream failed (HTTP \(code))."
        case let .transport(m): return m
        }
    }
}

struct EventStream: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = EventStream.streamingSession

    /// A URLSession that won't time out an idle stream. The default 60s request
    /// timeout would drop a quiet SSE connection between heartbeats.
    static let streamingSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600           // per-read idle ceiling; heartbeats keep it alive
        cfg.timeoutIntervalForResource = .infinity    // no cap on total stream duration
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Open `path` (relative to `base`) as an SSE stream, yielding each event as
    /// it arrives. The stream finishes when the server closes the connection or
    /// the consuming Task is cancelled; it throws on a non-2xx status (after one
    /// 401 refresh) or a transport error. `lastEventID` resumes a durable stream
    /// after a given `id:` (sent as the `Last-Event-ID` header), so a reconnect
    /// tails from where it left off rather than replaying from the start.
    func events(
        path: String,
        query: [URLQueryItem] = [],
        lastEventID: String? = nil
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(path: path, query: query, lastEventID: lastEventID,
                                  retryOn401: true, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        path: String,
        query: [URLQueryItem],
        lastEventID: String?,
        retryOn401: Bool,
        into continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) async throws {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let lastEventID { req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }

        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await run(path: path, query: query, lastEventID: lastEventID, retryOn401: false, into: continuation)
        }
        if code == 401 { throw SSEError.unauthorized }
        guard (200..<300).contains(code) else { throw SSEError.http(code) }

        var event = ""
        var data: [String] = []
        var id: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if !data.isEmpty {
                    continuation.yield(SSEEvent(
                        event: event.isEmpty ? "message" : event,
                        data: data.joined(separator: "\n"),
                        id: id
                    ))
                }
                event = ""; data = []; id = nil
                continue
            }
            if line.hasPrefix(":") { continue } // comment / heartbeat
            let field: String
            var value: String
            if let colon = line.firstIndex(of: ":") {
                field = String(line[..<colon])
                value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() } // strip one leading space
            } else {
                field = line // a bare field name with no colon: value is empty
                value = ""
            }
            switch field {
            case "event": event = value
            case "data": data.append(value)
            case "id": id = value
            default: break // retry: and unknown fields are ignored
            }
        }
        // Server closed the stream. A trailing event with no terminating blank
        // line is dropped, exactly as browser EventSource does.
    }
}
