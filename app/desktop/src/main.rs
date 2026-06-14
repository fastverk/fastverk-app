//! `fastverk` — the menu-bar application.
//!
//! A `tao` event loop hosts a `tray-icon` status item with a `muda` menu
//! (re-exported as `tray_icon::menu`). Menu actions will drive the `fvd`
//! daemon over its Unix socket; this first cut stands up the visible tray
//! + menu (Quit works), with the fvd client + egui settings windows
//! landing next.

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

/// Events forwarded from the global tray/menu channels into the tao loop.
enum UserEvent {
    Menu(MenuEvent),
    #[allow(dead_code)]
    Tray(TrayIconEvent),
}

fn main() {
    // (Dock-icon hiding — LSUIElement / Accessory activation policy — comes
    // with the .app bundle's Info.plist in packaging; not needed to show the
    // status item.)
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();

    // tray-icon + muda deliver clicks on global channels; forward them into
    // the tao loop (via the proxy) so it wakes and we handle them in one place.
    let menu_proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |e| {
        let _ = menu_proxy.send_event(UserEvent::Menu(e));
    }));
    let tray_proxy = event_loop.create_proxy();
    TrayIconEvent::set_event_handler(Some(move |e| {
        let _ = tray_proxy.send_event(UserEvent::Tray(e));
    }));

    // Build the menu.
    let menu = Menu::new();
    let status_i = MenuItem::new("Status", true, None);
    let connections_i = MenuItem::new("Connections…", true, None);
    let volumes_i = MenuItem::new("Volumes…", true, None);
    let maintain_i = MenuItem::new("Run maintenance", true, None);
    let updates_i = MenuItem::new("Check for updates", true, None);
    let quit_i = MenuItem::new("Quit fastverk", true, None);
    let _ = menu.append_items(&[
        &status_i,
        &PredefinedMenuItem::separator(),
        &connections_i,
        &volumes_i,
        &maintain_i,
        &updates_i,
        &PredefinedMenuItem::separator(),
        &quit_i,
    ]);

    let quit_id = quit_i.id().clone();
    let status_id = status_i.id().clone();
    let maintain_id = maintain_i.id().clone();

    let icon = make_icon();
    // The tray must be created after the event loop is running (macOS).
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
                    // Drop the status item before exiting so it disappears.
                    tray.take();
                    *control_flow = ControlFlow::Exit;
                } else if e.id == status_id {
                    println!("fastverk: Status (fvd client wiring is next)");
                } else if e.id == maintain_id {
                    println!("fastverk: Run maintenance (fvd client wiring is next)");
                }
            }
            Event::UserEvent(UserEvent::Tray(_)) => {}
            _ => {}
        }
    });
}

/// A simple 32×32 RGBA fastverk mark (filled teal disc on transparency).
fn make_icon() -> Icon {
    const S: u32 = 32;
    let mut rgba = vec![0u8; (S * S * 4) as usize];
    let center = (S as f32 - 1.0) / 2.0;
    let radius = center;
    for y in 0..S {
        for x in 0..S {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            if (dx * dx + dy * dy).sqrt() <= radius {
                let i = ((y * S + x) * 4) as usize;
                rgba[i] = 0x14; // R
                rgba[i + 1] = 0xb8; // G
                rgba[i + 2] = 0xa6; // B
                rgba[i + 3] = 0xff; // A
            }
        }
    }
    Icon::from_rgba(rgba, S, S).expect("valid icon")
}
