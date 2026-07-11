// Config — the fixed endpoints the iOS console talks to.
//
// These mirror the deployed fastverk-web Cognito client + the botnoc-web origin
// (see saas-console-app-runner: pool us-east-1_aeTUucLNU, web client
// 2hu1kjtgjp0c5rh0eh0f7jo2a3, hosted UI auth.fastverk.com). The client is a
// public PKCE client (GenerateSecret:false), so no secret ships in the app.

import Foundation

enum Config {
    /// The web console origin. All /api/* calls are same-origin against this.
    static let appOrigin = URL(string: "https://app.fastverk.com")!

    /// Cognito hosted-UI custom domain (COGNITO_DOMAIN in botnoc-web).
    static let cognitoDomain = "auth.fastverk.com"

    /// The fastverk-web app-client id (public, PKCE). Shared with the web.
    static let cognitoClientId = "2hu1kjtgjp0c5rh0eh0f7jo2a3"

    /// OAuth scopes — must be a subset of the client's AllowedOAuthScopes.
    static let scopes = "email openid profile"

    /// Native redirect (registered in fastverk-auth.yaml CallbackURLs) + the
    /// scheme ASWebAuthenticationSession watches for.
    static let redirectURI = "fastverk://auth/callback"
    static let callbackScheme = "fastverk"

    static var authorizeURL: URL { URL(string: "https://\(cognitoDomain)/oauth2/authorize")! }
    static var tokenURL: URL { URL(string: "https://\(cognitoDomain)/oauth2/token")! }
}
