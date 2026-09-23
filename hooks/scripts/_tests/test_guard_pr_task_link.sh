#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../guard-pr-task-link.sh"
TMP="$(mktemp -d)"; export COADMAP_RUN_DIR="$TMP/run"
fail=0
# PreToolUse(Bash) hook JSON を stdin で渡す
payload() { jq -nc --arg s "$1" --arg c "$2" '{session_id:$s, tool_input:{command:$c}}'; }
mark() { mkdir -p "$COADMAP_RUN_DIR"; : > "$COADMAP_RUN_DIR/$1.injected"; }
run() { payload "$1" "$2" | bash "$SUT" 2>/dev/null; }
run_capture_stderr() { payload "$1" "$2" | bash "$SUT" 2>"$3"; }
expect_blocked() {
  local label="$1" command="$2" rc=0
  run s1 "$command" || rc=$?
  if [[ $rc -eq 2 ]]; then
    echo "ok: $label"
  else
    echo "NG: $label rc=$rc"
    fail=1
  fi
}

mark s1
# command が argv 配列で来る実装でも検査できる(文字列化しないと gh が先頭語にならず素通りする)
rc=0; jq -nc '{session_id:"s1", tool_input:{command:["gh","pr","create","--title","t","--body","no link"]}}' | bash "$SUT" 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] && echo "ok: 配列 command もブロック" || { echo "NG: 配列 command が素通り rc=$rc"; fail=1; }
# タスク作業セッション + リンク無し gh pr create → ブロック(exit 2)
rc=0; run s1 'gh pr create --title "fix" --body "no link"' || rc=$?
[[ $rc -eq 2 ]] && echo "ok: リンク無しはブロック" || { echo "NG: ブロックされず rc=$rc"; fail=1; }
# タスクURL入り body → 通過
run s1 'gh pr create --title t --body "[[CMDEV-1] x](https://coadmap.com/ws/tasks/VGFzazoxMjM=)"' \
  && echo "ok: タスクURL有りは通過" || { echo "NG: タスクURL有りでブロック"; fail=1; }
# /tasks/ 直下形式のURLも通過
run s1 'gh pr create -b "see https://coadmap.com/tasks/VGFzazoxMjM="' \
  && echo "ok: tasks直下URLも通過" || { echo "NG: tasks直下URLでブロック"; fail=1; }
# 無関係な coadmap.com URL はブロック（タスクURLに限る）
rc=0; run s1 'gh pr create --body "see https://coadmap.com/pricing"' || rc=$?
[[ $rc -eq 2 ]] && echo "ok: 非タスクURLはブロック" || { echo "NG: 非タスクURLが通過 rc=$rc"; fail=1; }
# --body-file 内にタスクURL → 通過
printf 'top\n[[CMDEV-2] y](https://coadmap.com/ws/tasks/VGFzazoy)\n' > "$TMP/body.md"
run s1 "gh pr create --body-file $TMP/body.md" \
  && echo "ok: body-file内URLで通過" || { echo "NG: body-fileが見られていない"; fail=1; }
# 引用符付きの空白入りパスも1引数として読み取る
printf '[[CMDEV-2] y](https://coadmap.com/ws/tasks/VGFzazoy)\n' > "$TMP/body with spaces.md"
run s1 "gh pr create --body-file \"$TMP/body with spaces.md\"" \
  && echo "ok: 空白入りbody-file内URLで通過" || { echo "NG: 空白入りbody-fileが見られていない"; fail=1; }
# hook 実行時点で解決できないシェル変数のパスは誤ブロックせず、警告で区別する
warning="$TMP/unresolved-variable.log"
# shellcheck disable=SC2016 # hook に展開前の変数文字列を渡す回帰テスト
unresolved_cmd='gh pr create --body-file "$SCRATCH/pr.md"'
rc=0; run_capture_stderr s1 "$unresolved_cmd" "$warning" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: 未解決変数のbody-fileは警告して通過"
else
  echo "NG: 未解決変数のbody-fileを誤ブロック rc=$rc"
  fail=1
fi
# short option (-F) でも同じ安全境界を適用する
warning="$TMP/unresolved-short-option.log"
# shellcheck disable=SC2016 # hook に展開前の変数文字列を渡す回帰テスト
unresolved_cmd='gh pr create -F "$SCRATCH/pr.md"'
rc=0; run_capture_stderr s1 "$unresolved_cmd" "$warning" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: 未解決変数の-Fは警告して通過"
else
  echo "NG: 未解決変数の-Fを誤ブロック rc=$rc"
  fail=1
