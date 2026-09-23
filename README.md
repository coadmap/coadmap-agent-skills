# coadmap-agent-skills

[Coadmap](https://coadmap.com) を使う開発チーム向けの、AI コーディングエージェント用 skills / plugin。

現在は **`coadmap-task-workflow`** の 1 plugin を収録。Claude Code と Codex に対応(クライアントごとの差分は [docs/clients/](docs/clients/README.md))。

## coadmap-task-workflow

Coadmap のタスク(`[CMDEV-9618] タイトル` / `CMDEV-9618` / タスク URL)を渡して着手するときに、**着手から完了・後片付けまでのライフサイクル**をエージェントに徹底させる。

### 何をするか(9 フェーズ)

1. Coadmap MCP でタスク情報・プロジェクトコンテキストを取得
2. **DOING** パイプラインへ移動 + アサイン / 見積もり / スプリントの設定有無を確認・補完
3. 使う全リポで **worktree 作成**(同一ブランチ名)+ Docker 利用時は **PORT 衝突回避**(ローカルで複数セッションを並行する場合向け。隔離されたサンドボックスではスキップ)
4. 対話で確定した **意思決定・仕様詳細化をタスクコメントに記録**
5. **タスクリンク付き PR** を作成し、タスクを **IN_REVIEW** へ移動
6. 独立した立場での **レビュー → 指摘対応**(サブエージェントを使えるクライアントでは subagent、使えなければ inline)
7. **CI ステータス確認**(`gh pr checks`)
8. マージ準備が整ったら **ユーザーへ通知**(最終レビュー・マージは人間が実施)
9. マージ後(ユーザー指示で)**DONE** へ移動 + 継続タスクが無ければ **コンテナ / worktree クリーンアップ**

パイプライン移動・コメント投稿・PR 作成・Docker 停止・worktree 削除といった**破壊的・外向き操作はユーザー承認後**にのみ実行する。DONE 移動とクリーンアップはユーザーの明示指示後のみ。

### 構成要素

| 種別 | 名前 | 役割 | 使えないクライアントでの代替 |
|---|---|---|---|
| skill | `coadmap-task-workflow` | ライフサイクル全体のオーケストレーター(references で段階的に読む) | - |
| command | `/coadmap-task [TASK_ID\|URL]` | 明示的な着手エントリポイント | タスク ID を含めて依頼する |
| agent | `coadmap-pr-reviewer` | PR の独立レビュー担当 | skill が inline でレビュー |
| hook | UserPromptSubmit | プロンプトにタスク ID/URL を検出したら skill 利用を促す(セッション 1 回) | - |
| hook | PreToolUse (Bash / MCP の `create_pull_request`) | タスク作業中、Coadmap タスクリンクの無い PR 作成(`gh pr create` / `gh pr new`、MCP の `*__create_pull_request`)をブロック | skill が PR 作成後に body を読み戻して検証 |
| hook | SessionEnd / Stop | トークン使用量を Coadmap に自己申告(**既定 off**、後述) | - |

タスクと無関係な PR を作る場合は、**コマンド先頭に** `COADMAP_PR_NO_TASK=1 gh pr create ...` と付けてバイパスする(`export` では効かない)。

PR リンク検査の狙いはリンクの付け忘れで、意図的な回避(`eval` や `python -c`、`gh api` での作成、作成後に `gh pr edit` で本文を書き換える等)は防がない。静的に追えない書き方の中に `gh pr create` があればリンクを確認できない限りブロックするが、それも付け忘れを拾うための安全側の判定にすぎない。PR 作成後に skill が body を読み戻して確かめるのが二段目の検査になる。

どのクライアントで何が使えるかは [docs/clients/README.md](docs/clients/README.md) の能力マトリクスを参照。

## 前提

- Coadmap MCP サーバーがエージェントに接続済みであること(下記)
- `gh`(GitHub CLI、認証済み)、`git`、`jq`、`bash`

### Coadmap MCP の接続

Coadmap MCP(`https://mcp.coadmap.com/mcp`)をサーバーとして登録し、OAuth でログインする。クライアントごとの登録・ログイン方法は [Claude Code](docs/clients/claude-code.md#coadmap-mcp-の接続) / [Codex](docs/clients/codex.md#coadmap-mcp-の接続)。

サーバー名は任意。skill はツール一覧から Coadmap MCP のツールを持つサーバーを探して使う。複数ある場合は名前ではなく、`get_coadmap_task_dependency` が返すタスク URL のホスト(URL 指定時はそのホスト、ID 指定時は `coadmap.com`)で 1 つに決める。

## インストール

クライアントごとの手順は次を参照する。

- [Claude Code](docs/clients/claude-code.md#インストール)
- [Codex](docs/clients/codex.md#インストール)

クライアントによっては、インストールしただけでは hooks が動かず、別途信頼(レビュー)が必要になる。信頼しないままだと skill 誘導も PR リンク検査もエラーを出さずに素通りするので、各クライアントのページの手順を済ませておく。

### plugin 機構を使わない場合

`skills/coadmap-task-workflow/` をそのまま、クライアントが skill を読み込むディレクトリ(置き場は [docs/clients/](docs/clients/README.md#能力マトリクス) を参照)にコピーすれば skill 単体で動く。skill 配下は自己完結しており、外へのリンクは無い。hooks / command / agent は付かないが、skill の手順だけでワークフローは回るように書いてある。

## 使い方

```
CMDEV-1234 に着手して
```

```
/coadmap-task https://coadmap.com/<ws>/tasks/<id>
```

(2 つ目は slash command を持つクライアントのみ)

skill がチェックリストを作り、Orientation から順に進める。初回は本人アカウントやワークスペースのパイプラインロールをヒアリングし、本人アカウントは `~/.coadmap/` に、パイプラインロールはリポの `.coadmap/workflow.json` に記憶して次回以降は聞かない。

## プロジェクト設定(任意)

作業リポの `.coadmap/workflow.json` に、既定ブランチ・worktree の置き場・ポート上書き env・post-setup コマンド・docker コマンド・品質ゲート・パイプラインロール・`coadmap.com` 以外のタスク URL のホストを書いておくと、skill はそれを正として推測やヒアリングを省く。無ければ必要になった時点でユーザーに確認し、承認のうえで書き残す。

仕様と例、`~/.coadmap/` 配下の状態ファイル一覧は [skills/coadmap-task-workflow/references/configuration.md](skills/coadmap-task-workflow/references/configuration.md)。

## トークン使用量の自己申告(opt-in)

セッション終了時と各ターン終了時に、そのセッションで消費したトークン量(入力・出力・キャッシュ作成・キャッシュ読み取りの**集計値のみ**)を Coadmap に自己申告する hook を同梱している。Coadmap 側で「標準 AI 以外の外部エージェントがどれだけ使われているか」を把握するためのもの。集計元はクライアントごとに異なる(Claude Code の transcript、Codex の rollout log など。[docs/clients/](docs/clients/README.md#能力マトリクス))。

**plugin を入れただけでは何も送らない。** 送るには明示的に有効化する:

```bash
export COADMAP_AI_USAGE_REPORT=1
```

有効化した場合の接続先とトークンは、まず環境変数 `COADMAP_API_TOKEN` + `COADMAP_API_URL`(両方必須。任意の接続先を指定できる)を見て、無ければクライアントの MCP 設定・資格情報から探す。クライアントごとの探索順は [docs/clients/README.md](docs/clients/README.md#トークン使用量の資格情報の解決順)。どれでも解決できなければ黙って何もしない。

送られるもの: エージェント種別、最もトークンを消費したモデル名、各トークン数の集計値、セッション ID、分かる場合のみブランチ名から推定したタスク ID。
送られないもの: 会話内容・プロンプト・コード差分・ファイル内容(transcript はローカルでトークン集計にのみ使い、本文は一切送らない)、API トークン等の秘匿情報。hook 入力は argv に載せず stdin で worker に渡すので、`ps` から応答本文が読めることもない。

## 開発

```bash
bash scripts/test.sh   # skills / hooks の _tests を全実行
bash scripts/lint.sh   # shellcheck + manifest JSON + hook 配線 + Markdown リンク検証
```

CI は ubuntu と macOS の両方で回る。skill やドキュメントを書くときの約束(クライアント固有の記述の置き場など)は [CONTRIBUTING.md](CONTRIBUTING.md)。

## ライセンス

MIT
