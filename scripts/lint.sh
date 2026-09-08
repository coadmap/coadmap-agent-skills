#!/usr/bin/env bash
# shellcheck と manifest JSON の構文検証。CI とローカルで同じものを回す。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v shellcheck >/dev/null 2>&1; then
  find "$ROOT/skills" "$ROOT/hooks" "$ROOT/scripts" -name '*.sh' -type f -print0 \
    | xargs -0 shellcheck -S warning
else
  # ローカルに shellcheck が無くても他の検査は回せるようにする。CI では必ず入っている。
  echo "warn: shellcheck not found, syntax check only" >&2
  find "$ROOT/skills" "$ROOT/hooks" "$ROOT/scripts" -name '*.sh' -type f -print0 \
    | xargs -0 -n1 bash -n
fi
for f in "$ROOT"/.claude-plugin/*.json "$ROOT"/.codex-plugin/*.json "$ROOT"/.agents/plugins/*.json "$ROOT"/hooks/*.json; do
  jq -e . "$f" >/dev/null || { echo "invalid JSON: $f"; exit 1; }
done

# hooks.json が指すスクリプトと、hook スクリプトが辿る skill 側スクリプトが実在すること。
# ディレクトリ改名で黙って壊れるのを CI で止める。
for f in "$ROOT"/hooks/*.json; do
  jq -r '.. | .command? // empty' "$f" | grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[^" ]+' | sed 's#${CLAUDE_PLUGIN_ROOT}#'"$ROOT"'#' \
    | while IFS= read -r p; do [[ -x "$p" ]] || { echo "hook target missing or not executable: $p"; exit 1; }; done
done
[[ -x "$ROOT/skills/coadmap-task-workflow/scripts/extract-task-id.sh" ]] || { echo "extract-task-id.sh missing"; exit 1; }
grep -q 'skills/coadmap-task-workflow/scripts' "$ROOT/hooks/scripts/detect-task-id.sh" || { echo "detect-task-id.sh points at a stale skill dir"; exit 1; }

# Markdown の相対リンク切れ検出（skill だけコピーされても切れないよう、skill 配下は skill 内で閉じる）
fail=0
while IFS= read -r md; do
  dir="$(dirname "$md")"
  # リンクを含まないファイルでは grep が非ゼロ終了するので、pipefail に引っかけない
  links="$(grep -oE '\]\(([^)#]+)(#[^)]*)?\)' "$md" | sed -E 's/^\]\(//; s/\)$//; s/#.*$//' | grep -vE '^(https?:|mailto:|\$|<)' || true)"
  [[ -n "$links" ]] || continue
  while IFS= read -r link; do
    [[ -e "$dir/$link" ]] || { echo "broken link in $md: $link"; fail=1; continue; }
    case "$md" in "$ROOT"/skills/*)
      case "$(cd "$dir" && cd "$(dirname "$link")" 2>/dev/null && pwd)" in
        "$ROOT"/skills/*) ;;
        *) echo "link escapes skill dir (breaks standalone copy) in $md: $link"; fail=1 ;;
      esac ;;
    esac
  done <<<"$links"
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*')
[[ $fail -eq 0 ]] || exit 1
echo "lint ok"
