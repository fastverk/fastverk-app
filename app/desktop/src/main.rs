//! `fastverk` — the menu-bar application.
//!
//! A `tao` event loop hosts a `tray-icon` status item with a `muda` menu.
//! Menu actions are forwarded to a background worker thread that talks to
//! the `fvd` daemon over its Unix socket (`fvkit::ipc`, autostarting fvd
//! if needed) and reports results as macOS notifications. The egui
//! settings windows (Connections / Volumes / Bazelrc) land next; for now
//! Connections/Volumes route through Status-style summaries.

use std::sync::mpsc::{self, Sender};

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

use fvkit::proto::{GetStatusRequest, MaintainNowRequest};

/// Work the background thread performs against fvd.
enum Cmd {
    Status,
    Maintain,
    CheckUpdate,
}

enum UserEvent {
    Menu(MenuEvent),
    #[allow(dead_code)]
    Tray(TrayIconEvent),
}

fn main() {
    // Background worker: owns a tokio runtime, talks to fvd per command.
    let (tx, rx) = mpsc::channel::<Cmd>();
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
            rt.block_on(handle(cmd));
        }
    });

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();

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
    let connections_i = MenuItem::new("Connections…", true, None);
    let volumes_i = MenuItem::new("Volumes…", true, None);
    let repos_i = MenuItem::new("Repos…", true, None);
    let maintain_i = MenuItem::new("Run maintenance", true, None);
    let updates_i = MenuItem::new("Check for updates", true, None);
    let quit_i = MenuItem::new("Quit fastverk", true, None);
    let _ = menu.append_items(&[
        &status_i,
        &PredefinedMenuItem::separator(),
        &connections_i,
        &volumes_i,
        &repos_i,
        &maintain_i,
        &updates_i,
        &PredefinedMenuItem::separator(),
        &quit_i,
    ]);

    let quit_id = quit_i.id().clone();
    let status_id = status_i.id().clone();
    let connections_id = connections_i.id().clone();
    let volumes_id = volumes_i.id().clone();
    let repos_id = repos_i.id().clone();
    let maintain_id = maintain_i.id().clone();
    let updates_id = updates_i.id().clone();

    let icon = make_icon();
    let mut tray: Option<TrayIcon> = None;

    event_loop.run(move |event, _target, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::NewEvents(StartCause::Init) => {
                tray = TrayIconBuilder::new()
                    .with_menu(Box::new(menu.clone()))
                    .with_tooltip("fastverk")
                    .with_icon(icon.clone())
                    .build()
                    .ok();
                if tray.is_none() {
                    eprintln!("fastverk: failed to create the tray icon");
                }
            }
            Event::UserEvent(UserEvent::Menu(e)) => {
                if e.id == quit_id {
                    tray.take();
                    *control_flow = ControlFlow::Exit;
                } else if e.id == status_id {
                    send(&tx, Cmd::Status);
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

/// Run one fvd command and surface the result as a notification.
async fn handle(cmd: Cmd) {
    let mut client = match fvkit::ipc::connect_default().await {
        Ok(c) => c,
        Err(e) => {
            notify("fastverk", &format!("can't reach fvd: {e}"));
            return;
        }
    };
    match cmd {
        Cmd::Status => match client.get_status(GetStatusRequest {}).await {
            Ok(r) => {
                let s = r.into_inner();
                notify(
                    "fastverk",
                    &format!(
                        "fvd v{} · {} connection(s) · {} volume(s)",
                        s.version,
                        s.connection_count,
                        s.volumes.len()
                    ),
                );
            }
            Err(e) => notify("fastverk", &format!("status failed: {}", e.message())),
        },
        Cmd::Maintain => match client
            .maintain_now(MaintainNowRequest {
                validate_only: false,
                only: vec![],
            })
            .await
        {
            Ok(r) => {
                let report = r.into_inner();
                let ok = report.tasks.iter().filter(|t| t.ok).count();
                notify(
                    "fastverk",
                    &format!("maintenance done: {ok}/{} tasks ok", report.tasks.len()),
                );
            }
            Err(e) => notify("fastverk", &format!("maintenance failed: {}", e.message())),
        },
        Cmd::CheckUpdate => match client
            .check_update(fvkit::proto::CheckUpdateRequest {})
            .await
        {
            Ok(r) => {
                let u = r.into_inner();
                let msg = if u.update_available {
                    format!("update available: {}", u.latest_version)
                } else {
                    format!("up to date (v{})", u.current_version)
                };
                notify("fastverk", &msg);
            }
            Err(e) => notify("fastverk", &format!("update check failed: {}", e.message())),
        },
    }
}

/// Show a macOS notification (best-effort).
fn notify(title: &str, body: &str) {
    let script = format!(
        "display notification \"{}\" with title \"{}\"",
        body.replace('\\', "\\\\").replace('"', "\\\""),
        title.replace('\\', "\\\\").replace('"', "\\\""),
    );
    let _ = std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .status();
    // Also log, useful when run from a terminal.
    println!("[{title}] {body}");
}

/// The fastverk menu-bar icon — the GitHub org logo, decoded from the
/// embedded PNG and resized for the menu bar.
fn make_icon() -> Icon {
    const LOGO: &[u8] = include_bytes!("../../../assets/fastverk-logo.png");
    let rgba = image::load_from_memory(LOGO)
        .expect("decode logo")
        .resize_exact(32, 32, image::imageops::FilterType::Lanczos3)
        .to_rgba8();
    let (w, h) = rgba.dimensions();
    Icon::from_rgba(rgba.into_raw(), w, h).expect("valid icon")
}
