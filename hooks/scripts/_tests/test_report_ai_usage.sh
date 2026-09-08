#!/usr/bin/env bash
# report-ai-usage (_report-ai-usage-impl.sh) の統合テスト。
# curl をフェイクバイナリに差し替え、実ネットワークに出ずに以下を検証する:
#   1. transcript の message.id dedupe が効いていること
#      （dedupe しないと過大計上になる固定 fixture で正しい値になることを検証）
#   2. 送信先設定（COADMAP_API_TOKEN / COADMAP_API_URL）が無い環境では
#      黙って exit 0 で終わり、POST しないこと
#   3. 二重投稿ガード（.done マーカー）が2回目の実行をスキップすること
#   4. taskId 起因の 404 では taskId を落として再送し、使用量まで捨てないこと
#   5. 未対応の transcript 形式（Codex rollout log 等）では 0 のレポートを送らないこと
#   6. 形式は読めても outputTokens=0 なら空レポートを送らないこと
#   7. opt-in ゲート: COADMAP_AI_USAGE_REPORT=1 を明示しない限り送信しないこと
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$HERE/../_report-ai-usage-impl.sh"
FIXTURE="$HERE/fixtures/sample-transcript.jsonl"
CODEX_FIXTURE="$HERE/fixtures/codex-rollout-transcript.jsonl"
ZERO_OUTPUT_FIXTURE="$HERE/fixtures/zero-output-transcript.jsonl"

fail=0
assert_eq() {
  local got="$1" want="$2" case="$3"
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s — got=%q want=%q\n' "$case" "$got" "$want"
    fail=1
  else
    printf 'PASS: %s\n' "$case"
  fi
}
assert_true() {
  local cond="$1" case="$2"
  if [[ "$cond" == "1" ]]; then
    printf 'PASS: %s\n' "$case"
  else
    printf 'FAIL: %s\n' "$case"
    fail=1
  fi
}

# --- テスト用フェイク curl ----------------------------------------------------
# --data の中身を $CURL_CAPTURE_FILE に書き出し、-o のファイルには空JSONを、
# stdout には $CURL_STATUS_CODE (既定 201) を返す。実ネットワークには出ない。
FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
# 実物は --config - で stdin からヘッダを渡す。読み切らないと呼び出し側が SIGPIPE で落ちる
cat > /dev/null
out_file=""
data=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -o) out_file="$arg" ;;
    --data) data="$arg" ;;
  esac
  prev="$arg"
done
[[ -n "$out_file" ]] && printf '{}' > "$out_file"
if [[ -n "$data" && -n "${CURL_CAPTURE_FILE:-}" ]]; then
  printf '%s' "$data" > "$CURL_CAPTURE_FILE"
fi
printf '%s' "${CURL_STATUS_CODE:-201}"
CURL_STUB
chmod +x "$FAKE_BIN/curl"

TMP_HOME="$(mktemp -d)"
CAPTURE="$TMP_HOME/captured_payload.json"
cleanup() { rm -rf "$FAKE_BIN" "$TMP_HOME"; }
trap cleanup EXIT

mkdir -p "$TMP_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer test-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}' > "$TMP_HOME/.claude.json"

payload() {
  jq -nc --arg s "$1" --arg t "$2" --arg c "$3" \
    '{session_id:$s, hook_event_name:"SessionEnd", transcript_path:$t, cwd:$c}'
}

run_impl() {
  local session="$1" cwd="$2"
  env -i \
    HOME="$TMP_HOME" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
    CURL_CAPTURE_FILE="$CAPTURE" \
    CURL_STATUS_CODE="201" \
    COADMAP_AI_USAGE_REPORT="1" \
    bash "$IMPL" "$(payload "$session" "$FIXTURE" "$cwd")"
}

# =============================================================================
# 1. message.id dedupe が効いていること
# =============================================================================
rm -f "$CAPTURE"
run_impl "sess-dedupe-1" "$TMP_HOME" >/dev/null 2>&1

assert_true "$([[ -f "$CAPTURE" ]] && echo 1 || echo 0)" 'dedupe: POST が実行され payload が捕捉された'

