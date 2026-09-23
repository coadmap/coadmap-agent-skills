#!/usr/bin/env bash
# Coadmap の接続先キーを正規化する。source して使う。
#   normalize_host "https://Coadmap.com/ns/tasks/x" -> coadmap.com
# URL をそのまま渡されても同じキーになるよう scheme / userinfo / path / 末尾ドットを落とす。
# ポートは別環境を表し得るので残す。
normalize_host() {
  local h="$1" port=""
  h="${h#*://}"
  h="${h%%/*}"
  h="${h##*@}"
  if [[ "$h" == *:* ]]; then port=":${h##*:}"; h="${h%:*}"; fi
  h="${h%.}"
  printf '%s%s' "$h" "$port" | tr '[:upper:]' '[:lower:]'
}
