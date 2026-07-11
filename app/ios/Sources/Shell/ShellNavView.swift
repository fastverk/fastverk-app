// ShellNavView — the top-level console: a sidebar built from the server NavTree
// and a detail pane rendering the selected panel. NavigationSplitView adapts on
// its own (two columns on iPad / regular width, a push stack on iPhone), so the
// same tree drives both. Each root is a plugin section; a leaf's owning plugin
// is its ancestor root's id (used to route the panel's RPCs).

import SwiftUI
import MeridianUI

struct ShellNavView: View {
    @StateObject private var model: AppModel
    @EnvironmentObject private var auth: AuthService
    @State private var selection: PanelRef?

    init(auth: AuthService) {
        _model = StateObject(wrappedValue: AppModel(auth: auth))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("fastverk")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    }
                }
        } detail: {
            if let selection {
                PanelHostView(model: model, ref: selection)
            } else {
                ContentUnavailableView(
                    "Select a panel",
                    systemImage: "sidebar.left",
                    description: Text("Pick a section from the sidebar.")
                )
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load the console", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        case let .ready(tree):
            List(selection: $selection) {
                ForEach(tree.roots) { root in
                    section(for: root)
                }
            }
        }
    }

    /// A top-level root: a section of leaves (plugin with its own nav) or, when
    /// it's a flat leaf itself (a built-in / LayoutService-less plugin), a single
    /// selectable row.
    @ViewBuilder
    private func section(for root: NavNode) -> some View {
        if root.isLeaf {
            leafRow(root, plugin: root.id)
        } else {
            Section(root.label) {
                ForEach(root.children ?? []) { child in
                    node(child, plugin: root.id)
                }
            }
        }
    }

    /// A nav node within a plugin section: a leaf row or a nested disclosure.
    @ViewBuilder
    private func node(_ node: NavNode, plugin: String) -> some View {
        if node.isLeaf {
            leafRow(node, plugin: plugin)
        } else {
            DisclosureGroup(isExpanded: .constant(node.defaultOpen ?? true)) {
                ForEach(node.children ?? []) { child in
                    self.node(child, plugin: plugin)
                }
            } label: {
                Label(node.label, systemImage: node.icon ?? "folder")
            }
        }
    }

    private func leafRow(_ node: NavNode, plugin: String) -> some View {
        Label(node.label, systemImage: node.icon ?? "doc.text")
            .badge(node.badge.flatMap { $0.isEmpty ? nil : Text($0) })
            .tag(PanelRef(plugin: plugin, panelId: node.panelId ?? node.id, title: node.label))
    }
}
