// fastverk iOS console — @main entry. Gates on sign-in, then hands off to the
// server-driven shell. The macOS analog is app/dashboard/App.swift, but here the
// data comes from the cloud (app.fastverk.com), not a local fvd.

import SwiftUI

@main
struct FastverkApp: App {
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ShellNavView(auth: auth)
            } else {
                SignInView()
            }
        }
        .task { await auth.restoreSession() }
    }
}

/// The pre-auth screen: a single "Sign in" that launches the Cognito hosted UI.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("fastverk")
                .font(.largeTitle.bold())
            Text("Sign in with your fastverk account.")
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await signIn() }
            } label: {
                if signingIn {
                    ProgressView()
                } else {
                    Text("Sign in").frame(maxWidth: 220)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(signingIn)
        }
        .padding()
    }

    private func signIn() async {
        signingIn = true
        error = nil
        defer { signingIn = false }
        do {
            try await auth.signIn()
        } catch is CancellationError {
            // User dismissed the sheet — no error banner.
        } catch {
            self.error = "\(error)"
        }
    }
}
