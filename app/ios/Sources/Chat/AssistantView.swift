// AssistantView — the native console chat (Phase C). Subscribes to the chat.v1
// HostEvent stream and renders an ordered, blockId-keyed transcript (upsert, not
// append — a re-sent block replaces its predecessor, so tool cards flip
// RUNNING→OK/ERROR in place). A live `status` drives the busy spinner; a turn is
// sent with POST /turn and echoes back through the stream. Confirm-gated writes
// need no special UI: the host renders the preview as fields + a "reply yes"
// prompt, and the user just sends another turn.

import SwiftUI

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var blocks: [ChatBlock] = []
    @Published private(set) var status: ChatStatus = .idle
    @Published var sendError: String?
    @Published private(set) var streamDown = false

    private let client: ChatClient
    private var index: [String: Int] = [:]   // blockId -> position in `blocks`
    private var viewTask: Task<Void, Never>?

    init(auth: AuthService) {
        self.client = ChatClient(base: Config.appOrigin, auth: auth)
    }

    func connect() {
        guard viewTask == nil else { return }
        viewTask = Task { [weak self] in await self?.runView() }
    }

    func disconnect() {
        viewTask?.cancel()
        viewTask = nil
    }

    private func runView() async {
        while !Task.isCancelled {
            do {
                for try await event in client.view() {
                    if Task.isCancelled { return }
                    streamDown = false
                    guard let host = HostEvent.decode(event.data) else { continue }
                    apply(host)
                }
            } catch is CancellationError {
                return
            } catch {
                // Soft failure — keep the transcript, show a reconnecting hint.
                streamDown = true
            }
            if Task.isCancelled { return }
            // The broadcast stream closed (or errored); reconnect. There's no
            // replay, so existing blocks stay and we just resume future events.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func apply(_ host: HostEvent) {
        if let block = host.block { upsert(block) }
        if let status = host.status { self.status = status }
        if host.done != nil { status = .idle }
        if let error = host.error {
            status = .idle
            sendError = error.message
        }
    }

    /// Insert a new block or replace an existing one with the same id.
    private func upsert(_ block: ChatBlock) {
        guard !block.blockId.isEmpty else { blocks.append(block); return }
        if let i = index[block.blockId] {
            blocks[i] = block
        } else {
            index[block.blockId] = blocks.count
            blocks.append(block)
        }
    }

    func send(_ text: String) async {
        sendError = nil
        do {
            try await client.send(message: text)
        } catch ChatError.empty {
            // ignore empty sends
        } catch {
            sendError = "\(error)"
        }
    }
}

struct AssistantView: View {
    @StateObject private var model: ChatModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(auth: AuthService) {
        _model = StateObject(wrappedValue: ChatModel(auth: auth))
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle("Assistant")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { model.connect() }
        .onDisappear { model.disconnect() }
        .alert(
            "Message failed",
            isPresented: Binding(get: { model.sendError != nil }, set: { if !$0 { model.sendError = nil } })
        ) {
            Button("OK", role: .cancel) { model.sendError = nil }
        } message: {
            Text(model.sendError ?? "")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.blocks.isEmpty {
                        emptyState
                    }
                    ForEach(model.blocks) { block in
                        ChatBlockView(block: block)
                            .frame(maxWidth: .infinity, alignment: block.isUser ? .trailing : .leading)
                    }
                    if model.status.isBusy {
                        BusyRow(detail: model.status.detail)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding()
            }
            .onChange(of: model.blocks.count) { scroll(proxy) }
            .onChange(of: model.status) { scroll(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Ask the assistant").font(.headline)
            Text("Query repos, dispatch agents, check builds — it runs the console's tools for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message assistant…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
    }

    private let bottomAnchor = "chat-bottom"
}

private struct BusyRow: View {
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(detail.isEmpty ? "Thinking…" : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
