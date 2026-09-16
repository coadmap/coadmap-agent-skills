#!/usr/bin/env bash
# usage: release-port.sh <branch>
# registry から該当 branch の確保ポートを(base 違いも含めて)すべて解放する。alloc-ports.sh と
# 同じ mkdir ロック下で行い、並行更新によるロストアップデートを防ぐ。registry が無ければ何もしない。
set -euo pipefail
branch="$1"
REG="${COADMAP_PORT_REGISTRY:-$HOME/.coadmap/port-registry.json}"
[[ -f "$REG" ]] || exit 0
# shellcheck source=lib/lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lock.sh"
acquire_lock "$REG.lock"

tmp="$(mktemp)"
# 旧形式(キーが branch 名のみ)のエントリも同時に消す
jq --arg b "$branch" 'with_entries(select(.key != $b and (.key | startswith($b + ":") | not)))' "$REG" > "$tmp" && mv "$tmp" "$REG"
