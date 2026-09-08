#!/usr/bin/env bash
# coadmap-task-workflow: 外部AIエージェント トークン使用量自己申告 entry
# (Claude Code SessionEnd hook / Codex Stop hook 共通)
#
# 即 return ラッパー。stdin から hook 入力 JSON を読んだら、即座にバックグラウンドで
# 本処理 (_report-ai-usage-impl.sh) を detach 起動して終了する。
# Claude Code / Codex の
# 終了体感を一切阻害しない。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMPL="$SCRIPT_DIR/_report-ai-usage-impl.sh"

INPUT_JSON="$(cat 2>/dev/null || true)"

if [[ -z "$INPUT_JSON" ]]; then
  exit 0
fi

nohup "$IMPL" "$INPUT_JSON" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
