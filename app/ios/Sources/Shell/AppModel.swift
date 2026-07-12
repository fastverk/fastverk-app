// AppModel — the authenticated console session. Composes the console the same
// way the web does for plugins without a gRPC LayoutService (all of them today):
// for each entitled plugin it loads the static PanelBundle
// (`/api/gw/<plugin>/panels.binpb`) + describe manifest, and renders those panels
// directly (no per-panel `/api/shell/panel` fetch, which 404s). The iOS analog of
// the macOS Dashboard's RootModel, cloud-backed.

import Foundation
import MeridianUI

/// One rail section: a plugin and the panels from its static bundle.
struct ConsoleSection: Identifiable {
    let plugin: String
    let title: String
    let panels: [PanelDescriptor]
    var id: String { plugin }
}

/// A selected panel: which panel to render + the plugin whose gateway its RPCs
/// route through.
struct PanelRef: Hashable {
    let plugin: String
    let panelId: String
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case loading
        case ready([ConsoleSection])
        case failed(String)
    }

    @Published var phase: Phase = .loading

    let auth: AuthService
    private let client: ShellClient
    private var routes: RouteTable = [:]
    private var descriptors: [String: PanelDescriptor] = [:] // "plugin/panelId" -> descriptor

    // Shell-owned built-ins that aren't plugin gateway sections (they need bespoke
    // native views — integrations gallery, fleet, access-keys form — not built yet).
    private static let reserved: Set<String> = ["integrations", "fleet", "access_keys"]

    init(auth: AuthService) {
        self.auth = auth
        self.client = ShellClient(base: Config.appOrigin, auth: auth)
    }

    func load() async {
        phase = .loading
        routes = [:]
        descriptors = [:]
        do {
            let pluginIds = try await pluginOrder()
            var sections: [ConsoleSection] = []
            for id in pluginIds {
                if let section = await loadSection(id) { sections.append(section) }
            }
            phase = sections.isEmpty
                ? .failed("No panels are available for your account.")
                : .ready(sections)
        } catch {
            phase = .failed("\(error)")
        }
    }

    /// The plugin section order: from `/api/shell` (server order + entitlement,
    /// reserved built-ins dropped), falling back to `/api/plugins`.
    private func pluginOrder() async throws -> [String] {
        if let tree = try? await client.fetchShell() {
            let ids = tree.roots.map(\.id).filter { !Self.reserved.contains($0) }
            if !ids.isEmpty { return ids }
        }
        return try await client.fetchPlugins().filter { !Self.reserved.contains($0) }
    }

    /// Load one plugin's section — its describe (title + gateway routes) and static
    /// PanelBundle. A plugin that's unreachable or serves no panels is dropped
    /// (nil), like the web filters a failed section.
    private func loadSection(_ id: String) async -> ConsoleSection? {
        let manifest = try? await client.manifest(plugin: id)
        for entry in manifest?.routes ?? [] { routes[entry.key] = entry.route }
        guard let bundle = try? await client.pluginBundle(plugin: id), !bundle.panels.isEmpty else {
            return nil
        }
        for panel in bundle.panels { descriptors["\(id)/\(panel.panelID)"] = panel }
        return ConsoleSection(plugin: id, title: manifest?.displayName ?? id, panels: bundle.panels)
    }

    func invoker(for plugin: String) -> NetworkRpcInvoker {
        NetworkRpcInvoker(base: Config.appOrigin, plugin: plugin, routes: routes, auth: auth)
    }

    /// A PanelState for a selected panel, from the already-loaded descriptor.
    func panelState(for ref: PanelRef) -> PanelState? {
        guard let descriptor = descriptors["\(ref.plugin)/\(ref.panelId)"] else { return nil }
        return PanelState(panels: [descriptor], invoker: invoker(for: ref.plugin))
    }
}
