#!/usr/bin/env bash
# usage: release-port.sh <branch>
# registry から該当 branch の確保ポートを解放する。alloc-ports.sh と同じ mkdir ロック下で
# 行い、並行更新によるロストアップデートを防ぐ。registry が無ければ何もしない。
set -euo pipefail
branch="$1"
REG="${COADMAP_PORT_REGISTRY:-$HOME/.coadmap/port-registry.json}"
[[ -f "$REG" ]] || exit 0

LOCK="$REG.lock"
find "$LOCK" -maxdepth 0 -type d -mmin +1 -exec rmdir {} + 2>/dev/null || true
acquired=false
for _ in $(seq 1 2000); do
  if mkdir "$LOCK" 2>/dev/null; then acquired=true; break; fi
  sleep 0.01
done
if [[ "$acquired" != "true" ]]; then
  echo "release-port: failed to acquire lock ($LOCK)" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

tmp="$(mktemp)"
jq --arg b "$branch" 'del(.[$b])' "$REG" > "$tmp" && mv "$tmp" "$REG"