fi
# simple command 途中の redirect は command 終端ではなく、その後の body-file も検査する
warning="$TMP/redirect-before-body-file.log"
# shellcheck disable=SC2016 # hook に展開前の変数文字列を渡す回帰テスト
unresolved_cmd='gh pr create 2>/dev/null --body-file "$SCRATCH/pr.md"'
rc=0; run_capture_stderr s1 "$unresolved_cmd" "$warning" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: 中間redirect後の未解決body-fileは警告して通過"
else
  echo "NG: 中間redirectでbody-fileを見失い誤ブロック rc=$rc"
  fail=1
fi
# 存在しない literal path もリンク欠如とは断定せず、警告して gh 自身の検証へ委ねる
warning="$TMP/missing-body-file.log"
rc=0; run_capture_stderr s1 'gh pr create --body-file /path/that/does/not/exist.md' "$warning" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: 不存在body-fileは警告して通過"
else
  echo "NG: 不存在body-fileを誤ブロック rc=$rc"
  fail=1
fi
# stdin 指定は hook が本文を先読みできないため、待機せず警告して通過する
warning="$TMP/stdin-body-file.log"
rc=0; run_capture_stderr s1 'gh pr create --body-file -' "$warning" </dev/null || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: stdin body-fileは待機せず警告して通過"
else
  echo "NG: stdin body-fileを誤ブロック rc=$rc"
  fail=1
fi
# 読み取れた本文にリンクが無い場合だけは従来どおりブロックし、読み取り不能警告と区別する
printf 'no task link\n' > "$TMP/body-without-link.md"
warning="$TMP/readable-without-link.log"
rc=0; run_capture_stderr s1 "gh pr create --body-file $TMP/body-without-link.md" "$warning" || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'PR body に Coadmap タスクリンクがありません' "$warning" \
  && ! grep -q '本文ファイルを読み取れないため' "$warning"; then
  echo "ok: 読み取り済みリンク無しbody-fileは理由を区別してブロック"
else
  echo "NG: 読み取り済みリンク無しbody-fileの判定が不正 rc=$rc"
  fail=1
fi
# --body の引用符内に option 風の文字列があっても body-file 指定とは解釈しない
warning="$TMP/body-option-like-text.log"
rc=0; run_capture_stderr s1 "gh pr create --body 'example --body-file /path/that/does/not/exist.md'" "$warning" || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'PR body に Coadmap タスクリンクがありません' "$warning" \
  && ! grep -q '本文ファイルを読み取れないため' "$warning"; then
  echo "ok: 引用符内のbody-file風文字列はリンク無し本文としてブロック"
else
  echo "NG: 引用符内のbody-file風文字列でguardを迂回 rc=$rc"
  fail=1
fi
# shell comment 内の option 風文字列も実引数として扱わない
warning="$TMP/comment-option-like-text.log"
rc=0; run_capture_stderr s1 "gh pr create --body 'no link' # --body-file /path/that/does/not/exist.md" "$warning" || rc=$?
if [[ $rc -eq 2 ]] && grep -q 'PR body に Coadmap タスクリンクがありません' "$warning" \
  && ! grep -q '本文ファイルを読み取れないため' "$warning"; then
  echo "ok: コメント内のbody-file風文字列は無視してブロック"
else
  echo "NG: コメント内のbody-file風文字列でguardを迂回 rc=$rc"
  fail=1
fi
# shell comment 内のタスクURLは PR body として数えない
rc=0; run s1 "gh pr create --body 'no link' # https://coadmap.com/ws/tasks/comment-only" || rc=$?
[[ $rc -eq 2 ]] && echo "ok: コメント内タスクURLは無視してブロック" \
  || { echo "NG: コメント内タスクURLでguardを迂回 rc=$rc"; fail=1; }
# 引用符内の command 風文字列だけなら hook 対象外
run s1 "printf '%s\\n' 'gh pr create'" \
  && echo "ok: 引用符内のcommand風文字列は対象外" || { echo "NG: 引用符内command風文字列を誤ブロック"; fail=1; }
# shell の正当な command prefix / 実行パスを経由しても安全レールを維持する
expect_blocked "if 内の gh pr create はブロック" "if gh pr create --body 'no link'; then :; fi"
expect_blocked "先行リダイレクト付き gh pr create はブロック" "2>/dev/null gh pr create --body 'no link'"
expect_blocked "command 経由の gh pr create はブロック" "command gh pr create --body 'no link'"
expect_blocked "絶対パスの gh pr create はブロック" "/usr/bin/gh pr create --body 'no link'"
# 本文中の bypass 風文字列は明示バイパスではない
rc=0; run s1 'gh pr create --body "COADMAP_PR_NO_TASK=1"' || rc=$?
[[ $rc -eq 2 ]] && echo "ok: 本文中のバイパス風文字列は無視してブロック" \
  || { echo "NG: 本文中のバイパス風文字列でguardを迂回 rc=$rc"; fail=1; }
