// IntegrationsView — the connect surface (Phase E): a card grid of connectable
// services with per-user status, and a "Connect"/"Manage" action that opens the
// provider's flow (`/api/connect/<id>`, a 302 into OAuth) in an in-app Safari.
// SFSafariViewController shares the Safari cookie jar, so the flow authenticates
// via the browser session (require_auth redirects an unauthed browser through
// /auth/login → Cognito), stores the connection keyed by the same user sub the
// app's Bearer carries, and returns to "/". On dismiss we refresh the statuses.
//
// This is what lets a user connect GitHub from the phone — the prerequisite for
// the agents plugin's Dispatch/Cancel (the gateway needs X-Fastverk-Github-Token).

import SwiftUI
import SafariServices

@MainActor
final class IntegrationsModel: ObservableObject {
    enum Phase {
        case loading
        case ready([Integration])
        case failed(String)
    }

    @Published var phase: Phase = .loading
    let client: IntegrationsClient

    init(auth: AuthService) {
        self.client = IntegrationsClient(base: Config.appOrigin, auth: auth)
    }

    func load() async {
        do { phase = .ready(try await client.list()) }
        catch { phase = .failed("\(error)") }
    }
}

/// A connect flow to open in-app (Identifiable for `.fullScreenCover(item:)`).
struct ConnectTarget: Identifiable, Equatable {
    let id: String
    let url: URL
}

struct IntegrationsView: View {
    @StateObject private var model: IntegrationsModel
    @State private var connectTarget: ConnectTarget?

    init(auth: AuthService) {
        _model = StateObject(wrappedValue: IntegrationsModel(auth: auth))
    }

    var body: some View {
        content
            .navigationTitle("Integrations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await model.load() }
            .refreshable { await model.load() }
            .fullScreenCover(item: $connectTarget, onDismiss: { Task { await model.load() } }) { target in
                SafariView(url: target.url) { connectTarget = nil }
                    .ignoresSafeArea()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load integrations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        case let .ready(integrations):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(integrations) { integration in
                        IntegrationCard(integration: integration) {
                            if let url = model.client.connectURL(for: integration) {
                                connectTarget = ConnectTarget(id: integration.id, url: url)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
}

private struct IntegrationCard: View {
    let integration: Integration
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Monogram(name: integration.name, seed: integration.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.name).font(.headline).lineLimit(1)
                    if integration.isConnected {
                        Label("Connected", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(integration.blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onConnect) {
                Text(integration.actionLabel.isEmpty ? "Connect" : integration.actionLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(integration.isConnected ? .secondary : .accentColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A brand-neutral avatar: the service's initial on a color seeded by its id (no
/// bundled brand logos needed).
private struct Monogram: View {
    let name: String
    let seed: String

    private static let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .green, .red]

    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(color.gradient)
            .frame(width: 40, height: 40)
            .overlay(
                Text(initial)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            )
    }

    private var initial: String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    private var color: Color {
        Self.palette[abs(seed.hashValue) % Self.palette.count]
    }
}

/// SwiftUI wrapper for SFSafariViewController, calling `onFinish` when the user
/// dismisses it (Done) so the caller can clear its binding + refresh.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}
