#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../alloc-ports.sh"
TMP="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP/port-registry.json"
fail=0
# usage: alloc-ports.sh <branch> <base-port> -> 割当ポートを echo
p1="$(bash "$SUT" "claude/CMDEV-1" 8000)"
p1b="$(bash "$SUT" "claude/CMDEV-1" 8000)"
p2="$(bash "$SUT" "claude/CMDEV-2" 8000)"
[[ "$p1" == "$p1b" ]] && echo "ok: 決定性(同一branchは同一)" || { echo "NG: 決定性 $p1 != $p1b"; fail=1; }
[[ "$p1" != "$p2" ]] && echo "ok: branch差で別ポート" || { echo "NG: 衝突 $p1 == $p2"; fail=1; }
[[ "$p1" -ge 8000 && "$p1" -lt 9000 ]] && echo "ok: 範囲内" || { echo "NG: 範囲外 $p1"; fail=1; }
jq -e --arg b "claude/CMDEV-1" '.[$b].port' "$COADMAP_PORT_REGISTRY" >/dev/null && echo "ok: registry記録" || { echo "NG: registry"; fail=1; }
rm -rf "$TMP"

# 回帰: 並行割当でロストアップデート/重複が起きない（10件同時）
TMP2="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP2/reg.json"
pids=()
for i in $(seq 1 10); do bash "$SUT" "br-$i" 9000 >/dev/null & pids+=($!); done
prc=0; for p in "${pids[@]}"; do wait "$p" || prc=1; done
[[ "$prc" == "0" ]] && echo "ok: 並行割当が全て成功" || { echo "NG: 並行割当でエラー"; fail=1; }
cnt="$(jq 'length' "$COADMAP_PORT_REGISTRY")"
[[ "$cnt" == "10" ]] && echo "ok: 並行10件すべて保持" || { echo "NG: 並行ロストアップデート cnt=$cnt"; fail=1; }
uniq="$(jq '[.[].port] | unique | length' "$COADMAP_PORT_REGISTRY")"
[[ "$uniq" == "10" ]] && echo "ok: 並行ポート重複なし" || { echo "NG: ポート重複 uniq=$uniq"; fail=1; }
rm -rf "$TMP2"

# 回帰: 空きポート枯渇時は使用中ポートを返さず非ゼロ終了
TMP3="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP3/reg.json"
jq -n 'reduce range(0;1000) as $i ({}; .["b"+($i|tostring)] = {port: (9500+$i)})' > "$COADMAP_PORT_REGISTRY"
if out="$(bash "$SUT" "newbr" 9500 2>/dev/null)"; then
  echo "NG: 枯渇でも割当(out=$out)"; fail=1
else
  echo "ok: 枯渇時は非ゼロ終了"
fi
rm -rf "$TMP3"

# 回帰: release-port.sh で確保を解放できる
TMP4="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP4/reg.json"
RELEASE="$HERE/../release-port.sh"
bash "$SUT" "rel-br" 9000 >/dev/null
bash "$RELEASE" "rel-br"
left="$(jq -r --arg b "rel-br" 'has($b)' "$COADMAP_PORT_REGISTRY")"
[[ "$left" == "false" ]] && echo "ok: release-portで解放" || { echo "NG: 解放されず left=$left"; fail=1; }
rm -rf "$TMP4"

exit $fail
