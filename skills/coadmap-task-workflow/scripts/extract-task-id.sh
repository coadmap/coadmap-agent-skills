#!/usr/bin/env bash
# 標準入力から Coadmap タスク識別子を1つ抽出して echo する。
# 優先順位: (1) task URL, (2) displayId (ns-NN)。無ければ空。
# task URL のホストは coadmap.com と .coadmap/workflow.json の taskHosts(cwd から探索)。
set -euo pipefail
# shellcheck source=lib/task-link.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/task-link.sh"
input="$(cat)"

# (1) task URL。末尾に付きやすい区切り/閉じ括弧/句読点（ASCII・全角とも）は除去する。
# URL として有効な末尾文字集合(英数 = / _ ~ + % -)以外の trailing バイトを LC_ALL=C で
# 落とすことで、全角「。」等のマルチバイト句読点も安全に除去する（base64 の '=' は保持）。
# 先頭の境界文字は正規表現の都合で一緒に取れるので落とす(境界に英字は来ない)。
url_re="$(coadmap_task_url_prefix_regex "$(coadmap_task_host_pattern .)")[^[:space:]]+"
url="$(printf '%s' "$input" | LC_ALL=C grep -oiE "$url_re" | head -1 || true)"
if [[ -n "$url" ]]; then
  url="$(printf '%s' "$url" | LC_ALL=C sed -E 's#^[^hH]##; s#[^A-Za-z0-9=/_~+%-]+$##')"
  printf '%s' "$url"; exit 0
fi

# 文字コード・ハッシュ・規格番号(UTF-8, SHA-256, ISO-8601, RFC-7231 等)は displayId と同じ形をしている。
# 文脈で見分けるのは日本語の依頼文では当てにならないので、開発の会話でハイフン付きで書かれやすい接頭辞を除外する。
# MD5 / ES2015 / Base64 のようにハイフン無しで書くのが普通のものは、namespace と衝突させないため入れない。
# 同名の namespace を使うチームは、[RFC-12] のような角括弧付きの表記か URL で指定すれば拾える。
standard_prefixes='^(UTF|UCS|ISO|IEC|JIS|EUC|CP|SHA|CRC|HMAC|AES|DES|RSA|RFC|CVE|CWE|ECMA|IEEE|PEP|JSR|TLS|SSL|HTTP|IPV|GPT|WPA|COVID|SARS|HDMI|USB|DDR|LTE|PCI)-'
drop_standards() { { grep -viE "$standard_prefixes" || true; } | head -1; }

# (2a) タスクタイトルの表記 [<displayId>] <title>。角括弧で囲まれていればタスク ID とみなせるので、
# 小文字だけの namespace(例 [pypoo2-1])や規格風の接頭辞もそのまま拾う。
id="$(printf '%s' "$input" \
  | grep -oE '\[[A-Za-z][A-Za-z0-9_]+-[0-9]+\]' \
  | tr -d '[]' | head -1 || true)"
if [[ -n "$id" ]]; then printf '%s' "$id"; exit 0; fi

# (2b) 文中の displayId は
#   - 大文字 namespace（例 CMDEV-9618） … prefix が英大文字で始まり英大文字/数字のみ、または
#   - アンダースコアを含む namespace（例 development_coadmap-36）
# のいずれか。小文字だけの namespace を文中から拾うと release-2024 / covid-19 / python-3 / opus-4 /
# UUID 切片(a8c236e1-1)と区別できないので、(2a) の角括弧表記か URL に任せる。prefix の先頭 2 文字を
# 英字に限定しているのは、正規表現の文字クラス表記 [A-Z0-9] の断片 "Z0-9" を拾わないため。
id="$(printf '%s' "$input" \
  | grep -oE '[A-Za-z][A-Za-z0-9_]*-[0-9]+' \
  | grep -E '^([A-Z]{2}[A-Z0-9]*|[A-Za-z0-9]*_[A-Za-z0-9_]*)-[0-9]+$' \
  | drop_standards || true)"
if [[ -n "$id" ]]; then printf '%s' "$id"; exit 0; fi

# (3) ブランチ名（`/` を含む入力）だけは慣例上 displayId が小文字になる（feature/cmdev-9618-…）ので、
# 大小無視で拾って大文字化する。chat 文にこの緩い判定を使うと一般語を拾うため、ブランチ名限定。
# アンダースコア namespace は元々小文字なので大文字化しない。
if [[ "$input" == */* ]]; then
  id="$(printf '%s' "$input" \
    | grep -oE '(^|/)[A-Za-z]{2}[A-Za-z0-9]*-[0-9]+' \
    | sed 's#^/##' | drop_standards || true)"
  [[ -n "$id" ]] && id="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
fi
printf '%s' "$id"
