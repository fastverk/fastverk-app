#!/usr/bin/env bash
# Bazel credential helper: forwards `gh auth token` as a Bearer header.
#
# Bazel protocol: stdin = JSON with a `uri` field; stdout = JSON with
# a `headers` field. See:
# https://github.com/EngFlow/credential-helper-spec
#
# Use case: fetching private GitHub tarballs (e.g., source.json URLs
# in fastverk's premium bazel-registry that point at private repos).
# Wired in .bazelrc:
#   common --credential_helper=*.github.com=%workspace%/tools/credhelper/gh-cred-helper.sh
#   common --credential_helper=github.com=%workspace%/tools/credhelper/gh-cred-helper.sh
#   common --credential_helper=raw.githubusercontent.com=%workspace%/tools/credhelper/gh-cred-helper.sh
#   common --credential_helper=codeload.github.com=%workspace%/tools/credhelper/gh-cred-helper.sh
set -euo pipefail

read -r _request_json || true

token=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
    token="$GITHUB_TOKEN"
elif [ -n "${GH_TOKEN:-}" ]; then
    token="$GH_TOKEN"
elif command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
fi

if [ -z "$token" ]; then
    echo '{"headers": {}}'
    exit 0
fi

printf '{"headers": {"Authorization": ["Bearer %s"]}}\n' "$token"
