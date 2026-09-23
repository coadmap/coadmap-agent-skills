# Claude Code

能力の一覧は [README.md](README.md#能力マトリクス)。

## インストール

```
/plugin marketplace add coadmap/coadmap-agent-skills
/plugin install coadmap-task-workflow@coadmap-agent-skills
```

skill・`/coadmap-task` command・`coadmap-pr-reviewer` agent・hooks(`hooks/hooks.json`)がまとめて入る。

hooks に信頼・レビューの手順は無く、インストール後の次の新規セッションから UserPromptSubmit / PreToolUse が発火することを確認している。plugin のインストールや更新は、実行中のセッションには反映されず新しいセッションから効く。

## Coadmap MCP の接続

Coadmap の設定画面で API キーを発行し、MCP サーバーとして登録する。

```bash
claude mcp add --transport http --scope user \
  coadmap-mcp https://mcp.coadmap.com/mcp \
  --header "Authorization:Bearer <ApiKey>"
```

サーバー名は任意(選び方は [README.md](README.md#mcp-の接続名))。ツールは `mcp__<サーバー名>__<ツール名>` の名前で見える。

## 固有の注意

- `/coadmap-task [TASK_ID|URL]` で明示的に着手できる。タスク ID / URL を含む依頼文でも UserPromptSubmit hook が skill 利用を促す。
- PR レビューは `coadmap-pr-reviewer` agent を spawn して行う。skill はチェックリスト本文をプロンプトで渡す。
- チェックリストは TodoWrite で項目化される。
- デスクトップアプリの既定設定では、SSH の `git push` と `gh pr create` が追加の承認なしで成功した。サンドボックスを有効にした構成での挙動は未検証。
- デスクトップアプリはセッションを `<repo>/.claude/worktrees/<name>` の worktree(ブランチ `claude/<name>`)で開始できる。skill はその worktree をそのまま使うが、ブランチは `claude/` prefix ではなく `<branchPrefix><TASK_ID>-<slug>` で、`git fetch origin` した最新の `origin/<base>` から切る(`references/02-worktree-setup.md`)。
- トークン使用量の自己申告(opt-in)は transcript を集計し、資格情報は MCP OAuth 資格情報 → MCP 設定に直書きされた `Authorization` ヘッダの順に探す。MCP 設定は user / local scope と repo 直下の `.mcp.json` を見る。

## plugin 機構を使わない場合

`skills/coadmap-task-workflow/` を `~/.claude/skills/` またはリポの `.claude/skills/` にコピーすれば skill 単体で動く。
