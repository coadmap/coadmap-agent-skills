#!/usr/bin/env bash
# 状態ファイルの read-modify-write を直列化する mkdir ロック。source して使う。
#   acquire_lock "<file>.lock"   # 取得できなければ非ゼロ終了。EXIT で自動解放。
# macOS には flock が無いので mkdir で lock ディレクトリを作る。ただし uutils coreutils
# (Ubuntu 26.04 以降の既定) の mkdir は同じディレクトリを同時に作ると複数のプロセスに成功を
# 返すので、所有の確定は noclobber (O_EXCL) での owner ファイル作成で行う。
# クリティカルセクションは一瞬なので、1 分以上残っている lock は SIGKILL 等で取り残された
# ものとみなして回収する。
acquire_lock() {
  local lock="$1" _i
  find "$lock" -maxdepth 0 -type d -mmin +1 -exec rm -rf {} + 2>/dev/null || true
  for _i in $(seq 1 2000); do
    if mkdir "$lock" 2>/dev/null && (set -C; printf '%s' "$$" >"$lock/owner") 2>/dev/null; then
      # shellcheck disable=SC2064 # 取得時点のパスを固定したい
      trap "rm -rf '$lock' 2>/dev/null || true" EXIT
      return 0
    fi
    sleep 0.01
  done
  echo "failed to acquire lock ($lock)" >&2
  return 1
}
