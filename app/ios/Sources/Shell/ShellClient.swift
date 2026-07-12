// ShellClient — the HTTP surface of the cloud console the iOS host consumes.
//
// Panels come from each plugin's STATIC bundle (`/api/gw/<plugin>/panels.binpb`),
// composed client-side exactly like the web's `loadPluginSection` — NOT from the
// server-driven `/api/shell/panel` (LayoutService.GetPanel), which 404s
// ("no gRPC LayoutService") because no plugin implements that optional tier yet.
// `/api/shell` is used only for the section order + entitlement gating. All calls
// carry the Cognito Bearer id_token; codes are mapped per shell.rs / gateway.rs.

import Foundation
import MeridianUI

enum ShellError: Error, CustomStringConvertible {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case backend(String)
    case decode(String)

    var description: String {
        switch self {
        case .unauthorized: return "Session expired — sign in again."
        case let .forbidden(m): return m
        case let .notFound(m): return m
        case let .backend(m): return m
        case let .decode(m): return "Malformed response: \(m)"
        }
    }
}

/// A plugin's describe manifest, reduced to what the console needs.
struct PluginManifest: Sendable {
    var displayName: String
    var routes: [(key: String, route: Route)]
}

struct ShellClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    // MARK: - Endpoints

    /// The server-driven nav — used for the section order + which plugins the
    /// caller is entitled to. Panels themselves come from the static bundles.
    func fetchShell() async throws -> NavTree {
        let data = try await get(path: "/api/shell", accept: "application/json")
        do {
            return try JSONDecoder().decode(NavTree.self, from: data)
        } catch {
            throw ShellError.decode("\(error)")
        }
    }

    /// The boot-time plugin set (fallback ordering when /api/shell is unavailable).
    func fetchPlugins() async throws -> [String] {
        let data = try await get(path: "/api/plugins", accept: "application/json")
        let json = try JSONValue.parse(data)
        return json["plugins"].asArray?.compactMap { $0.asString } ?? []
    }

    /// A plugin's static PanelBundle (`/api/gw/<plugin>/panels.binpb`) — the same
    /// serialized meridian.ui.v1.PanelBundle the web decodes, consumed by the
    /// existing `BundleLoader`.
    func pluginBundle(plugin: String) async throws -> PanelBundle {
        let data = try await get(path: "/api/gw/\(plugin)/panels.binpb", accept: "application/octet-stream")
        do {
            return try BundleLoader.decode(data)
        } catch {
            throw ShellError.decode("\(error)")
        }
    }

    /// A plugin's describe manifest: its display name + the (service/method) ->
    /// gateway-route table the NetworkRpcInvoker uses (mirrors main.js
    /// registerRoutes). Shape verified live: `{ manifest: { display_name,
    /// web_routes: [{service, method, path, http_method}] } }`.
    func manifest(plugin: String) async throws -> PluginManifest {
        let data = try await get(path: "/api/gw/\(plugin)/describe", accept: "application/json")
        let json = try JSONValue.parse(data)
        let manifest = json["manifest"]
        let displayName = manifest["display_name"].asString ?? plugin

        let list: [JSONValue]
        if case let .array(a) = manifest["web_routes"] { list = a }
        else if case let .array(a) = json["web_routes"] { list = a }
        else { list = [] }

        let routes: [(key: String, route: Route)] = list.compactMap { entry in
            guard let service = entry["service"].asString,
                  let method = entry["method"].asString,
                  let path = entry["path"].asString else { return nil }
            let verb = entry["http_method"].asString
                ?? entry["httpMethod"].asString
                ?? entry["verb"].asString
                ?? "GET"
            return (key: "\(service)/\(method)", route: Route(verb: verb, rest: path))
        }
        return PluginManifest(displayName: displayName, routes: routes)
    }

    // MARK: - Transport

    private func get(path: String, accept: String, retryOn401: Bool = true) async throws -> Data {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = path
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return data
        case 401 where retryOn401:
            _ = try await auth.refreshedIdToken()
            return try await get(path: path, accept: accept, retryOn401: false)
        case 401:
            throw ShellError.unauthorized
        case 403:
            throw ShellError.forbidden(message(data) ?? "Not entitled.")
        case 404:
            throw ShellError.notFound(message(data) ?? "Not available for this plugin.")
        default:
            throw ShellError.backend(message(data) ?? "Backend error (HTTP \(code)).")
        }
    }

    private func message(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
