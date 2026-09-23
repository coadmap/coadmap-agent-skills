# Codex

能力の一覧は [README.md](README.md#能力マトリクス)。

## インストール

```
codex plugin marketplace add coadmap/coadmap-agent-skills
codex plugin add coadmap-task-workflow@coadmap-agent-skills
```

または対話セッションで `/plugins` を開き、マーケットプレイスから選ぶ。skill と hooks(`hooks/codex-hooks.json`)が入る。command と agent は入らない(下記)。

## hooks の信頼

**インストール後、hooks を信頼するまで 4 つの hook はどれも動かない。** Codex は plugin の hook を実行前にレビューさせる仕組みで、未信頼の hook はセッション中に確認を出さず黙ってスキップされる。Codex デスクトップアプリでは plugin の詳細画面に「N 個のフックは実行前にレビューが必要です」と出るので、「見直し」で中身を確認するか「すべて信頼する」を選ぶ。CLI でも同様に信頼(レビュー)が済むまで hook は実行されない。

- 信頼は hook ごとに `~/.codex/config.toml` の `[hooks.state]` に記録される。plugin の更新などで hook ファイルが変わると、再びレビューが必要になる。
- 信頼しないままだと UserPromptSubmit の skill 誘導が出ず、PreToolUse の PR リンク検査も効かない。検査は UserPromptSubmit hook がマーカーを作ったセッションだけを対象にするため、エラーにもならず素通りする。

## Coadmap MCP の接続

Coadmap の設定画面で API キーを発行し、`~/.codex/config.toml` に登録する。

```toml
[mcp_servers.coadmap-mcp]
url = "https://mcp.coadmap.com/mcp"
http_headers = { "Authorization" = "Bearer <ApiKey>" }
```

サーバー名は任意(選び方は [README.md](README.md#mcp-の接続名))。

## サンドボックスと `git push` / `gh`

Codex の既定のサンドボックス内では、`git push`(SSH の ssh-agent)や `gh`(macOS キーチェーンのトークン)が `Permission denied (publickey)` / `The token in default is invalid` などで失敗することがある。サンドボックス外では認証は正常なので再ログインは不要で、該当コマンドをサンドボックス外で実行する承認を出せばよい。

## 固有の注意

- slash command は無い。`CMDEV-1234 に着手して` のようにタスク ID を含めて依頼する。
- plugin は agent を同梱しないため、PR レビューは skill が `references/review-checklist.md` の観点で inline に行う。
- チェックリストは plan / update_plan で項目化される。
- Codex アプリはセッション用の worktree を detached HEAD で用意することがある。skill はそれをそのまま使うが、ブランチは `codex/` prefix ではなく `<branchPrefix><TASK_ID>-<slug>` で `origin/<base>` から切る。
- トークン使用量の自己申告(opt-in)は rollout log を集計し、資格情報は `~/.codex/config.toml` の `http_headers.Authorization`(または `bearer_token_env_var` が指す環境変数)から取る。Codex 自身の OAuth 資格情報は読まない。

## plugin 機構を使わない場合

`skills/coadmap-task-workflow/` を `~/.codex/skills/` またはリポの `.agents/skills/` にコピーすれば skill 単体で動く。
