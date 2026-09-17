#!/usr/bin/env bash
# usage: alloc-ports.sh <branch> <base-port>
# branch 名のハッシュから [base, base+1000) の決定的ポートを算出し registry に記録して echo。
# - 同一 (branch, base) には常に同じポートを返す（決定性）。base が違えば別サービス扱いで
#   別ポートを割り当てる（backend=3000 と frontend=5173 を同じブランチで同時に立てるため）。
# - 他エントリが確保済みのポートは線形プロービングで避ける。
# - registry の read-modify-write は mkdir ロックで直列化し、並行 worktree 間の
#   ロストアップデート/重複割当を防ぐ。
# - 空きが無い場合は非ゼロ終了する。
# registry 内の他ブランチとだけ衝突を避ける。ホスト上の実際の占有(lsof 等)は見ていない。
set -euo pipefail
branch="$1"; base="$2"
REG="${COADMAP_PORT_REGISTRY:-$HOME/.coadmap/port-registry.json}"
mkdir -p "$(dirname "$REG")"
# shellcheck source=lib/lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lock.sh"
acquire_lock "$REG.lock"

[[ -f "$REG" ]] || echo '{}' > "$REG"
key="${branch}:${base}"

existing="$(jq -r --arg k "$key" '.[$k].port // empty' "$REG" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then printf '%s' "$existing"; exit 0; fi

# branch ハッシュ -> 0..999 オフセット
h="$(printf '%s' "$branch" | cksum | awk '{print $1}')"
port=$(( base + h % 1000 ))
allocated=false
for _ in $(seq 0 999); do
  taken="$(jq -r --argjson p "$port" 'to_entries | map(select(.value.port==$p)) | length' "$REG")"
  if [[ "$taken" == "0" ]]; then allocated=true; break; fi
  port=$(( base + ( (port - base + 1) % 1000 ) ))
done
if [[ "$allocated" != "true" ]]; then
  echo "alloc-ports: no free port in [$base, $((base + 1000)))" >&2
  exit 1
fi
tmp="$(mktemp)"
jq --arg k "$key" --arg b "$branch" --argjson base "$base" --argjson p "$port" \
  '.[$k] = {port:$p, branch:$b, base:$base}' "$REG" > "$tmp"; mv "$tmp" "$REG"
printf '%s' "$port"
