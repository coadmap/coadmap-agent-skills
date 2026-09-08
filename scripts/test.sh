#!/usr/bin/env bash
# リポ内の全 _tests/*.sh を実行し、1つでも失敗すれば非ゼロ終了する。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
while IFS= read -r t; do
  echo "### $t"
  bash "$t" || { echo "FAILED: $t"; fail=1; }
done < <(find "$ROOT/skills" "$ROOT/hooks" -path '*/_tests/*.sh' -type f | sort)
exit $fail
