# Contributing

## 開発

```bash
bash scripts/test.sh   # skills / hooks の _tests を全実行
bash scripts/lint.sh   # shellcheck + manifest JSON + hook 配線 + Markdown リンク検証
```

## skill とドキュメントの書き方

対応クライアントは今後も増える。クライアントごとの例外を skill 本体や README に積み上げると、クライアントを 1 つ足すたびに全手順を読み直すことになるので、「クライアント非依存の手順」と「クライアント固有の事情」を分けて書く。

- **skill 本体(`skills/coadmap-task-workflow/` の SKILL.md と references)は能力の条件で分岐を書く。** 例: 「サブエージェントを使えるなら〜、使えなければ〜」「サンドボックス内で認証エラーが出たら〜」「クライアントが worktree を用意済みなら〜」。クライアント名は括弧内の例としてだけ出し、「Codex では〜」のような製品名での分岐は書かない。
- **クライアント固有の事情は `docs/clients/` に置く。** インストール手順、MCP 登録方法、hooks の有効化・信頼、サンドボックスのエラー文言、設定ファイルのパスなど。README はクライアント共通の説明に留め、そこからリンクする。
- skill 配下は単体コピーでも動くよう自己完結させる(`scripts/lint.sh` が skill 外へのリンクを検出する)。skill から `docs/clients/` へはリンクしない。
- 説明には「なぜそうするか」のうち自明でないものだけを書く。タスク ID や変更経緯は本文に書かず、コミットメッセージと CHANGELOG に書く。

## クライアントを追加する

[docs/clients/README.md](docs/clients/README.md#新しいクライアントを追加するとき) の手順に従う。要点は、`docs/clients/<name>.md` を追加して能力マトリクスに列を 1 つ足すこと。skill 本体は新しい能力の条件が必要な場合にだけ変更し、その場合も製品名ではなく条件として書く。
