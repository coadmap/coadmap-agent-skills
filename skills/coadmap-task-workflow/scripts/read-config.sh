#!/usr/bin/env bash
# usage: read-config.sh [start-dir]
# start-dir(既定: cwd)から親方向に .coadmap/workflow.json を探し、最初に見つかったものを
# stdout に出す。見つからなければ '{}' を出して exit 0（設定は任意なので fail-open）。
# 呼び出し側が jq にそのまま渡せるよう、stdout には JSON 以外を出さない。
set -euo pipefail
dir="$(cd "${1:-.}" && pwd)"
if [[ -n "${COADMAP_WORKFLOW_CONFIG:-}" ]]; then
  [[ -f "$COADMAP_WORKFLOW_CONFIG" ]] && { cat "$COADMAP_WORKFLOW_CONFIG"; exit 0; }
  echo '{}'; exit 0
fi
while :; do
  if [[ -f "$dir/.coadmap/workflow.json" ]]; then
    cat "$dir/.coadmap/workflow.json"; exit 0
  fi
  [[ "$dir" == "/" ]] && break
  dir="$(dirname "$dir")"
done
echo '{}'
