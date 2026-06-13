//! `fastverk` — the menu-bar application.
//!
//! P3 builds the real UI: a `tray-icon` + `muda` menu-bar item and
//! `egui`/`eframe` settings windows (Connections, Volumes, Bazelrc,
//! Maintenance, Updates), all as a gRPC client to the `fvd` daemon
//! (autostarting it if absent). P0 is a placeholder so the crate and its
//! Bazel target exist and the workspace builds.

fn main() {
    println!(
        "fastverk app — UI lands in P3. Start the daemon with `fvd` (or `bazel run //app/daemon:fvd`)."
    );
}
