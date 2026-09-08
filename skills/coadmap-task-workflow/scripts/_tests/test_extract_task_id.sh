#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../extract-task-id.sh"
fail=0
check() { # desc input expected
  local got; got="$(printf '%s' "$2" | bash "$SUT" || true)"
  if [[ "$got" == "$3" ]]; then echo "ok: $1"; else echo "NG: $1 (got='$got' want='$3')"; fail=1; fi
}
check "displayId大文字"        "[CMDEV-9618] Yataチャットで…"                 "CMDEV-9618"
check "displayId小文字namespace" "development_coadmap-36 を直す"               "development_coadmap-36"
check "task URL"               "https://coadmap.com/ws/tasks/VGFzazoxMjM= 対応" "https://coadmap.com/ws/tasks/VGFzazoxMjM="
check "URL優先(両方含む)"        "CMDEV-1 https://coadmap.com/a/tasks/X="        "https://coadmap.com/a/tasks/X="
check "該当なしは空"            "ただのメッセージ"                              ""
check "hex切片は拾わない"        "a8c236e1-1 のログ"                            ""
# 回帰: URL を括弧/句読点で囲んでも末尾混入しない（base64 の = は保持）
check "URL括弧除去"            "(https://coadmap.com/ws/tasks/VGFzazoxMjM=) を見て" "https://coadmap.com/ws/tasks/VGFzazoxMjM="
check "URL末尾句読点除去"      "詳細は https://coadmap.com/a/tasks/abc123。"        "https://coadmap.com/a/tasks/abc123"
# 回帰: 一般語/バージョン表記の偽陽性を拾わない
check "release偽陽性なし"      "release-2024 をデプロイ"                            ""
check "covid偽陽性なし"        "covid-19 の話"                                      ""
check "python偽陽性なし"       "python-3 で書く"                                    ""
# 正規表現の文字クラス断片を拾わない
check "文字クラス断片なし"     "正規表現 [A-Z0-9]+ にマッチ"                        ""
# ブランチ名(慣例上小文字)からは大小無視で拾って大文字化する
check "ブランチ小文字"         "feature/cmdev-9618-fix-login"                       "CMDEV-9618"
check "ブランチ大文字"         "feature/CMDEV-9618-fix-login"                       "CMDEV-9618"
check "ブランチ underscore"    "feature/development_coadmap-36-x"                   "development_coadmap-36"
check "ブランチ偽陽性なし"     "release/v2-1"                                       ""
exit $fail
