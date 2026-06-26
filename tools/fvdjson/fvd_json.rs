//! `fvd-json` — a one-shot JSON view of fvkit's read-only state.
//!
//! The SwiftUI Dashboard renders meridian panels and needs an `RpcInvoker`
//! that maps `(service, method, request-json) -> response-json`. The Dashboard
//! shells out to this tiny Rust binary for each panel populate.
//!
//! Following `cli/fv`'s pattern ("No tokio. Every operation is sync I/O"), it
//! calls fvkit's **synchronous core API directly** — the same functions fvd's
//! read handlers wrap — rather than the async gRPC client. That means no
//! daemon dependency, and it avoids driving fvkit's tokio from a separate
//! tokio instance (the app and fvkit have distinct crate_universe hubs, so a
//! locally-built runtime can't satisfy fvkit's reactor).
//!
//! It dispatches by the fvd contract names (`fastverk.v1.Fvd` / method) so the
//! meridian panel bundle stays transport-agnostic, and emits proto field names
//! in snake_case so meridian `field_path`s resolve. Read-only: it never prints
//! secrets (the registry strips them) and MaintainNow defaults to a preview.
//!
//! Usage: `fvd-json <service> <method> [request-json]`
//!   - On success: the response JSON on stdout, exit 0.
//!   - On failure: a message on stderr, exit 1.

use std::process::ExitCode;