if [[ -f "$CAPTURE" ]]; then
  BODY="$(cat "$CAPTURE")"
  IN="$(printf '%s' "$BODY" | jq -r '.inputTokens')"
  OUT="$(printf '%s' "$BODY" | jq -r '.outputTokens')"
  CC="$(printf '%s' "$BODY" | jq -r '.cacheCreationTokens')"
  CR="$(printf '%s' "$BODY" | jq -r '.cacheReadTokens')"
  MODEL="$(printf '%s' "$BODY" | jq -r '.modelName')"
  AGENT="$(printf '%s' "$BODY" | jq -r '.agent')"

  # fixture: msg_1(out=100,dup x3) + msg_2(out=50,dup x2) + msg_3(out=20, sidechain)
  # dedupe 後の正しい合計は 100+50+20=170。dedupe しない場合の素朴な合計は
  # 100*3+50*2+20=420 になり、これと異なることも併せて確認する。
  assert_eq "$OUT" "170" 'dedupe: outputTokens は dedupe 後の合計(170)'
  assert_eq "$IN" "17"   'dedupe: inputTokens は dedupe 後の合計(17)'
  assert_eq "$CC" "1"    'dedupe: cacheCreationTokens'
  assert_eq "$CR" "2"    'dedupe: cacheReadTokens'
  assert_true "$([[ "$OUT" != "420" ]] && echo 1 || echo 0)" 'dedupe: 素朴な合算(420)とは異なる値になっている'
  assert_eq "$MODEL" "claude-sonnet-4-5" 'dedupe: 代表モデルは output_tokens 合計最大のモデル'
  assert_eq "$AGENT" "claude_code" 'dedupe: SessionEnd は agent=claude_code'
fi

# =============================================================================
# 2. 送信先設定が無い環境では黙って exit 0 で終わり、POST しない
# =============================================================================
NOCONF_HOME="$(mktemp -d)"
rm -f "$CAPTURE"
rc=0
env -i \
  HOME="$NOCONF_HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$CAPTURE" \
  CURL_STATUS_CODE="201" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-noconf" "$FIXTURE" "$TMP_HOME")" >"$NOCONF_HOME/noconf.out" 2>"$NOCONF_HOME/noconf.err" || rc=$?
assert_eq "$rc" "0" 'no-config: 終了コード0'
assert_true "$([[ ! -s "$NOCONF_HOME/noconf.out" ]] && echo 1 || echo 0)" 'no-config: stdoutは空'
assert_true "$([[ ! -s /tmp/noconf.err ]] && echo 1 || echo 0)" 'no-config: stderrも空（エラーで汚さない）'
assert_true "$([[ ! -f "$CAPTURE" ]] && echo 1 || echo 0)" 'no-config: POSTは発生しない'
rm -rf "$NOCONF_HOME"

# =============================================================================
# 3. 二重投稿ガード: 同一 session_id の2回目はスキップされる
# =============================================================================
GUARD_HOME="$(mktemp -d)"
mkdir -p "$GUARD_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer guard-token-bbbbbbbbbbbbbbbbbbbbbbbb"}}}}' > "$GUARD_HOME/.claude.json"

CAPTURE2="$GUARD_HOME/captured.json"
run_guard() {
  rm -f "$CAPTURE2"
  env -i \
    HOME="$GUARD_HOME" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
    CURL_CAPTURE_FILE="$CAPTURE2" \
    CURL_STATUS_CODE="201" \
    COADMAP_AI_USAGE_REPORT="1" \
    bash "$IMPL" "$(payload "sess-guard-1" "$FIXTURE" "$TMP_HOME")"
}

run_guard
assert_true "$([[ -f "$CAPTURE2" ]] && echo 1 || echo 0)" 'guard: 1回目はPOSTされる'
assert_true "$([[ -f "$GUARD_HOME/.coadmap/ai-usage-reports/sess-guard-1.done" ]] && echo 1 || echo 0)" 'guard: 1回目の成功で .done が作られる'

run_guard
assert_true "$([[ ! -f "$CAPTURE2" ]] && echo 1 || echo 0)" 'guard: 2回目はPOSTされない(スキップ)'

rm -rf "$GUARD_HOME"

# =============================================================================
# 4. taskId 起因の 404 では、taskId を落として再送し使用量まで捨てない
# =============================================================================
# BE は解決できない taskId を 404 で明示的に弾く。taskId はブランチ名からの
# best-effort 推定なので、紐付けに失敗しただけで使用量の記録ごと落ちてはいけない。
RETRY_HOME="$(mktemp -d)"
mkdir -p "$RETRY_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer retry-token-cccccccccccccccccccccccc"}}}}' > "$RETRY_HOME/.claude.json"

