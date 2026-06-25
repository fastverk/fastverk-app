//! `fastverk-settings` — the egui/eframe settings window, an `fvd` gRPC
//! client. Launched by the menu-bar app (tray) with an optional panel
//! name as argv[1] (`connections` | `volumes` | `bazelrc` | `maintenance`
//! | `status`). Runs in its own process + event loop, so it never
//! contends with the tray's `tao` loop.
//!
//! Async fvd calls run on a background tokio worker; the UI sends typed
//! `Job`s and reads a shared snapshot, repainting when the worker updates.

use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

use eframe::egui;
use fvkit::proto::{
    BazelrcApplyRequest, BazelrcPreviewRequest, ConnectProviderRequest, Connection,
    DisconnectRequest, GetStatusRequest, ListConnectionsRequest, MaintainNowRequest,
    MaintenanceReport, OAuthConfig, RepoSyncReport, ReposSyncRequest, StatusResponse, VolumeAudit,
    VolumeAuditRequest, VolumeCreateRequest, VolumeDisposition,
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Status,
    Connections,
    Volumes,
    Repos,
    Bazelrc,
    Maintenance,
}

#[derive(Default, Clone)]
struct Shared {
    busy: bool,
    error: Option<String>,
    status: Option<StatusResponse>,
    connections: Vec<Connection>,
    audits: Vec<VolumeAudit>,
    repo_sources: Vec<String>,
    repo_report: Option<RepoSyncReport>,
    bazelrc: String,
    maint: Option<MaintenanceReport>,
    log: Vec<String>,
}

enum Job {
    Refresh,
    Connect {
        provider: String,
        host: String,
        client_id: String,
        api_key: String,
    },
    Disconnect(String),
    VolumeCreate(String),
    ReposSync { dry_run: bool },
    BazelrcApply { dry_run: bool },
    Maintain { dry_run: bool },
}

struct App {
    tab: Tab,
    shared: Arc<Mutex<Shared>>,
    jobs: Sender<Job>,
    connect_provider: String,
    connect_host: String,
    connect_client_id: String,
    connect_api_key: String,
}

impl App {
    fn send(&self, job: Job) {
        let _ = self.jobs.send(job);
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let snap = self.shared.lock().unwrap().clone();

        egui::TopBottomPanel::top("tabs").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.tab, Tab::Status, "Status");
                ui.selectable_value(&mut self.tab, Tab::Connections, "Connections");
                ui.selectable_value(&mut self.tab, Tab::Volumes, "Volumes");
                ui.selectable_value(&mut self.tab, Tab::Repos, "Repos");
                ui.selectable_value(&mut self.tab, Tab::Bazelrc, "Bazelrc");
                ui.selectable_value(&mut self.tab, Tab::Maintenance, "Maintenance");
                ui.separator();
                if ui.button("Refresh").clicked() {
                    self.send(Job::Refresh);
                }
                if snap.busy {
                    ui.spinner();
                }
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            if let Some(err) = &snap.error {
                ui.colored_label(egui::Color32::from_rgb(0xd0, 0x40, 0x40), err);
                ui.separator();
            }
            match self.tab {
                Tab::Status => self.status_panel(ui, &snap),
                Tab::Connections => self.connections_panel(ui, &snap),
                Tab::Volumes => self.volumes_panel(ui, &snap),
                Tab::Repos => self.repos_panel(ui, &snap),
                Tab::Bazelrc => self.bazelrc_panel(ui, &snap),
                Tab::Maintenance => self.maintenance_panel(ui, &snap),
            }
        });
    }
}

impl App {
    fn status_panel(&self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("Daemon");
        match &snap.status {
            Some(s) => {
                ui.label(format!("fvd v{}", s.version));
                ui.label(format!("connections: {}", s.connection_count));
                ui.label(format!("volumes: {}", s.volumes.len()));
                if s.update_available {
                    ui.label(format!("update available: {}", s.latest_version));
                }
            }
            None => {
                ui.label("(press Refresh)");
            }
        }
    }

