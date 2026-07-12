// ShellNavView — the top-level console: a sidebar of plugin sections (each a
// plugin's static-bundle panels) and a detail pane rendering the selected panel.
// NavigationSplitView adapts on its own (two columns on iPad / a push stack on
// iPhone). A leaf's plugin is its section's plugin (used to route the panel's RPCs).

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
            ProgressView("Loading the console…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load the console", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        case let .ready(sections):
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.panels) { panel in
                            let title = panel.title.isEmpty ? panel.panelID : panel.title
                            Label(title, systemImage: "tablecells")
                                .tag(PanelRef(plugin: section.plugin, panelId: panel.panelID, title: title))
                        }
                    }
                }
            }
        }
    }
}
