---
name: coadmap-reference-lookup
description: Coadmap MCP のタスク取得(get_coadmap_task_dependency)や採用済みナレッジ一覧(get_coadmap_team_knowledge)の応答に、手順の索引行(`coadmap/release-check` のようなキーと「いつ引くか」)が載っているときに使う。索引行の場面の作業に入る前に lookup_coadmap_reference で手順の本文を引き、従った結果と食い違いをタスクのコメントに残す。
---

# coadmap-reference-lookup

Coadmap のチームが採用した手順は、本文がタスクの応答に載らない。載るのは索引行だけで、本文は必要になったときにキーで引く。

## 索引行

タスク取得の応答(`procedureIndex`、および JSON の後の text ブロック)に、手順ごとに 1 行ずつ載る。

```
- `coadmap/release-check`: リリース前の E2E を組む前に読む(主要変更と既知回帰の絞り方・権限差・監視ログ)
```

- バッククォートの中がキー。同じ名前の手順が複数あるときは `coadmap/release-check#1a2b3c4d` のように id が付く
- コロンの後が「いつ引くか」。この場面の作業に入る前に本文を引く
- 採用済みナレッジ一覧では、手順の件の `skillKey` に同じキーが入る

## 引き方

索引行の場面に当たる作業を始める前に、キーで本文を引く。

```
lookup_coadmap_reference(
  key    = "coadmap/release-check",
  taskId = "<作業中のタスクの UUID>"    # タスクの作業中なら渡す
)
```

- 応答の `body` が手順の本文(SKILL.md 形式の Markdown)。`files` に補助ファイルがあれば、`path` を指定してその本文を引く
- `sources` は、この手順を採用したナレッジの出典(元のタスク・Note・引用・時刻)。手順の背景を知りたいときに読む
- `validity.status` が `archived`、または `validity.knowledge[]` の `state` が `retired` なら、その手順は組織がもう使っていない。従わず、下の「食い違いを残す」でその旨をコメントに書く
- 404 は、無い・読めない・公開されていないのどれか。取り直しても変わらないので、その手順なしで進め、引けなかったことをコメントに残す

## 従ったあと

- 手順に従って作業したら、PR の本文やタスクのコメントにキー(`coadmap/release-check`)を書く。どの手順に従ったかを後から辿れるようにするため
- 引いた本文は会話に残すだけでよい。ファイルに写したり、リポに置いたりしない

## 食い違いを残す

手順と実態が違っていた(手順どおりにできない・手順に無い確認が要った・手順が古い)ときは、タスクのコメントに残す。夜間の収穫がコメントから候補を拾い、人が手順を直す材料になる。

```
create_coadmap_task_comment(
  taskId  = "<raw UUID または global ID>",
  content = "<Markdown 本文>"
)
```

```markdown
## 手順との食い違い: `coadmap/release-check`

**手順**: <何をするように書かれていたか>

**実態**: <実際に何が起きたか・何をしたか>

**直すなら**: <手順のどこをどう変えるべきか。分からなければ空欄>
```

投稿は外向き操作なので、投稿前に本文をユーザーに見せて承認を取る。「特になし」のコメントは書かない。

## MCP ツールの呼び方

ツール名は `lookup_coadmap_reference` のように名前だけで書いている。実際の呼び出し名は接続方法によって prefix が異なる(例: `mcp__coadmap-mcp__lookup_coadmap_reference`)。セッションで利用可能なツール一覧から、索引行を返した Coadmap MCP のサーバーと同じ prefix を付けて呼ぶ。
