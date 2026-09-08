# プロジェクト設定 `.coadmap/workflow.json`

skill が「リポ固有の作法」を推測しないで済むように、利用者側のリポに置く設定ファイル。**すべて任意**で、無ければ skill は必要になった項目をその都度ユーザーに確認し、承認のうえでこのファイルに書き残す(learn & remember)。

置き場所は作業リポの直下 `.coadmap/workflow.json`。skill は cwd から親方向に探索するので、モノレポやサブディレクトリからでも見つかる。環境変数 `COADMAP_WORKFLOW_CONFIG` でパスを明示することもできる。

## 例

```json
{
  "branchPrefix": "feature/",
  "worktreeDir": ".worktrees",
  "qualityGate": ["npm run lint", "npm run typecheck", "npm test"],
  "reviewGuidelines": "docs/review-guidelines.md",
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
| `repos[].name` | 必須 | 識別名 |
| `repos[].path` | 必須 | ローカルパス(`~` 展開可) |
| `repos[].defaultBranch` | `origin/HEAD` から推定 | worktree の base にする既定ブランチ |
| `repos[].ports[]` | なし | `env`: docker-compose 等がポート上書きに使う環境変数名、`base`: 割当の基準ポート |
| `repos[].postSetup[]` | なし | worktree 作成直後に worktree 直下で実行するコマンド |
| `repos[].docker.up` / `down` | なし | 起動・停止コマンド(実行はユーザー承認後) |
| `repos[].docker.healthcheck` | なし | 起動後の疎通確認コマンド |

## 状態ファイル(自動生成)

設定ファイルとは別に、skill は `~/.coadmap/` 配下にユーザー単位の状態を持つ。これらはリポにコミットしない。

- `~/.coadmap/task-flow.json` — 本人アカウント(`identity`)と、MCP から自動判別できなかった場合のパイプラインロール(`workspaces[<id>].pipelineRoles`)
- `~/.coadmap/port-registry.json` — 並行 worktree のポート割当

環境変数 `COADMAP_STATE_FILE` / `COADMAP_PORT_REGISTRY` で置き場を変えられる(主にテスト用)。
