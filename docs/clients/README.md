# クライアント別の対応

skill 本体(`skills/coadmap-task-workflow/`)はクライアント非依存の語彙で書いてあり、どのクライアントでもそのまま動く。手順の分岐は「サブエージェントを使えるなら」「サンドボックス内で認証エラーが出たら」のような**能力の条件**で書き、クライアント名は括弧内の例としてしか出さない。

クライアントごとに差が出るのは、plugin として同梱している付加物(command / agent / hooks)と、インストール・MCP 登録・サンドボックスなど skill の外側の事情。それらはこのディレクトリにまとめる。

- [Claude Code](claude-code.md)
- [Codex](codex.md)

## 能力マトリクス

| 能力 | Claude Code | Codex |
|---|---|---|
| skill の読み込み | plugin 経由で `skills/` を読み込む | `.codex-plugin/plugin.json` の `skills` で読み込む |
| slash command(`/coadmap-task`) | あり | 無し。`CMDEV-1234 に着手して` のようにタスク ID を含めて依頼すると、UserPromptSubmit hook が skill 利用を促す |
| PR 作成前のタスクリンク検査 | `gh pr create` / `gh pr new` と MCP の `*__create_pull_request` を検査する | `gh pr create` / `gh pr new` を検査する。MCP の `*__create_pull_request` も同じ設定で配線しているが、発火は未確認(次回の Codex E2E で確認する) |
| サブエージェント(PR レビュー担当) | `coadmap-pr-reviewer` agent を spawn する | plugin は agent を同梱しない。skill が `references/review-checklist.md` の観点で inline レビューする |
| タスク管理ツール | TodoWrite | plan / update_plan。どちらも無ければ応答内のチェックリストで代替する |
| hooks 設定ファイル + パス変数 | `hooks/hooks.json`、`${CLAUDE_PLUGIN_ROOT}` | `hooks/codex-hooks.json`、`${PLUGIN_ROOT}` |
| hooks の信頼 | インストールで有効になる(信頼・レビューの手順なしで、次の新規セッションから UserPromptSubmit / PreToolUse の発火を確認済み)。plugin の変更は新しいセッションから反映される | 信頼(レビュー)するまで hook はどれも黙ってスキップされる([codex.md](codex.md#hooks-の信頼)) |
| サンドボックスの影響(`git push` / `gh`) | デスクトップアプリの既定設定では、SSH の `git push` と `gh pr create` が追加の承認なしで成功した。サンドボックスを有効にした構成は未検証 | 既定のサンドボックス内で認証エラーになることがある。サンドボックス外での実行を承認する([codex.md](codex.md#サンドボックスと-git-push--gh)) |
| クライアント管理の worktree | デスクトップアプリはセッションを `<repo>/.claude/worktrees/<name>` の worktree(ブランチ `claude/<name>`)で開始できる | アプリがセッション用 worktree を用意する(detached HEAD、`codex/` prefix) |
| MCP の登録 | `claude mcp add`([claude-code.md](claude-code.md#coadmap-mcp-の接続)) | `~/.codex/config.toml` の `[mcp_servers.<name>]`([codex.md](codex.md#coadmap-mcp-の接続)) |
| MCP ツール名の prefix | `mcp__<サーバー名>__<ツール名>` | `mcp__<サーバー名>__<ツール名>`。サーバー名のハイフンはアンダースコアに変わる(`coadmap-mcp` → `mcp__coadmap_mcp__get_coadmap_task_dependency`) |
| トークン使用量の集計元 | transcript(`transcript_path` の JSONL) | rollout log |
| トークン使用量の資格情報 | MCP OAuth 資格情報 → MCP 設定の `Authorization` ヘッダ | `~/.codex/config.toml` の `http_headers.Authorization` / `bearer_token_env_var`。Codex の OAuth 資格情報は読まない([codex.md](codex.md#固有の注意)) |
| skill 単体コピーの置き場 | `~/.claude/skills/` / リポの `.claude/skills/` | `~/.codex/skills/` / リポの `.agents/skills/` |

クライアント管理の worktree を使う場合も、タスクブランチはクライアント独自の prefix(`claude/` / `codex/`)ではなく `<branchPrefix><TASK_ID>-<slug>` で `origin/<base>` から切る(`references/02-worktree-setup.md`)。

## hooks の配線

UserPromptSubmit / PreToolUse / SessionEnd / Stop は両者とも同じイベント名・同じ stdin JSON(`session_id` / `prompt` / `tool_input.command` / `transcript_path`)・同じブロック方法(exit 2)を採用している。PreToolUse の matcher もシェルは `Bash`、`tool_input.command` は Codex 公式ドキュメントに明記されている。matcher はどちらも正規表現として解釈され、MCP ツールは `tool_name` に `mcp__<サーバー名>__<ツール名>` で渡るので、MCP 経由の PR 作成は `^mcp__.+__create_pull_request$` の別エントリで同じ guard に配線している(本文は `tool_input.body`)。matcher と入力形式は両クライアントの公式ドキュメントの記述に基づく。Codex で MCP ツールに対してこの matcher が発火するかは実機では未確認で、次回の Codex E2E で確認する。

usage report は両クライアントとも `SessionEnd` と `Stop` の両方に配線し、`SessionEnd` 側には `--event SessionEnd` を明示引数で渡す。stdin に `hook_event_name` が乗らない実装でもイベント名が分かるようにするためで、クライアント種別はイベント名ではなく transcript の中身(Claude Code 形式か Codex の rollout log か)で判定する。`Stop` は毎ターン発火するが、impl は前回送信値より増えた時だけ送るので多重計上にはならない。

hook スクリプトのパスは Claude Code 側が `${CLAUDE_PLUGIN_ROOT}`、Codex 側が `${PLUGIN_ROOT}`。Codex は互換用に `CLAUDE_PLUGIN_ROOT` も渡すが、互換エイリアスに依存しないよう Codex 側は本来の名前で書いている。

## 変数展開に頼らない設計

`${CLAUDE_PLUGIN_ROOT}` が確実に展開されるのは hooks の command と MCP 設定だけで、skill / agent / command の Markdown 本文で展開されるかはバージョンによって挙動が異なる。そのため:

- skill の references はスクリプトを `<skill dir>/scripts/...` というプレースホルダで書き、skill 読み込み時に提示されるベースディレクトリを使うよう SKILL.md で指示している。
- `coadmap-pr-reviewer` agent はレビュー観点を本文にインラインしており、plugin 内のファイルを探しに行かなくても動く。呼び出し元(skill)はさらにチェックリスト本文をプロンプトで渡す。

## MCP の接続名

Coadmap MCP のツール名は接続方法で prefix が変わる(`mcp__coadmap-mcp__...` / `mcp__coadmap_mcp__...` など)。skill はツール名だけを書き、prefix はセッションのツール一覧から Coadmap MCP のツールを持つサーバーを探して補う。候補が複数あるときはサーバー名で選ばず、`get_coadmap_task_dependency` が返す `taskUrl` のホストで決める(SKILL.md「MCP ツールの呼び方」)。どのクライアントでも同じ扱い。

## トークン使用量の資格情報の解決順

opt-in(`COADMAP_AI_USAGE_REPORT=1`)時の接続先とトークンは、次の順で解決する。どれでも解決できなければ黙って何もしない。

1. 環境変数 `COADMAP_API_TOKEN` + `COADMAP_API_URL`(両方必須。任意の接続先を指定できる)
2. Claude Code の MCP OAuth 資格情報(`mcp.coadmap.com` に接続しているサーバーのもの)
3. Claude Code の MCP 設定に直書きされた `Authorization` ヘッダ
4. Codex の `~/.codex/config.toml` の `http_headers.Authorization`(または `bearer_token_env_var` が指す環境変数)

2〜4 で見つかる接続先は `mcp.coadmap.com` / `mcp-dev.coadmap.com`(`.net` も同様)の MCP サーバーに限られ、既定では本番を優先する。`COADMAP_AI_USAGE_TARGET=dev` を設定すると dev の接続を優先する。

## 新しいクライアントを追加するとき

1. `docs/clients/<name>.md` を作り、インストール手順・MCP 登録・hooks の有効化・サンドボックスなどの固有事情を書く。
2. 上の能力マトリクスに列を 1 つ足す。対応しない能力は「無し」と書き、skill 側の代替手段(inline レビュー、応答内チェックリストなど)を添える。
3. hooks の設定ファイルやパス変数が既存と違うなら `hooks/` に設定ファイルを追加し、manifest から参照する。`scripts/lint.sh` は `hooks/*.json` の配線先の実在を検査する。
4. skill 本体は、既存の能力条件で分岐を表せない場合にだけ変更する。その場合も「〜できるなら」「〜が出たら」という条件として書き、クライアント名は括弧内の例に留める。
