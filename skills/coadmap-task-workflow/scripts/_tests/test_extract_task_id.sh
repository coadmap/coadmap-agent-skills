#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../extract-task-id.sh"
fail=0
check() { # desc input expected
  local got; got="$(printf '%s' "$2" | bash "$SUT" || true)"
  if [[ "$got" == "$3" ]]; then echo "ok: $1"; else echo "NG: $1 (got='$got' want='$3')"; fail=1; fi
}
check "displayId大文字"        "[CMDEV-9618] ログイン画面の…"                 "CMDEV-9618"
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
# 規格・文字コード・ハッシュ名は displayId と同じ形でも拾わない
check "UTF-8偽陽性なし"        "UTF-8 で保存する"                                   ""
check "SHA-256偽陽性なし"      "SHA-256 のハッシュ"                                 ""
check "ISO-8601偽陽性なし"     "ISO-8601 形式の日付"                                ""
check "RFC-7231偽陽性なし"     "RFC-7231 を参照"                                    ""
check "規格名の後ろのIDは拾う" "UTF-8 の件で CMDEV-12 を直す"                       "CMDEV-12"
check "ブランチ内の規格名なし" "docs/utf-8"                                         ""
# タスクタイトル表記の角括弧付きなら小文字 namespace もそのまま拾う
check "角括弧の小文字namespace" "[pypoo2-1] タイトル"                               "pypoo2-1"
check "角括弧の小文字displayId" "[cmdev-9618] ログイン画面"                         "cmdev-9618"
check "文中の小文字は拾わない" "cmdev-9618 の件"                                    ""
# /tasks/ 直下の URL も拾い、ホスト境界と埋め込み URL は区別する
check "tasks直下URL"           "https://coadmap.com/tasks/VGFzazoxMjM= を見て"      "https://coadmap.com/tasks/VGFzazoxMjM="
check "偽ドメインは拾わない"   "https://evilcoadmap.com/x/tasks/1"                  ""
check "埋め込みURLは拾わない"  "https://evil.example/?u=https://coadmap.com/ws/tasks/VGFzazoxMjM=" ""
# taskHosts で許可したホストの URL も拾う(設定は cwd から探す)
TMP="$(mktemp -d)"
mkdir -p "$TMP/.coadmap"
echo '{"taskHosts":["coadmap.example.co.jp"]}' > "$TMP/.coadmap/workflow.json"
got="$(cd "$TMP" && printf '%s' "https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM= 対応" | bash "$SUT" || true)"
[[ "$got" == "https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM=" ]] && echo "ok: taskHosts のURL" \
  || { echo "NG: taskHosts のURL (got='$got')"; fail=1; }
got="$(cd "$(dirname "$TMP")" && printf '%s' "https://coadmap.example.co.jp/ws/tasks/VGFzazoxMjM=" | bash "$SUT" || true)"
[[ -z "$got" ]] && echo "ok: 未設定ホストのURLは拾わない" || { echo "NG: 未設定ホストのURL (got='$got')"; fail=1; }
rm -rf "$TMP"
exit $fail
