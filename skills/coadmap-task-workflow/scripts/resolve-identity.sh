#!/usr/bin/env bash
# usage: resolve-identity.sh <host|task URL>
# .identities[<host>].accountId があれば echo して exit 0。無ければ何も出さず exit 3（要ヒアリング）。
# accountId は Coadmap の接続先ごとに別物なので、ホスト単位で引く。
# ホスト別になる前の単一の .identity は、当時の接続先だった coadmap.com のものとして扱う。
set -euo pipefail
[[ $# -ge 1 && -n "$1" ]] || { echo "usage: resolve-identity.sh <host|task URL>" >&2; exit 2; }
# shellcheck source=lib/host.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/host.sh"
host="$(normalize_host "$1")"
STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
[[ -f "$STATE" ]] || exit 3
acc="$(jq -r --arg h "$host" \
  '.identities[$h].accountId // (if $h == "coadmap.com" then .identity.accountId else empty end) // empty' \
  "$STATE" 2>/dev/null || true)"
[[ -n "$acc" ]] || exit 3
printf '%s' "$acc"
