//! `fastverk` — the menu-bar application.
//!
//! A `tao` event loop hosts a `tray-icon` status item with a `muda` menu. Menu
//! actions are forwarded to a background worker that drives `fvd` over gRPC —
//! the daemon hosts every service (the core `Fvd` service plus the plugin
//! contract's `fastverk.identity.v1.Auth`). The worker owns a tokio runtime and
//! brackets each command with `Busy(true/false)` so the tray icon pulses while
//! it works.

use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

use fvkit::identity_proto::auth_client::AuthClient;
use fvkit::identity_proto::{LoginRequest, LogoutRequest, WhoAmIRequest};
use fvkit::proto::fvd_client::FvdClient;
use fvkit::proto::{ApplyUpdateRequest, CheckUpdateRequest, GetStatusRequest, MaintainNowRequest};

/// Busy-pulse animation frame interval.
const FRAME: Duration = Duration::from_millis(110);

/// Work the background worker performs against `fvd`.
enum Cmd {
    Status,
    Maintain,
    CheckUpdate,
    InstallUpdate,
    /// Interactive Cognito login (fvd opens the browser + runs PKCE).
    Login,
    Logout,
    WhoAmI,
}

impl Cmd {
    /// Short verb for failure notifications ("<label> failed: …").
    fn label(&self) -> &'static str {
        match self {
            Cmd::Status => "status",
            Cmd::Maintain => "maintenance",
            Cmd::CheckUpdate => "update check",
            Cmd::InstallUpdate => "update",
            Cmd::Login => "login",
            Cmd::Logout => "logout",
            Cmd::WhoAmI => "whoami",
        }
    }
}

enum UserEvent {
    Menu(MenuEvent),
    #[allow(dead_code)]
    Tray(TrayIconEvent),
    /// Worker → UI: a command started (`true`) / finished (`false`). Drives the
    /// tray-icon busy pulse so long ops (esp. update download/install) show
    /// progress.
    Busy(bool),
}