# taskId を載せさせるため、branch 名に displayId を含む git repo を cwd として用意する。
RETRY_REPO="$RETRY_HOME/repo"
mkdir -p "$RETRY_REPO"
git -C "$RETRY_REPO" init -q 2>/dev/null
git -C "$RETRY_REPO" checkout -q -b feature/cmdev-99999-probe 2>/dev/null

# 1 回目だけ 404 を返し、2 回目以降は 201 を返すフェイク curl。
# 各呼び出しの payload を連番ファイルに追記していく。
RETRY_BIN="$(mktemp -d)"
cat > "$RETRY_BIN/curl" <<'RETRY_STUB'
#!/usr/bin/env bash
cat > /dev/null
out_file=""; data=""; prev=""
for arg in "$@"; do
  case "$prev" in
    -o) out_file="$arg" ;;
    --data) data="$arg" ;;
  esac
  prev="$arg"
done
[[ -n "$out_file" ]] && printf '{}' > "$out_file"
n=1
[[ -f "$CURL_COUNT_FILE" ]] && n=$(( $(cat "$CURL_COUNT_FILE") + 1 ))
printf '%s' "$n" > "$CURL_COUNT_FILE"
printf '%s' "$data" > "${CURL_CAPTURE_FILE}.$n"
if [[ "$n" -le 2 ]]; then printf '404'; else printf '201'; fi
RETRY_STUB
chmod +x "$RETRY_BIN/curl"

RETRY_CAPTURE="$RETRY_HOME/captured.json"
env -i \
  HOME="$RETRY_HOME" \
  PATH="$RETRY_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$RETRY_CAPTURE" \
  CURL_COUNT_FILE="$RETRY_HOME/count" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-retry-1" "$FIXTURE" "$RETRY_REPO")" >/dev/null 2>&1

# BE の displayId 解決は大小文字を区別するので、verbatim → 大文字化 → taskId なし の順に試す。
assert_eq "$(cat "$RETRY_HOME/count" 2>/dev/null || echo 0)" "3" 'retry: verbatim→大文字→taskIdなし の 3 回 POST する'
assert_eq "$(jq -r '.taskId // "none"' "$RETRY_CAPTURE.1" 2>/dev/null)" "cmdev-99999" 'retry: 1回目は verbatim の taskId'
assert_eq "$(jq -r '.taskId // "none"' "$RETRY_CAPTURE.2" 2>/dev/null)" "CMDEV-99999" 'retry: 2回目は大文字化した taskId (BE は大小文字を区別する)'
assert_eq "$(jq -r '.taskId // "none"' "$RETRY_CAPTURE.3" 2>/dev/null)" "none" 'retry: 3回目は taskId を落として送る'
assert_eq "$(jq -r '.outputTokens' "$RETRY_CAPTURE.3" 2>/dev/null)" "170" 'retry: 最後も使用量はそのまま送られる'
assert_true "$([[ -f "$RETRY_HOME/.coadmap/ai-usage-reports/sess-retry-1.done" ]] && echo 1 || echo 0)" 'retry: 再送成功で .done が作られる'

rm -rf "$RETRY_HOME" "$RETRY_BIN"

# =============================================================================
# 5 & 6. 0 トークンのレポートを絶対に送らない
# =============================================================================
# 「使ったが 0 トークン」という嘘のレコードが ai_tokens_total に残るのを防ぐ。
# 未対応形式(Codex rollout log)と、形式は読めるが出力 0 のセッションの両方を塞ぐ。
ZERO_HOME="$(mktemp -d)"
mkdir -p "$ZERO_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer zero-token-dddddddddddddddddddddddd"}}}}' > "$ZERO_HOME/.claude.json"

ZERO_CAPTURE="$ZERO_HOME/captured.json"
ZERO_LOG="$ZERO_HOME/.coadmap/ai-usage-report.log"

# hook_event_name も差し替えられる payload (Codex は Stop で発火する)
payload_for() {
  jq -nc --arg s "$1" --arg t "$2" --arg c "$3" --arg e "$4" \
    '{session_id:$s, hook_event_name:$e, transcript_path:$t, cwd:$c}'
}
run_zero() {
  local session="$1" fixture="$2" event="$3"
  rm -f "$ZERO_CAPTURE"
  env -i \
    HOME="$ZERO_HOME" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
    CURL_CAPTURE_FILE="$ZERO_CAPTURE" \
    CURL_STATUS_CODE="201" \
    COADMAP_AI_USAGE_REPORT="1" \
    bash "$IMPL" "$(payload_for "$session" "$fixture" "$ZERO_HOME" "$event")"
}

