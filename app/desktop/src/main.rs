//! `fastverk` — the menu-bar application.
//!
//! A `tao` event loop hosts a `tray-icon` status item with a `muda` menu.
//! Menu actions are forwarded to a background worker thread that calls
//! fvkit's synchronous core directly (like cli/fv — no daemon, no tokio) and
//! reports results as macOS notifications. While a command runs, the worker
//! signals the UI to pulse the tray icon as a busy/progress indicator.

use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

/// Busy-pulse animation frame interval.
const FRAME: Duration = Duration::from_millis(110);

/// Work the background thread performs against fvkit's core.
enum Cmd {
    Status,
    Maintain,
    CheckUpdate,
    InstallUpdate,
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

    // Background worker: runs each command off the UI thread, bracketed with
    // Busy(true/false) so the tray pulses while it works. fvkit's core API is
    // synchronous (like cli/fv); we call it directly — driving fvkit's async
    // gRPC client from a runtime built here would panic (its tokio is a
    // separate crate_universe instance, so its reactor is never entered).
    let (tx, rx) = mpsc::channel::<Cmd>();
    let busy_proxy = event_loop.create_proxy();
    std::thread::spawn(move || {
        for cmd in rx {
            let _ = busy_proxy.send_event(UserEvent::Busy(true));
            handle(cmd);
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
/// sibling `fvd-json` helper, which reads fvkit's state directly (no daemon
/// needed). The child inherits our environment, so any `$FASTVERK_CONFIG_DIR`
/// override carries through and the Dashboard sees the same config we do.
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

/// Run one command against fvkit's sync core and surface the result as a
/// notification. Mirrors the fvd read handlers (server.rs), called directly.
fn handle(cmd: Cmd) {
    match cmd {
        Cmd::Status => {
            let volumes = fvkit::volume::status().unwrap_or_default();
            let reg = fvkit::connections::load().unwrap_or_default();
            notify(
                "fastverk",
                &format!(
                    "fvd v{} · {} connection(s) · {} volume(s)",
                    fvkit::version(),
                    reg.connections.len(),
                    volumes.len()
                ),
            );
        }
        Cmd::Maintain => match fvkit::maintain::run(false, &[]) {
            Ok(report) => {
                let ok = report.tasks.iter().filter(|t| t.ok).count();
                notify(
                    "fastverk",
                    &format!("maintenance done: {ok}/{} tasks ok", report.tasks.len()),
                );
            }
            Err(e) => notify("fastverk", &format!("maintenance failed: {e}")),
        },
        Cmd::CheckUpdate => match fvkit::update::check() {
            Ok(u) => {
                let msg = if u.available {
                    format!("update available: v{} — pick \"Install update…\"", u.latest)
                } else {
                    format!("up to date (v{})", u.current)
                };
                notify("fastverk", &msg);
            }
            Err(e) => notify("fastverk", &format!("update check failed: {e}")),
        },
        Cmd::InstallUpdate => match fvkit::update::check() {
            Ok(u) if !u.available => {
                notify("fastverk", &format!("Already up to date (v{})", u.current));
            }
            Ok(u) => {
                notify("fastverk", &format!("Downloading update v{}…", u.latest));
                // apply() downloads the .dmg, swaps the .app in place, and emits
                // its own "Updated to v…" notification on success.
                if let Err(e) = fvkit::update::apply(false) {
                    notify("fastverk", &format!("update failed: {e}"));
                } else {
                    notify("fastverk", "Reopen fastverk to finish updating.");
                }
            }
            Err(e) => notify("fastverk", &format!("update check failed: {e}")),
        },
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
