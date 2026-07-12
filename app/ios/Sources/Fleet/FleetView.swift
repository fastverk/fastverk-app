// FleetView — the fleet dashboard (Phase D): the coordination control plane on a
// phone. A segmented picker over the four fleet CR lists (agents / tasks / builds
// / prompts), each poll-loaded from `/api/gw/fleet/…`. Agent and build rows drill
// into the live transcript (TranscriptView, Phase B). This is the read/observe
// side of the fleet; the `agents` plugin surface (AgentsView) is the write side
// (dispatch/cancel). The two are distinct backends — a fleet Agent CR name is the
// transcript key, not an AgentRun.id.

import SwiftUI

enum FleetTab: String, CaseIterable, Identifiable {
    case agents = "Agents"
    case tasks = "Tasks"
    case builds = "Builds"
    case prompts = "Prompts"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .agents: return "cpu"
        case .tasks: return "list.bullet.indent"
        case .builds: return "hammer"
        case .prompts: return "questionmark.bubble"
        }
    }
}

@MainActor
final class FleetModel: ObservableObject {
    enum Phase<T> {
        case loading
        case ready([T])
        case failed(String)
    }

    @Published var agents: Phase<FleetAgent> = .loading
    @Published var tasks: Phase<FleetTask> = .loading
    @Published var builds: Phase<FleetBuild> = .loading
    @Published var prompts: Phase<FleetPrompt> = .loading

    private let client: FleetClient

    init(auth: AuthService) {
        self.client = FleetClient(base: Config.appOrigin, auth: auth)
    }

    /// Load the active tab (lazy: each tab fetches on first appearance / refresh).
    func load(_ tab: FleetTab) async {
        switch tab {
        case .agents:
            do { agents = .ready(try await client.agents()) } catch { agents = .failed("\(error)") }
        case .tasks:
            do { tasks = .ready(try await client.tasks()) } catch { tasks = .failed("\(error)") }
        case .builds:
            do { builds = .ready(try await client.builds()) } catch { builds = .failed("\(error)") }
        case .prompts:
            do { prompts = .ready(try await client.prompts()) } catch { prompts = .failed("\(error)") }
        }
    }
}

struct FleetView: View {
    let auth: AuthService
    @StateObject private var model: FleetModel
    @State private var tab: FleetTab = .agents

    init(auth: AuthService) {
        self.auth = auth
        _model = StateObject(wrappedValue: FleetModel(auth: auth))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(FleetTab.allCases) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                tabContent
            }
            .navigationTitle("Fleet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: tab) { await model.load(tab) }
            .refreshable { await model.load(tab) }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .agents:
            phaseList(model.agents, empty: "No agents in the fleet.") { agent in
                NavigationLink {
                    TranscriptView(auth: auth, kind: "agent", name: agent.name)
                } label: {
                    FleetRow(title: agent.name, phase: agent.phase, subtitle: agent.focus, timestamp: agent.updatedAt)
                }
            }
        case .tasks:
            phaseList(model.tasks, empty: "No tasks.") { task in
                FleetRow(
                    title: task.title.isEmpty ? task.name : task.title,
                    phase: task.phase,
                    subtitle: task.agent.isEmpty ? task.name : "agent: \(task.agent)",
                    timestamp: task.createdAt
                )
            }
        case .builds:
            phaseList(model.builds, empty: "No builds.") { build in
                NavigationLink {
                    TranscriptView(auth: auth, kind: "build", name: build.name)
                } label: {
                    FleetRow(title: build.repo.isEmpty ? build.name : build.repo, phase: build.phase, subtitle: build.name, timestamp: build.updatedAt)
                }
            }
        case .prompts:
            phaseList(model.prompts, empty: "No open prompts.") { prompt in
                FleetRow(title: prompt.question.isEmpty ? prompt.name : prompt.question, phase: prompt.phase, subtitle: prompt.name, timestamp: "")
            }
        }
    }

    @ViewBuilder
    private func phaseList<T: Identifiable, Row: View>(
        _ phase: FleetModel.Phase<T>,
        empty: String,
        @ViewBuilder row: @escaping (T) -> Row
    ) -> some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case let .ready(items) where items.isEmpty:
            ContentUnavailableView(empty, systemImage: "tray")
        case let .ready(items):
            List(items) { row($0) }
                .listStyle(.plain)
        }
    }
}

/// One fleet CR row: a title, a phase badge, an optional status line + timestamp.
private struct FleetRow: View {
    let title: String
    let phase: String
    let subtitle: String
    let timestamp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                PhaseBadge(phase: phase)
            }
            if !subtitle.isEmpty || !timestamp.isEmpty {
                HStack(spacing: 6) {
                    if !subtitle.isEmpty { Text(subtitle).lineLimit(1) }
                    if !subtitle.isEmpty, !timestamp.isEmpty { Text("·") }
                    if !timestamp.isEmpty { Text(timestamp).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A phase pill, colored by lifecycle stage across Agent/AgentTask/BuildRun.
private struct PhaseBadge: View {
    let phase: String

    var body: some View {
        Text(phase)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch phase.lowercased() {
        case "running", "working", "dispatched": return .blue
        case "suspended", "handedoff", "pending", "unknown": return .orange
        case "propened", "reviewrequired", "review_required": return .purple
        case "merged", "succeeded", "success", "ready": return .green
        case "failed", "error", "cancelled": return .red
        default: return .secondary
        }
    }
}