# --- 5. 未対応形式 (Codex rollout log) ---
rc=0
run_zero "sess-codex-1" "$CODEX_FIXTURE" "Stop" >"$ZERO_HOME/codex.out" 2>"$ZERO_HOME/codex.err" || rc=$?
assert_eq "$rc" "0" 'unsupported: 終了コード0 (エージェントの終了を汚さない)'
assert_true "$([[ ! -s "$ZERO_HOME/codex.out" && ! -s "$ZERO_HOME/codex.err" ]] && echo 1 || echo 0)" 'unsupported: stdout/stderr は空'
assert_true "$([[ ! -f "$ZERO_CAPTURE" ]] && echo 1 || echo 0)" 'unsupported: 0 のレポートを POST しない'
assert_true "$([[ ! -f "$ZERO_HOME/.coadmap/ai-usage-reports/sess-codex-1.done" ]] && echo 1 || echo 0)" 'unsupported: .done を作らない (形式対応後に再送できる)'
assert_true "$(grep -q 'unsupported transcript format' "$ZERO_LOG" && echo 1 || echo 0)" 'unsupported: 形式未対応と分かるログを残す'

# --- 6. 形式は読めるが outputTokens=0 ---
rc=0
run_zero "sess-zero-1" "$ZERO_OUTPUT_FIXTURE" "SessionEnd" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" 'zero-output: 終了コード0'
assert_true "$([[ ! -f "$ZERO_CAPTURE" ]] && echo 1 || echo 0)" 'zero-output: outputTokens=0 のレポートを POST しない'
assert_true "$(grep -q 'refusing to send an empty usage report' "$ZERO_LOG" && echo 1 || echo 0)" 'zero-output: 空レポート拒否と分かるログを残す'

# --- 対照: 同じ経路・同じ設定で正常な transcript なら POST される (ガードが広すぎないこと) ---
run_zero "sess-zero-control" "$FIXTURE" "SessionEnd" >/dev/null 2>&1
assert_true "$([[ -f "$ZERO_CAPTURE" ]] && echo 1 || echo 0)" 'control: 正常な transcript なら同じ設定で POST される'
assert_eq "$(jq -r '.outputTokens' "$ZERO_CAPTURE" 2>/dev/null)" "170" 'control: 正常時の outputTokens は 170'

cleanup_zero() { rm -rf "$ZERO_HOME"; }
cleanup_zero

# =============================================================================
# 7. opt-in ゲート: 明示的に有効化しない限り送信しない
# =============================================================================
# MCP 接続をもって同意とみなさない。認証情報が揃っていて transcript も正常でも、
# COADMAP_AI_USAGE_REPORT=1 が無ければ何もしない。
# 「有効化した時だけ送られる」ことを両側で固定する。
OPTIN_HOME="$(mktemp -d)"
mkdir -p "$OPTIN_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer optin-token-eeeeeeeeeeeeeeeeeeeeeeee"}}}}' > "$OPTIN_HOME/.claude.json"

OPTIN_CAPTURE="$OPTIN_HOME/captured.json"
# $1: session, $2: COADMAP_AI_USAGE_REPORT に渡す値 ("__unset__" なら変数自体を渡さない)
run_optin() {
  local session="$1" flag="$2"
  rm -f "$OPTIN_CAPTURE"
  if [[ "$flag" == "__unset__" ]]; then
    env -i \
      HOME="$OPTIN_HOME" \
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
      CURL_CAPTURE_FILE="$OPTIN_CAPTURE" \
      CURL_STATUS_CODE="201" \
      bash "$IMPL" "$(payload "$session" "$FIXTURE" "$OPTIN_HOME")"
  else
    env -i \
      HOME="$OPTIN_HOME" \
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
      CURL_CAPTURE_FILE="$OPTIN_CAPTURE" \
      CURL_STATUS_CODE="201" \
      COADMAP_AI_USAGE_REPORT="$flag" \
      bash "$IMPL" "$(payload "$session" "$FIXTURE" "$OPTIN_HOME")"
  fi
}

