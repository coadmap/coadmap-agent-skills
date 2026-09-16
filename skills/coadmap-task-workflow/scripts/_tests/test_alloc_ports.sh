#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../alloc-ports.sh"
RELEASE="$HERE/../release-port.sh"
TMP="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP/port-registry.json"
fail=0
# usage: alloc-ports.sh <branch> <base-port> -> 割当ポートを echo
p1="$(bash "$SUT" "feature/CMDEV-1" 8000)"
p1b="$(bash "$SUT" "feature/CMDEV-1" 8000)"
p2="$(bash "$SUT" "feature/CMDEV-2" 8000)"
[[ "$p1" == "$p1b" ]] && echo "ok: 決定性(同一branch+baseは同一)" || { echo "NG: 決定性 $p1 != $p1b"; fail=1; }
[[ "$p1" != "$p2" ]] && echo "ok: branch差で別ポート" || { echo "NG: 衝突 $p1 == $p2"; fail=1; }
[[ "$p1" -ge 8000 && "$p1" -lt 9000 ]] && echo "ok: 範囲内" || { echo "NG: 範囲外 $p1"; fail=1; }
jq -e '.["feature/CMDEV-1:8000"].port' "$COADMAP_PORT_REGISTRY" >/dev/null && echo "ok: registry記録" || { echo "NG: registry"; fail=1; }
# 同一ブランチで base が違えば別サービスとして別ポート(backend=3000 / frontend=5173 の同時起動)
p3="$(bash "$SUT" "feature/CMDEV-1" 5000)"
[[ "$p3" != "$p1" && "$p3" -ge 5000 && "$p3" -lt 6000 ]] && echo "ok: 同一branchでもbase差で別ポート" \
  || { echo "NG: base が無視された p1=$p1 p3=$p3"; fail=1; }
p3b="$(bash "$SUT" "feature/CMDEV-1" 5000)"
[[ "$p3" == "$p3b" ]] && echo "ok: base 別でも決定性" || { echo "NG: base 別の決定性 $p3 != $p3b"; fail=1; }
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
jq -n 'reduce range(0;1000) as $i ({}; .["b"+($i|tostring)+":9500"] = {port: (9500+$i)})' > "$COADMAP_PORT_REGISTRY"
if out="$(bash "$SUT" "newbr" 9500 2>/dev/null)"; then
  echo "NG: 枯渇でも割当(out=$out)"; fail=1
else
  echo "ok: 枯渇時は非ゼロ終了"
fi
rm -rf "$TMP3"

# 回帰: release-port.sh は同一ブランチの全 base と旧形式キーをまとめて解放する
TMP4="$(mktemp -d)"; export COADMAP_PORT_REGISTRY="$TMP4/reg.json"
bash "$SUT" "rel-br" 9000 >/dev/null
bash "$SUT" "rel-br" 3000 >/dev/null
bash "$SUT" "other-br" 9000 >/dev/null
tmp="$(mktemp)"; jq '.["rel-br"] = {port: 7777}' "$COADMAP_PORT_REGISTRY" > "$tmp"; mv "$tmp" "$COADMAP_PORT_REGISTRY"
bash "$RELEASE" "rel-br"
left="$(jq -r 'keys | join(",")' "$COADMAP_PORT_REGISTRY")"
[[ "$left" == "other-br:9000" ]] && echo "ok: release-portで同一branchの全エントリ解放" || { echo "NG: 解放結果 left=$left"; fail=1; }
rm -rf "$TMP4"

exit $fail