use fvkit::proto::{
    AuthKind, Connection, MaintenanceReport, MaintenanceTask, RepoSpec, RepoState, VolumeSpec,
    VolumeState, Worktree,
};
use serde_json::{json, Value};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: fvd-json <service> <method> [request-json]");
        return ExitCode::FAILURE;
    }
    let service = args[1].as_str();
    let method = args[2].as_str();
    let req: Value = match args.get(3).map(String::as_str) {
        Some(s) if !s.is_empty() => match serde_json::from_str(s) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("bad request json: {e}");
                return ExitCode::FAILURE;
            }
        },
        _ => Value::Object(serde_json::Map::new()),
    };

    match dispatch(service, method, &req) {
        Ok(v) => {
            println!("{v}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Map one `(service, method)` to fvkit's sync core and return JSON. Mirrors
/// the fvd handlers (app/daemon/src/server.rs).
fn dispatch(service: &str, method: &str, req: &Value) -> Result<Value, String> {
    if service != "fastverk.v1.Fvd" {
        return Err(format!("unknown service: {service}"));
    }
    match method {
        "GetStatus" => Ok(get_status()),

        "VolumeStatus" => {
            let volumes = fvkit::volume::status().map_err(err_str)?;
            Ok(json!({ "volumes": vec_to_json(volumes, volume_state_to_json) }))
        }

        "ListConnections" => {
            let reg = fvkit::connections::load().map_err(err_str)?;
            Ok(json!({ "connections": vec_to_json(reg.connections, connection_to_json) }))
        }

        "ReposStatus" => {
            let cfg = fvkit::config::Config::load().map_err(err_str)?;
            let repos_dir = cfg.repos_dir();
            let mut specs = Vec::new();
            for s in &cfg.sources {
                specs.extend(
                    fvkit::repos::enumerate(&s.forge, &s.host, &s.group, true).map_err(err_str)?,
                );
            }
            let repos = fvkit::repos::status(&repos_dir, &specs);
            Ok(json!({ "repos": vec_to_json(repos, repo_state_to_json) }))
        }

        "WorktreeList" => {
            let cfg = fvkit::config::Config::load().map_err(err_str)?;
            let repo = req.get("repo").and_then(Value::as_str).unwrap_or("");
            let worktrees = fvkit::repos::worktree_list(&cfg.repos_dir(), repo).map_err(err_str)?;
            Ok(json!({ "worktrees": vec_to_json(worktrees, worktree_to_json) }))
        }

        "MaintainNow" => {
            // Default to a read-safe preview; a caller may pass validate_only=false.
            let validate_only = req
                .get("validate_only")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let only = str_array(req, "only");
            let report = fvkit::maintain::run(validate_only, &only).map_err(err_str)?;
            Ok(maintenance_report_to_json(report))
        }

        _ => Err(format!("unknown method: {service}/{method}")),
    }
}

/// The daemon + system snapshot, mirroring fvd's get_status handler.
fn get_status() -> Value {
    let volumes = fvkit::volume::status().unwrap_or_default();
    let reg = fvkit::connections::load().unwrap_or_default();
    // update::check() builds its own blocking reqwest runtime; a failed/blocked
    // check must not sink the whole snapshot.
    let update = fvkit::update::check().ok();
    json!({
        "version": fvkit::version(),
        "volumes": vec_to_json(volumes, volume_state_to_json),
        "connection_count": i32::try_from(reg.connections.len()).unwrap_or(i32::MAX),
        "last_maintenance": Value::Null,
        "update_available": update.as_ref().is_some_and(|u| u.available),
        "latest_version": update.map(|u| u.latest).unwrap_or_default(),
    })
}

// ─── helpers ─────────────────────────────────────────────────────────────

fn str_array(v: &Value, k: &str) -> Vec<String> {
    v.get(k)
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// Stringify any error (fvkit::Error and friends all impl Display).
fn err_str<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn vec_to_json<T>(items: Vec<T>, f: impl Fn(T) -> Value) -> Value {
    Value::Array(items.into_iter().map(f).collect())
}

// ─── response → JSON (snake_case proto field names) ──────────────────────

fn volume_spec_to_json(s: VolumeSpec) -> Value {
    json!({
        "id": s.id,
        "display_name": s.display_name,
        "mount_point": s.mount_point,
        "fs_volume": s.fs_volume,
        "quota_bytes": s.quota_bytes,
    })
}

fn volume_state_to_json(s: VolumeState) -> Value {
    json!({
        "spec": s.spec.map_or(Value::Null, volume_spec_to_json),
        "exists": s.exists,
        "mounted": s.mounted,
        "used_bytes": s.used_bytes,
        "free_bytes": s.free_bytes,
        "device": s.device,
    })
}

fn repo_spec_to_json(s: RepoSpec) -> Value {
    json!({
        "name": s.name,
        "dir": s.dir,
        "clone_url": s.clone_url,
        "forge": s.forge,
        "is_private": s.is_private,
    })
}

fn repo_state_to_json(s: RepoState) -> Value {
    json!({
        "spec": s.spec.map_or(Value::Null, repo_spec_to_json),
        "present": s.present,
        "head": s.head,
        "branch": s.branch,
        "dirty": s.dirty,
    })
}

fn worktree_to_json(w: Worktree) -> Value {
    json!({
        "repo": w.repo,
        "path": w.path,
        "branch": w.branch,
        "head": w.head,
        "is_primary": w.is_primary,
    })
}

fn maintenance_task_to_json(t: MaintenanceTask) -> Value {
    json!({
        "name": t.name,
        "ok": t.ok,
        "detail": t.detail,
        "bytes_reclaimed": t.bytes_reclaimed,
    })
}

fn maintenance_report_to_json(r: MaintenanceReport) -> Value {
    json!({
        "started_at": r.started_at,
        "finished_at": r.finished_at,
        "validate_only": r.validate_only,
        "tasks": vec_to_json(r.tasks, maintenance_task_to_json),
    })
}

fn auth_kind_name(k: i32) -> &'static str {
    match AuthKind::try_from(k).unwrap_or(AuthKind::Unspecified) {
        AuthKind::Oauth => "oauth",
        AuthKind::ApiKey => "api_key",
        AuthKind::Unspecified => "",
    }
}

fn connection_to_json(c: Connection) -> Value {
    json!({
        "id": c.id,
        "display_name": c.display_name,
        "provider": c.provider,
        "host_patterns": c.host_patterns,
        "header": c.header,
        "value_prefix": c.value_prefix,
        "auth_kind": auth_kind_name(c.auth_kind),
        "token_expires_at": c.token_expires_at,
        "connected_at": c.connected_at,
    })
}
