// AgentsView — a native surface for the agents plugin: the active coding-agent
// runs (ListActive), per-row Cancel, and a Dispatch sheet. Replaces the generic
// meridian table for this one panel because the write side (Dispatch isn't a
// panel; Cancel is a bespoke {run_id} action) can't be expressed as descriptors.

import SwiftUI

@MainActor
final class AgentsModel: ObservableObject {
    enum Phase {
        case loading
        case ready([AgentRun])
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var actionError: String?

    private let client: AgentsClient

    init(auth: AuthService) {
        self.client = AgentsClient(base: Config.appOrigin, auth: auth)
    }

    func load() async {
        do { phase = .ready(try await client.listActive()) }
        catch { phase = .failed("\(error)") }
    }

    func dispatch(issueRef: String, backend: AgentBackendOption) async -> Bool {
        actionError = nil
        do {
            try await client.dispatch(issueRef: issueRef, backend: backend)
            await load()
            return true
        } catch {
            actionError = "\(error)"
            return false
        }
    }

    func cancel(_ run: AgentRun) async {
        actionError = nil
        do { try await client.cancel(runId: run.id); await load() }
        catch { actionError = "\(error)" }
    }
}

struct AgentsView: View {
    @StateObject private var model: AgentsModel
    @State private var showDispatch = false

    init(auth: AuthService) {
        _model = StateObject(wrappedValue: AgentsModel(auth: auth))
    }

    var body: some View {
        content
            .navigationTitle("Agents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showDispatch = true } label: { Label("Dispatch", systemImage: "plus") }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .sheet(isPresented: $showDispatch) { DispatchSheet(model: model) }
            .alert(
                "Couldn't complete",
                isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
            ) {
                Button("OK", role: .cancel) { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        case let .ready(runs) where runs.isEmpty:
            ContentUnavailableView(
                "No agents in flight",
                systemImage: "sparkles",
                description: Text("Tap + to dispatch a coding agent to a GitHub issue.")
            )
        case let .ready(runs):
            List {
                ForEach(runs) { run in
                    AgentRunRow(run: run)
                        .swipeActions(edge: .trailing) {
                            if run.isActive {
                                Button(role: .destructive) {
                                    Task { await model.cancel(run) }
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
        }
    }
}

private struct AgentRunRow: View {
    let run: AgentRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.issueRef.isEmpty ? run.id : run.issueRef)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StateBadge(state: run.state)
            }
            HStack(spacing: 6) {
                Text(AgentBackendOption(rawValue: run.backend)?.label ?? run.backend)
                if let pr = run.prRef, !pr.isEmpty { Text("· \(pr)").lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct StateBadge: View {
    let state: String

    var body: some View {
        Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case "working", "dispatched": return .blue
        case "review_required": return .orange
        case "merged": return .green
        case "cancelled": return .gray
        case "failed": return .red
        default: return .secondary
        }
    }
}

private struct DispatchSheet: View {
    @ObservedObject var model: AgentsModel
    @Environment(\.dismiss) private var dismiss

    @State private var issueRef = ""
    @State private var backend: AgentBackendOption = .claude
    @State private var dispatching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Issue") {
                    TextField("owner/repo#123", text: $issueRef)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Backend") {
                    Picker("Backend", selection: $backend) {
                        ForEach(AgentBackendOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("Dispatch agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Dispatch") { Task { await dispatch() } }
                        .disabled(issueRef.trimmingCharacters(in: .whitespaces).isEmpty || dispatching)
                }
            }
        }
    }

    private func dispatch() async {
        dispatching = true
        defer { dispatching = false }
        let trimmed = issueRef.trimmingCharacters(in: .whitespaces)
        if await model.dispatch(issueRef: trimmed, backend: backend) { dismiss() }
    }
}
