# coadmap-agent-skills

[Coadmap](https://coadmap.com) を使う開発チーム向けの、AI コーディングエージェント用 skills / plugin。

現在は **`coadmap-task-workflow`** の 1 plugin を収録。Claude Code と Codex に対応。

## coadmap-task-workflow

Coadmap のタスク(`[CMDEV-9618] タイトル` / `CMDEV-9618` / タスク URL)を渡して着手するときに、**着手から完了・後片付けまでのライフサイクル**をエージェントに徹底させる。

### 何をするか(9 フェーズ)

1. Coadmap MCP でタスク情報・プロジェクトコンテキストを取得
2. **DOING** パイプラインへ移動 + アサイン / 見積もり / スプリントの設定有無を確認・補完
3. 使う全リポで **worktree 作成**(同一ブランチ名)+ Docker 利用時は **PORT 衝突回避**
4. 対話で確定した **意思決定・仕様詳細化をタスクコメントに記録**
5. **タスクリンク付き PR** を作成し、タスクを **IN_REVIEW** へ移動
6. 独立した立場での **レビュー → 指摘対応**(Claude Code は subagent、Codex は inline)
7. **CI ステータス確認**(`gh pr checks`)
8. マージ準備が整ったら **ユーザーへ通知**(最終レビュー・マージは人間が実施)
9. マージ後(ユーザー指示で)**DONE** へ移動 + 継続タスクが無ければ **コンテナ / worktree クリーンアップ**

パイプライン移動・コメント投稿・PR 作成・Docker 停止・worktree 削除といった**破壊的・外向き操作はユーザー承認後**にのみ実行する。DONE 移動とクリーンアップはユーザーの明示指示後のみ。

### 構成要素

| 種別 | 名前 | 役割 | Claude Code | Codex |
|---|---|---|---|---|
| skill | `coadmap-task-workflow` | ライフサイクル全体のオーケストレーター(references で段階的に読む) | ○ | ○ |
| command | `/coadmap-task [TASK_ID\|URL]` | 明示的な着手エントリポイント | ○ | ×(タスク ID を含めて依頼する) |
| agent | `coadmap-pr-reviewer` | PR の独立レビュー担当 | ○ | ×(skill が inline でレビュー) |
| hook | UserPromptSubmit | プロンプトにタスク ID/URL を検出したら skill 利用を促す(セッション 1 回) | ○ | ○ |
| hook | PreToolUse (Bash) | タスク作業中、Coadmap タスクリンクの無い `gh pr create` をブロック(無関係な PR は `COADMAP_PR_NO_TASK=1` でバイパス) | ○ | ○(要 hooks 有効化) |
| hook | SessionEnd / Stop | トークン使用量を Coadmap に自己申告(**既定 off**、後述) | ○ | 配線のみ(実測値は未対応) |

差分の詳細は [docs/claude-vs-codex.md](docs/claude-vs-codex.md)。

## 前提

- Coadmap MCP サーバーがエージェントに接続済みであること(タスク取得・パイプライン移動・コメント投稿に使用)
- `gh`(GitHub CLI、認証済み)、`git`、`jq`、`bash`

## インストール

### Claude Code

```
/plugin marketplace add simula-labs/coadmap-agent-skills
/plugin install coadmap-task-workflow@coadmap-agent-skills
```

### Codex

```
codex plugin marketplace add simula-labs/coadmap-agent-skills
codex plugin add coadmap-task-workflow@coadmap-agent-skills
```

または対話セッションで `/plugins` を開き、マーケットプレイスから選ぶ。Codex の hooks は機能フラグで無効になっている場合があるので、hook を使うには `~/.codex/config.toml` で `codex_hooks` を有効にする(手順は Codex のドキュメントを参照)。

### plugin 機構を使わない場合

`skills/coadmap-task-workflow/` をそのまま `~/.claude/skills/`、`~/.codex/skills/`、またはリポの `.claude/skills/` / `.agents/skills/` にコピーすれば skill 単体で動く。skill 配下は自己完結しており、外へのリンクは無い。hooks / command / agent は付かないが、skill の手順だけでワークフローは回るように書いてある。

## 使い方

```
CMDEV-1234 に着手して
```

```
/coadmap-task https://coadmap.com/<ws>/tasks/<id>
```

skill がチェックリストを作り、Orientation から順に進める。初回はワークスペースのパイプラインロールや本人アカウントをヒアリングし、`~/.coadmap/` に記憶して次回以降は聞かない。

## プロジェクト設定(任意)

作業リポの `.coadmap/workflow.json` に、既定ブランチ・worktree の置き場・ポート上書き env・post-setup コマンド・docker コマンド・品質ゲートを書いておくと、skill はそれを正として推測やヒアリングを省く。無ければ必要になった時点でユーザーに確認し、承認のうえで書き残す。

仕様と例は [skills/coadmap-task-workflow/references/configuration.md](skills/coadmap-task-workflow/references/configuration.md)。

## トークン使用量の自己申告(opt-in)

セッション終了時に、そのセッションで消費したトークン量(入力・出力・キャッシュ作成・キャッシュ読み取りの**集計値のみ**)を Coadmap に自己申告する hook を同梱している。Coadmap 側で「標準 AI 以外の外部エージェントがどれだけ使われているか」を把握するためのもの。

**plugin を入れただけでは何も送らない。** 送るには明示的に有効化する:

```bash
export COADMAP_AI_USAGE_REPORT=1
```

有効化した場合の接続先は、環境変数 `COADMAP_API_TOKEN` / `COADMAP_API_URL` で指定する。未指定なら Claude Code の `~/.claude.json` にある MCP サーバー設定のうち、名前か URL に `coadmap` を含むものの認証ヘッダから解決を試みる(claude.ai のコネクタ経由や Codex の `config.toml` からは解決できない)。どちらも無ければ黙って何もしない。

送られるもの: エージェント種別、最もトークンを消費したモデル名、各トークン数の集計値、セッション ID、分かる場合のみブランチ名から推定したタスク ID。
送られないもの: 会話内容・プロンプト・コード差分・ファイル内容(transcript はローカルでトークン集計にのみ使い、本文は一切送らない)、API トークン等の秘匿情報。

Codex は transcript 形式が異なるため現状は集計できず、読めない形式を検出した場合は 0 の嘘レポートを送らずに終了する(`~/.coadmap/ai-usage-report.log` に 1 行残る)。

## 開発

```bash
bash scripts/test.sh   # skills / hooks の _tests を全実行
bash scripts/lint.sh   # shellcheck + manifest JSON + hook 配線 + Markdown リンク検証
```

## ライセンス

MIT
