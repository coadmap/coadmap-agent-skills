#!/usr/bin/env bash
# usage: read-config.sh [start-dir]          -> 設定 JSON を stdout に出す（無ければ '{}'）
#        read-config.sh --path [start-dir]   -> 設定ファイルのパスを出す（無ければ空、exit 0）
# start-dir(既定: cwd)から親方向に .coadmap/workflow.json を探す。設定は任意なので
# 見つからなくても失敗にしない(fail-open)。環境変数 COADMAP_WORKFLOW_CONFIG で明示もできる。
# 呼び出し側が jq にそのまま渡せるよう、stdout には JSON かパス以外を出さない。
set -euo pipefail
mode=json
if [[ "${1:-}" == "--path" ]]; then mode=path; shift; fi
dir="$(cd "${1:-.}" && pwd)"

find_config() {
  if [[ -n "${COADMAP_WORKFLOW_CONFIG:-}" ]]; then
    [[ -f "$COADMAP_WORKFLOW_CONFIG" ]] && printf '%s' "$COADMAP_WORKFLOW_CONFIG"
    return 0
  fi
  local d="$dir"
  while :; do
    if [[ -f "$d/.coadmap/workflow.json" ]]; then printf '%s' "$d/.coadmap/workflow.json"; return 0; fi
    [[ "$d" == "/" ]] && return 0
    d="$(dirname "$d")"
  done
}

path="$(find_config)"
if [[ "$mode" == "path" ]]; then printf '%s' "$path"; exit 0; fi
if [[ -n "$path" ]]; then cat "$path"; else echo '{}'; fi
