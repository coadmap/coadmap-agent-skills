#!/usr/bin/env bash
# タスク URL の判定を PR ガード hook とタスク ID 抽出で共有する。source して使う。
#   coadmap_task_host_pattern [start-dir]  -> 許可ホストの ERE 選択肢 "(coadmap\.com|...)"
#   coadmap_task_url_prefix_regex <hosts>  -> ID 直前の "/tasks/" までの ERE
# 判定は LC_ALL=C の grep -E で使う前提。

# 許可ホストは coadmap.com(サブドメイン含む)と、.coadmap/workflow.json の taskHosts だけ。
# 任意ホストの /tasks/ を認めると、それらしい URL を書くだけで検査を通せてしまう。
coadmap_task_host_pattern() {
  local start="${1:-.}" lib_dir hosts
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  hosts="$(
    {
      echo coadmap.com
      bash "$lib_dir/../read-config.sh" "$start" 2>/dev/null \
        | jq -r '(.taskHosts // [])[]? | strings' 2>/dev/null || true
    } | tr '[:upper:]' '[:lower:]' \
      | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
      | sort -u | sed 's/\./\\./g' | paste -sd '|' -
  )"
  printf '(%s)' "$hosts"
}

# URL の直前が URL 構成文字だと、別 URL のクエリに埋め込まれた文字列
# (例: https://evil.example/?u=https://coadmap.com/...)を本物のリンクと取り違える。
coadmap_task_url_prefix_regex() {
  printf '%s' "(^|[^A-Za-z0-9._~:/?#@&=%+-])https?://([A-Za-z0-9-]+\\.)*$1(:[0-9]+)?/([^[:space:]\"'()<>]*/)?tasks/"
}
