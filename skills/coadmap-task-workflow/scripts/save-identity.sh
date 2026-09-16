#!/usr/bin/env bash
# usage: save-identity.sh <accountId> <email> <displayName>
# ~/.coadmap/task-flow.json の .identity を更新（既存キーは保持）。
# 並行セッションが同じファイルを書くのでロック下で read-modify-write する。
set -euo pipefail
STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
mkdir -p "$(dirname "$STATE")"
# shellcheck source=lib/lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lock.sh"
acquire_lock "$STATE.lock"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"
tmp="$(mktemp)"
jq --arg a "$1" --arg e "$2" --arg d "$3" \
  '.identity = {accountId:$a, email:$e, displayName:$d}' "$STATE" > "$tmp"
mv "$tmp" "$STATE"
