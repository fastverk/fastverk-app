// ShellClient — the HTTP surface of the cloud console the iOS host consumes:
// the server-driven nav (`/api/shell`), per-panel bundles (`/api/shell/panel`),
// and the plugin route table (`/api/plugins` + each `/api/gw/<id>/describe`).
// All calls carry the Cognito Bearer id_token; codes are mapped per shell.rs.

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

struct ShellClient: Sendable {
    let base: URL
    let auth: AuthService
    var session: URLSession = .shared

    // MARK: - Endpoints

    func fetchShell() async throws -> NavTree {
        let data = try await get(path: "/api/shell", accept: "application/json")
        do {
            return try JSONDecoder().decode(NavTree.self, from: data)
        } catch {
            throw ShellError.decode("\(error)")
        }
    }

    /// A single panel resolved server-side (LayoutService.GetPanel), returned as
    /// a serialized meridian.ui.v1.PanelBundle — the exact bytes BundleLoader
    /// already decodes.
    func fetchPanelBundle(plugin: String, panelId: String) async throws -> PanelBundle {
        let data = try await get(
            path: "/api/shell/panel/\(plugin)/\(panelId)",
            accept: "application/octet-stream"
        )
        do {
            return try BundleLoader.decode(data)
        } catch {
            throw ShellError.decode("\(error)")
        }
    }

    func fetchPlugins() async throws -> [String] {
        let data = try await get(path: "/api/plugins", accept: "application/json")
        let json = try JSONValue.parse(data)
        return json["plugins"].asArray?.compactMap { $0.asString } ?? []
    }

    /// Build the (service/method) -> Route table from every plugin's describe
    /// manifest (mirrors main.js registerRoutes). Per-plugin failures are
    /// tolerated — an unreachable plugin just contributes no routes.
    func fetchRoutes(plugins: [String]) async throws -> RouteTable {
        var table: RouteTable = [:]
        await withTaskGroup(of: [(String, Route)].self) { group in
            for plugin in plugins {
                group.addTask { (try? await routes(for: plugin)) ?? [] }
            }
            for await entries in group {
                for (key, route) in entries { table[key] = route }
            }
        }
        return table
    }

    // MARK: - Route manifest parsing

    // NOTE: verify the describe manifest shape against a live response — the web
    // reads `manifest.web_routes: [{service, method, path, http_method}]`. We
    // parse defensively (top-level or nested, snake/camel verb key).
    private func routes(for plugin: String) async throws -> [(String, Route)] {
        let data = try await get(path: "/api/gw/\(plugin)/describe", accept: "application/json")
        let json = try JSONValue.parse(data)
        let list: [JSONValue]
        if case let .array(a) = json["manifest"]["web_routes"] { list = a }
        else if case let .array(a) = json["web_routes"] { list = a }
        else { list = [] }

        return list.compactMap { entry in
            guard let service = entry["service"].asString,
                  let method = entry["method"].asString,
                  let path = entry["path"].asString else { return nil }
            let verb = entry["http_method"].asString
                ?? entry["httpMethod"].asString
                ?? entry["verb"].asString
                ?? "GET"
            return ("\(service)/\(method)", Route(verb: verb, rest: path))
        }
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