# --- 未設定: 送らない ---
rc=0
run_optin "sess-optin-unset" "__unset__" >"$OPTIN_HOME/unset.out" 2>"$OPTIN_HOME/unset.err" || rc=$?
assert_eq "$rc" "0" 'opt-in: 未設定でも終了コード0'
assert_true "$([[ ! -f "$OPTIN_CAPTURE" ]] && echo 1 || echo 0)" 'opt-in: 未設定なら POST しない（認証情報が揃っていても）'
assert_true "$([[ ! -s "$OPTIN_HOME/unset.out" && ! -s "$OPTIN_HOME/unset.err" ]] && echo 1 || echo 0)" 'opt-in: 未設定なら stdout/stderr は空'
# ログファイルすら作らない = 有効化していない環境に痕跡を残さない
assert_true "$([[ ! -e "$OPTIN_HOME/.coadmap" ]] && echo 1 || echo 0)" 'opt-in: 未設定なら ~/.coadmap を作らない（痕跡を残さない）'

# --- 明示的に 0: 送らない ---
run_optin "sess-optin-zero" "0" >/dev/null 2>&1
assert_true "$([[ ! -f "$OPTIN_CAPTURE" ]] && echo 1 || echo 0)" 'opt-in: =0 なら POST しない'

# --- 1 以外の値: 送らない（fail-closed）---
run_optin "sess-optin-true" "true" >/dev/null 2>&1
assert_true "$([[ ! -f "$OPTIN_CAPTURE" ]] && echo 1 || echo 0)" 'opt-in: =1 以外の値では POST しない（fail-closed）'

# --- 1: 送る（対照。ゲート以外の条件はすべて上と同一）---
run_optin "sess-optin-one" "1" >/dev/null 2>&1
assert_true "$([[ -f "$OPTIN_CAPTURE" ]] && echo 1 || echo 0)" 'opt-in: =1 のときだけ POST される'
assert_eq "$(jq -r '.outputTokens' "$OPTIN_CAPTURE" 2>/dev/null)" "170" 'opt-in: 有効化時は正しい使用量が送られる'

cleanup_optin() { rm -rf "$OPTIN_HOME"; }
cleanup_optin

# =============================================================================
# 8. payload のキー集合がホワイトリストと完全一致する
# =============================================================================
# プライバシーが最重要要件なので、将来うっかり transcript 由来のフィールドが増えても
# 気付けるよう、送信キーの集合そのものを固定する。
WL_HOME="$(mktemp -d)"
mkdir -p "$WL_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer wl-token-ffffffffffffffffffffffff"}}}}' > "$WL_HOME/.claude.json"
WL_CAPTURE="$WL_HOME/captured.json"
env -i \
  HOME="$WL_HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$WL_CAPTURE" \
  CURL_STATUS_CODE="201" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-wl-1" "$FIXTURE" "$WL_HOME")" >/dev/null 2>&1

EXPECTED_KEYS='agent cacheCreationTokens cacheReadTokens inputTokens modelName outputTokens sessionKey'
ACTUAL_KEYS="$(jq -r 'keys_unsorted | sort | join(" ")' "$WL_CAPTURE" 2>/dev/null)"
assert_eq "$ACTUAL_KEYS" "$EXPECTED_KEYS" 'whitelist: payload のキー集合が想定と完全一致する'
rm -rf "$WL_HOME"

# =============================================================================
# 9. .done は「再送禁止」ではなく前回送信値の記録（BE の upsert が正）
# =============================================================================
# BE は加算せず上書きする upsert なので、同一 session_id のまま作業が続いた場合
# (/clear や --resume) に再送しないと部分累計が最終値として固定されてしまう。
RESEND_HOME="$(mktemp -d)"
mkdir -p "$RESEND_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer resend-token-gggggggggggggggggggg"}}}}' > "$RESEND_HOME/.claude.json"
RESEND_CAPTURE="$RESEND_HOME/captured.json"

# 出力トークンがより多い transcript（同じ message.id で値だけ増えた続き）
GROWN_FIXTURE="$RESEND_HOME/grown.jsonl"
cat "$FIXTURE" > "$GROWN_FIXTURE"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$GROWN_FIXTURE"

run_resend() {
  rm -f "$RESEND_CAPTURE"
  env -i \
    HOME="$RESEND_HOME" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
    CURL_CAPTURE_FILE="$RESEND_CAPTURE" \
    CURL_STATUS_CODE="201" \
    COADMAP_AI_USAGE_REPORT="1" \
    bash "$IMPL" "$(payload "sess-resend-1" "$1" "$RESEND_HOME")"
}

