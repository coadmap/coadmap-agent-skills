#!/usr/bin/env bash
# usage: save-identity.sh <host|task URL> <accountId> <email> <displayName>
# ~/.coadmap/task-flow.json の .identities[<host>] を更新（既存キーは保持）。
# 並行セッションが同じファイルを書くのでロック下で read-modify-write する。
set -euo pipefail
[[ $# -eq 4 && -n "$1" && -n "$2" ]] || { echo "usage: save-identity.sh <host|task URL> <accountId> <email> <displayName>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/host.sh
. "$HERE/lib/host.sh"
host="$(normalize_host "$1")"
STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
mkdir -p "$(dirname "$STATE")"
# shellcheck source=lib/lock.sh
. "$HERE/lib/lock.sh"
acquire_lock "$STATE.lock"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"
tmp="$(mktemp)"
jq --arg h "$host" --arg a "$2" --arg e "$3" --arg d "$4" \
  '.identities[$h] = {accountId:$a, email:$e, displayName:$d}' "$STATE" > "$tmp"
mv "$tmp" "$STATE"
