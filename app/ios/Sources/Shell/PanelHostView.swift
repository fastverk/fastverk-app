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
        content
            .navigationTitle(ref.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: ref) { state = model.panelState(for: ref) }
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