run_resend "$FIXTURE" >/dev/null 2>&1
assert_true "$([[ -f "$RESEND_CAPTURE" ]] && echo 1 || echo 0)" 'resend: 1回目は送られる'
assert_eq "$(jq -r '.outputTokens' "$RESEND_CAPTURE" 2>/dev/null)" "170" 'resend: 1回目は 170'

# 同じ値で再実行 → 増えていないので送らない
run_resend "$FIXTURE" >/dev/null 2>&1
assert_true "$([[ ! -f "$RESEND_CAPTURE" ]] && echo 1 || echo 0)" 'resend: 増えていなければ送らない'

# 値が増えた transcript → 送り直す（BE 側が上書きするので二重計上にならない）
run_resend "$GROWN_FIXTURE" >/dev/null 2>&1
assert_true "$([[ -f "$RESEND_CAPTURE" ]] && echo 1 || echo 0)" 'resend: 増えていれば送り直す（部分累計で固定しない）'
assert_eq "$(jq -r '.outputTokens' "$RESEND_CAPTURE" 2>/dev/null)" "250" 'resend: 送り直しは増えた後の累計(250)'
assert_eq "$(jq -r '.sessionKey' "$RESEND_CAPTURE" 2>/dev/null)" "sess-resend-1" 'resend: sessionKey は同じ（BE が上書きできる）'
rm -rf "$RESEND_HOME"

# =============================================================================
# 10. session_id がパスとして不正なら送らない
# =============================================================================
BADID_HOME="$(mktemp -d)"
mkdir -p "$BADID_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer bad-token-hhhhhhhhhhhhhhhhhhhhhh"}}}}' > "$BADID_HOME/.claude.json"
BADID_CAPTURE="$BADID_HOME/captured.json"
rc=0
env -i \
  HOME="$BADID_HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$BADID_CAPTURE" \
  CURL_STATUS_CODE="201" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "../../etc/passwd" "$FIXTURE" "$BADID_HOME")" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" 'session-id: 不正でも終了コード0'
assert_true "$([[ ! -f "$BADID_CAPTURE" ]] && echo 1 || echo 0)" 'session-id: パスとして不正なら送らない'
assert_true "$([[ ! -e "$BADID_HOME/.coadmap/ai-usage-reports/../../etc/passwd.done" ]] && echo 1 || echo 0)" 'session-id: 経路外にファイルを作らない'
# 「たまたま mkdir に失敗して止まった」ではなく検証で弾いたことを固定する
# (検証を外すと lock 取得失敗で偶然 POST されないため、理由まで見ないと空振りする)
assert_true "$(grep -q 'unexpected session_id format' "$BADID_HOME/.coadmap/ai-usage-report.log" && echo 1 || echo 0)" 'session-id: 形式検証で弾いたとログに残る'
rm -rf "$BADID_HOME"

# =============================================================================
# 11. transcript に object 以外の JSON 行が混ざっても集計が中断しない
# =============================================================================
# `fromjson?` はパース不能行しか捨てない。`"文字列"` や `123` はパースが通るので
# そのまま流れ、.type のインデックスで jq がプログラムごと abort し使用量が丸ごと欠測する。
MIXED_HOME="$(mktemp -d)"
mkdir -p "$MIXED_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer mixed-token-iiiiiiiiiiiiiiiiiiii"}}}}' > "$MIXED_HOME/.claude.json"
MIXED_FIXTURE="$MIXED_HOME/mixed.jsonl"
{ printf '%s\n' '"just a string"'; printf '%s\n' '123'; printf '%s\n' 'null'; cat "$FIXTURE"; } > "$MIXED_FIXTURE"
MIXED_CAPTURE="$MIXED_HOME/captured.json"
env -i \
  HOME="$MIXED_HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$MIXED_CAPTURE" \
  CURL_STATUS_CODE="201" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-mixed-1" "$MIXED_FIXTURE" "$MIXED_HOME")" >/dev/null 2>&1
assert_true "$([[ -f "$MIXED_CAPTURE" ]] && echo 1 || echo 0)" 'mixed-json: object 以外の行が混ざっても POST される'
assert_eq "$(jq -r '.outputTokens' "$MIXED_CAPTURE" 2>/dev/null)" "170" 'mixed-json: 使用量が欠測しない'
cleanup_mixed() { rm -rf "$MIXED_HOME"; }
cleanup_mixed

