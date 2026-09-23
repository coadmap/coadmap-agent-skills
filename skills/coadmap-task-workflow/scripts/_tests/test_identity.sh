#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../resolve-identity.sh"; SAVE="$HERE/../save-identity.sh"; ROLES="$HERE/../save-pipeline-roles.sh"
TMP="$(mktemp -d)"; export COADMAP_STATE_FILE="$TMP/task-flow.json"
fail=0
# 未保存なら sentinel(空) + exit 3
out="$(bash "$RESOLVE" coadmap.com || echo "rc=$?")"
[[ "$out" == "rc=3" ]] && echo "ok: 未保存はrc=3" || { echo "NG: 未保存 got='$out'"; fail=1; }
# ホスト指定が無ければ usage エラー(黙って既定ホストで引かない)
out="$(bash "$RESOLVE" 2>/dev/null || echo "rc=$?")"
[[ "$out" == "rc=2" ]] && echo "ok: ホスト未指定はrc=2" || { echo "NG: ホスト未指定 got='$out'"; fail=1; }
# 保存後は accountId を返す。URL で渡しても同じホストキーになる
bash "$SAVE" "https://Coadmap.com/ns/tasks/abc" "acc_123" "you@example.com" "You"
got="$(bash "$RESOLVE" coadmap.com)"
[[ "$got" == "acc_123" ]] && echo "ok: 保存後はaccountId" || { echo "NG: got='$got'"; fail=1; }
jq -e '.identities["coadmap.com"].email == "you@example.com"' "$COADMAP_STATE_FILE" >/dev/null && echo "ok: email保存" || { echo "NG: email"; fail=1; }
# 別ホストの本人は混ざらない
out="$(bash "$RESOLVE" dev.example.com || echo "rc=$?")"
[[ "$out" == "rc=3" ]] && echo "ok: 別ホストは未登録扱い" || { echo "NG: 別ホストに漏れた got='$out'"; fail=1; }
bash "$SAVE" "dev.example.com:8443" "acc_dev" "you@example.com" "You"
[[ "$(bash "$RESOLVE" "http://dev.example.com:8443/x")" == "acc_dev" && "$(bash "$RESOLVE" coadmap.com)" == "acc_123" ]] \
  && echo "ok: ホストごとに保持" || { echo "NG: ホスト別保持"; fail=1; }
# 既存キーは保持する
tmp="$(mktemp)"; jq '.other = 1' "$COADMAP_STATE_FILE" > "$tmp"; mv "$tmp" "$COADMAP_STATE_FILE"
bash "$SAVE" coadmap.com "acc_456" "me@example.com" "Me"
jq -e '.other == 1 and .identities["coadmap.com"].accountId == "acc_456" and .identities["dev.example.com:8443"].accountId == "acc_dev"' "$COADMAP_STATE_FILE" >/dev/null && echo "ok: 既存キー保持" || { echo "NG: 既存キー消失"; fail=1; }
# 旧形式(単一の .identity)は coadmap.com のものとして読み、他ホストには使わない
echo '{"identity":{"accountId":"acc_legacy","email":"old@example.com","displayName":"Old"}}' > "$COADMAP_STATE_FILE"
[[ "$(bash "$RESOLVE" coadmap.com)" == "acc_legacy" ]] && echo "ok: 旧形式を coadmap.com として読む" || { echo "NG: 旧形式"; fail=1; }
out="$(bash "$RESOLVE" dev.example.com || echo "rc=$?")"
[[ "$out" == "rc=3" ]] && echo "ok: 旧形式は他ホストに使わない" || { echo "NG: 旧形式が他ホストに漏れた got='$out'"; fail=1; }
bash "$SAVE" coadmap.com "acc_new" "new@example.com" "New"
[[ "$(bash "$RESOLVE" coadmap.com)" == "acc_new" ]] && echo "ok: ホスト別の保存が旧形式より優先" || { echo "NG: 旧形式が優先された"; fail=1; }
# 回帰: 並行書き込みでロストアップデートが起きない(ロック無しだと大半が消える)
rm -f "$COADMAP_STATE_FILE"
pids=()
for i in $(seq 1 15); do bash "$SAVE" "host$i.example.com" "acc_$i" "u$i@example.com" "U$i" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done
cnt="$(jq '.identities | length' "$COADMAP_STATE_FILE")"
[[ "$cnt" == "15" ]] && echo "ok: 並行 15 ホストすべて保持" || { echo "NG: 並行保存でロストアップデート cnt=$cnt"; fail=1; }
rm -rf "$TMP"

# save-pipeline-roles: プロジェクト設定 .coadmap/workflow.json に書き、既存キーを保持し、並行でも消えない
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/repo/.coadmap"
echo '{"branchPrefix":"feature/"}' > "$TMP2/repo/.coadmap/workflow.json"
unset COADMAP_WORKFLOW_CONFIG
cfg="$(bash "$ROLES" ws1 p-doing p-review p-done "$TMP2/repo")"
[[ "$cfg" == "$TMP2/repo/.coadmap/workflow.json" ]] && echo "ok: 既存設定ファイルに書く" || { echo "NG: 書き先 $cfg"; fail=1; }
jq -e '.branchPrefix == "feature/" and .pipelineRoles.ws1.IN_REVIEW == "p-review"' "$cfg" >/dev/null && echo "ok: pipelineRoles 保存 + 既存キー保持" || { echo "NG: pipelineRoles"; fail=1; }
pids=()
for i in $(seq 1 15); do bash "$ROLES" "ws$i" "d$i" "r$i" "n$i" "$TMP2/repo" >/dev/null & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done
cnt="$(jq '.pipelineRoles | length' "$cfg")"
[[ "$cnt" == "15" ]] && echo "ok: 並行 15 件すべて保持" || { echo "NG: 並行ロストアップデート cnt=$cnt"; fail=1; }
# 設定ファイルが無ければ start-dir 直下に作る
mkdir -p "$TMP2/fresh"
cfg2="$(bash "$ROLES" ws1 a b c "$TMP2/fresh")"
[[ -f "$TMP2/fresh/.coadmap/workflow.json" ]] && echo "ok: 未作成なら新規作成" || { echo "NG: 新規作成されず cfg2=$cfg2"; fail=1; }
rm -rf "$TMP2"
exit $fail
