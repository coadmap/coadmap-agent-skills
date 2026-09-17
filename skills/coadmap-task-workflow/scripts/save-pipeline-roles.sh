#!/usr/bin/env bash
# usage: save-pipeline-roles.sh <workspaceId> <DOING pipelineId> <IN_REVIEW pipelineId> <DONE pipelineId> [start-dir]
# 利用者リポの .coadmap/workflow.json に .pipelineRoles[<workspaceId>] を書く（既存キーは保持）。
# パイプラインロールはワークスペース単位でチーム共通の事実なので、ユーザー単位の
# ~/.coadmap/ ではなくリポ側の設定に置き、メンバー全員が同じヒアリングを受けないようにする。
# 設定ファイルが無ければ start-dir(既定: cwd) 直下に作る。書き込みはロック下で行う。
set -euo pipefail
ws="$1"; doing="$2"; review="$3"; done_="$4"; start="${5:-.}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$(bash "$HERE/read-config.sh" --path "$start")"
if [[ -z "$CFG" ]]; then
  CFG="$(cd "$start" && pwd)/.coadmap/workflow.json"
  mkdir -p "$(dirname "$CFG")"
fi
# shellcheck source=lib/lock.sh
. "$HERE/lib/lock.sh"
acquire_lock "$CFG.lock"
[[ -f "$CFG" ]] || echo '{}' > "$CFG"
tmp="$(mktemp)"
jq --arg ws "$ws" --arg doing "$doing" --arg review "$review" --arg finished "$done_" \
  '.pipelineRoles[$ws] = {DOING:$doing, IN_REVIEW:$review, DONE:$finished}' "$CFG" > "$tmp"
mv "$tmp" "$CFG"
printf '%s' "$CFG"