# =============================================================================
# 12. Authorization を curl の argv に置かない
# =============================================================================
# argv は ps auxww / /proc/<pid>/cmdline から同一ホストの他ユーザーに読める。
ARGV_BIN="$(mktemp -d)"
cat > "$ARGV_BIN/curl" <<'ARGV_STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGV_FILE"
cat > /dev/null
out_file=""; prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out_file="$arg"
  prev="$arg"
done
[[ -n "$out_file" ]] && printf '{}' > "$out_file"
printf '201'
ARGV_STUB
chmod +x "$ARGV_BIN/curl"
ARGV_HOME="$(mktemp -d)"
mkdir -p "$ARGV_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer supersecrettoken12345678"}}}}' > "$ARGV_HOME/.claude.json"
ARGV_FILE="$ARGV_HOME/argv.txt"
env -i \
  HOME="$ARGV_HOME" \
  PATH="$ARGV_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_ARGV_FILE="$ARGV_FILE" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-argv-1" "$FIXTURE" "$ARGV_HOME")" >/dev/null 2>&1
assert_true "$([[ -f "$ARGV_FILE" ]] && echo 1 || echo 0)" 'argv: curl が呼ばれた'
assert_true "$(grep -q 'supersecrettoken12345678' "$ARGV_FILE" && echo 0 || echo 1)" 'argv: トークンが curl の argv に現れない'
assert_true "$(grep -q 'Authorization' "$ARGV_FILE" && echo 0 || echo 1)" 'argv: Authorization ヘッダが argv に現れない'
cleanup_argv() { rm -rf "$ARGV_HOME" "$ARGV_BIN"; }
cleanup_argv

# =============================================================================
# 13. タイムアウト (000) では taskId を落として再送しない
# =============================================================================
# サーバ側で commit 済みだった場合、taskId 無しの再送が紐付けを NULL に上書きしてしまう。
TO_BIN="$(mktemp -d)"
cat > "$TO_BIN/curl" <<'TO_STUB'
#!/usr/bin/env bash
out_file=""; data=""; prev=""
for arg in "$@"; do
  case "$prev" in
    -o) out_file="$arg" ;;
    --data) data="$arg" ;;
  esac
  prev="$arg"
done
cat > /dev/null
[[ -n "$out_file" ]] && printf '{}' > "$out_file"
n=1
[[ -f "$CURL_COUNT_FILE" ]] && n=$(( $(cat "$CURL_COUNT_FILE") + 1 ))
printf '%s' "$n" > "$CURL_COUNT_FILE"
printf '%s' "$data" > "${CURL_CAPTURE_FILE}.$n"
printf '000'
TO_STUB
chmod +x "$TO_BIN/curl"
TO_HOME="$(mktemp -d)"
mkdir -p "$TO_HOME/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.net/mcp","headers":{"Authorization":"Bearer to-token-jjjjjjjjjjjjjjjjjjjjjj"}}}}' > "$TO_HOME/.claude.json"
TO_REPO="$TO_HOME/repo"
mkdir -p "$TO_REPO"
git -C "$TO_REPO" init -q 2>/dev/null
git -C "$TO_REPO" checkout -q -b feature/cmdev-99999-probe 2>/dev/null
env -i \
  HOME="$TO_HOME" \
  PATH="$TO_BIN:/usr/bin:/bin:/usr/local/bin" \
  CURL_CAPTURE_FILE="$TO_HOME/captured.json" \
  CURL_COUNT_FILE="$TO_HOME/count" \
  COADMAP_AI_USAGE_REPORT="1" \
  bash "$IMPL" "$(payload "sess-timeout-1" "$FIXTURE" "$TO_REPO")" >/dev/null 2>&1
# 000 を受けた時点で候補ループも打ち切る (次の候補も同じくタイムアウトする公算が高く、
# かつ commit 済みかもしれない要求を重ねる意味が無い)。taskId 無しの再送もしない
assert_eq "$(cat "$TO_HOME/count" 2>/dev/null || echo 0)" "1" 'timeout: 打ち切って taskId 無しの再送をしない'
assert_true "$([[ ! -f "$TO_HOME/.coadmap/ai-usage-reports/sess-timeout-1.done" ]] && echo 1 || echo 0)" 'timeout: .done を作らない (次回再送できる)'
cleanup_timeout() { rm -rf "$TO_HOME" "$TO_BIN"; }
cleanup_timeout

exit "$fail"
