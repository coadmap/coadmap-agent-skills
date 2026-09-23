# 02. worktree 構築 + Docker / PORT 衝突回避

ユーザーに別の指定が無い限り、**作業に使う全リポジトリで worktree を作成**して対応する。並行セッションを想定し、ローカル結合 / Docker を使う場合は **PORT 衝突を回避**する。

このフェーズは「1 台のマシンで複数セッションを並行する」ローカル CLI 向けの手順。セッションごとに隔離されたサンドボックス(クラウド実行など)で動いている場合は、worktree もポート割当も不要なのでフェーズ全体をスキップし、その旨をユーザーに伝える。

このフェーズで使う値は `.coadmap/workflow.json`(00 で読み込み済み)を正とする。キーの意味は [configuration.md](configuration.md) を参照。以下のコード例では、設定を `CFG` に読み込んである前提で書く:

```bash
CFG="$(bash "<skill dir>/scripts/read-config.sh")"
prefix="$(jq -r '.branchPrefix // "feature/"' <<<"$CFG")"
wtdir="$(jq -r '.worktreeDir // ".worktrees"' <<<"$CFG")"
```

## 1. 対象リポジトリの特定

- 設定の `repos[]` があれば、タスクが触る範囲に該当するリポをその中から選ぶ。`path` の先頭 `~` はシェルが展開しないので、`${path/#\~/$HOME}` で自分で展開する。
- 設定が無ければ、現在の cwd のリポを対象とし、複数リポにまたがりそうなら他リポのローカルパスをユーザーに確認する(確認結果は設定に残す)。

## 2. base 最新化 + worktree 作成(全リポ同一ブランチ名)

複数リポ横断でも追跡しやすいよう、**全リポで同じブランチ名**を切る。ブランチ名は `<branchPrefix><TASK_ID>-<slug>`(`branchPrefix` の既定は `feature/`)。

```bash
name="${prefix}<TASK_ID>-<slug>"
for repo in "<repoA>" "<repoB>"; do
  repo="${repo/#\~/$HOME}"
  base="<repos[].defaultBranch があればその値>"
  [[ -n "$base" ]] || base="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [[ -n "$base" ]] || { echo "既定ブランチを特定できません: $repo"; exit 1; }   # ユーザーに確認して設定に残す
  git -C "$repo" fetch origin
  git -C "$repo" worktree add --no-track "$repo/$wtdir/<TASK_ID>" -b "$name" "origin/$base"
done
```

- `--no-track` を付けるのは、新ブランチの upstream が `origin/<base>` になると、引数なしの `git push` / `git pull` が base に向いてしまうため。
- 既定ブランチは設定の `repos[].defaultBranch` を優先し、無ければ `origin/HEAD` から求める。どちらも取れなければ推測せず、ユーザーに確認して設定に残す。
- worktree ディレクトリが gitignore されていないリポでは、`.git/info/exclude` に追記するか、ユーザーに置き場を確認する。

## 3. PORT 衝突回避(Docker / ローカル結合を使う場合のみ)

worktree ごとに決定的なホストポートを確保し、各リポの docker-compose のポート上書き env に渡す:

```bash
PORT="$(bash "<skill dir>/scripts/alloc-ports.sh" "$name" <base>)"
export <PORT_ENV>="$PORT"                            # このセッションの docker / healthcheck 用
echo "<PORT_ENV>=$PORT" >> "<worktree>/.env"         # 別セッションから起動する時のために残す
```

- `alloc-ports.sh <branch> <base>` は同一ブランチには常に同じポートを返し(決定性)、他ブランチが確保済みのポートは線形プロービングで避ける。確保は `~/.coadmap/port-registry.json` に記録される。
- `<base>` と `<PORT_ENV>` は設定の `repos[].ports[]` から取る。無ければ、そのリポの docker-compose がポートをどの env で上書きできるかをユーザーに確認し、設定に残す。
- 複数サービスを同時に立てる場合は base を変えて複数回呼ぶ(例 backend=3000, frontend=5173)。
- `.env` に書くだけでは `docker.healthcheck` 内の `$<PORT_ENV>` が展開されないので、**必ず export もする**。
- registry は他ブランチとの衝突しか見ていない。起動時に bind エラーが出たらホスト上の別プロセスが使っているので、`release-port.sh` で解放して割り当て直すか `base` を変える。

## 4. リポ別 post-setup(必要時のみ)

設定の `repos[].postSetup[]` に列挙されたコマンドを worktree 直下で順に実行する(例: gitignore された証明書ディレクトリの symlink、依存インストール)。設定に無いが必要そうな手順(`CLAUDE.md` / `AGENTS.md` に書かれている等)があれば、ユーザーに確認したうえで実行し、設定への追記を提案する。

## 5. Docker 起動

設定の `repos[].docker.up`(例 `make up`)などの起動・停止系コマンドは**ユーザー承認後**に実行する。起動後は `repos[].docker.healthcheck`(例 `curl -fsS http://localhost:$APP_PORT/health`)で疎通を確認する。
