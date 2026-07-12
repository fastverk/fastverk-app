// IntegrationsClient — the connections/integrations surface. `GET /api/integrations`
// returns the catalog + this user's per-provider status (the web renders it as a
// meridian GalleryPanel; on iOS it's a native card grid). Each card's `href` is a
// connect entry point (`/api/connect/<id>`) that 302s into the provider's OAuth
// flow — opened in an in-app Safari so the browser session (cookie) carries it.
//
// This is the reserved "integrations" shell surface (not a `/api/gw` plugin), and
// it's what lets a user connect GitHub — the connection the agents plugin needs
// before Dispatch/Cancel (the gateway injects X-Fastverk-Github-Token from it).

import Foundation

/// One connectable service (a row of `/api/integrations`).
struct Integration: Codable, Identifiable {
    let id: String
    let name: String
    let blurb: String
    let icon: String       // a key ("github"/"gitlab"/…), NOT a URL
    let status: String     // "connected" | ""
    let href: String       // "/api/connect/<id>"
    let actionLabel: String // "Connect" | "Manage"

    enum CodingKeys: String, CodingKey {
        case id, name, blurb, icon, status, href
        case actionLabel = "action_label"
    }

    var isConnected: Bool { status == "connected" }
}

struct IntegrationsClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    func list() async throws -> [Integration] {
        let data = try await get("/api/integrations")
        struct Resp: Decodable { let integrations: [Integration]? }
        return (try JSONDecoder().decode(Resp.self, from: data)).integrations ?? []
    }

    /// The absolute connect URL for a card (`/api/connect/<id>` resolved against
    /// the app origin) — opened in SFSafariViewController.
    func connectURL(for integration: Integration) -> URL? {
        URL(string: integration.href, relativeTo: base)?.absoluteURL
    }

    // MARK: - Transport

    private func get(_ path: String, retryOn401: Bool = true) async throws -> Data {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = path
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await get(path, retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSEError.transport(body.isEmpty ? "Integrations request failed (HTTP \(code))." : body)
        }
        return data
    }
}
