#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../detect-task-id.sh"
TMP="$(mktemp -d)"; export COADMAP_RUN_DIR="$TMP/run"
fail=0
# UserPromptSubmit hook JSON を stdin で渡す
payload() { printf '{"session_id":"%s","prompt":"%s"}' "$1" "$2"; }
out="$(payload s1 '[CMDEV-9618] 対応して' | bash "$SUT")"
echo "$out" | grep -q 'coadmap-task-workflow' && echo "ok: ID検出で注入" || { echo "NG: 注入なし out='$out'"; fail=1; }
# 2回目(同session)は注入しない
out2="$(payload s1 'CMDEV-9618 続き' | bash "$SUT")"
[[ -z "$out2" ]] && echo "ok: 同session2回目は無注入" || { echo "NG: 重複注入 '$out2'"; fail=1; }
# タスクIDなしは無注入
out3="$(payload s2 'ただの雑談' | bash "$SUT")"
[[ -z "$out3" ]] && echo "ok: ID無しは無注入" || { echo "NG: 誤注入 '$out3'"; fail=1; }
# 正規表現の文字クラス表記(例 [A-Z0-9])の断片 "Z0-9" を displayId と誤検出しない
out4="$(payload s3 '正規表現 [A-Z0-9]+ にマッチさせる' | bash "$SUT")"
[[ -z "$out4" ]] && echo "ok: 文字クラス断片は無注入" || { echo "NG: 誤注入 '$out4'"; fail=1; }
# 規格名(UTF-8 等)だけのプロンプトではマーカーを作らない(作ると PR ガードが無関係な PR を止める)
out5="$(payload s4 'UTF-8 と SHA-256 の話' | bash "$SUT")"
if [[ -z "$out5" && ! -f "$COADMAP_RUN_DIR/s4.injected" ]]; then echo "ok: 規格名はマーカー無し"; else echo "NG: 規格名で誤検出 '$out5'"; fail=1; fi
# taskHosts はセッションの cwd から探す
mkdir -p "$TMP/repo/.coadmap"
echo '{"taskHosts":["coadmap.example.co.jp"]}' > "$TMP/repo/.coadmap/workflow.json"
out6="$(jq -nc --arg d "$TMP/repo" '{session_id:"s5", cwd:$d, prompt:"https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM= を対応"}' | bash "$SUT")"
echo "$out6" | grep -q 'coadmap-task-workflow' && echo "ok: cwd の taskHosts で検出" || { echo "NG: cwd の taskHosts で未検出 '$out6'"; fail=1; }
rm -rf "$TMP"; exit $fail
