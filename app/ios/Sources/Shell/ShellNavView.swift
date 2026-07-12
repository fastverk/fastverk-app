// ShellNavView — the top-level console. A sidebar with a pinned "Console" section
// (the native cross-cutting surfaces: Assistant chat + Fleet) above the plugin
// sections (each a plugin's static-bundle panels). The detail pane renders the
// selection: a meridian panel, the chat, or the fleet dashboard.
// NavigationSplitView adapts on its own (two columns on iPad / a push stack on
// iPhone). The Console section is always present, even while plugin sections load.

import SwiftUI
import MeridianUI

/// What the sidebar selection points at: a plugin panel, or a native surface.
enum Sidebar: Hashable {
    case panel(PanelRef)
    case assistant
    case fleet
}

struct ShellNavView: View {
    @StateObject private var model: AppModel
    @EnvironmentObject private var auth: AuthService
    // Start on the sidebar (nil) so iPhone doesn't launch pushed into a detail;
    // iPad shows the "select a section" placeholder until the user picks one.
    @State private var selection: Sidebar?

    init(auth: AuthService) {
        _model = StateObject(wrappedValue: AppModel(auth: auth))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Console") {
                    Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                        .tag(Sidebar.assistant)
                    Label("Fleet", systemImage: "point.3.connected.trianglepath.dotted")
                        .tag(Sidebar.fleet)
                }
                pluginSections
            }
            .navigationTitle("fastverk")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sign out", role: .destructive) { auth.signOut() }
                }
            }
        } detail: {
            detail
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .assistant:
            AssistantView(auth: auth)
        case .fleet:
            FleetView(auth: auth)
        case let .panel(ref):
            PanelHostView(model: model, ref: ref)
        case nil:
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left",
                description: Text("Pick a section from the sidebar.")
            )
        }
    }

    @ViewBuilder
    private var pluginSections: some View {
        switch model.phase {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading sections…").foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await model.load() } }
            }
        case let .ready(sections):
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.panels) { panel in
                        let title = panel.title.isEmpty ? panel.panelID : panel.title
                        Label(title, systemImage: "tablecells")
                            .tag(Sidebar.panel(PanelRef(plugin: section.plugin, panelId: panel.panelID, title: title)))
                    }
                }
            }
        }
    }
}
