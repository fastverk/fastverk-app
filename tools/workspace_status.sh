#!/usr/bin/env bash
# Bazel workspace-status: emit STABLE_FASTVERK_VERSION so the fvkit lib
# (rustc_env = {"FASTVERK_VERSION": "{STABLE_FASTVERK_VERSION}"}, stamp = 1)
# bakes the real version into the binaries. fvkit::version() then reports it
# instead of the crate-version fallback — so a freshly-installed release stops
# seeing itself as "update available".
#
# On a tagged release build the version is the tag (e.g. v0.0.4 -> 0.0.4);
# locally it's `git describe` (e.g. 0.0.3-5-gabc123). Wired via
# `build --workspace_status_command` in .bazelrc.
set -euo pipefail

version="${FASTVERK_RELEASE_VERSION:-}"
if [ -z "$version" ]; then
  version="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
fi
version="${version#v}"

echo "STABLE_FASTVERK_VERSION ${version}"
