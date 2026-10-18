#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Regression tests for the retired authoring entry points. Requires bash, just,
# and standard coreutils. From the repository root: bash tests/profile-authoring-test.sh
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

command -v just >/dev/null || { echo 'FAIL: just is required' >&2; exit 1; }

assert_retired() {
    local name=$1
    shift
    local case_dir="$test_root/$name"
    local baseline_dir="$test_root/$name-before"
    local status=0

    # Run against a disposable copy so even a regression cannot modify the
    # repository. Reuse an existing legacy input; author no new A2ML in the repo.
    mkdir -p "$case_dir/profiles" "$case_dir/panel-clades/gsa-game-valheim" "$case_dir/scripts"
    cp "$repo_root/Justfile" "$case_dir/Justfile"
    cp "$repo_root/scripts/generate-clades.sh" "$case_dir/scripts/generate-clades.sh"
    cp "$repo_root/profiles/valheim.a2ml" "$case_dir/profiles/valheim.a2ml"
    printf '%s\n' 'existing clade sentinel' > "$case_dir/panel-clades/gsa-game-valheim/keep.txt"
    cp -a "$case_dir" "$baseline_dir"

    (cd "$case_dir" && "$@" </dev/null) >"$test_root/$name.log" 2>&1 || status=$?
    if [[ $status != 1 ]]; then
        printf 'FAIL: %s exited %s, expected 1\n' "$name" "$status" >&2
        cat "$test_root/$name.log" >&2
        return 1
    fi
    local output
    output=$(cat "$test_root/$name.log")
    if [[ "$output" != *"Disabled:"* || "$output" != *"retired"* ]]; then
        printf 'FAIL: %s did not explain its retirement\n' "$name" >&2
        cat "$test_root/$name.log" >&2
        return 1
    fi
    # Includes additions, removals, directory changes and modified contents.
    diff -r "$baseline_dir" "$case_dir"
    printf 'PASS: %s refuses generation and preserves all existing files\n' "$name"
}

assert_retired script bash scripts/generate-clades.sh
assert_retired add-profile just --no-dotenv add-profile boundary-regression
assert_retired generate-clades just --no-dotenv generate-clades
