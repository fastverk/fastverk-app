// fastverk Dashboard — a native SwiftUI window that renders meridian panels
// (Repos / Volumes / Worktrees / Connections / Maintenance) backed by the fvd
// daemon. Spawned by the menu-bar tray ("Dashboard…"); a peer gRPC client
// alongside the egui settings window, not embedded in it.
//
// It loads the compiled panel bundle, decodes it with the meridian Swift
// renderer (MeridianUI), and drives it with a ProcessRpcInvoker that shells
// out to the fvd-json shim.

import SwiftUI
import MeridianUI

@main
struct DashboardApp: App {
    @StateObject private var root = RootModel()

    var body: some Scene {
        WindowGroup("fastverk Dashboard") {
            RootView(model: root)
                .frame(minWidth: 760, minHeight: 440)
        }
    }
}

@MainActor
final class RootModel: ObservableObject {
    enum Phase {
        case loading
        case ready(PanelState)
        case failed(String)
    }

    @Published var phase: Phase = .loading

    init() {
        load()
    }

    func load() {
        do {
            let data = try Loader.panelBundleData()
            let bundle = try BundleLoader.decode(data)
            guard let invoker = ProcessRpcInvoker.locate() else {
                phase = .failed(
                    "Couldn't find the fvd-json helper. Run from the app bundle, "
                        + "or set $FASTVERK_FVD_JSON to its path."
                )
                return
            }
            phase = .ready(PanelState(panels: bundle.panels, invoker: invoker))
        } catch {
            phase = .failed("\(error)")
        }
    }
}

struct RootView: View {
    @ObservedObject var model: RootModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(state):
            PanelContainerView(state: state)
        case let .failed(message):
            ContentUnavailableView(
                "Dashboard unavailable",
                systemImage: "xmark.octagon",
                description: Text(message)
            )
        }
    }
}

/// Locates the compiled panel bundle: an explicit `$FASTVERK_PANELS` override
/// (for `bazel run`), else `panels.binpb` in the .app's Resources.
enum Loader {
    static func panelBundleData() throws -> Data {
        if let override = ProcessInfo.processInfo.environment["FASTVERK_PANELS"],
           !override.isEmpty {
            return try Data(contentsOf: URL(fileURLWithPath: override))
        }
        if let url = Bundle.main.url(forResource: "panels", withExtension: "binpb") {
            return try Data(contentsOf: url)
        }
        throw DashboardError.bundleMissing
    }
}

enum DashboardError: Error, CustomStringConvertible {
    case bundleMissing
    var description: String {
        "panels.binpb not found — set $FASTVERK_PANELS, or bundle it in Resources."
    }
}
