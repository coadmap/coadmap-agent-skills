#!/usr/bin/env bash
# Coadmap の接続先キーを正規化する。source して使う。
#   normalize_host "https://Coadmap.com/ns/tasks/x" -> coadmap.com
# URL をそのまま渡されても同じキーになるよう scheme / path を落とす。ポートは別環境を表し得るので残す。
normalize_host() {
  local h="$1"
  h="${h#*://}"
  h="${h%%/*}"
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}
