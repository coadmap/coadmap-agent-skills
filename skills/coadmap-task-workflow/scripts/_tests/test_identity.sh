#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../resolve-identity.sh"; SAVE="$HERE/../save-identity.sh"
TMP="$(mktemp -d)"; export COADMAP_STATE_FILE="$TMP/task-flow.json"
fail=0
# 未保存なら sentinel(空) + exit 3
out="$(bash "$RESOLVE" || echo "rc=$?")"
[[ "$out" == "rc=3" ]] && echo "ok: 未保存はrc=3" || { echo "NG: 未保存 got='$out'"; fail=1; }
# 保存後は accountId を返す
bash "$SAVE" "acc_123" "you@example.com" "You"
got="$(bash "$RESOLVE")"
[[ "$got" == "acc_123" ]] && echo "ok: 保存後はaccountId" || { echo "NG: got='$got'"; fail=1; }
# JSON 構造検証
jq -e '.identity.email == "you@example.com"' "$COADMAP_STATE_FILE" >/dev/null && echo "ok: email保存" || { echo "NG: email"; fail=1; }
rm -rf "$TMP"; exit $fail
