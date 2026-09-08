#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../read-config.sh"
TMP="$(mktemp -d)"; fail=0
mkdir -p "$TMP/repo/.coadmap" "$TMP/repo/sub/dir"
echo '{"branchPrefix":"codex/"}' > "$TMP/repo/.coadmap/workflow.json"
got="$(bash "$SUT" "$TMP/repo/sub/dir" | jq -r .branchPrefix)"
[[ "$got" == "codex/" ]] && echo "ok: 親方向探索" || { echo "NG: 親方向探索 got='$got'"; fail=1; }
got="$(bash "$SUT" "$TMP" | jq -c .)"
[[ "$got" == "{}" ]] && echo "ok: 未設定は{}" || { echo "NG: 未設定 got='$got'"; fail=1; }
got="$(COADMAP_WORKFLOW_CONFIG="$TMP/repo/.coadmap/workflow.json" bash "$SUT" "$TMP" | jq -r .branchPrefix)"
[[ "$got" == "codex/" ]] && echo "ok: 環境変数で明示指定" || { echo "NG: 環境変数 got='$got'"; fail=1; }
rm -rf "$TMP"; exit $fail
