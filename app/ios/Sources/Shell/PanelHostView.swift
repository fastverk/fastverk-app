// PanelHostView — renders the selected panel from its already-loaded descriptor
// (fetched with its plugin's static bundle in AppModel), driven by a per-plugin
// NetworkRpcInvoker, via the shared meridian PanelBodyView. The panel's own
// `populate` RPC runs when the body appears; no per-panel network fetch here.

import SwiftUI
import MeridianUI

struct PanelHostView: View {
    let model: AppModel
    let ref: PanelRef

    @State private var state: PanelState?

    var body: some View {
        // Bespoke native panels hook in here — surfaces whose interactions can't
        // be expressed as meridian descriptors. The agents panel is the first:
        // Dispatch isn't a panel and Cancel is a per-row {run_id} action.
        if ref.plugin == "agents", ref.panelId == "agents" {
            AgentsView(auth: model.auth)
        } else {
            content
                .navigationTitle(ref.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .task(id: ref) { state = model.panelState(for: ref) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let state, let panel = state.panels.first {
            PanelBodyView(state: state, panel: panel)
        } else {
            ContentUnavailableView(
                "Panel unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This panel couldn't be loaded.")
            )
        }
    }
}
