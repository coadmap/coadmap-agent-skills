# 04. PR 作成(タスクリンク) + IN_REVIEW 移動 + レビュー

## 1. PR 作成

- 作成前に base を最新化(`git fetch` + 既定ブランチ取り込み)し、リポのコード品質ゲート(設定の `qualityGate[]`、無ければ `CLAUDE.md` / `AGENTS.md` に書かれた lint / type / test)を通す。
- PR は **ユーザー承認後**に `gh pr create` で作成する。

### 1-1. body 組み立て(タスクリンクは body の1行目)

- **PR body の1行目に必ずタスクリンクを Markdown で入れる**:

  ```
  [[<TASK_ID>] <TASK_TITLE>](<task URL>)
  ```

  `<task URL>` は 00 で取得済みのものを使う(例: `[[CMDEV-9618] チャット画面の…](https://coadmap.com/ws/tasks/VGFzazoxMjM=)`)。
  未取得なら 00 に戻って MCP で取得してから PR を作る。**リンク無しで作成してはならない。**
- リポに PR テンプレート(`pull_request_template.md`)がある場合も、タスクリンクは**テンプレート構造より前の1行目**に置き、その下にテンプレートに沿った本文を続ける。テンプレートを優先してタスクリンクを省略しない。
- 複数リポにまたがる場合は**各リポの PR すべて**にタスクリンクを入れる。
- hooks が有効な環境では PreToolUse hook(`guard-pr-task-link.sh`)がタスクリンクの無い `gh pr create` をブロックする。ブロックされたらリンクを入れて再実行する。タスクと無関係な PR に限り、**コマンド先頭に** `COADMAP_PR_NO_TASK=1 gh pr create ...` と付けてバイパスできる(`export` では効かない)。hooks が無い環境でも次の 1-2 で同じことを担保する。

### 1-2. 作成後の検証(必須)

PR 作成直後に body を読み戻し、タスクリンクが1行目に入っているか必ず確認する:

```bash
gh pr view <PR番号> --json body -q .body | head -3
```

無ければ即座に修正する(body 先頭にタスクリンク行を追加して `gh pr edit <PR番号> --body-file <修正後body>`)。

### 1-3. クロスリポの相互参照(フル形式必須)

複数リポにまたがる場合は各リポで PR を立て、相互に参照を張る。このとき:

- **素の `#119` 形式は禁止**。GitHub 上では参照を書いたリポ自身の #119 に解決されてしまい、別リポの PR には紐づかない。
- 必ず **`owner/repo#番号` のフル形式**か **PR の完全 URL** を使う。

```markdown
## Related PRs
- org/backend#456 (BE)
- org/frontend#119 (FE)
```

## 2. IN_REVIEW へ移動

PR 作成後、タスクを IN_REVIEW ロールのパイプラインへ移動する(ユーザー承認後):

```
update_coadmap_task(
  taskIdentifier = "<...>",
  pipelineId     = "<IN_REVIEW の pipelineId>"   # 00 のロールマッピング由来
)
```

## 3. レビュー

レビューの観点は [review-checklist.md](review-checklist.md) に集約してある。実行方法は環境で選ぶ:

- **subagent を spawn できる環境(Claude Code など)**: `coadmap-pr-reviewer` agent(または agents team のレビュー担当)に **PR 番号 / 対象リポ / タスク要件 / review-checklist.md の本文** を渡してレビューさせる。subagent は plugin のファイルパスを知らないので、チェックリストはパスではなく本文をプロンプトに含める。担当が既にいる場合は重複レビューを避ける。
- **subagent が無い環境(Codex など)**: 自分で `gh pr diff <pr>` を読み、review-checklist.md の観点で **実装した時とは別の立場**からレビューし、同じ返却フォーマットで結果をまとめる。

レビュー結果のうち **must-fix(対応必須)** は **このセッションで対応**し、再 push する。nit は任意。verdict が needs-changes の間はマージ準備に進まない。