# バイパス指定 → 通過
run s1 'COADMAP_PR_NO_TASK=1 gh pr create --body "unrelated"' \
  && echo "ok: バイパス通過" || { echo "NG: バイパス無効"; fail=1; }
# 迂回経路の回帰: 静的に追えない構文はリンクが無ければブロック(fail-close)
expect_blocked "バックティック内の gh pr create はブロック" '`gh pr create --body "no link"`'
expect_blocked "eval 経由の gh pr create はブロック" 'eval "gh pr create --body \"no link\""'
expect_blocked "bash -c 経由の gh pr create はブロック" 'bash -c "gh pr create --body \"no link\""'
run s1 'bash -c "gh pr create --body \"[[CMDEV-1] x](https://coadmap.com/ws/tasks/VGFzazoxMjM=)\""' \
  && echo "ok: bash -c 内でもリンクがあれば通過" || { echo "NG: bash -c 内のリンクを誤ブロック"; fail=1; }
# 行継続: `gh pr \` + 改行 + `create` は 1 コマンドとして検査し、逆に正しい行継続を誤爆しない
expect_blocked "行継続で分割した gh pr create はブロック" $'gh pr \\\ncreate --body "no link"'
run s1 $'gh pr create \\\n  --body "[[CMDEV-1] x](https://coadmap.com/ws/tasks/VGFzazoxMjM=)"' \
  && echo "ok: 正しい行継続は通過" || { echo "NG: 正しい行継続を誤ブロック"; fail=1; }
# gh のグローバルオプションが pr の前にあっても検査する
expect_blocked "--repo 付き gh pr create はブロック" 'gh --repo acme/widget pr create --body "no link"'
expect_blocked "-R 付き gh pr create はブロック" 'gh -R acme/widget pr create --body "no link"'
# 1 コマンド列に複数の gh pr create があれば全件検査する
expect_blocked "2 つ目のリンク無し gh pr create はブロック" \
  'gh pr create --body "https://coadmap.com/ws/tasks/VGFzazox" && gh pr create --body "no link"'
# URL 判定: ホスト境界と ID 非空
expect_blocked "偽ドメインの URL はブロック" 'gh pr create --body "https://evilcoadmap.com/ws/tasks/x"'
expect_blocked "ID 無しの /tasks/ URL はブロック" 'gh pr create --body "https://coadmap.com/tasks/"'
run s1 'gh pr create --body "https://app.coadmap.com/ws/tasks/VGFzazoxMjM="' \
  && echo "ok: サブドメインの URL は通過" || { echo "NG: サブドメイン URL を誤ブロック"; fail=1; }
# export では効かない(実装は gh 直前の代入語だけ認める)ことを固定する
rc=0; run s1 'export COADMAP_PR_NO_TASK=1; gh pr create --body "no link"' || rc=$?
[[ $rc -eq 2 ]] && echo "ok: export 形式のバイパスは無効" || { echo "NG: export 形式が通過 rc=$rc"; fail=1; }
# gh pr create 以外 → 対象外
run s1 'gh pr view 12 --json body' \
  && echo "ok: 対象外コマンドは通過" || { echo "NG: 対象外コマンドをブロック"; fail=1; }
# マーカー無しセッション → 対象外
run s9 'gh pr create --body "no link"' \
  && echo "ok: 非タスクセッションは通過" || { echo "NG: 非タスクセッションをブロック"; fail=1; }
