#!/usr/bin/env bash
# usage: save-identity.sh <accountId> <email> <displayName>
# ~/.coadmap/task-flow.json の .identity を更新（既存の .workspaces 等は保持）。
set -euo pipefail
STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
mkdir -p "$(dirname "$STATE")"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"
tmp="$(mktemp)"
jq --arg a "$1" --arg e "$2" --arg d "$3" \
  '.identity = {accountId:$a, email:$e, displayName:$d}' "$STATE" > "$tmp"
mv "$tmp" "$STATE"
