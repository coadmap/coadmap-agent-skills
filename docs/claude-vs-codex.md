# Claude Code と Codex の差分と fallback

skill 本体(`skills/coadmap-task-workflow/`)はエージェント非依存の語彙で書いてあり、両方でそのまま動く。差が出るのは plugin として同梱している付加物で、次の表の通り fallback を用意している。

| 構成要素 | Claude Code | Codex | Codex での fallback |
|---|---|---|---|
| skill | `skills/` を plugin 経由で読み込み | `.codex-plugin/plugin.json` の `skills` で読み込み | なし(同一) |
| `/coadmap-task` command | あり | slash command 互換なし | `CMDEV-1234 に着手して` のようにタスク ID を含めて依頼する。UserPromptSubmit hook が skill 利用を促す |
| `coadmap-pr-reviewer` agent | `Agent` ツールで spawn | subagent 機構なし | skill が `references/review-checklist.md` の観点で inline レビューする |
| hooks | `hooks/hooks.json`(SessionEnd で usage report) | `hooks/codex-hooks.json`(Stop で usage report) | UserPromptSubmit / PreToolUse は同じスクリプトを共用 |
| チェックリスト化 | TodoWrite | plan / update_plan | skill は「使えるタスク管理ツール」と書いてあり、どちらでもよい |
| トークン使用量の自己申告 | SessionEnd で実測値を送信 | Stop で hook は動くが transcript 形式が未対応 | 読めない形式では何も送らない(0 の嘘レポートを送らない) |

## hooks を 2 枚に分けている理由

UserPromptSubmit / PreToolUse は両者とも同じイベント名・同じ stdin JSON(`session_id` / `prompt` / `tool_input.command`)・同じブロック方法(exit 2)で、PreToolUse の matcher もシェルは `Bash`。ここまでは共用できる。

usage report の配線だけが違う。Codex の公式ドキュメントには `SessionEnd` が載っているが、手元の Codex CLI(0.142 系)のバイナリが列挙するイベントは `Stop` までで `SessionEnd` が無い。ドキュメント先行の可能性があるため、確実に動く `Stop` で配線している。Claude Code の `Stop` は毎ターン発火するので、Claude 側まで `Stop` にすると毎ターン transcript を集計することになり、こちらは `SessionEnd` のまま分けている。

hook スクリプトのパスは両ファイルとも `${CLAUDE_PLUGIN_ROOT}` で書いている。Codex は `PLUGIN_ROOT` に加えて互換用に `CLAUDE_PLUGIN_ROOT` も環境変数として渡す(公式ドキュメントの plugin hooks の項に明記)ので、シェルが展開してくれる。

## 変数展開に頼らない設計

`${CLAUDE_PLUGIN_ROOT}` が確実に展開されるのは hooks の command と MCP 設定だけで、skill / agent / command の Markdown 本文で展開されるかはバージョンによって挙動が異なる。そのため:

- skill の references はスクリプトを `<skill dir>/scripts/...` というプレースホルダで書き、skill 読み込み時に提示されるベースディレクトリを使うよう SKILL.md で指示している。
- `coadmap-pr-reviewer` agent はレビュー観点を本文にインラインしており、plugin 内のファイルを探しに行かなくても動く。呼び出し元(skill)はさらにチェックリスト本文をプロンプトで渡す。

## Codex の PreToolUse `tool_input` について

Codex 側の `tool_input` の形状(`command` が文字列か argv 配列か)は実機で未検証。`guard-pr-task-link.sh` は配列で来た場合も文字列化して検査するようにしてあるが、キー名が `command` / `cmd` 以外の場合は検査が黙って素通りする(fail-open)。Codex で hook をあてにする場合は、一度 stdin をダンプして確認すること。

## MCP の接続名

Coadmap MCP のツール名は接続方法で prefix が変わる(`mcp__coadmap-mcp__...` など)。skill はツール名だけを書き、prefix はセッションのツール一覧から `coadmap` を含むサーバーを探して補う。Claude Code / Codex どちらでも同じ扱い。
