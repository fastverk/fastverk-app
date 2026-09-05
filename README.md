> [!IMPORTANT]
> **This repository is retired.** `fastverk-app` is developed in the
> [`fastverk/desktop`](https://github.com/fastverk/desktop) ship vehicle, at
> [`fastverk-app/`](https://github.com/fastverk/desktop/tree/main/fastverk-app).
> Open issues and pull requests there.
>
> The published module is unchanged — `bazel_dep(name = "fastverk-app", version = "0.0.2")`
> resolves exactly as before. This remote keeps its full history and every tag,
> including the `ios-v*` line, so existing registry entries and `git_override`
> pins stay valid.
>
> Retired at [`985a7a0`](https://github.com/fastverk/fastverk-app/commit/985a7a0feee08a95e92331418a0c0f2eb28b6ed6),
> the commit the vehicle imported — nothing here is unimported. Background:
> [Consolidation](https://docs.fastverk.com/consolidation.html).

# fastverk-app

The fastverk macOS desktop app and the daemon-aware Bazel credential helper.

Three crates, all gRPC clients of the [`fvd`](https://github.com/fastverk/fvkit)
daemon, built on the `fvkit` core library:

- **`fastverk`** (`app/desktop`) — the menu-bar app: a `tao` event loop hosting
  a `tray-icon`/`muda` status item. Menu actions talk to `fvd` over its Unix
  socket and surface results as macOS notifications.
- **`fastverk-settings`** (`app/settings`) — the `eframe`/`egui` settings window
  (Status / Connections / Volumes / Repos / Bazelrc / Maintenance), launched by
  the tray as a separate process.
- **`fastverk-cred-helper`** (`tools/credhelper`) — the universal Bazel
  credential helper. Resolves auth headers for a request host from the
  connection registry + OS keychain (`fvkit::connections`), replacing the
  per-service `gh-cred-helper.sh` / `glab` shell scripts.

`tools/macos` packages the binaries into a signed `.app` + `.dmg`.

## Building

Bazel is the primary build:

```sh
CARGO_BAZEL_REPIN=1 bazel build //...
bazel test //...
```

The first build fetches the [`fvkit`](https://github.com/fastverk/fvkit)
module (v0.0.1) from the fastverk Bazel registry — see `.bazelrc`.

### The fvkit dependency

`fvkit` is consumed as a **Bazel module** (`@fvkit//app/core:fvkit`,
`@fvkit//app/daemon:fvd`), declared in `MODULE.bazel` via
`bazel_dep(name = "fvkit", version = "0.0.1")`. The `crate` extension uses
`from_specs` (third-party crates only) rather than `from_cargo`, so fvkit is
not double-managed across the module boundary — the same pattern `wave` uses
for `forge`.

The Cargo workspace's `fvkit = { path = "../fvkit/app/core" }` dep is for
cargo / IDE iteration only; it resolves when a sibling `../fvkit` checkout is
present next to this repo. Bazel never uses it.

### macOS bundle

```sh
bazel build //tools/macos:fastverk_dmg   # the installer .dmg
bazel build //tools/macos:fastverk_app   # just the bundled .app (tar)
```

These are `manual` + `local` (non-hermetic `codesign` / `hdiutil`), so the
`//...` wildcard skips them; build them explicitly.

> The `fv` CLI (from the fastverk meta-repo) is intentionally **not** bundled
> yet — it has no release artifact. See the TODO in `tools/macos/BUILD.bazel`.