    fn connections_panel(&mut self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("Connections");
        if snap.connections.is_empty() {
            ui.label("(no connections)");
        }
        for c in &snap.connections {
            ui.horizontal(|ui| {
                ui.monospace(format!("{:<12}", c.id));
                ui.label(c.host_patterns.join(", "));
                if ui.button("Disconnect").clicked() {
                    self.send(Job::Disconnect(c.id.clone()));
                }
            });
        }
        ui.separator();
        ui.heading("Connect a provider");
        ui.horizontal(|ui| {
            ui.label("provider:");
            egui::ComboBox::from_id_salt("provider")
                .selected_text(&self.connect_provider)
                .show_ui(ui, |ui| {
                    for p in ["github", "gitlab", "buildbuddy"] {
                        ui.selectable_value(&mut self.connect_provider, p.to_string(), p);
                    }
                });
        });
        if self.connect_provider != "buildbuddy" {
            ui.horizontal(|ui| {
                ui.label("host:");
                ui.text_edit_singleline(&mut self.connect_host);
            });
            ui.small("blank = default (github.com / gitlab.savvifi.com). For enterprise / self-hosted, e.g. github.acme.com.");
        }
        if self.connect_provider == "buildbuddy" {
            ui.horizontal(|ui| {
                ui.label("API key:");
                ui.text_edit_singleline(&mut self.connect_api_key);
            });
        } else {
            ui.horizontal(|ui| {
                ui.label("OAuth client id:");
                ui.text_edit_singleline(&mut self.connect_client_id);
            });
            ui.small("Blank uses the bundled id for known hosts; required for custom instances. Device-code flow; watch for the fvd notification with the user code.");
        }
        if ui.button("Connect").clicked() {
            self.send(Job::Connect {
                provider: self.connect_provider.clone(),
                host: self.connect_host.clone(),
                client_id: self.connect_client_id.clone(),
                api_key: self.connect_api_key.clone(),
            });
        }
    }

    fn volumes_panel(&mut self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("Volumes");
        ui.small(
            "Audit-first: fastverk never reformats or mounts over existing data. \
             It only creates genuinely-absent volumes and adopts/augments the rest in place.",
        );
        ui.add_space(4.0);
        for a in &snap.audits {
            let spec = a.state.as_ref().and_then(|s| s.spec.clone()).unwrap_or_default();
            let state = a.state.clone().unwrap_or_default();
            let (label, color) = disposition_badge(a.disposition);
            ui.horizontal(|ui| {
                ui.monospace(format!("{:<8}", spec.id));
                ui.colored_label(color, format!("{label:<8}"));
                ui.label(&spec.mount_point);
                if state.exists {
                    ui.label(format!("{} free", human(state.free_bytes)));
                }
            });
            ui.small(&a.detail);
        }
        if snap.audits.is_empty() {
            ui.label("(press Refresh)");
        }
        ui.separator();
        if ui
            .button("Provision volumes (audit-safe; prompts for admin)")
            .on_hover_text("Creates only absent volumes; existing data is left untouched.")
            .clicked()
        {
            self.send(Job::VolumeCreate("all".to_string()));
        }
        for line in &snap.log {
            ui.small(line);
        }
    }

    fn repos_panel(&mut self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("Repos");
        ui.small("Org/group sources kept in sync with the repos volume + worktrees.");
        ui.add_space(4.0);
        if snap.repo_sources.is_empty() {
            ui.label("(no sources configured)");
        }
        for s in &snap.repo_sources {
            ui.monospace(s);
        }
        ui.separator();
        ui.horizontal(|ui| {
            if ui
                .button("Sync (clone + pull)")
                .on_hover_text("Clone missing repos and fast-forward clean clones.")
                .clicked()
            {
                self.send(Job::ReposSync { dry_run: false });
            }
            if ui.button("Dry run").clicked() {
                self.send(Job::ReposSync { dry_run: true });
            }
        });
        if let Some(r) = &snap.repo_report {
            ui.add_space(4.0);
            let count = |a: &str| r.outcomes.iter().filter(|o| o.action == a).count();
            let skipped = r
                .outcomes
                .iter()
                .filter(|o| o.action.starts_with("skipped"))
                .count();
            ui.label(format!(
                "cloned {}  updated {}  up-to-date {}  skipped {}  failed {}",
                count("cloned"),
                count("updated"),
                count("up-to-date"),
                skipped,
                count("failed"),
            ));
            egui::ScrollArea::vertical().max_height(220.0).show(ui, |ui| {
                for o in &r.outcomes {
                    ui.small(format!("{:<10} {:<28} {}", o.action, o.name, o.detail));
                }
            });
        }
    }

