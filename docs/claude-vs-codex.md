# Claude Code と Codex の差分と fallback

skill 本体(`skills/coadmap-task-workflow/`)はエージェント非依存の語彙で書いてあり、両方でそのまま動く。差が出るのは plugin として同梱している付加物で、次の表の通り fallback を用意している。

| 構成要素 | Claude Code | Codex | Codex での fallback |
|---|---|---|---|
| skill | `skills/` を plugin 経由で読み込み | `.codex-plugin/plugin.json` の `skills` で読み込み | なし(同一) |
| `/coadmap-task` command | あり | slash command 互換なし | `CMDEV-1234 に着手して` のようにタスク ID を含めて依頼する。UserPromptSubmit hook が skill 利用を促す |
| `coadmap-pr-reviewer` agent | `Agent` ツールで spawn | subagent 機構なし | skill が `references/review-checklist.md` の観点で inline レビューする |
| hooks | `hooks/hooks.json` | `hooks/codex-hooks.json` | 中身は同じ。パス変数が `CLAUDE_PLUGIN_ROOT` / `PLUGIN_ROOT` で違うだけ |
| チェックリスト化 | TodoWrite | plan / update_plan | skill は「使えるタスク管理ツール」と書いてあり、どちらでもよい。無ければ応答内のチェックリストで代替する |
| トークン使用量の自己申告 | SessionEnd + Stop | SessionEnd + Stop | Codex の rollout log も集計対象(上流 v0.4.0 相当) |

## hooks の配線

UserPromptSubmit / PreToolUse / SessionEnd / Stop は両者とも同じイベント名・同じ stdin JSON(`session_id` / `prompt` / `tool_input.command` / `transcript_path`)・同じブロック方法(exit 2)を採用している。PreToolUse の matcher もシェルは `Bash`、`tool_input.command` は Codex 公式ドキュメントに明記されている。

usage report は両エージェントとも `SessionEnd` と `Stop` の両方に配線し、`SessionEnd` 側には `--event SessionEnd` を明示引数で渡す。stdin に `hook_event_name` が乗らない実装でもイベント名が分かるようにするためで、エージェント種別はイベント名ではなく transcript の中身(Claude Code 形式か Codex の rollout log か)で判定する。`Stop` は毎ターン発火するが、impl は前回送信値より増えた時だけ送るので多重計上にはならない。

hook スクリプトのパスは Claude 側が `${CLAUDE_PLUGIN_ROOT}`、Codex 側が `${PLUGIN_ROOT}`。Codex は互換用に `CLAUDE_PLUGIN_ROOT` も渡すが、互換エイリアスに依存しないよう Codex 側は本来の名前で書いている。

## 変数展開に頼らない設計

`${CLAUDE_PLUGIN_ROOT}` が確実に展開されるのは hooks の command と MCP 設定だけで、skill / agent / command の Markdown 本文で展開されるかはバージョンによって挙動が異なる。そのため:

- skill の references はスクリプトを `<skill dir>/scripts/...` というプレースホルダで書き、skill 読み込み時に提示されるベースディレクトリを使うよう SKILL.md で指示している。
- `coadmap-pr-reviewer` agent はレビュー観点を本文にインラインしており、plugin 内のファイルを探しに行かなくても動く。呼び出し元(skill)はさらにチェックリスト本文をプロンプトで渡す。

## MCP の接続名

Coadmap MCP のツール名は接続方法で prefix が変わる(`mcp__coadmap-mcp__...` など)。skill はツール名だけを書き、prefix はセッションのツール一覧から Coadmap MCP のツールを持つサーバーを探して補う。候補が複数あるときはサーバー名で選ばず、`get_coadmap_task_dependency` が返す `taskUrl` のホストで決める(SKILL.md「MCP ツールの呼び方」)。Claude Code / Codex どちらでも同じ扱い。
