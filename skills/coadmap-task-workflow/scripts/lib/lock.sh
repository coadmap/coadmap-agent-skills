#!/usr/bin/env bash
# 状態ファイルの read-modify-write を直列化する mkdir ロック。source して使う。
#   acquire_lock "<file>.lock"   # 取得できなければ非ゼロ終了。EXIT で自動解放。
# macOS には flock が無いので mkdir のアトミック性に頼る。クリティカルセクションは一瞬なので、
# 1 分以上残っている lock は SIGKILL 等で取り残されたものとみなして回収する。
acquire_lock() {
  local lock="$1" _i
  find "$lock" -maxdepth 0 -type d -mmin +1 -exec rmdir {} + 2>/dev/null || true
  for _i in $(seq 1 2000); do
    if mkdir "$lock" 2>/dev/null; then
      # shellcheck disable=SC2064 # 取得時点のパスを固定したい
      trap "rmdir '$lock' 2>/dev/null || true" EXIT
      return 0
    fi
    sleep 0.01
  done
  echo "failed to acquire lock ($lock)" >&2
  return 1
}
