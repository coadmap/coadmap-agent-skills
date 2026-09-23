#!/usr/bin/env bash
# UserPromptSubmit hook。stdin の JSON から prompt を取り、タスクID/URLを検出したら
# skill 利用を促す additionalContext を1セッション1回だけ stdout に出す。
set -euo pipefail
EXTRACT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/coadmap-task-workflow/scripts" && pwd)/extract-task-id.sh"
input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
# session_id をファイル名に使うのでパス区切り等を除去する（想定は UUID だが防御的に）。
session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
[[ -n "$session" ]] || session="unknown"
[[ -n "$prompt" ]] || exit 0
# taskHosts は利用者リポの設定なので、セッションの cwd から探させる。
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$cwd" && -d "$cwd" ]] || cwd="."
id="$(cd "$cwd" && printf '%s' "$prompt" | bash "$EXTRACT" || true)"
[[ -n "$id" ]] || exit 0
# 共有 /tmp だと Linux で他ユーザーが先にディレクトリを作れてしまい書き込めなくなるので、
# ユーザー専有の置き場にする。セッションごとに増えるマーカーはここで古いものを掃除する。
marker_dir="${COADMAP_RUN_DIR:-$HOME/.coadmap/run}"; mkdir -p "$marker_dir"
find "$marker_dir" -maxdepth 1 -name '*.injected' -type f -mtime +7 -delete 2>/dev/null || true
marker="$marker_dir/${session}.injected"
[[ -f "$marker" ]] && exit 0
: > "$marker"
printf 'Coadmap タスク(%s)が検出されました。`coadmap-task-workflow` skill を使い、着手→DOING移動→worktree→コメント記録→PR+IN_REVIEW→レビュー→CI→マージ準備通知→DONE+クリーンアップのライフサイクルを徹底してください。' "$id"
