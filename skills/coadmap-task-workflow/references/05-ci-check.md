# 05. CI ステータス確認

PR に CI が設定されている場合、ステータスチェックを行う。

## 確認

```bash
gh pr checks <pr>          # チェック一覧とステータス
gh pr checks <pr> --watch  # 完了まで待機する場合
```

- 失敗チェックがあれば `gh run view <run-id> --log-failed` 等で原因を確認し、**修正 → 修正内容を示して承認を得てから再 push → 再確認**を繰り返す。
- ローカルでの再現コマンド(lint/type/test)は設定の `qualityGate[]`、無ければ `CLAUDE.md` / `AGENTS.md` を参照する。
- draft の間テスト系ジョブを skip するリポでは、skip されたジョブが成功扱いで表示される。ready にした直後も、新しい run が作られるまでは draft のときの `skipping` だけが残って緑に見えることがある。判定は ready にした後の run で行い、各チェックが `skipping` ではなく `pass` になっていることを確かめる。
- required checks が設定されているリポでは、`gh pr checks <pr> --required` で必須チェックだけに絞って確認できる。

## 完了条件

- **全チェックが green になること**(draft で skip されたままの `skipping` は green に数えない)を「マージ準備完了」(→ 06)の前提条件とする。green になったら 06 の 1(ユーザーへの通知)に進み、そこで止まる。
- CI が設定されていないリポの PR はこのステップをスキップしてよい(その旨をユーザーに伝える)。