expect_passed() {
  local label="$1" command="$2" rc=0
  run s1 "$command" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "ok: $label"
  else
    echo "NG: $label rc=$rc"
    fail=1
  fi
}
LINK='https://coadmap.com/ws/tasks/VGFzazoxMjM='
printf '[[CMDEV-3] z](%s)\n' "$LINK" > "$TMP/linked.md"
# gh pr new は gh pr create の公式エイリアス
expect_blocked "gh pr new はブロック" 'gh pr new --title t --body "no link"'
expect_passed "リンク付き gh pr new は通過" "gh pr new --body '$LINK'"
# gh の前に置くラッパーコマンドとそのオプションを読み飛ばす
expect_blocked "timeout 経由はブロック" "timeout 120 gh pr create --body 'no link'"
expect_blocked "timeout -k 経由はブロック" "timeout -k 5 120 gh pr create --body 'no link'"
expect_blocked "nice 経由はブロック" "nice -n 5 gh pr create --body 'no link'"
expect_blocked "xargs 経由はブロック" "echo x | xargs -n 1 gh pr create --body 'no link'"
expect_blocked "env -u 経由はブロック" "env -u X gh pr create --body 'no link'"
expect_blocked "command -p 経由はブロック" "command -p gh pr create --body 'no link'"
expect_blocked "time -p 経由はブロック" "time -p gh pr create --body 'no link'"
expect_blocked "stdbuf 経由はブロック" "stdbuf -o L gh pr create --body 'no link'"
expect_blocked "{ } グループ内はブロック" "{ gh pr create --body 'no link'; }"
expect_passed "env 経由の COADMAP_PR_NO_TASK=1 はバイパス" "env COADMAP_PR_NO_TASK=1 gh pr create --body 'no link'"
# シェルの -c は他の引数の後ろにあっても文字列実行として扱う
expect_blocked "bash --login -c 経由はブロック" 'bash --login -c "gh pr create --body \"no link\""'
expect_blocked "bash -e -c 経由はブロック" 'bash -e -c "gh pr create --body \"no link\""'
expect_blocked "sh -lc 経由はブロック" "sh -lc 'gh pr create --body x'"
expect_blocked "シェルに渡す heredoc 内はブロック" $'bash <<\'EOF\'\ngh pr create --fill\nEOF'
# コマンド置換の中身は実際に実行されるので、同じ規則で検査する
# shellcheck disable=SC2016 # hook に展開前の文字列を渡す回帰テスト
expect_blocked "\$() 内のリンク無しはブロック" 'url=$(gh pr create --body "no link")'
expect_passed "\$() 内でも body-file にリンクがあれば通過" "url=\$(gh pr create --body-file $TMP/linked.md)"
# --body "$(cat <path>)" は --body-file <path> と同じ扱い
expect_passed "--body \"\$(cat file)\" のリンクで通過" "gh pr create --body \"\$(cat $TMP/linked.md)\""
expect_passed "--body \"\$(< file)\" のリンクで通過" "gh pr create --body \"\$(< $TMP/linked.md)\""
expect_passed "引用符付きパスの \$(cat) も読む" "gh pr create --body \"\$(cat \"$TMP/body with spaces.md\")\""
expect_blocked "\$(cat file) の中身にリンクが無ければブロック" "gh pr create --body \"\$(cat $TMP/body-without-link.md)\""
warning="$TMP/unresolved-cat.log"
# shellcheck disable=SC2016 # hook に展開前の変数文字列を渡す回帰テスト
unresolved_cmd='gh pr create --body "$(cat "$SCRATCH/pr.md")"'
rc=0; run_capture_stderr s1 "$unresolved_cmd" "$warning" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '本文ファイルを読み取れないため、ブロックせず続行します' "$warning"; then
  echo "ok: 読めない \$(cat) は body-file と同じく警告して通過"
else
  echo "NG: 読めない \$(cat) の扱いが body-file と異なる rc=$rc"
  fail=1
