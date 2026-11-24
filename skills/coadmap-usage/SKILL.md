---
name: coadmap-usage
description: Coadmap のタスク・エピック・目標・機能・ノート・リリースなどを読む・作る・更新する・閉じる・列を動かすとき、また Coadmap の使い方や用語について答えるときに使う。Coadmap MCP のどの道具から引くかと、守る決まりを示す。
---

# Coadmap の使い方

> この Skill は Coadmap の使い方の説明書から自動で作られている。手で直さない。

## いつ使うか

Coadmap のタスク・エピック・目標・機能・ノート・リリースなどを、読む・作る・更新する・閉じる・列を動かすとき。Coadmap の使い方・用語・要素どうしの繋がりについて答えるとき。

## 最初にすること

1. Coadmap MCP の道具（`get_coadmap_workspaces` など、名前に `coadmap` を含む道具）が使えるかを確かめる。使えなければ、推測で作業を進めず、利用者に Coadmap MCP サーバーをつなぐよう頼む。つながったら続ける。
2. MCP の案内文（server instructions）の「Coadmap の使い方の索引」から、作業の対象や場面に当たる節の呼び名（例 `L1.task`・`L5.task_close`）を選び、`lookup_coadmap_reference` の `key` に渡して本文を読む。本文に従う。
3. 操作する対象の ID は読む道具の応答から取る。プロジェクトは `get_coadmap_workspaces`、列・メンバー・エピック・スプリントは `get_coadmap_workspace_context`。
4. 計画・優先順位・進め方の判断が要るときは、Coadmap の AI の PM（Yata）に相談する道具 `consult_coadmap_pm` がある。AI クレジットを使う。

## 一番大事な決まり

- タスク・エピックを作る・直すときは、`get_coadmap_feature_hierarchy_board` か `get_coadmap_objective_hierarchy_board` で実在する機能か目標を探して紐付ける。
- 利用者への返事では画面の呼び名（`L3.ui_naming` の表）を使い、型名や内部の名前を出さない。
- 答えや書き込みは道具で読んだ内容だけをもとにし、どのタスク・ノートなどから得たかを示す。
- 答える・操作する前に、読む道具で今の状態を読む。ID・項目・呼び名は道具の応答から取り、推測で埋めない。
- エピックを指すときは Epic-id（`get_coadmap_workspace_context` の `epics[].id`）を渡し、エピックに対応するタスクの ID を渡さない。