fn main() {
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();

    // Background worker: owns a tokio runtime and drives fvd over gRPC per
    // command, bracketed with Busy(true/false) so the tray pulses while it
    // works. fvd hosts every service; this worker is the app's single gRPC
    // caller (the menu-bar UI itself never touches tonic).
    let (tx, rx) = mpsc::channel::<Cmd>();
    let busy_proxy = event_loop.create_proxy();
    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                notify("fastverk", &format!("runtime error: {e}"));
                return;
            }
        };
        for cmd in rx {
            let _ = busy_proxy.send_event(UserEvent::Busy(true));
            rt.block_on(handle(cmd));
            let _ = busy_proxy.send_event(UserEvent::Busy(false));
        }
    });

    // Forward muda + tray clicks into the tao loop so it wakes.
    let menu_proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |e| {
        let _ = menu_proxy.send_event(UserEvent::Menu(e));
    }));
    let tray_proxy = event_loop.create_proxy();
    TrayIconEvent::set_event_handler(Some(move |e| {
        let _ = tray_proxy.send_event(UserEvent::Tray(e));
    }));

    let menu = Menu::new();
    let status_i = MenuItem::new("Status", true, None);
    let dashboard_i = MenuItem::new("Dashboard…", true, None);
    let account_i = MenuItem::new("Account", true, None);
    let login_i = MenuItem::new("Sign in…", true, None);
    let logout_i = MenuItem::new("Sign out", true, None);
    let connections_i = MenuItem::new("Connections…", true, None);
    let volumes_i = MenuItem::new("Volumes…", true, None);
    let repos_i = MenuItem::new("Repos…", true, None);
    let maintain_i = MenuItem::new("Run maintenance", true, None);
    let updates_i = MenuItem::new("Check for updates", true, None);
    let install_i = MenuItem::new("Install update…", true, None);
    let quit_i = MenuItem::new("Quit fastverk", true, None);
    let _ = menu.append_items(&[
        &status_i,
        &dashboard_i,
        &account_i,
        &PredefinedMenuItem::separator(),
        &login_i,
        &logout_i,
        &PredefinedMenuItem::separator(),
        &connections_i,
        &volumes_i,
        &repos_i,
        &maintain_i,
        &updates_i,
        &install_i,
        &PredefinedMenuItem::separator(),
        &quit_i,
    ]);

    let quit_id = quit_i.id().clone();
    let status_id = status_i.id().clone();
    let dashboard_id = dashboard_i.id().clone();
    let account_id = account_i.id().clone();
    let login_id = login_i.id().clone();
    let logout_id = logout_i.id().clone();
    let connections_id = connections_i.id().clone();
    let volumes_id = volumes_i.id().clone();
    let repos_id = repos_i.id().clone();
    let maintain_id = maintain_i.id().clone();
    let updates_id = updates_i.id().clone();
    let install_id = install_i.id().clone();

    let (base_icon, frames) = icon_frames();
    let mut tray: Option<TrayIcon> = None;
    let mut busy = false;
    let mut frame = 0usize;

    event_loop.run(move |event, _target, control_flow| {
        // While busy, keep waking on the frame interval to advance the pulse;
        // otherwise sleep until the next event.
        *control_flow = if busy {
            ControlFlow::WaitUntil(Instant::now() + FRAME)
        } else {
            ControlFlow::Wait
        };

        match event {
            Event::NewEvents(StartCause::Init) => {
                tray = TrayIconBuilder::new()
                    .with_menu(Box::new(menu.clone()))
                    .with_tooltip("fastverk")
                    .with_icon(base_icon.clone())
                    .build()
                    .ok();
                if tray.is_none() {
                    eprintln!("fastverk: failed to create the tray icon");
                }
            }
            // Frame tick: advance the busy pulse.
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                if busy {
                    if let Some(t) = &tray {
                        let _ = t.set_icon(Some(frames[frame % frames.len()].clone()));
                    }
                    frame = frame.wrapping_add(1);
                }
            }
            Event::UserEvent(UserEvent::Busy(b)) => {
                busy = b;
                if b {
                    frame = 0;
                    *control_flow = ControlFlow::WaitUntil(Instant::now() + FRAME);
                } else {
                    // Restore the steady icon.
                    if let Some(t) = &tray {
                        let _ = t.set_icon(Some(base_icon.clone()));
                    }
                    *control_flow = ControlFlow::Wait;
                }
            }
            Event::UserEvent(UserEvent::Menu(e)) => {
                if e.id == quit_id {
                    tray.take();
                    *control_flow = ControlFlow::Exit;
                } else if e.id == status_id {
                    send(&tx, Cmd::Status);
                } else if e.id == dashboard_id {
                    spawn_dashboard();
                } else if e.id == account_id {
                    send(&tx, Cmd::WhoAmI);
                } else if e.id == login_id {
                    send(&tx, Cmd::Login);
                } else if e.id == logout_id {
                    send(&tx, Cmd::Logout);
                } else if e.id == connections_id {
                    spawn_settings("connections");
                } else if e.id == volumes_id {
                    spawn_settings("volumes");
                } else if e.id == repos_id {
                    spawn_settings("repos");
                } else if e.id == maintain_id {
                    send(&tx, Cmd::Maintain);
                } else if e.id == updates_id {
                    send(&tx, Cmd::CheckUpdate);
                } else if e.id == install_id {
                    send(&tx, Cmd::InstallUpdate);
                }
            }
            Event::UserEvent(UserEvent::Tray(_)) => {}
            _ => {}
        }
    });
}

fn send(tx: &Sender<Cmd>, cmd: Cmd) {
    if tx.send(cmd).is_err() {
        notify("fastverk", "background worker is gone");
    }
}

/// Launch the standalone egui settings window on the given panel. The
/// binary lives next to the tray (cargo target dir / app bundle).
fn spawn_settings(panel: &str) {
    let bin = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join("fastverk-settings")))
        .filter(|p| p.is_file());
    match bin {
        Some(bin) => {
            let _ = std::process::Command::new(bin).arg(panel).spawn();
        }
        None => notify("fastverk", "settings app not found next to the tray binary"),
    }
}

/// Launch the native SwiftUI Dashboard window (a meridian renderer). The
/// binary lives next to the tray in the app bundle; it shells out to the
/// sibling `fvd-json` helper, which reads fvkit's state directly. The child
/// inherits our environment, so any `$FASTVERK_CONFIG_DIR` override carries
/// through and the Dashboard sees the same config we do.
fn spawn_dashboard() {
    let bin = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join("fastverk-dashboard")))
        .filter(|p| p.is_file());
    match bin {
        Some(bin) => {
            let _ = std::process::Command::new(bin).spawn();
        }
        None => notify("fastverk", "dashboard app not found next to the tray binary"),
    }
}

