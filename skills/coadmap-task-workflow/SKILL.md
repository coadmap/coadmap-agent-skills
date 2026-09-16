---
name: coadmap-task-workflow
description: Coadmap のタスク(例 [CMDEV-9618] タイトル / CMDEV-9618 / https://coadmap.com/.../tasks/...)に着手・対応する時に使う。Coadmap MCP でタスク/プロジェクトのコンテキストを取得し、DOING 移動・アサイン/見積もり/スプリント設定・worktree 作成(PORT 衝突回避)・意思決定のタスクコメント記録・タスクリンク付き PR 作成 + IN_REVIEW 移動・レビュー・CI 確認・マージ準備通知・DONE 移動 + クリーンアップまでのライフサイクルを徹底する。
---

# coadmap-task-workflow

Coadmap タスクの着手から完了・後片付けまでのライフサイクルを徹底するオーケストレーター。

## 発火条件

- ユーザーがタスク ID(`CMDEV-9618` / `[ns-NN] title`)やタスク URL を渡して着手を依頼した時
- `/coadmap-task` コマンド実行時(Claude Code)

## パスの約束

この skill の references に出てくる `<skill dir>` は、**この SKILL.md があるディレクトリの絶対パス**を指す。skill 読み込み時に提示されるベースディレクトリ(例: `.../skills/coadmap-task-workflow`)をそのまま使う。作業ディレクトリは利用者のリポなので、`scripts/...` を相対パスのまま実行してはならない。

## 最初にやること

以下のチェックリストを **タスク管理ツール(TodoWrite / plan など、使えるもの)で必ず項目化**してから着手する。各フェーズの詳細は必要になった時点で references を読む。

- [ ] 1. Orientation: 本人アカウント解決 + タスク/ワークスペースコンテキスト取得 + プロジェクト設定の読み込み → [references/00-orientation.md](references/00-orientation.md)
- [ ] 2. DOING へ移動 + アサイン/見積もり/スプリント確認・設定 → [references/01-start-doing.md](references/01-start-doing.md)
- [ ] 3. worktree 作成 + Docker/PORT 構成 → [references/02-worktree-setup.md](references/02-worktree-setup.md)
- [ ] 4. 作業中: 意思決定・仕様詳細化をタスクコメント投稿 → [references/03-progress-comments.md](references/03-progress-comments.md)
- [ ] 5. PR 作成(body 1行目にタスクリンク + 作成後に body を読み戻して検証) + IN_REVIEW 移動 → [references/04-pr-and-review.md](references/04-pr-and-review.md)
- [ ] 6. レビュー + 指摘対応 → [references/04-pr-and-review.md](references/04-pr-and-review.md)
- [ ] 7. CI ステータス確認 → [references/05-ci-check.md](references/05-ci-check.md)
- [ ] 8. マージ準備をユーザー通知 → [references/06-merge-and-cleanup.md](references/06-merge-and-cleanup.md)
- [ ] 9. (ユーザー指示後) DONE 移動 + クリーンアップ → [references/06-merge-and-cleanup.md](references/06-merge-and-cleanup.md)

## Progressive Disclosure

| フェーズ | reference |
|---|---|
| 本人特定 / コンテキスト取得 / プロジェクト設定 | [references/00-orientation.md](references/00-orientation.md) |
| プロジェクト設定 `.coadmap/workflow.json` の仕様 | [references/configuration.md](references/configuration.md) |
| DOING 移動 / メタ設定 | [references/01-start-doing.md](references/01-start-doing.md) |
| worktree / Docker / PORT | [references/02-worktree-setup.md](references/02-worktree-setup.md) |
| タスクコメント記録 | [references/03-progress-comments.md](references/03-progress-comments.md) |
| PR / IN_REVIEW / レビュー | [references/04-pr-and-review.md](references/04-pr-and-review.md) |
| レビュー観点(agent と inline レビュー共用) | [references/review-checklist.md](references/review-checklist.md) |
| CI 確認 | [references/05-ci-check.md](references/05-ci-check.md) |
| マージ通知 / DONE / クリーンアップ | [references/06-merge-and-cleanup.md](references/06-merge-and-cleanup.md) |

## 絶対に守るルール

- **破壊的・外向き操作はユーザー承認後**: パイプライン移動・タスクコメント投稿・PR 作成・マージ・Docker 停止系・worktree/コンテナ削除。
- **DONE 移動とクリーンアップはユーザーの明示指示後にのみ**実行する。
- Coadmap MCP が接続されていない、または認証できない場合は、パイプライン移動・コメント投稿をスキップしてその旨をユーザーに伝える。
- **リポ固有の作法**(既定ブランチ名・CI・docker コマンド・レビュー観点)は、利用者リポの `.coadmap/workflow.json` と `CLAUDE.md` / `AGENTS.md` を正とする。無ければ推測せず、ユーザーに確認して設定に残す(learn & remember)。
- スクリプトは実行するもので、内容をロードして読む必要はない。

## MCP ツールの呼び方

本 skill の references は Coadmap MCP のツールを `get_coadmap_workspaces` のような **ツール名だけ**で書く。実際の呼び出し名は接続方法によって prefix が異なる(例: `mcp__coadmap-mcp__get_coadmap_workspaces`)。セッションで利用可能なツール一覧から `coadmap` を含むサーバーを探し、その prefix を付けて呼ぶ。

## scripts(すべて `<skill dir>/scripts/` 配下)

- `extract-task-id.sh` — stdin(プロンプト / ブランチ名)からタスク識別子を抽出
- `read-config.sh [dir]` — 利用者リポの `.coadmap/workflow.json` を親方向に探索して出力(無ければ `{}`)。`--path` でファイルパスを出す
- `save-pipeline-roles.sh <ws> <DOING> <IN_REVIEW> <DONE>` — パイプラインロールを `.coadmap/workflow.json` に記録(ロック付き)
- `resolve-identity.sh` / `save-identity.sh` — 本人アカウントの記憶(`~/.coadmap/task-flow.json`、ロック付き)
- `alloc-ports.sh <branch> <base>` — 決定的ポート割当(ロック付き、`~/.coadmap/port-registry.json`)
- `release-port.sh <branch>` — ポート確保の解放(クリーンアップ時)
