#!/usr/bin/env bash
# .identity.accountId があれば echo して exit 0。無ければ何も出さず exit 3（要ヒアリング）。
set -euo pipefail
STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
[[ -f "$STATE" ]] || exit 3
acc="$(jq -r '.identity.accountId // empty' "$STATE" 2>/dev/null || true)"
[[ -n "$acc" ]] || exit 3
printf '%s' "$acc"
