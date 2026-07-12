// ChatClient — the chat.v1 transport (Phase C). The stream comes from
// `GET /api/noc-agent/view` (SSE, HostEvents); a turn is sent with
// `POST /api/noc-agent/turn` (a 202 ack — all content flows back through /view).
// The conversation is keyed server-side by the signed-in user (the console
// injects X-Fastverk-User-Sub from the Cognito session behind the Bearer), so no
// conversation id is threaded from the client. Confirm-gated writes are
// conversational: to confirm, just send another turn ("yes").

import Foundation

enum ChatError: Error, CustomStringConvertible {
    case empty
    case http(Int, String)

    var description: String {
        switch self {
        case .empty: return "Message is required."
        case let .http(code, msg): return msg.isEmpty ? "Send failed (HTTP \(code))." : msg
        }
    }
}

struct ChatClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    /// The live HostEvent stream. Yields raw SSE events; the caller decodes each
    /// `data:` with `HostEvent.decode`.
    func view() -> AsyncThrowingStream<SSEEvent, Error> {
        EventStream(base: base, auth: auth).events(path: "/api/noc-agent/view")
    }

    /// Send a user turn. Returns once the host acks (202); the echoed user block
    /// and the assistant's reply arrive over `view()`.
    func send(message: String, retryOn401: Bool = true) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatError.empty }

        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = "/api/noc-agent/turn"
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["message": trimmed])

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await send(message: trimmed, retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            throw ChatError.http(code, message(data))
        }
    }

    private func message(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
