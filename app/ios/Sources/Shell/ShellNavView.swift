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
                    if root.isLeaf {
                        // A built-in / LayoutService-less plugin: a single row.
                        NavNodeView(node: root, plugin: root.id)
                    } else {
                        // A plugin section: its own nav subtree.
                        Section(root.label) {
                            ForEach(root.children ?? []) { child in
                                NavNodeView(node: child, plugin: root.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One nav node within a plugin section — a selectable leaf row or a nested
/// disclosure. A dedicated `View` struct (not a recursive `@ViewBuilder`
/// function) so the recursion is over a named type, which the compiler allows;
/// a recursive function returning `some View` would define its opaque type in
/// terms of itself and fail to compile.
struct NavNodeView: View {
    let node: NavNode
    let plugin: String
    @State private var expanded: Bool

    init(node: NavNode, plugin: String) {
        self.node = node
        self.plugin = plugin
        _expanded = State(initialValue: node.defaultOpen ?? true)
    }

    var body: some View {
        if node.isLeaf {
            Label(node.label, systemImage: node.icon ?? "doc.text")
                .badge(node.badge.flatMap { $0.isEmpty ? nil : Text($0) })
                .tag(PanelRef(plugin: plugin, panelId: node.panelId ?? node.id, title: node.label))
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children ?? []) { child in
                    NavNodeView(node: child, plugin: plugin)
                }
            } label: {
                Label(node.label, systemImage: node.icon ?? "folder")
            }
        }
    }
}
