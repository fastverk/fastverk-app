"""macOS `.app` bundle + `.dmg` packaging for the fastverk app.

Genrule-based: `codesign` / `hdiutil` are non-hermetic macOS tools, so the
genrules are tagged `local` (run outside the sandbox) + `manual` (skipped
by `//...` wildcards; build them explicitly).

The default build **ad-hoc signs** (identity `-`). Pass a real
`"Developer ID Application: …"` via `identity` once available.

**Notarization is intentionally NOT part of the build.** It needs an
Apple Developer ID + a `notarytool` keychain profile; see the gated step
in `.github/workflows/release.yml`. `spctl -a` will reject an ad-hoc /
un-notarized bundle — expected until then.
"""

def macos_app_bundle(name, app_name, plist, binaries, icon = None, identity = "-", **kwargs):
    """Assemble + ad-hoc-codesign a `.app`, output as `<name>.tar`.

    Args:
      name: target name (output is `<name>.tar`, a tar of `<app_name>.app`).
      app_name: bundle name; also `Contents/MacOS/<app_name>` is the exec.
      plist: the `Info.plist` file label.
      binaries: dict of `binary_label -> dest filename` placed in
        `Contents/MacOS/`.
      icon: optional `.icns` file label (copied to `Resources/AppIcon.icns`).
      identity: codesign identity (`-` = ad-hoc; a Developer ID later).
      **kwargs: forwarded to the genrule.
    """
    cp_bins = [
        'cp $(location {}) "$$M/{}"'.format(label, dest)
        for label, dest in binaries.items()
    ]
    icon_line = 'cp $(location {}) "$$R/AppIcon.icns"'.format(icon) if icon else "true"
    srcs = list(binaries.keys()) + [plist] + ([icon] if icon else [])
    cmd = "\n".join([
        "set -e",
        'A="$$(mktemp -d)/{}.app"'.format(app_name),
        'M="$$A/Contents/MacOS"',
        'R="$$A/Contents/Resources"',
        'mkdir -p "$$M" "$$R"',
    ] + cp_bins + [
        'cp $(location {}) "$$A/Contents/Info.plist"'.format(plist),
        icon_line,
        'chmod +x "$$M/"*',
        'codesign --force --deep --sign "{}" "$$A" 2>/dev/null || echo "fastverk: ad-hoc codesign skipped" >&2'.format(identity),
        'tar -C "$$(dirname "$$A")" -cf $@ "{}.app"'.format(app_name),
    ])
    native.genrule(
        name = name,
        srcs = srcs,
        outs = [name + ".tar"],
        cmd = cmd,
        tags = ["local", "manual"],
        **kwargs
    )

def macos_dmg(name, app, app_name, volname, **kwargs):
    """Build `<name>.dmg` from a `macos_app_bundle` tar via `hdiutil`."""
    cmd = "\n".join([
        "set -e",
        'T="$$(mktemp -d)"',
        'tar -C "$$T" -xf $(location {})'.format(app),
        'hdiutil create -volname "{}" -srcfolder "$$T/{}.app" -ov -format UDZO $@ >/dev/null'.format(volname, app_name),
    ])
    native.genrule(
        name = name,
        srcs = [app],
        outs = [name + ".dmg"],
        cmd = cmd,
        tags = ["local", "manual"],
        **kwargs
    )
