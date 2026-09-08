#!/usr/bin/env bash
# 標準入力から Coadmap タスク識別子を1つ抽出して echo する。
# 優先順位: (1) coadmap.com の task URL, (2) displayId (ns-NN)。無ければ空。
set -euo pipefail
input="$(cat)"

# (1) task URL。末尾に付きやすい区切り/閉じ括弧/句読点（ASCII・全角とも）は除去する。
# URL として有効な末尾文字集合(英数 = / _ ~ + % -)以外の trailing バイトを LC_ALL=C で
# 落とすことで、全角「。」等のマルチバイト句読点も安全に除去する（base64 の '=' は保持）。
url="$(printf '%s' "$input" | grep -oE 'https?://[^[:space:]]*coadmap\.com/[^[:space:]]*/tasks/[^[:space:]]+' | head -1 || true)"
if [[ -n "$url" ]]; then
  url="$(printf '%s' "$url" | LC_ALL=C sed -E 's#[^A-Za-z0-9=/_~+%-]+$##')"
  printf '%s' "$url"; exit 0
fi

# (2) displayId。Coadmap の displayId は
#   - 大文字 namespace（例 CMDEV-9618） … prefix が英大文字で始まり英大文字/数字のみ、または
#   - アンダースコアを含む namespace（例 development_coadmap-36）
# のいずれか。これにより release-2024 / covid-19 / python-3 / opus-4 / UUID 切片(a8c236e1-1)
# などの一般語・偽陽性を除外する。prefix の先頭 2 文字を英字に限定しているのは、
# 正規表現の文字クラス表記 [A-Z0-9] の断片 "Z0-9" を拾わないため。
id="$(printf '%s' "$input" \
  | grep -oE '[A-Za-z][A-Za-z0-9_]*-[0-9]+' \
  | grep -E '^([A-Z]{2}[A-Z0-9]*|[A-Za-z0-9]*_[A-Za-z0-9_]*)-[0-9]+$' \
  | head -1 || true)"
if [[ -n "$id" ]]; then printf '%s' "$id"; exit 0; fi

# (3) ブランチ名（`/` を含む入力）だけは慣例上 displayId が小文字になる（feature/cmdev-9618-…）ので、
# 大小無視で拾って大文字化する。chat 文にこの緩い判定を使うと一般語を拾うため、ブランチ名限定。
# アンダースコア namespace は元々小文字なので大文字化しない。
if [[ "$input" == */* ]]; then
  id="$(printf '%s' "$input" \
    | grep -oE '(^|/)[A-Za-z]{2}[A-Za-z0-9]*-[0-9]+' \
    | sed 's#^/##' | head -1 || true)"
  [[ -n "$id" ]] && id="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
fi
printf '%s' "$id"
