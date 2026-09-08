# 00. Orientation(本人特定 / タスク・コンテキスト取得 / プロジェクト設定)

タスク着手前に「誰が・どのタスクを・どのワークスペースで・どのリポ構成で」を確定する。`<skill dir>` は SKILL.md の「パスの約束」を参照。

## 1. タスク識別子の確定

ユーザー入力(プロンプト)、それが無ければ現在のブランチ名(`git branch --show-current`)からタスク識別子を抽出する:

```bash
printf '%s' "<ユーザー入力 or ブランチ名>" | bash "<skill dir>/scripts/extract-task-id.sh"
```

- 出力が URL ならそのままタスク URL として使う。
- 出力が displayId(`CMDEV-9618` / `development_coadmap-36`)なら後段の MCP 取得に使う。ブランチ名は慣例上小文字だが、スクリプトが大文字化して返す。
- 空なら、ユーザーにタスク ID/URL を尋ねる。

## 2. プロジェクト設定の読み込み

```bash
bash "<skill dir>/scripts/read-config.sh"
```

`.coadmap/workflow.json`(仕様は [configuration.md](configuration.md))があれば、以降のフェーズはその値を優先する。無ければ `{}` が返るので、必要になった項目をその都度ユーザーに確認し、**確認した内容は `.coadmap/workflow.json` に書いて次回以降の再ヒアリングを無くす**(ファイル作成はユーザー承認後)。

## 3. 本人アカウントの解決(learn & remember)

```bash
bash "<skill dir>/scripts/resolve-identity.sh"
```

- **exit 0 + accountId 出力**: 記憶済み。その accountId をアサインに使う。
- **exit 3(出力なし)**: 未登録。以下で確定する:
  1. `git config user.email` で現在の email を取得(このセッションの作業者)。
  2. 後述の workspace context の `members` から email 一致候補を提示し、ユーザーに本人アカウントを確認する。
  3. 確定したら保存して以後再利用する:
     ```bash
     bash "<skill dir>/scripts/save-identity.sh" "<accountId>" "<email>" "<displayName>"
     ```

## 4. タスク情報・プロジェクトコンテキストの取得(MCP)

1. `get_coadmap_workspaces` で全ワークスペースを取得し、対象タスクが属する workspace を特定する。
2. `get_coadmap_workspace_context(workspaceId)` で **pipelines / members / sprints / estimateValues / labels / epics / releases** を取得する。
3. タスク本体(タイトル・現在パイプライン・既存のアサイン/見積もり/スプリント)は `get_coadmap_workspace_tasks` などで取得し把握する。
   - displayId しか無い場合もここで raw UUID / global ID とタスク URL を得ておく(後段のコメント投稿・PR リンクで使う)。

## 5. パイプラインロールの特定(DOING / IN_REVIEW / DONE)

workspace context の `pipelines` から各ロールに対応する `pipelineId` を決める:

- pipelines に **role / type 等のロール相当フィールドがある場合**: それを使って DOING / IN_REVIEW / DONE を自動マッピングする。
- **無い / 判別できない場合**: ユーザーに各ロールのパイプラインを確認し、`~/.coadmap/task-flow.json` の `.workspaces[<workspaceId>].pipelineRoles` に記録して以後再利用する:
  ```bash
  STATE="${COADMAP_STATE_FILE:-$HOME/.coadmap/task-flow.json}"
  mkdir -p "$(dirname "$STATE")"; [[ -f "$STATE" ]] || echo '{}' > "$STATE"
  tmp="$(mktemp)"
  jq --arg ws "<workspaceId>" --arg doing "<pid>" --arg review "<pid>" --arg done "<pid>" \
    '.workspaces[$ws].pipelineRoles = {DOING:$doing, IN_REVIEW:$review, DONE:$done}' "$STATE" > "$tmp"
  mv "$tmp" "$STATE"
  ```
- 次回以降は `jq -r '.workspaces["<workspaceId>"].pipelineRoles' "$STATE"` で読み出し、再ヒアリングしない。

## 6. 結果の要約

タスク(ID・タイトル・URL)、ワークスペース、パイプラインロール、本人アカウント、読み込んだプロジェクト設定をユーザーに一度要約してから次フェーズへ進む。
