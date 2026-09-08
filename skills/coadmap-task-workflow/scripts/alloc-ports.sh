#!/usr/bin/env bash
# usage: alloc-ports.sh <branch> <base-port>
# branch 名のハッシュから [base, base+1000) の決定的ポートを算出し registry に記録して echo。
# - 同一 branch には常に同じポートを返す（決定性）。
# - 他 branch が確保済みのポートは線形プロービングで避ける。
# - registry の read-modify-write は mkdir ロックで直列化し、並行 worktree 間の
#   ロストアップデート/重複割当を防ぐ（macOS には flock が無いため mkdir を使う）。
# - 空きが無い場合は非ゼロ終了する。
set -euo pipefail
branch="$1"; base="$2"
REG="${COADMAP_PORT_REGISTRY:-$HOME/.coadmap/port-registry.json}"
mkdir -p "$(dirname "$REG")"

# --- ロック取得（mkdir はアトミック）。短命クリティカルセクション。 ---
LOCK="$REG.lock"
# クリティカルセクションは一瞬なので、1 分以上残っている lock は SIGKILL 等で取り残された
# ものとみなして回収する。これが無いと以後の全呼び出しが 20 秒待って失敗し続ける。
find "$LOCK" -maxdepth 0 -type d -mmin +1 -exec rmdir {} + 2>/dev/null || true
acquired=false
for _ in $(seq 1 2000); do
  if mkdir "$LOCK" 2>/dev/null; then acquired=true; break; fi
  sleep 0.01
done
if [[ "$acquired" != "true" ]]; then
  echo "alloc-ports: failed to acquire lock ($LOCK)" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

[[ -f "$REG" ]] || echo '{}' > "$REG"

# 既に割当済みなら再利用（決定性）
existing="$(jq -r --arg b "$branch" '.[$b].port // empty' "$REG" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then printf '%s' "$existing"; exit 0; fi

# branch ハッシュ -> 0..999 オフセット
h="$(printf '%s' "$branch" | cksum | awk '{print $1}')"
port=$(( base + h % 1000 ))
# 衝突回避（他 branch が同ポートを保持していたら +1 ずつ。空きが見つかるまで最大1000回）
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
jq --arg b "$branch" --argjson p "$port" '.[$b] = {port:$p}' "$REG" > "$tmp"; mv "$tmp" "$REG"
printf '%s' "$port"
