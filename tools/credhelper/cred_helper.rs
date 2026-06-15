//! fastverk universal Bazel credential helper — config-driven.
//!
//! Lifted from the aion universal helper
//! (`infra/ci/cred_helper/cred_helper.rs`) and rebased on fastverk's
//! connection registry: instead of a compile-time host->env table, it
//! resolves the auth header for the request host from the persisted
//! connection registry + OS keychain (`fvkit::connections::resolve`).
//! Replaces the per-service `gh-cred-helper.sh` / `glab` shell scripts.
//!
//! Bazel cred-helper protocol (EngFlow spec):
//!   * `cred-helper get` with stdin `{"uri":"https://host[:port]/path"}`.
//!   * stdout `{"headers":{"Header-Name":["value"]}}`.
//!   * Any miss (no matching connection, no stored secret, malformed
//!     request, or non-`get` argv) yields `{"headers":{}}` and exit 0, so
//!     a fetch degrades to anonymous rather than failing the build.
//!
//! Reads the keychain directly (no daemon round-trip) so it stays fast on
//! Bazel's per-host hot path. `fvd`'s scheduler keeps stored tokens fresh,
//! and `fvd.GetCredentials` remains for refresh-on-demand clients.

use std::io::{Read, Write};

const EMPTY: &str = "{\"headers\":{}}";

fn main() {
    // Lenient on the subcommand: only `get` does anything.
    if std::env::args().nth(1).as_deref() != Some("get") {
        println!("{EMPTY}");
        return;
    }
    let mut body = String::new();
    // Consume stdin fully so Bazel's writer never sees EPIPE.
    let _ = std::io::stdin().read_to_string(&mut body);

    let out = respond(&body);
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    let _ = writeln!(handle, "{out}");
}

fn respond(body: &str) -> String {
    let Some(uri) = fvkit::uri::parse_request_uri(body) else {
        return EMPTY.to_string();
    };
    // 1) A configured connection (keychain) wins — the interactive/local path.
    if let Ok(Some(c)) = fvkit::connections::resolve(&uri) {
        return headers(&c.header, &c.value);
    }
    // 2) Env fallback for CI/automation, where there's no keychain: a small
    //    host -> env table (as the original aion universal helper used).
    //    Connections always take precedence over this.
    if let Some((header, value)) = env_fallback(fvkit::uri::host_of(&uri)) {
        return headers(&header, &value);
    }
    EMPTY.to_string()
}

fn headers(header: &str, value: &str) -> String {
    format!(
        "{{\"headers\":{{\"{}\":[\"{}\"]}}}}",
        json_escape(header),
        json_escape(value),
    )
}

/// CI/automation token source: a host -> (header, env-var) table. Returns
/// the header + value when a relevant env var is set and non-empty.
fn env_fallback(host: &str) -> Option<(String, String)> {
    let is_github = host == "github.com"
        || host.ends_with(".github.com")
        || host == "raw.githubusercontent.com"
        || host == "codeload.github.com";
    if is_github {
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let Ok(v) = std::env::var(key) {
                if !v.is_empty() {
                    return Some(("Authorization".to_string(), format!("Bearer {v}")));
                }
            }
        }
    }
    if host == "remote.buildbuddy.io" {
        if let Ok(v) = std::env::var("BUILDBUDDY_API_KEY") {
            if !v.is_empty() {
                return Some(("x-buildbuddy-api-key".to_string(), v));
            }
        }
    }
    None
}

/// JSON-escape a string for embedding as a JSON string value.
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{json_escape, respond, EMPTY};

    #[test]
    fn malformed_or_unknown_is_empty() {
        assert_eq!(respond("not json"), EMPTY);
        assert_eq!(respond(""), EMPTY);
        // A well-formed request for an unconfigured host is anonymous
        // (no connection in the registry -> empty headers).
        assert_eq!(
            respond(r#"{"uri":"https://no-such-host.example/x"}"#),
            EMPTY
        );
    }

    #[test]
    fn escapes_json() {
        assert_eq!(json_escape(r#"a"b\c"#), r#"a\"b\\c"#);
    }
}
