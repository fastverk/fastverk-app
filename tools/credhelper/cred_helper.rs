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
//! Resolves secrets inline through the pluggable secret backends (keychain
//! locally, canonical env vars in CI — no daemon round-trip) so it stays
//! fast on Bazel's per-host hot path. `fvd`'s scheduler keeps stored tokens
//! fresh, and `fvd.GetCredentials` remains for refresh-on-demand clients.

use std::io::{Read, Write};

const EMPTY: &str = "{\"headers\":{}}";

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("get") => {
            let mut body = String::new();
            // Consume stdin fully so Bazel's writer never sees EPIPE.
            let _ = std::io::stdin().read_to_string(&mut body);
            let out = respond(&body);
            let stdout = std::io::stdout();
            let mut handle = stdout.lock();
            let _ = writeln!(handle, "{out}");
        }
        // `diagnose <uri>` — explain how the URI resolves: the matched
        // connection, every secret ref tried + which source is present, and
        // the header that would be sent. Reads NO secret values, so it's safe
        // to run as a CI step to answer "which token does this pipeline
        // actually use?" — the visibility the host-only `get` path never gave.
        Some("diagnose") => {
            let Some(uri) = std::env::args().nth(2).filter(|u| !u.is_empty()) else {
                eprintln!("usage: cred-helper diagnose <uri>");
                std::process::exit(2);
            };
            print!("{}", fvkit::connections::explain(&uri));
        }
        // Lenient: any other argv yields anonymous (matches the get-miss path).
        _ => println!("{EMPTY}"),
    }
}

fn respond(body: &str) -> String {
    let Some(uri) = fvkit::uri::parse_request_uri(body) else {
        return EMPTY.to_string();
    };
    // The connection registry resolves the header for the request host
    // through the secret backends (keychain locally, canonical env vars in
    // CI). `resolve` falls back to the built-in default registry, so CI with
    // no registry file still authenticates via the env backend. Any miss —
    // unknown host, no stored secret, or an error — degrades to anonymous.
    match fvkit::connections::resolve(&uri) {
        Ok(Some(c)) => headers(&c.header, &c.value),
        _ => EMPTY.to_string(),
    }
}

fn headers(header: &str, value: &str) -> String {
    format!(
        "{{\"headers\":{{\"{}\":[\"{}\"]}}}}",
        json_escape(header),
        json_escape(value),
    )
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

    // The savvi GitLab "Bearer not Private-Token" guarantee and the
    // canonical/alias env naming are covered hermetically (no secret reads,
    // no keychain/env races) in fvkit::connections + fvkit::secretstore
    // tests. The end-to-end respond() path here is just parse + resolve +
    // headers; the miss-is-anonymous edge is exercised above.
}
