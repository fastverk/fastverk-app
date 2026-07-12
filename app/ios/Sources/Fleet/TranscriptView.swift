// TranscriptView — the live agent/build transcript (Phase B). Streams the fleet
// SSE, decodes each frame, and appends it (never mutates in place — the web's
// fleet.js does the same; JetStream sequence + Last-Event-ID handle replay/resume
// at the transport). On a dropped connection it reconnects with the last seen
// event id, tailing from where it left off; a terminal `result` frame ends it.

import SwiftUI

enum TranscriptConnState: Equatable {
    case connecting
    case live
    case reconnecting
    case ended
    case failed(String)
}

/// One appended frame with a stable identity for the list.
struct TranscriptEntry: Identifiable {
    let id: Int
    let frame: TranscriptFrame
}

@MainActor
final class TranscriptModel: ObservableObject {
    @Published var entries: [TranscriptEntry] = []
    @Published var state: TranscriptConnState = .connecting

    let kind: String
    let name: String
    private let client: FleetClient
    private var streamTask: Task<Void, Never>?
    private var nextID = 0
    private var lastEventID: String?
    private var terminated = false

    init(auth: AuthService, kind: String, name: String) {
        self.client = FleetClient(base: Config.appOrigin, auth: auth)
        self.kind = kind
        self.name = name
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func runLoop() async {
        var backoff: UInt64 = 500_000_000 // 0.5s, capped at 5s
        while !Task.isCancelled && !terminated {
            state = entries.isEmpty ? .connecting : .reconnecting
            do {
                for try await event in client.transcript(kind: kind, name: name, lastEventID: lastEventID) {
                    if Task.isCancelled { return }
                    state = .live
                    backoff = 500_000_000
                    if let id = event.id { lastEventID = id }
                    if event.event == "error" {
                        append(.raw("⚠️ \(event.data)"))
                        continue
                    }
                    let frame = TranscriptFrame.decode(event.data, isJSON: kind == "agent")
                    append(frame)
                    if case .result = frame { terminated = true }
                }
            } catch is CancellationError {
                return
            } catch {
                state = .failed("\(error)")
                return
            }
            if terminated { break }
            // The server closed the stream without a terminal frame (e.g. a dropped
            // connection). Back off, then reconnect resuming after lastEventID.
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 5_000_000_000)
        }
        if terminated { state = .ended }
    }

    private func append(_ frame: TranscriptFrame) {
        entries.append(TranscriptEntry(id: nextID, frame: frame))
        nextID += 1
    }
}

struct TranscriptView: View {
    @StateObject private var model: TranscriptModel

    init(auth: AuthService, kind: String, name: String) {
        _model = StateObject(wrappedValue: TranscriptModel(auth: auth, kind: kind, name: name))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.entries.isEmpty, model.state == .connecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting to the live transcript…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    }
                    ForEach(model.entries) { entry in
                        TranscriptFrameView(frame: entry.frame)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding()
            }
            .onChange(of: model.entries.count) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
        .navigationTitle(model.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { TranscriptStatusView(state: model.state) }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private let bottomAnchor = "transcript-bottom"
}

private struct TranscriptStatusView: View {
    let state: TranscriptConnState

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .connecting, .reconnecting:
                ProgressView().controlSize(.small)
                Text(state == .connecting ? "Connecting" : "Reconnecting").font(.caption)
            case .live:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Live").font(.caption)
            case .ended:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Finished").font(.caption)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text("Disconnected").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Frame rendering

private struct TranscriptFrameView: View {
    let frame: TranscriptFrame

    var body: some View {
        switch frame {
        case let .system(subtype):
            Label(subtype.isEmpty ? "system" : subtype, systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .assistant(blocks):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { AssistantBlockView(block: $0) }
            }
        case let .toolResults(results):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results) { ToolResultView(result: $0) }
            }
        case let .result(result):
            ResultFrameView(result: result)
        case let .raw(text):
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct AssistantBlockView: View {
    let block: AssistantBlock

    var body: some View {
        switch block {
        case let .text(text):
            MarkdownText(text: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .toolUse(name, input):
            VStack(alignment: .leading, spacing: 4) {
                Label(name, systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                if !input.isEmpty, input != "{}" {
                    Text(input)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case let .other(json):
            Text(json).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

private struct ToolResultView: View {
    let result: ToolResult
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(String(result.content.prefix(4000)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Result", systemImage: "arrow.turn.down.right").font(.caption)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ResultFrameView: View {
    let result: TranscriptResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.subtype == "success" ? "checkmark.seal.fill" : "flag.checkered")
                .foregroundStyle(result.subtype == "success" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.subtype.isEmpty ? "Done" : result.subtype.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        var parts: [String] = []
        if let cost = result.costUSD { parts.append(String(format: "$%.4f", cost)) }
        if let ms = result.durationMs { parts.append(String(format: "%.1fs", ms / 1000)) }
        if let inTok = result.inputTokens, let outTok = result.outputTokens {
            parts.append("\(inTok) in / \(outTok) out")
        }
        return parts.joined(separator: " · ")
    }
}
