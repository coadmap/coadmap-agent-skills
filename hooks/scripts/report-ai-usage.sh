#!/usr/bin/env bash
# coadmap-task-workflow: 外部AIエージェント トークン使用量自己申告 entry
# (Claude Code / Codex の SessionEnd・Stop hook 共通)
#
# 即 return ラッパー。stdin から hook 入力 JSON を読んだら、即座にバックグラウンドで
# 本処理 (_report-ai-usage-impl.sh) を detach 起動して終了する。
# Claude Code / Codex の終了体感を一切阻害しない。
#
# 引数: `--event <name>` を渡すと、その名前を hook イベント名の既定値として impl へ
# 渡す。Codex の終端イベント名は Claude Code の `SessionEnd` と一致するとは限らず、
# stdin に `hook_event_name` が乗らない実装もある。イベント名が分からないと impl は
# throttle を効かせてしまい、セッション最終ターンぶんが落ちる。
set -uo pipefail

# opt-in していない環境では worker を起動すること自体を避ける。impl 側にも同じゲートが
# あるが、ここで止めれば hook 入力(応答本文を含み得る)がプロセスに渡ることすら無い。
if [[ "${COADMAP_AI_USAGE_REPORT:-0}" != "1" ]]; then
  exit 0
fi

EVENT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)   EVENT_NAME="${2:-}"; shift 2 || shift $# ;;
    --event=*) EVENT_NAME="${1#--event=}"; shift ;;
    *)         shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMPL="$SCRIPT_DIR/_report-ai-usage-impl.sh"

INPUT_JSON="$(cat 2>/dev/null || true)"

if [[ -z "$INPUT_JSON" ]]; then
  exit 0
fi

# hook 入力 JSON は argv に載せず stdin で渡す。Stop の入力には応答本文
# (last_assistant_message) が含まれ、argv は同一ホストの他ユーザーから ps で読めるため。
# 第 1 引数の `-` は「stdin から読め」の印。
printf '%s' "$INPUT_JSON" | nohup "$IMPL" - "$EVENT_NAME" >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
