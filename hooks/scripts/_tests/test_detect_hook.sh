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
rm -rf "$TMP"; exit $fail
