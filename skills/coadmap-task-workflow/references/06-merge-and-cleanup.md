# 06. マージ準備通知 + DONE 移動 + クリーンアップ

## 1. マージ準備完了をユーザーに通知

CI が green かつレビュー指摘(must-fix)対応済みになったら、**ユーザーへマージ準備完了を通知し、最終レビューとマージを依頼する**。

- **自動マージはしない。** マージは必ずユーザーが行う(または明示指示を得てから)。
- 通知には PR リンク・CI 状態・対応済みレビュー指摘の要約を含める。

## 2. DONE へ移動(ユーザー指示後)

**マージされ、ユーザーから DONE 移動の指示があったら**タスクを DONE ロールへ移動する:

```
update_coadmap_task(
  taskIdentifier = "<...>",
  pipelineId     = "<DONE の pipelineId>"   # 00 のロールマッピング由来
)
```

## 3. クリーンアップ(継続タスクが無ければ / ユーザー指示後)

継続作業が無いことを確認し、**ユーザー承認のうえ**で後片付けする。各操作は破壊的なので実行前に確認する。02 で使った `wtdir`(設定の `worktreeDir`、既定 `.worktrees`)と同じ置き場を対象にする。

1. **Docker コンテナの停止/削除**(設定の `repos[].docker.down`。承認後)。
2. **ポート確保の解放** — registry から該当ブランチのエントリを削除:
   ```bash
   bash "<skill dir>/scripts/release-port.sh" "<branch>"
   ```
3. **worktree の削除** — 全リポで:
   ```bash
   for repo in "<repoA>" "<repoB>"; do
     git -C "$repo" worktree remove "$repo/$wtdir/<TASK_ID>"
   done
   ```

継続タスクがある場合はクリーンアップせず、その旨をユーザーに伝えて環境を残す。