fi
# 引用符内の文字列は構文として扱わない
expect_passed "--title の単引用符内バックティックは無視" "gh pr create --title 'fix \`foo\` bug' --body-file $TMP/linked.md"
expect_passed "--title の引用符内 sh -c は無視" "gh pr create --title \"use sh -c here\" --body-file $TMP/linked.md"
# heredoc の本文はコマンドではない
expect_passed "ファイルに書く heredoc 内の gh pr create は無視" $'cat > notes.md <<\'EOF\'\ngh pr create --fill\nEOF'
expect_passed "<<- heredoc の後ろのコマンドも正しく読む" $'cat > notes.md <<-EOF\n\tgh pr create --fill\n\tEOF\necho done'
expect_blocked "heredoc の後ろの gh pr create は検査する" $'cat > notes.md <<\'EOF\'\nmemo\nEOF\ngh pr create --body "no link"'
expect_blocked "引用しない heredoc 内のコマンド置換は検査する" $'cat > notes.md <<EOF\n$(gh pr create --body "no link")\nEOF'
# URL 判定: 別 URL のクエリへの埋め込みと、ID として短すぎるものは認めない
expect_blocked "別 URL のクエリに埋め込んだリンクはブロック" "gh pr create --body 'https://evil.example/?u=$LINK'"
expect_blocked "短すぎる ID はブロック" "gh pr create --body 'https://coadmap.com/ws/tasks/x'"
expect_passed "ポート付き URL は通過" "gh pr create --body 'https://coadmap.com:443/ws/tasks/VGFzazoxMjM='"
expect_blocked "未設定ホストはブロック" "gh pr create --body 'https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM='"
# taskHosts で許可したホストは通る(設定はセッションの cwd から探す)
mkdir -p "$TMP/repo/.coadmap"
echo '{"taskHosts":["coadmap.example.co.jp"]}' > "$TMP/repo/.coadmap/workflow.json"
with_cwd() { jq -nc --arg c "$1" --arg d "$TMP/repo" '{session_id:"s1", cwd:$d, tool_input:{command:$c}}' | bash "$SUT" 2>/dev/null; }
rc=0; with_cwd "gh pr create --body 'https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM='" || rc=$?
[[ $rc -eq 0 ]] && echo "ok: taskHosts のホストは通過" || { echo "NG: taskHosts のホストでブロック rc=$rc"; fail=1; }
rc=0; with_cwd "gh pr create --body 'https://other.example/ws/tasks/VGFzazoxMjM='" || rc=$?
[[ $rc -eq 2 ]] && echo "ok: taskHosts 以外のホストはブロック" || { echo "NG: taskHosts 以外のホストが通過 rc=$rc"; fail=1; }
# MCP の create_pull_request も body を検査する
mcp() { jq -nc --arg s "$1" --arg t "$2" --arg b "$3" '{session_id:$s, tool_name:$t, tool_input:{owner:"o", repo:"r", title:"t", body:$b}}' | bash "$SUT" 2>/dev/null; }
rc=0; mcp s1 mcp__github__create_pull_request 'no link' || rc=$?
[[ $rc -eq 2 ]] && echo "ok: MCP のリンク無し PR 作成はブロック" || { echo "NG: MCP のリンク無し PR 作成が通過 rc=$rc"; fail=1; }
mcp s1 mcp__github__create_pull_request "[[CMDEV-1] x]($LINK)" \
  && echo "ok: MCP のリンク付き PR 作成は通過" || { echo "NG: MCP のリンク付き PR 作成をブロック"; fail=1; }
mcp s9 mcp__github__create_pull_request 'no link' \
  && echo "ok: MCP も非タスクセッションは対象外" || { echo "NG: MCP の非タスクセッションをブロック"; fail=1; }
mcp s1 mcp__github__list_pull_requests '' \
  && echo "ok: 他の MCP ツールは対象外" || { echo "NG: 他の MCP ツールをブロック"; fail=1; }
# hooks 設定が MCP の PR 作成ツールにも配線されていること
for f in "$HERE/../../hooks.json" "$HERE/../../codex-hooks.json"; do
  matcher="$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | test("guard-pr-task-link")) | .matcher | select(test("create_pull_request"))' "$f")"
  if [[ -n "$matcher" && "mcp__github__create_pull_request" =~ $matcher && ! "mcp__github__list_pull_requests" =~ $matcher ]]; then
    echo "ok: $(basename "$f") は MCP の PR 作成を guard に配線"
  else
    echo "NG: $(basename "$f") に MCP の PR 作成の配線が無い"
    fail=1
  fi
done
# よく使われる --body "$(cat <<'EOF' ... EOF)" 形式は本文を heredoc から読む
expect_passed "\$(cat <<EOF) 本文のリンクで通過" $'gh pr create --title t --body "$(cat <<\'EOF\'\n[[CMDEV-1] x](https://coadmap.com/ws/tasks/VGFzazoxMjM=)\n\n## Summary\n- `code` span\nEOF\n)"'
expect_blocked "\$(cat <<EOF) 本文にリンクが無ければブロック" $'gh pr create --title t --body "$(cat <<\'EOF\'\n## Summary\n- `code` span\nEOF\n)"'
# 長い本文でもリンクを見落とさない
long_body="[[CMDEV-1] x]($LINK)"$'\n'"$(seq 1 20000 | sed 's/^/line /')"
rc=0; mcp s1 mcp__github__create_pull_request "$long_body" || rc=$?
[[ $rc -eq 0 ]] && echo "ok: 長い本文でもリンクで通過" || { echo "NG: 長い本文でリンクを見落とし rc=$rc"; fail=1; }
# $() 内の heredoc 本文の括弧・引用符で置換の終わりを見誤らない
expect_passed "heredoc 本文の閉じ括弧で置換を打ち切らない" $'gh pr create --body "$(cat <<\'EOF\'\n[[CMDEV-1] x](https://coadmap.com/ws/tasks/VGFzazoxMjM=)\n1) it\'s done :)\nEOF\n)" && echo "gh pr create" > /dev/null'
expect_blocked "heredoc 本文の引用符で後ろの gh pr create を見失わない" $'gh pr view --json body -q "$(cat <<\'EOF\'\nit\'s a note\nEOF\n)"; gh pr create --body "no link"'
rm -rf "$TMP"; exit $fail
