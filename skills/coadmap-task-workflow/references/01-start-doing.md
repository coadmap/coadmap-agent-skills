# 01. DOING へ移動 + メタ設定(アサイン / 見積もり / スプリント)

着手を Coadmap 上に反映する。**破壊的・外向き操作のため、移動先と設定する値を示してユーザー承認を取ってから実行する**(承認の定義は [SKILL.md](../SKILL.md) の「絶対に守るルール」)。

## 1. DOING パイプラインへ移動

タスクが DOING より前(新規・バックログなど)にある場合だけ移動する。既に DOING かそれより後(IN_REVIEW・DONE など)なら動かさない。作業再開時にレビュー中のタスクを DOING に戻してしまうため。前後が判断できなければユーザーに確認する。

00 で確定した DOING ロールの `pipelineId` を使う:

```
update_coadmap_task(
  taskIdentifier = "<URL or displayId or [ns-NN] title>",
  pipelineId     = "<DOING の pipelineId>"
)
```

## 2. メタの欠落チェックと補完

00 で取得したタスクの既存メタを確認し、未設定のものは設定する値を提案して、承認後に設定する。**設定は1回の `update_coadmap_task` にまとめてよい。**

| 項目 | 未設定時の対応 |
|---|---|
| アサイン | `assigneeIds = ["<記憶済み accountId>"]`(00 の resolve-identity 由来) |
| 見積もり | workspace context の `estimateValues` から値を提案し、承認後に `estimateValue = <値>` |
| スプリント | **そのワークスペースが sprints を使う場合のみ**。現行スプリントを提案し、承認後に `sprintIds = ["<sprintId>"]` |

- スプリントを使わない PJ(workspace context の `sprints` が空など)ではスプリント設定をスキップする。
- 既に設定済みの項目は上書きしない(`update_coadmap_task` の配列フィールドは全置換なので、既存値を保持したい場合は既存 + 追加をまとめて渡す)。

### まとめて設定する例

```
update_coadmap_task(
  taskIdentifier = "<...>",
  pipelineId     = "<DOING>",           // DOING より前にある場合のみ
  assigneeIds    = ["<accountId>"],
  estimateValue  = <値>,
  sprintIds      = ["<sprintId>"]   // スプリント運用 PJ のみ
)
```

## 3. 結果の要約

移動先ロール・設定したメタ(アサイン/見積もり/スプリント)をユーザーへ要約報告し、次フェーズ(worktree 構築)へ進む。