    fn bazelrc_panel(&mut self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("~/.bazelrc (managed region)");
        ui.horizontal(|ui| {
            if ui.button("Apply").clicked() {
                self.send(Job::BazelrcApply { dry_run: false });
            }
            if ui.button("Dry run").clicked() {
                self.send(Job::BazelrcApply { dry_run: true });
            }
        });
        egui::ScrollArea::vertical().show(ui, |ui| {
            ui.monospace(if snap.bazelrc.is_empty() {
                "(press Refresh)"
            } else {
                &snap.bazelrc
            });
        });
    }

    fn maintenance_panel(&mut self, ui: &mut egui::Ui, snap: &Shared) {
        ui.heading("Maintenance");
        ui.horizontal(|ui| {
            if ui.button("Run").clicked() {
                self.send(Job::Maintain { dry_run: false });
            }
            if ui.button("Dry run").clicked() {
                self.send(Job::Maintain { dry_run: true });
            }
        });
        if let Some(r) = &snap.maint {
            for t in &r.tasks {
                ui.label(format!(
                    "{:<16} {} {}",
                    t.name,
                    if t.ok { "ok" } else { "FAIL" },
                    t.detail
                ));
            }
        }
    }
}

/// The configured repo sources, as display strings (read directly from
/// the fastverk config; the registry has no list-sources RPC).
fn configured_sources() -> Vec<String> {
    fvkit::config::Config::load()
        .map(|cfg| {
            cfg.sources
                .iter()
                .map(|s| {
                    format!(
                        "{:<8} {:<22} {}{}",
                        s.forge,
                        s.host,
                        s.group,
                        if s.include_archived { "  (incl. archived)" } else { "" }
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `(label, color)` for a volume disposition badge.
fn disposition_badge(disposition: i32) -> (&'static str, egui::Color32) {
    match VolumeDisposition::try_from(disposition) {
        Ok(VolumeDisposition::Create) => ("CREATE", egui::Color32::from_rgb(0x40, 0xa0, 0xd0)),
        Ok(VolumeDisposition::Adopt) => ("ADOPT", egui::Color32::from_rgb(0x40, 0xc0, 0x60)),
        Ok(VolumeDisposition::Migrate) => ("MIGRATE", egui::Color32::from_rgb(0xd0, 0xa0, 0x40)),
        Ok(VolumeDisposition::Conflict) => ("CONFLICT", egui::Color32::from_rgb(0xd0, 0x40, 0x40)),
        _ => ("UNKNOWN", egui::Color32::GRAY),
    }
}

fn human(bytes: i64) -> String {
    const U: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut b = bytes as f64;
    let mut i = 0;
    while b >= 1024.0 && i < U.len() - 1 {
        b /= 1024.0;
        i += 1;
    }
    format!("{b:.1}{}", U[i])
}

fn spawn_worker(shared: Arc<Mutex<Shared>>, ctx: egui::Context) -> Sender<Job> {
    let (tx, rx) = channel::<Job>();
    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                shared.lock().unwrap().error = Some(format!("runtime: {e}"));
                ctx.request_repaint();
                return;
            }
        };
        for job in rx {
            {
                let mut g = shared.lock().unwrap();
                g.busy = true;
                g.error = None;
            }
            ctx.request_repaint();
            let res = rt.block_on(run_job(job, &shared));
            {
                let mut g = shared.lock().unwrap();
                g.busy = false;
                if let Err(e) = res {
                    g.error = Some(e.to_string());
                }
            }
            ctx.request_repaint();
        }
    });
    tx
}

async fn run_job(job: Job, shared: &Arc<Mutex<Shared>>) -> anyhow::Result<()> {
    // fvkit exposes its own `anyhow` across the module boundary; this crate's
    // `anyhow` is a distinct crate (two isolated crate_universes), so we
    // convert at the edge via Display rather than relying on a same-type `From`.
    let mut c = fvkit::ipc::connect_default()
        .await
        .map_err(|e| anyhow::anyhow!("{e:#}"))?;
    match job {
        Job::Refresh => {
            let status = c.get_status(GetStatusRequest {}).await?.into_inner();
            let connections = c
                .list_connections(ListConnectionsRequest {})
                .await?
                .into_inner()
                .connections;
            let audits = c
                .volume_audit(VolumeAuditRequest {})
                .await?
                .into_inner()
                .audits;
            let bazelrc = c
                .bazelrc_preview(BazelrcPreviewRequest {})
                .await?
                .into_inner()
                .managed_block;
            let repo_sources = configured_sources();
            let mut g = shared.lock().unwrap();
            g.status = Some(status);
            g.connections = connections;
            g.audits = audits;
            g.repo_sources = repo_sources;
            g.bazelrc = bazelrc;
        }
        Job::Connect {
            provider,
            host,
            client_id,
            api_key,
        } => {
            c.connect_provider(ConnectProviderRequest {
                provider,
                host,
                oauth: if client_id.is_empty() {
                    None
                } else {
                    Some(OAuthConfig {
                        client_id,
                        ..Default::default()
                    })
                },
                api_key,
                ..Default::default()
            })
            .await?;
            let connections = c
                .list_connections(ListConnectionsRequest {})
                .await?
                .into_inner()
                .connections;
            shared.lock().unwrap().connections = connections;
        }
        Job::Disconnect(id) => {
            c.disconnect(DisconnectRequest { id }).await?;
            let connections = c
                .list_connections(ListConnectionsRequest {})
                .await?
                .into_inner()
                .connections;
            shared.lock().unwrap().connections = connections;
        }
        Job::VolumeCreate(id) => {
            let r = c.volume_create(VolumeCreateRequest { id }).await?.into_inner();
            shared.lock().unwrap().log.push(r.message);
            // Re-audit so the panel reflects the post-provision state.
            let audits = c
                .volume_audit(VolumeAuditRequest {})
                .await?
                .into_inner()
                .audits;
            shared.lock().unwrap().audits = audits;
        }
        Job::ReposSync { dry_run } => {
            let r = c
                .repos_sync(ReposSyncRequest {
                    pull: !dry_run,
                    validate_only: dry_run,
                    ..Default::default()
                })
                .await?
                .into_inner();
            shared.lock().unwrap().repo_report = Some(r);
        }
        Job::BazelrcApply { dry_run } => {
            let r = c
                .bazelrc_apply(BazelrcApplyRequest {
                    validate_only: dry_run,
                })
                .await?
                .into_inner();
            shared.lock().unwrap().log.push(if r.changed {
                r.diff
            } else {
                "already up to date".to_string()
            });
        }
        Job::Maintain { dry_run } => {
            let r = c
                .maintain_now(MaintainNowRequest {
                    validate_only: dry_run,
                    only: vec![],
                })
                .await?
                .into_inner();
            shared.lock().unwrap().maint = Some(r);
        }
    }
    Ok(())
}

fn main() -> eframe::Result<()> {
    let tab = match std::env::args().nth(1).as_deref() {
        Some("connections") => Tab::Connections,
        Some("volumes") => Tab::Volumes,
        Some("repos") => Tab::Repos,
        Some("bazelrc") => Tab::Bazelrc,
        Some("maintenance") => Tab::Maintenance,
        _ => Tab::Status,
    };
    let shared = Arc::new(Mutex::new(Shared::default()));
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "fastverk",
        options,
        Box::new(move |cc| {
            let jobs = spawn_worker(shared.clone(), cc.egui_ctx.clone());
            let _ = jobs.send(Job::Refresh);
            Ok(Box::new(App {
                tab,
                shared,
                jobs,
                connect_provider: "github".to_string(),
                connect_host: String::new(),
                connect_client_id: String::new(),
                connect_api_key: String::new(),
            }))
        }),
    )
}
