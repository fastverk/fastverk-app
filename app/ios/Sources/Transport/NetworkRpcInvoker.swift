// NetworkRpcInvoker — the iOS RpcInvoker. Where the macOS Dashboard shells out
// to fvd-json, this maps a meridian (service, method) call to the botnoc-web
// gateway (`/api/gw/<plugin>/<path>`) over HTTPS with a Bearer id_token. It is
// the native twin of the web's makeInvoker/endpointFor (botnoc web/static/assets
// /main.js): the route table is assembled from each plugin's /describe manifest.

import Foundation
import MeridianUI

/// One resolved gateway route: the HTTP verb + the path under /api/gw/<plugin>/.
struct Route: Sendable {
    let verb: String
    let rest: String
}

/// (service/method) -> Route, built from the plugins' web_routes manifests.
typealias RouteTable = [String: Route]

struct NetworkRpcInvoker: RpcInvoker {
    let base: URL          // https://app.fastverk.com
    let plugin: String
    let routes: RouteTable
    let auth: AuthService
    var session: URLSession = .shared

    func invoke(service: String, method: String, request: JSONValue) async throws -> JSONValue {
        guard let route = routes["\(service)/\(method)"] else {
            throw RpcError.unknownMethod(service: service, method: method)
        }
        return try await send(route: route, request: request, retryOn401: true)
    }

    private func send(route: Route, request: JSONValue, retryOn401: Bool) async throws -> JSONValue {
        let verb = route.verb.uppercased()
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let rest = route.rest.hasPrefix("/") ? String(route.rest.dropFirst()) : route.rest
        comps.path = "/api/gw/\(plugin)/\(rest)"

        let params = topLevelParams(request)
        if verb == "GET", !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = verb
        req.setValue("Bearer \(try await auth.validIdToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if verb != "GET", !params.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data((try request.serialized()).utf8)
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if code == 401, retryOn401 {
            _ = try await auth.refreshedIdToken()
            return try await send(route: route, request: request, retryOn401: false)
        }
        guard (200..<300).contains(code) else {
            throw RpcError.transport(errorMessage(data, status: code))
        }
        return try JSONValue.parse(data)
    }

    /// Flatten a request object's top-level scalar fields to query params (for
    /// the GET-populate case the gateway drops a body on). Nested/array values
    /// are JSON-encoded so nothing is silently lost.
    private func topLevelParams(_ request: JSONValue) -> [(key: String, value: String)] {
        guard case let .object(map) = request else { return [] }
        return map.compactMap { key, value in
            switch value {
            case .null: return nil
            case let .string(s): return (key, s)
            case let .bool(b): return (key, b ? "true" : "false")
            case let .number(n): return (key, n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n))
            case .array, .object: return (key, (try? value.serialized()) ?? "")
            }
        }
    }

    private func errorMessage(_ data: Data, status: Int) -> String {
        if let parsed = try? JSONValue.parse(data), case let .string(m) = parsed["error"] {
            return m
        }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "HTTP \(status)" : body
    }
}
