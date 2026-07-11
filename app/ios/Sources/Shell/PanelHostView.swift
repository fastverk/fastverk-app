// PanelHostView — fetches one panel's bundle from the cloud, wraps it in a
// PanelState driven by a per-plugin NetworkRpcInvoker, and renders it with the
// shared meridian PanelBodyView. Reloads whenever the selected leaf changes.

import SwiftUI
import MeridianUI

struct PanelHostView: View {
    let model: AppModel
    let ref: PanelRef

    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case ready(PanelState)
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle(ref.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: ref) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(state):
            if let panel = state.panels.first {
                PanelBodyView(state: state, panel: panel)
            } else {
                ContentUnavailableView("Empty panel", systemImage: "tray")
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load panel", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            let bundle = try await model.fetchPanel(plugin: ref.plugin, panelId: ref.panelId)
            let invoker = model.invoker(for: ref.plugin)
            phase = .ready(PanelState(panels: bundle.panels, invoker: invoker))
        } catch {
            phase = .failed("\(error)")
        }
    }
}
