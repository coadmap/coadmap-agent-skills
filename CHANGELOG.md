# Changelog

## Unreleased

- Coadmap MCP のサーバーが複数接続されているとき、サーバー名ではなく `get_coadmap_task_dependency` が返す `taskUrl` のホストで使うサーバーを決めるようにした(URL 指定時はそのホスト、ID 指定時は `coadmap.com`)
- タスク取得をワークスペースのタスク一覧からの検索ではなく `get_coadmap_task_dependency` で直接行うようにした。一覧はツール出力の上限を超えて切れていた。所属 workspace はタスクの現在パイプライン ID を含む workspace として特定する
- worktree 作成時に `--no-track` を付け、新ブランチの upstream が `origin/<base>` にならないようにした
- タスク管理ツールが無い環境では、応答内にチェックリストを示して進捗を更新するようにした

## 0.1.0

初版。simula-labs 社内 plugin `coadmap-task-workflow`(社内マーケットプレイス `simula-labs-plugins`)を、Coadmap を使う任意の開発チームが Claude Code / Codex で使えるように汎用化した。

### 社内版からの移行に関する注意

- **skill 名を `work-on-coadmap-task` から `coadmap-task-workflow` に変更した。** plugin 名と揃えるため。社内版と本 plugin を両方インストールすると同じワークフローの skill が 2 つ並ぶので、どちらか一方にする。
- 状態ファイル `~/.coadmap/port-registry.json` のキーを `<branch>` から `<branch>:<base>` に変更した。旧形式のエントリは `release-port.sh` が同時に消す。
- パイプラインロール(DOING / IN_REVIEW / DONE)の保存先を `~/.coadmap/task-flow.json` からリポ側の `.coadmap/workflow.json` に変更した。チーム共通の事実なのでコミットして共有する。
- hook のセッションマーカーを共有 `/tmp` から `~/.coadmap/run/` に移動した。

### 変更点

- リポ固有の手順(対象リポ・既定ブランチ・ポート env・post-setup)を利用者側の `.coadmap/workflow.json` に外出し
- skill 本文をエージェント非依存の語彙に書き換え、レビュー観点を `references/review-checklist.md` に集約(Claude Code は agent、Codex は inline で共用)
- hooks は Claude Code 用 `hooks.json` と Codex 用 `codex-hooks.json` の 2 枚。usage report は両方とも SessionEnd + Stop に配線
- トークン使用量の自己申告 hook は社内版 v0.4.0 相当(Codex rollout log 対応、segment 方式、再送キュー)を opt-in のまま収録。hook 入力は argv ではなく stdin で worker に渡す
- `guard-pr-task-link.sh`: バックティック / eval / `sh -c` 内の `gh pr create` は fail-close、`gh --repo` 等のグローバルオプション対応、1 コマンド列の全件検査、行継続の扱いを修正、URL 判定のホスト境界と ID 非空を検証
- `alloc-ports.sh`: 同一ブランチで base が違えば別ポートを割り当てる
- `save-identity.sh` / `save-pipeline-roles.sh`: mkdir ロックで並行書き込みを直列化
- `extract-task-id.sh`: ブランチ名(小文字 displayId)からも抽出。正規表現断片 `[A-Z0-9]` の誤検出を防止
- `scripts/test.sh` / `scripts/lint.sh`(hook 配線の実在チェック、Markdown リンク切れ検出)と GitHub Actions(ubuntu / macOS)を追加
