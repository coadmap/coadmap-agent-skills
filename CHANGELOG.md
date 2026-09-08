# Changelog

## Unreleased

- 初版。simula-labs 社内 plugin `coadmap-task-workflow` 0.3.1 を汎用化。
  - リポ固有の手順(対象リポ・既定ブランチ・ポート env・post-setup)を利用者側の `.coadmap/workflow.json` に外出し
  - skill 本文をエージェント非依存の語彙に書き換え、レビュー観点を `references/review-checklist.md` に集約(Claude Code は agent、Codex は inline で共用)
  - hooks は UserPromptSubmit / PreToolUse を共用し、usage report のみ Claude Code は SessionEnd、Codex は Stop で配線
  - hook のセッションマーカーを共有 `/tmp` から `~/.coadmap/run/` に移動
  - `extract-task-id.sh` がブランチ名(小文字 displayId)からも抽出できるように変更
  - トークン使用量の自己申告 hook は opt-in のまま収録。MCP 設定からの認証情報探索は固定サーバー名ではなく名前/URL に `coadmap` を含むものを対象に変更
