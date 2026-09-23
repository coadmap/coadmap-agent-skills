# プロジェクト設定 `.coadmap/workflow.json`

skill が「リポ固有の作法」を推測しないで済むように、利用者側のリポに置く設定ファイル。**すべて任意**で、無ければ skill は必要になった項目をその都度ユーザーに確認し、承認のうえでこのファイルに書き残す(learn & remember)。チームで共有する事実(パイプラインロール、対象リポ、ポート env など)はここに置く。タスクの PR には含めず、コミットして共有するのはユーザーに頼まれた時だけ、タスクとは別に行う。

置き場所は作業リポの直下 `.coadmap/workflow.json`。skill は cwd から親方向に探索するので、モノレポやサブディレクトリからでも見つかる。環境変数 `COADMAP_WORKFLOW_CONFIG` でパスを明示することもできる。

## 例

```json
{
  "branchPrefix": "feature/",
  "worktreeDir": ".worktrees",
  "qualityGate": ["npm run lint", "npm run typecheck", "npm test"],
  "reviewGuidelines": "docs/review-guidelines.md",
  "pipelineRoles": {
    "<workspaceId>": { "DOING": "<pipelineId>", "IN_REVIEW": "<pipelineId>", "DONE": "<pipelineId>" }
  },
  "repos": [
    {
      "name": "backend",
      "path": "~/src/acme/backend",
      "defaultBranch": "develop",
      "ports": [{ "env": "APP_PORT", "base": 3000 }],
      "postSetup": ["bundle install"],
      "docker": {
        "up": "make up",
        "down": "make down",
        "healthcheck": "curl -fsS http://localhost:$APP_PORT/health"
      }
    },
    {
      "name": "frontend",
      "path": "~/src/acme/frontend",
      "ports": [{ "env": "VITE_PORT", "base": 5173 }],
      "postSetup": ["[ -d ../../certs ] && ln -sfn ../../certs certs", "pnpm install"]
    }
  ]
}
```

## キー

| キー | 既定 | 意味 |
|---|---|---|
| `branchPrefix` | `feature/` | 作業ブランチ名の prefix。ブランチ名は `<branchPrefix><TASK_ID>-<slug>` |
| `worktreeDir` | `.worktrees` | 各リポ直下からの worktree 置き場(相対パス) |
| `qualityGate[]` | なし | PR 作成前と CI 失敗時にローカルで回すコマンド |
| `reviewGuidelines` | なし | レビュー時に参照するリポ固有の観点ファイル |
| `pipelineRoles[<workspaceId>]` | MCP から自動判別 | DOING / IN_REVIEW / DONE に対応する `pipelineId`。自動判別できない場合に `save-pipeline-roles.sh` が書く |
| `repos[].name` | 必須 | 識別名 |
| `repos[].path` | 必須 | ローカルパス。先頭の `~` は skill 側で `$HOME` に展開する(シェルは展開しない) |
| `repos[].defaultBranch` | `origin/HEAD` から推定 | worktree の base にする既定ブランチ |
| `repos[].ports[]` | なし | `env`: docker-compose 等がポート上書きに使う環境変数名、`base`: 割当の基準ポート |
| `repos[].postSetup[]` | なし | worktree 作成直後に worktree 直下で実行するコマンド |
| `repos[].docker.up` / `down` | なし | 起動・停止コマンド(実行はユーザー承認後) |
| `repos[].docker.healthcheck` | なし | 起動後の疎通確認コマンド。`$<env>` を参照するので、ポート割当後に export しておく |

## 状態ファイル(自動生成、ユーザー単位)

設定ファイルとは別に、skill と hooks は `~/.coadmap/` 配下にユーザー単位の状態を持つ。これらはリポにコミットしない。

| パス | 用途 | 上書き用の環境変数 |
|---|---|---|
| `task-flow.json` | 本人アカウント(接続先ホストごとの `identities`。旧形式の単一 `identity` は `coadmap.com` として読む) | `COADMAP_STATE_FILE` |
| `task-flow.json.lock` | 上記の書き込みロック(mkdir ロック、1 分で stale 回収) | 同上 |
| `port-registry.json` | 並行 worktree のポート割当。キーは `<branch>:<base>` | `COADMAP_PORT_REGISTRY` |
| `port-registry.json.lock` | 上記の書き込みロック | 同上 |
| `run/<session>.injected` | hook 用のセッションマーカー(タスク検出済みの印)。7 日で掃除 | `COADMAP_RUN_DIR` |
| `ai-usage-report.log` | トークン使用量自己申告のログ(opt-in 時のみ) | なし |
| `ai-usage-reports/` | 自己申告の送信状態・再送キュー(opt-in 時のみ) | なし |

ポート割当は registry 内の他ブランチとだけ衝突を避ける。ホスト上で別プロセスが同じポートを既に使っている場合は bind エラーになるので、その時は `release-port.sh` で解放して割り当て直すか、`base` を変える。
