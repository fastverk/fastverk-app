// AppModel — the authenticated console session. Loads the server-driven nav +
// the plugin route table once, then vends a per-plugin NetworkRpcInvoker and
// fetches per-panel bundles on demand. The iOS analog of the macOS Dashboard's
// RootModel, but cloud-backed.

import Foundation
import MeridianUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case loading
        case ready(NavTree)
        case failed(String)
    }

    @Published var phase: Phase = .loading

    let auth: AuthService
    private let client: ShellClient
    private var routes: RouteTable = [:]

    init(auth: AuthService) {
        self.auth = auth
        self.client = ShellClient(base: Config.appOrigin, auth: auth)
    }

    /// Load the nav tree and the route table together. A whole-console failure
    /// (nav unreachable / unauthorized) surfaces as `.failed`; individual plugin
    /// route failures are swallowed inside `fetchRoutes`.
    func load() async {
        phase = .loading
        do {
            async let navTree = client.fetchShell()
            let plugins = try await client.fetchPlugins()
            routes = try await client.fetchRoutes(plugins: plugins)
            phase = .ready(try await navTree)
        } catch {
            phase = .failed("\(error)")
        }
    }

    func invoker(for plugin: String) -> NetworkRpcInvoker {
        NetworkRpcInvoker(base: Config.appOrigin, plugin: plugin, routes: routes, auth: auth)
    }

    func fetchPanel(plugin: String, panelId: String) async throws -> PanelBundle {
        try await client.fetchPanelBundle(plugin: plugin, panelId: panelId)
    }
}

/// A selected nav leaf: the panel to render plus the plugin that owns it (the
/// ancestor root's id — which gateway to route this panel's RPCs through).
struct PanelRef: Hashable {
    let plugin: String
    let panelId: String
    let title: String
}