/// Run one command against `fvd` over gRPC and surface the outcome as a
/// notification. Each arm produces the success message (or short-circuits with
/// `?` on a gRPC error); the single tail notifies, formatting any failure
/// uniformly. One autostarted channel backs whichever service client the
/// command needs — the `Fvd` core service or `fastverk.identity.v1.Auth`. The
/// gRPC client types are inferred, so the tray needs no direct tonic dep.
async fn handle(cmd: Cmd) {
    let channel = match fvkit::ipc::connect_channel_default().await {
        Ok(c) => c,
        Err(e) => {
            notify("fastverk", &format!("can't reach fvd: {e}"));
            return;
        }
    };
    let label = cmd.label();

    let outcome: Result<String, String> = async move {
        match cmd {
            Cmd::Status => {
                let s = FvdClient::new(channel)
                    .get_status(GetStatusRequest {})
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner();
                Ok(format!(
                    "fvd v{} · {} connection(s) · {} volume(s){}",
                    s.version,
                    s.connection_count,
                    s.volumes.len(),
                    account_suffix(&s),
                ))
            }
            Cmd::Maintain => {
                let report = FvdClient::new(channel)
                    .maintain_now(MaintainNowRequest { validate_only: false, only: vec![] })
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner();
                let ok = report.tasks.iter().filter(|t| t.ok).count();
                Ok(format!("maintenance done: {ok}/{} tasks ok", report.tasks.len()))
            }
            Cmd::CheckUpdate => {
                let u = FvdClient::new(channel)
                    .check_update(CheckUpdateRequest {})
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner();
                Ok(if u.update_available {
                    format!("update available: {} — pick \"Install update…\"", u.latest_version)
                } else {
                    format!("up to date (v{})", u.current_version)
                })
            }
            // Apply blocks while fvd downloads + swaps the release in place.
            Cmd::InstallUpdate => {
                let r = FvdClient::new(channel)
                    .apply_update(ApplyUpdateRequest { force: false })
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner();
                Ok(match (r.started, r.message.is_empty()) {
                    (true, true) => "update started — reopen fastverk to finish".to_string(),
                    (false, true) => "already up to date".to_string(),
                    (_, false) => r.message,
                })
            }
            // Login blocks while fvd opens the browser + runs PKCE.
            Cmd::Login => {
                let id = AuthClient::new(channel)
                    .login(LoginRequest {})
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner()
                    .identity
                    .unwrap_or_default();
                Ok(format!("signed in as {}", account_label(&id)))
            }
            Cmd::Logout => {
                let removed = AuthClient::new(channel)
                    .logout(LogoutRequest {})
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner()
                    .removed;
                Ok(if removed { "signed out" } else { "was not signed in" }.to_string())
            }
            Cmd::WhoAmI => {
                let id = AuthClient::new(channel)
                    .who_am_i(WhoAmIRequest {})
                    .await
                    .map_err(|e| e.message().to_string())?
                    .into_inner();
                Ok(if id.authenticated {
                    format!("signed in as {}", account_label(&id))
                } else {
                    "not signed in".to_string()
                })
            }
        }
    }
    .await;

    notify("fastverk", &outcome.unwrap_or_else(|e| format!("{label} failed: {e}")));
}

/// " · <email>" (or " · signed in") appended to the Status line when an identity
/// is present, else empty.
fn account_suffix(s: &fvkit::proto::StatusResponse) -> String {
    if !s.signed_in {
        return String::new();
    }
    let who = if s.account_email.is_empty() {
        "signed in"
    } else {
        s.account_email.as_str()
    };
    format!(" · {who}")
}

/// The display label for an identity: its email, falling back to the subject id.
fn account_label(id: &fvkit::identity_proto::Identity) -> String {
    if id.email.is_empty() {
        id.subject.clone()
    } else {
        id.email.clone()
    }
}

/// Show a desktop notification (best-effort), via the shared fvkit helper.
fn notify(title: &str, body: &str) {
    fvkit::notify::send(title, body);
    // Also log, useful when run from a terminal.
    println!("[{title}] {body}");
}

/// The steady tray icon plus a set of dimmed frames for the busy pulse.
/// Both are derived from the @brand mark (full variant) embedded as PNG —
/// no extra assets; the pulse just scales alpha so the mark "breathes".
fn icon_frames() -> (Icon, Vec<Icon>) {
    const LOGO: &[u8] = include_bytes!("../../../assets/tray-icon.png");
    let base_rgba = image::load_from_memory(LOGO)
        .expect("decode logo")
        .resize_exact(32, 32, image::imageops::FilterType::Lanczos3)
        .to_rgba8();
    let (w, h) = base_rgba.dimensions();
    let base = Icon::from_rgba(base_rgba.clone().into_raw(), w, h).expect("valid icon");

    // One pulse cycle: bright → dim → bright (alpha scale).
    let factors = [1.0_f32, 0.78, 0.55, 0.35, 0.55, 0.78];
    let frames = factors
        .iter()
        .map(|&f| {
            let mut buf = base_rgba.clone();
            for px in buf.pixels_mut() {
                px.0[3] = (f32::from(px.0[3]) * f) as u8;
            }
            Icon::from_rgba(buf.into_raw(), w, h).expect("valid frame")
        })
        .collect();

    (base, frames)
}
