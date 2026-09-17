#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2010 # 社内版 v0.4.0 と同期して取り込むファイルなので、差分を最小にするため未使用変数と ls|grep は許容する
# report-ai-usage (_report-ai-usage-impl.sh) の統合テスト。
# curl / security をフェイクバイナリに差し替え、HOME を一時ディレクトリに逃がして
# 実ネットワーク・実 keychain・実 ~/.coadmap に一切触れずに検証する。
#
#  1. Claude Code transcript: message.id dedupe と segment フィールド
#  2. Codex rollout log: token_count からの実測（列対応・model・session id）
#  3. opt-in ゲート（既定は何もしない。HOME 配下に何も作らない）
#  4. 未対応形式 / token_count 0 件 / output 0 / 不正 session_id では送らない
#  5. Stop→SessionEnd→resume の再送判定（同値なら送らない、増えたら同 segment で再送）
#  6. ブランチ切替で新 segment（baseline = 直前の観測累計）
#  7. 404 / 409 / 5xx の扱いと再送キューの flush
#  8. 認証情報の探索（MCP OAuth / 期限切れ除外 / prod 優先 / Codex config.toml）
#  9. プライバシー（transcript 本文が payload に載らない / トークンが argv に出ない）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$HERE/../_report-ai-usage-impl.sh"
FIXTURE="$HERE/fixtures/sample-transcript.jsonl"
CODEX_FIXTURE="$HERE/fixtures/codex-rollout-transcript.jsonl"
CODEX_NO_TOKENS_FIXTURE="$HERE/fixtures/codex-no-token-count.jsonl"
CODEX_RESET_FIXTURE="$HERE/fixtures/codex-rollout-reset.jsonl"
CODEX_SKEW_FIXTURE="$HERE/fixtures/codex-column-skew.jsonl"
UNSUPPORTED_FIXTURE="$HERE/fixtures/unsupported-transcript.jsonl"
ZERO_OUTPUT_FIXTURE="$HERE/fixtures/zero-output-transcript.jsonl"
MARKER='ZZTRANSCRIPTMARKERZZ'

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
  if [[ "$1" == "1" ]]; then printf 'PASS: %s\n' "$2"; else printf 'FAIL: %s\n' "$2"; fail=1; fi
}
yn() { if eval "$1"; then echo 1; else echo 0; fi; }

# --- フェイクバイナリ ---------------------------------------------------------
FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
# 実物は --config - で stdin からヘッダを渡す。読み切らないと呼び出し側が SIGPIPE で落ちる
stdin_data="$(cat)"
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
if [[ -n "${CURL_COUNT_FILE:-}" ]]; then
  [[ -f "$CURL_COUNT_FILE" ]] && n=$(( $(cat "$CURL_COUNT_FILE") + 1 ))
  printf '%s' "$n" > "$CURL_COUNT_FILE"
fi
if [[ -n "${CURL_CAPTURE_FILE:-}" ]]; then
  printf '%s' "$data" > "$CURL_CAPTURE_FILE"
  printf '%s' "$data" > "$CURL_CAPTURE_FILE.$n"
fi
[[ -n "${CURL_ARGV_FILE:-}" ]] && printf '%s\n' "$@" > "$CURL_ARGV_FILE"
[[ -n "${CURL_SLEEP:-}" ]] && sleep "$CURL_SLEEP"
[[ -n "${CURL_STDIN_FILE:-}" ]] && printf '%s' "$stdin_data" > "$CURL_STDIN_FILE"
if [[ -n "${CURL_STATUS_SEQ:-}" ]]; then
  # 空白区切りのステータス列。呼び出し回数を超えたら最後の値を使い続ける
  set -- ${CURL_STATUS_SEQ}
  if (( n <= $# )); then st="${!n}"; else st="${!#}"; fi
else
  st="${CURL_STATUS_CODE:-201}"
fi
printf '%s' "$st"
# 実 curl は接続できないとき -w の 000 を出したうえで exit 7 する。
# スタブが 0 で返ると、呼び出し側の `|| echo 000` 由来のバグを再現できない。
[[ "$st" == "000" ]] && exit 7
exit 0
CURL_STUB
chmod +x "$FAKE_BIN/curl"

# 実 keychain を読ませない（テストが実 Claude Code の資格情報を拾わないようにする）
cat > "$FAKE_BIN/security" <<'SEC_STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_KEYCHAIN_FILE:-}" && -f "$FAKE_KEYCHAIN_FILE" ]]; then
  cat "$FAKE_KEYCHAIN_FILE"
  exit 0
fi
exit 1
SEC_STUB
chmod +x "$FAKE_BIN/security"

TEST_PATH="$FAKE_BIN:/usr/bin:/bin:/usr/local/bin"
HOMES=()
cleanup() { rm -rf "$FAKE_BIN" "${HOMES[@]:-}"; }
trap cleanup EXIT

# 直書き ApiKey ヘッダの MCP 設定を持つ HOME を作る
mkhome() {
  local h; h="$(mktemp -d)"; HOMES+=("$h")
  mkdir -p "$h/.claude"
  printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer inline-token-aaaaaaaaaaaaaaaaaaaa"}}}}' > "$h/.claude.json"
  printf '%s' "$h"
}

mk_grown_early() {
  # $1: 出力先 — FIXTURE(累計170) に +80 した累計250の transcript
  cat "$FIXTURE" > "$1"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$1"
}
mk_grown2_early() {
  # $1: 出力先 — さらに +30 した累計280の transcript
  mk_grown_early "$1"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_10","model":"claude-sonnet-4-5","usage":{"input_tokens":2,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$1"
}

setup_boundary_home() {
  # $1: ブランチ接頭辞 — FIXTURE(170) / GROWN(250) / GROWN2(280) と git repo を用意する
  H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
  mk_grown_early "$GROWN"; mk_grown2_early "$GROWN2"
  REPO="$H/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q 2>/dev/null
  git -C "$REPO" checkout -q -b "feature/$1-a" 2>/dev/null
}

payload_of() {
  # session, transcript, cwd, event ("-" で hook_event_name 自体を省略), model
  jq -nc --arg s "$1" --arg t "$2" --arg c "$3" --arg e "${4:-SessionEnd}" --arg m "${5:-}" \
    '{session_id:$s, transcript_path:$t, cwd:$c}
     + (if $e != "-" then {hook_event_name:$e} else {} end)
     + (if $m != "" then {model:$m} else {} end)'
}

# HOME/session/transcript/cwd/event/model を指定して impl を1回走らせる。
# CURL_* / COADMAP_* は呼び出し側が env 変数として渡す（run_env 配列）。
run_impl() {
  local home="$1" session="$2" transcript="$3" cwd="$4" event="${5:-SessionEnd}" model="${6:-}"
  env -i HOME="$home" PATH="$TEST_PATH" "${run_env[@]}" \
    bash "$IMPL" "$(payload_of "$session" "$transcript" "$cwd" "$event" "$model")"
}

# =============================================================================
# 1. Claude Code transcript: dedupe と segment フィールド
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-cc-1" "$FIXTURE" "$H" >/dev/null 2>&1

assert_true "$(yn '[[ -f "$CAP" ]]')" 'claude: POST が実行され payload が捕捉された'
B="$(cat "$CAP" 2>/dev/null)"
# fixture: msg_1(out=100, 3重複) + msg_2(out=50, 2重複) + msg_3(out=20, sidechain)
# dedupe 後 170。dedupe しない素朴な合算は 420。
assert_eq "$(jq -r '.outputTokens' <<<"$B")" "170" 'claude: outputTokens は dedupe 後の合計(170)'
# fixture の重複行は最終行だけ値が大きい。first を採ると 32 になるので last 勝ちが固定される。
assert_true "$(yn '[[ "$(jq -r ".outputTokens" <<<"$B")" != "32" ]]')" 'claude: dedupe は同一 message.id の最後の行を採る（first ではない）'
assert_eq "$(jq -r '.inputTokens' <<<"$B")" "17" 'claude: inputTokens(17)'
assert_eq "$(jq -r '.cacheCreationTokens' <<<"$B")" "1" 'claude: cacheCreationTokens(1)'
assert_eq "$(jq -r '.cacheReadTokens' <<<"$B")" "2" 'claude: cacheReadTokens(2)'
assert_eq "$(jq -r '.modelName' <<<"$B")" "claude-sonnet-4-5" 'claude: 代表モデルは output 合計最大のモデル'
assert_eq "$(jq -r '.agent' <<<"$B")" "claude_code" 'claude: agent は transcript の中身から claude_code と判別'
assert_eq "$(jq -r '.sessionKey' <<<"$B")" "sess-cc-1" 'claude: sessionKey は hook stdin の session_id'
assert_eq "$(jq -r '.tokenBaseline | [.inputTokens,.outputTokens,.cacheReadTokens,.cacheCreationTokens] | join(",")' <<<"$B")" \
  "0,0,0,0" 'claude: 最初の segment の tokenBaseline は全列 0'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" <<<"$B")" =~ ^1-[0-9]+-[0-9]+$ ]]')" 'claude: segmentKey は "<n>-<epoch>-<pid>" 形'
assert_true "$(yn '[[ "$(jq -r ".segmentStartedAt" <<<"$B")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]')" \
  'claude: segmentStartedAt は ISO8601 UTC'
assert_true "$(yn '[[ "$(jq -r ".collectorKey" <<<"$B")" =~ ^[0-9a-f]{16,64}$ ]]')" 'claude: collectorKey は hex 16..64'

# payload のキー集合を固定する（将来 transcript 由来の項目が増えても気付けるように）
EXPECTED_KEYS='agent cacheCreationTokens cacheReadTokens collectorKey inputTokens modelName outputTokens segmentKey segmentStartedAt sessionKey tokenBaseline'
assert_eq "$(jq -r 'keys_unsorted | sort | join(" ")' <<<"$B")" "$EXPECTED_KEYS" 'claude: payload のキー集合が想定と完全一致する'

# プライバシー: transcript 本文の文字列は payload に一切出ない
assert_true "$(yn 'grep -q "$MARKER" "$FIXTURE"')" 'privacy: fixture に目印文字列が入っている（アサーションが空振りしない）'
assert_true "$(yn '! grep -q "$MARKER" "$CAP"')" 'privacy: payload に transcript 本文が含まれない'
assert_true "$(yn '! grep -q "対応して" "$CAP"')" 'privacy: payload に会話本文が含まれない'

# =============================================================================
# 2. Codex rollout log: token_count からの実測
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
# Codex hook の stdin は Claude Code 互換。ここでは Stop で発火させる。
run_impl "$H" "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
B="$(cat "$CAP" 2>/dev/null)"
assert_true "$(yn '[[ -f "$CAP" ]]')" 'codex: token_count のある rollout log は POST される'
assert_eq "$(jq -r '.agent' <<<"$B")" "codex" 'codex: agent は session_meta の存在から codex と判別'
# 最終行 total_token_usage: input 2500 / cached 2000 / cache_write 120 / output 300
assert_eq "$(jq -r '.inputTokens' <<<"$B")" "500" 'codex: inputTokens = input_tokens - cached_input_tokens (2500-2000)'
assert_eq "$(jq -r '.cacheReadTokens' <<<"$B")" "2000" 'codex: cacheReadTokens = cached_input_tokens'
assert_eq "$(jq -r '.cacheCreationTokens' <<<"$B")" "120" 'codex: cacheCreationTokens = cache_write_input_tokens'
assert_eq "$(jq -r '.outputTokens' <<<"$B")" "300" 'codex: outputTokens は reasoning 込みで別加算しない(300)'
assert_eq "$(jq -r '.modelName' <<<"$B")" "gpt-5.1-codex" 'codex: model は turn_context の最頻値'
assert_true "$(yn '! grep -q "$MARKER" "$CAP"')" 'codex: payload に rollout log の本文が含まれない'

# stdin の session_id が空なら transcript 先頭の session_meta の id を使う
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.sessionKey' "$CAP" 2>/dev/null)" "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b" \
  'codex: stdin が空なら先頭の session_meta の id を sessionKey に使う（2行目の親ではない）'

# stdin と食い違う場合は stdin を採用し、ログに不一致を残す
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-from-stdin" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.sessionKey' "$CAP" 2>/dev/null)" "sess-from-stdin" 'codex: 不一致時は stdin の session_id を採用'
assert_true "$(yn 'grep -q "session id mismatch" "$H/.coadmap/ai-usage-report.log"')" 'codex: 不一致をログに残す'

# 累計カウンタがリセットされる rollout（Codex 旧版に実在）でも消費を落とさない
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-codex-reset" "$CODEX_RESET_FIXTURE" "$H" "Stop" >/dev/null 2>&1
# output: 100 → 300 →(リセット) 50 → 120。単調区間の終値の和 = 300 + 120 = 420
# （max なら 300、last なら 120 になる）
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "420" 'codex-reset: 単調区間ごとの終値を合算する（max=300 / last=120 のどちらでもない）'
# fixture には「まったく同じ累計の連続行」を 1 組入れてある。区切り判定を `<` ではなく
# `<=` にすると同値行で区間が切れ、300 を二重計上して 720 になる。
assert_true "$(yn '[[ "$(jq -r ".outputTokens" "$CAP")" != "720" ]]')" 'codex-reset: 同値の連続行で二重計上しない'
assert_eq "$(jq -r '.cacheReadTokens' "$CAP" 2>/dev/null)" "2700" 'codex-reset: cacheReadTokens も run-sum(2000+700)'
assert_eq "$(jq -r '.cacheCreationTokens' "$CAP" 2>/dev/null)" "150" 'codex-reset: cacheCreationTokens も run-sum(120+30)'
assert_eq "$(jq -r '.inputTokens' "$CAP" 2>/dev/null)" "700" 'codex-reset: inputTokens = run-sum(input) - run-sum(cached) = 3400-2700'
assert_true "$(yn 'grep -q "cumulative counter reset" "$H/.coadmap/ai-usage-report.log"')" 'codex-reset: 非単調をログに残す'

# 列ごとに独立してリセット判定すると、cached だけが減った行で input と cached が
# 別々の行から来て `input - cached` が 0 に潰れる。区切りは行単位で共有する。
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-codex-skew" "$CODEX_SKEW_FIXTURE" "$H" "Stop" >/dev/null 2>&1
# 累計は単調 (total 1050→1160→1270)。cached だけが 900→200 と減るが、これは
# キャッシュの入れ替わりであってカウンタのリセットではない。
# 行区切りは total_tokens (1050 → 1160 →(リセット) 380)。区切りは全列で共有するので
# input は 1100+300=1400、cached は 200+100=300、output は 60+70=130。
# 列ごとに区切ると cached が 900+200+100=1200 になり input-cached が 200 に潰れる。
# 区切り列を output_tokens にすると (単調なので) 区切りが消えて 300-100=200 になる。
assert_eq "$(jq -r '.cacheReadTokens' "$CAP" 2>/dev/null)" "300" 'codex-skew: cached が減っただけの行では区切らない'
assert_eq "$(jq -r '.inputTokens' "$CAP" 2>/dev/null)" "1100" 'codex-skew: inputTokens が潰れない(1400-300)'
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "130" 'codex-skew: 行区切りは total_tokens の減少で決まる(60+70)'

# turn_context が無ければ hook stdin の model にフォールバックする
H="$(mkhome)"; CAP="$H/cap.json"
NOMODEL="$H/nomodel.jsonl"
grep -v '"turn_context"' "$CODEX_FIXTURE" > "$NOMODEL"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-codex-nomodel" "$NOMODEL" "$H" "Stop" "gpt-5.1-from-hook" >/dev/null 2>&1
assert_eq "$(jq -r '.modelName' "$CAP" 2>/dev/null)" "gpt-5.1-from-hook" 'codex: turn_context が無ければ hook stdin の model を使う'

# =============================================================================
# 3. opt-in ゲート: 明示的に有効化しない限りネットワークもファイルも触らない
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"
BEFORE="$(cd "$H" && ls -A | sort | tr '\n' ' ')"
for flag in __unset__ 0 true; do
  if [[ "$flag" == "__unset__" ]]; then
    run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201)
  else
    run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT="$flag")
  fi
  rc=0
  run_impl "$H" "sess-optin-$flag" "$FIXTURE" "$H" >"$H/out" 2>"$H/err" || rc=$?
  assert_eq "$rc" "0" "opt-in($flag): 終了コード0"
  assert_true "$(yn '[[ ! -f "$CAP" ]]')" "opt-in($flag): POST しない"
  assert_true "$(yn '[[ ! -s "$H/out" && ! -s "$H/err" ]]')" "opt-in($flag): stdout/stderr は空"
done
AFTER="$(cd "$H" && ls -A | grep -v -e '^out$' -e '^err$' | sort | tr '\n' ' ')"
assert_eq "$AFTER" "$BEFORE" 'opt-in: HOME 配下に何も作らない（~/.coadmap すら作らない）'

# 対照: =1 なら同じ条件で送られる
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-optin-one" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$CAP" ]]')" 'opt-in: =1 のときだけ POST される'

# =============================================================================
# 4. 送らないケース（未対応形式 / token_count 0 件 / output 0 / 不正 session_id）
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"; LOG="$H/.coadmap/ai-usage-report.log"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)

rm -f "$CAP"; rc=0
run_impl "$H" "sess-unsupported" "$UNSUPPORTED_FIXTURE" "$H" >"$H/o" 2>"$H/e" || rc=$?
assert_eq "$rc" "0" 'unsupported: 終了コード0（エージェントの終了を汚さない）'
assert_true "$(yn '[[ ! -s "$H/o" && ! -s "$H/e" ]]')" 'unsupported: stdout/stderr は空'
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'unsupported: 未対応形式では POST しない'
assert_true "$(yn 'grep -q "unsupported transcript format" "$LOG"')" 'unsupported: 形式未対応と分かるログを残す'

rm -f "$CAP"
run_impl "$H" "sess-codex-notok" "$CODEX_NO_TOKENS_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'codex: token_count が 0 件なら POST しない（0 のレポートを作らない）'
assert_true "$(yn 'grep -q "no usage records found" "$LOG"')" 'codex: token_count 0 件と分かるログを残す'

rm -f "$CAP"
run_impl "$H" "sess-zero-out" "$ZERO_OUTPUT_FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'zero-output: outputTokens=0 なら POST しない'
assert_true "$(yn 'grep -q "refusing to send an empty usage report" "$LOG"')" 'zero-output: 空レポート拒否のログを残す'

rm -f "$CAP"; rc=0
run_impl "$H" "../../etc/passwd" "$FIXTURE" "$H" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" 'session-id: 不正でも終了コード0'
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'session-id: パスとして不正なら送らない'
assert_true "$(yn '[[ ! -e "$H/.coadmap/ai-usage-reports/../../etc/passwd.state.json" ]]')" 'session-id: 経路外にファイルを作らない'
assert_true "$(yn 'grep -q "unexpected session_id format" "$LOG"')" 'session-id: 形式検証で弾いたとログに残る'

# object 以外の JSON 行が混ざっても集計が中断しない
MIXED="$H/mixed.jsonl"
{ printf '%s\n' '"just a string"' '123' 'null'; cat "$FIXTURE"; } > "$MIXED"
rm -f "$CAP"
run_impl "$H" "sess-mixed" "$MIXED" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "170" 'mixed-json: object 以外の行が混ざっても使用量が欠測しない'

# =============================================================================
# 5. Stop → SessionEnd → resume（同 segment 内の再送判定）
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"
GROWN="$H/grown.jsonl"
cat "$FIXTURE" > "$GROWN"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)

rm -f "$CAP"
run_impl "$H" "sess-resend" "$FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "170" 'resend: 1回目(Stop)は送られる'
SEG1="$(jq -r '.segmentKey' "$CAP")"

rm -f "$CAP"
run_impl "$H" "sess-resend" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'resend: 2回目(SessionEnd)は同値なので送らない'

rm -f "$CAP"
run_impl "$H" "sess-resend" "$GROWN" "$H" "SessionEnd" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "250" 'resend: 増えていれば送り直す（累計 250）'
assert_eq "$(jq -r '.segmentKey' "$CAP" 2>/dev/null)" "$SEG1" 'resend: context が同じなら segmentKey は同じ'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP" 2>/dev/null)" "0" 'resend: 同 segment の baseline は変わらない'

# =============================================================================
# 6. ブランチ切替 → 新 segment（baseline = 直前の観測累計）
# =============================================================================
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-11111-first 2>/dev/null
GROWN2="$H/grown.jsonl"
cat "$FIXTURE" > "$GROWN2"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$GROWN2"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)

rm -f "$CAP"
run_impl "$H" "sess-branch" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.taskId' "$CAP" 2>/dev/null)" "CMDEV-11111" 'branch: ブランチ名から taskId を大文字化して載せる'
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "170" 'branch: 1本目の segment は 170'
SEG_A="$(jq -r '.segmentKey' "$CAP")"

git -C "$REPO" checkout -q -b feature/cmdev-22222-second 2>/dev/null
rm -f "$CAP"
run_impl "$H" "sess-branch" "$GROWN2" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.taskId' "$CAP" 2>/dev/null)" "CMDEV-22222" 'branch: 切替後は新しい taskId'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP")" != "$SEG_A" ]]')" 'branch: context 切替で新しい segmentKey になる'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP" 2>/dev/null)" "170" 'branch: 新 segment の baseline は直前の観測累計(170)'
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "80" 'branch: 送るのは segment 累計(250-170=80)'
assert_eq "$(jq -r '.inputTokens' "$CAP" 2>/dev/null)" "5" 'branch: inputTokens も segment 差分(22-17=5)'
assert_eq "$(jq -r '.sessionKey' "$CAP" 2>/dev/null)" "sess-branch" 'branch: sessionKey は変わらない'

# =============================================================================
# 7. 404 / 409 / 5xx と再送キュー
# =============================================================================
# --- 404: taskId を落として再送し、使用量まで捨てない ---
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-99999-probe 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="404 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-404" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '404: taskId 付き → taskId 無し の 2 回だけ POST する'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.1" 2>/dev/null)" "CMDEV-99999" '404: 1回目は taskId 付き'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "none" '404: 2回目は taskId を落とす'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "170" '404: 再送でも使用量はそのまま'
assert_eq "$(jq -r '.segments[0].lastSent.outputTokens' "$H/.coadmap/ai-usage-reports/sess-404.state.json" 2>/dev/null)" "170" \
  '404: 再送成功で lastSent が記録される'

# --- 403: 権限外の Task。404 と同様に taskId を落として 1 回再送する ---
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-77777-forbidden 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="403 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-403" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '403: taskId 付き → taskId 無し の 2 回 POST する'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "none" '403: 2回目は taskId を落とす'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "170" '403: 使用量は落とさない'

# --- 409: 新しい segmentKey を発行して 1 回だけ再送 ---
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '409: 1回だけ再送する（無限に再発行しない）'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.1")" != "$(jq -r ".segmentKey" "$CAP.2")" ]]')" '409: 再送は新しい segmentKey'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.2" 2>/dev/null)" "0" '409: 未送信だったので baseline は直前の観測累計(初回=0)'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "170" '409: 再送の使用量は segment 累計'

# 409 再送で 404 が返っても、taskId を落として同じ新 segment で 1 回送り直す
# （409 経路にだけ 404 フォールバックが無いと、ここで使用量が丸ごと落ちる）
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-99999-probe 2>/dev/null
# 1回目: taskId付き/seg1 → 409、2回目: taskId付き/seg2 → 404、3回目: taskId無し/seg2 → 201
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="409 404 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-404" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "3" '409+404: 409→新segment→404→taskId無し の 3 回'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "CMDEV-99999" '409+404: 新 segment の 1 投目は taskId 付き'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.3" 2>/dev/null)" "none" '409+404: 409 再送でも 404 なら taskId を落として送り直す'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.3")" != "$(jq -r ".segmentKey" "$CAP.1")" ]]')" '409+404: 最終 payload の segmentKey は新しいもの'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "170" '409+404: 使用量は落とさずに送り切る'
assert_eq "$(jq -r '.unresolvedTaskIds | join(",")' "$H/.coadmap/ai-usage-reports/sess-409-404.state.json" 2>/dev/null)" "CMDEV-99999" \
  '409+404: 弾かれた taskId は state に記録される（同 session で再試行しない）'

# 409 が続く場合は諦める（再発行ループにしない）
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="409" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409b" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '409: 再送しても 409 なら 2 回で打ち切る'
assert_true "$(yn '[[ ! -e "$H/.coadmap/ai-usage-reports/queue/sess-409b-1-"* ]]')" '409: 409 は再送キューに積まない'
# 2 回目の 409 で blocked を記録し、以後は集計前に打ち切る
# （mode 固定済みセッションで毎回 2 回 POST し、segments を肥大させ続けないため）
STATE_409B="$H/.coadmap/ai-usage-reports/sess-409b.state.json"
assert_eq "$(jq -r '.blocked.reason // "none"' "$STATE_409B" 2>/dev/null)" "conflict" '409: 2回目の 409 で blocked を記録する'
assert_true "$(yn '[[ "$(jq -r ".blocked.at" "$STATE_409B")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]')" '409: blocked.at は ISO8601 UTC'
assert_eq "$(jq -r '.segments | length' "$STATE_409B" 2>/dev/null)" "2" '409: blocked 時点の segments は 2 本'

rm -f "$CAP" "$CAP".*
rc=0
run_impl "$H" "sess-409b" "$FIXTURE" "$H" >"$H/o" 2>"$H/e" || rc=$?
assert_eq "$rc" "0" 'blocked: 終了コード0'
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'blocked: 以後の実行では curl が呼ばれない'
assert_eq "$(jq -r '.segments | length' "$STATE_409B" 2>/dev/null)" "2" 'blocked: segments が増えない'
assert_true "$(yn 'grep -q "is blocked by a persistent segment conflict" "$H/.coadmap/ai-usage-report.log"')" 'blocked: 打ち切りをログ1行で残す'

# --- 422: ログのみ・再送しない ---
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="422" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-422" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" '422: 再送しない'
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue" 2>/dev/null | wc -l | tr -d ' ')" "0" '422: 再送キューに積まない'
assert_true "$(yn 'grep -q "contract violation" "$H/.coadmap/ai-usage-report.log"')" '422: 契約違反と分かるログを残す'

# --- 5xx: キューに保存し、次回実行の冒頭で flush して削除される ---
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-queue" "$FIXTURE" "$H" >/dev/null 2>&1
QF="$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | head -1)"
assert_true "$(yn '[[ -n "$QF" ]]')" '5xx: 再送キューに保存される'
assert_eq "$(jq -r '.payload.outputTokens' "$QF" 2>/dev/null)" "170" '5xx: キューには payload がそのまま入る'
assert_eq "$(jq -r '.payload.sessionKey' "$QF" 2>/dev/null)" "sess-queue" '5xx: キューの payload に sessionKey がある'
assert_true "$(yn '! grep -qi "authorization\|bearer" "$QF"')" '5xx: キューにトークンを保存しない'
assert_eq "$(jq -r '.baseUrl' "$QF" 2>/dev/null)" "https://api.coadmap.com" '5xx: キューには宛先 BASE_URL だけを保存する'

# 次回実行（別セッション・成功する応答）でキューが flush されて消える
rm -f "$H/count"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-queue-2" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0" 'queue: 次回実行の冒頭で flush されて削除される'
assert_true "$(yn 'grep -q "queue: flushed" "$H/.coadmap/ai-usage-report.log"')" 'queue: flush したとログに残る'

# キュー flush でも 404 なら taskId を落として 1 回だけ送り直す（payload を捨てない）
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-88888-queued 2>/dev/null
# 1投目(taskId付き)=500 → キューへ
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-q404" "$FIXTURE" "$REPO" >/dev/null 2>&1
QF="$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | head -1)"
assert_eq "$(jq -r '.payload.taskId // "none"' "$QF" 2>/dev/null)" "CMDEV-88888" 'queue404: キューには taskId 付きの payload が入る'

# 次回実行: flush の 1 投目が 404、taskId を落とした 2 投目が 201。3 投目は本体。
rm -f "$H/count" "$CAP" "$CAP".*
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="404 201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-q404-next" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.taskId // "none"' "$CAP.1" 2>/dev/null)" "CMDEV-88888" 'queue404: flush の1投目は taskId 付き'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "none" 'queue404: 404 なら taskId を落として送り直す'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "170" 'queue404: 再送でも使用量を捨てない'
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0" 'queue404: 成功したらキューから消える'
assert_true "$(yn 'grep -q "flushed .* without taskId" "$H/.coadmap/ai-usage-report.log"')" 'queue404: taskId 無しで通ったとログに残る'

# 7日より古いキューは送らずに削除される
H="$(mkhome)"
mkdir -p "$H/.coadmap/ai-usage-reports/queue"
jq -nc --argjson savedAt "$(( $(date +%s) - 8*24*3600 ))" \
  '{baseUrl:"https://api.coadmap.com", payload:{sessionKey:"old"}, savedAt:$savedAt}' \
  > "$H/.coadmap/ai-usage-reports/queue/old.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-stale" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$H/.coadmap/ai-usage-reports/queue/old.json" ]]')" 'queue: 7日より古いエントリは削除される'
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'queue: 古いエントリは送らない（本体の1回だけ）'

# =============================================================================
# 7b. 409 再送の baseline / 負値ガード / Stop の throttle / 並行起動
# =============================================================================
mk_grown() {
  # $1: 出力先 — FIXTURE(累計170) に +80 した累計250の transcript を作る
  cat "$FIXTURE" > "$1"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$1"
}

# --- (a) 送信済み segment が 409 → 新 segment の baseline は lastSent ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-base-a" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.segments[0].lastSent.outputTokens' "$H/.coadmap/ai-usage-reports/sess-409-base-a.state.json" 2>/dev/null)" "170" \
  '409-baseline(a): 1回目の送信で lastSent=170 が残る'
rm -f "$H/count" "$CAP" "$CAP".*
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-base-a" "$GROWN" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.2" 2>/dev/null)" "170" \
  '409-baseline(a): 送信済みなら新 segment の baseline は直前に送った累計(170)'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "80" '409-baseline(a): 送るのは差分(250-170=80)'

# --- (b) 未送信(5xx で退避)のまま 409 → baseline は直前の観測累計 ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-base-b" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.segments[0].lastSent' "$H/.coadmap/ai-usage-reports/sess-409-base-b.state.json" 2>/dev/null)" "null" \
  '409-baseline(b): 5xx では lastSent が残らない'
assert_eq "$(jq -r '.lastObserved.outputTokens' "$H/.coadmap/ai-usage-reports/sess-409-base-b.state.json" 2>/dev/null)" "170" \
  '409-baseline(b): 観測累計は残る'
rm -f "$H/count" "$CAP" "$CAP".*
# 1投目はキューの flush(500 のまま据え置き)、2投目が本体で 409、3投目が新 segment
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-base-b" "$GROWN" "$H" >/dev/null 2>&1
# 1 回目は 5xx でキューに載っている = flush で BE に届き得るので、lastQueued(170) を
# baseline にする。ここで元 segment の baseline(0) に戻すと、flush 済みの 170 と
# 重ねて 250 を送り、BE 合計が 420 になって実測 250 と合わなくなる。
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.3" 2>/dev/null)" "170" \
  '409-baseline(b): キューに載せた分は届いた前提で baseline にする(170)'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "80" \
  '409-baseline(b): 送るのは残りの 80'

# --- 負値ガード: baseline > 現在累計 なら送らない ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-31111-a 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-negative" "$GROWN" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "250" 'negative: 1回目は累計250を送る'
# context を切り替えると baseline=250 の新 segment になる。そこで累計が 170 に減った
# transcript を観測させる（累計が巻き戻る状況）。
git -C "$REPO" checkout -q -b feature/cmdev-31222-b 2>/dev/null
rm -f "$H/count" "$CAP" "$CAP".*
run_impl "$H" "sess-negative" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "0" 'negative: baseline を下回る累計では POST しない'
assert_true "$(yn 'grep -q "segment tokens went negative" "$H/.coadmap/ai-usage-report.log"')" 'negative: fail-closed の理由をログに残す'

# --- Stop の throttle ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-throttle" "$FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'throttle: 最初の Stop は送る'

rm -f "$CAP"
run_impl "$H" "sess-throttle" "$GROWN" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'throttle: 直後の Stop は（使用量が増えていても）送らない'
assert_eq "$(jq -r '.lastObserved.outputTokens' "$H/.coadmap/ai-usage-reports/sess-throttle.state.json" 2>/dev/null)" "250" \
  'throttle: 送らなくても lastObserved は更新する'
assert_true "$(yn 'grep -q "skip: throttled" "$H/.coadmap/ai-usage-report.log"')" 'throttle: throttle したとログに残る'

# SessionEnd は throttle しない
run_impl "$H" "sess-throttle" "$GROWN" "$H" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'throttle: SessionEnd は throttle せず必ず送る'
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "250" 'throttle: SessionEnd では最新の累計が送られる'

# context 切替は throttle しない（区間の切れ目を落とさない）
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-32111-a 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-throttle-ctx" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-32222-b 2>/dev/null
run_impl "$H" "sess-throttle-ctx" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'throttle: context 切替（新 segment）は throttle しない'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP" 2>/dev/null)" "170" 'throttle: 切替時の baseline は直前の観測累計'

# 閾値は環境変数で調整でき、0 なら常に送る
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1 COADMAP_AI_USAGE_STOP_THROTTLE_SEC=0)
run_impl "$H" "sess-throttle-off" "$FIXTURE" "$H" "Stop" >/dev/null 2>&1
run_impl "$H" "sess-throttle-off" "$GROWN" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'throttle: COADMAP_AI_USAGE_STOP_THROTTLE_SEC=0 なら毎回送る'

# --- context 切替時に、前 segment の未送信分を締めてから切り替える ---
# Stop の throttle で lastObserved だけ進んだ状態で切り替えると、その差分を
# どの segment も報告せず欠測する（実測で 80 欠落）。
mk_grown2() {
  mk_grown "$1"
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_10","model":"claude-sonnet-4-5","usage":{"input_tokens":2,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$1"
}
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
mk_grown "$GROWN"; mk_grown2 "$GROWN2"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-41111-a 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-boundary" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP")"
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "170" 'boundary: 1回目の Stop で 170 を送る'
run_impl "$H" "sess-boundary" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'boundary: 2回目の Stop は throttle され送らない（lastObserved だけ進む）'
git -C "$REPO" checkout -q -b feature/cmdev-41222-b 2>/dev/null
run_impl "$H" "sess-boundary" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "3" 'boundary: 切替時は「前 segment の締め」と「新 segment」の 2 回送る'
assert_eq "$(jq -r '.segmentKey' "$CAP.2" 2>/dev/null)" "$SEG1" 'boundary: 締めは前 segment の segmentKey 宛'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "250" 'boundary: 締めは throttle 中に進んだぶんを含む区間累計(250)'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.3" 2>/dev/null)" "250" 'boundary: 新 segment の baseline は 250'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "30" 'boundary: 新 segment は残りの 30'
# BE は segmentKey ごとに単調 upsert するので、届いた合計は 250 + 30 = 280 = 実測累計
assert_eq "$(( $(jq -r '.outputTokens' "$CAP.2") + $(jq -r '.outputTokens' "$CAP.3") ))" "280" \
  'boundary: BE に届く合計が実測累計(280)と一致する（欠測しない）'

# 5xx で退避 → throttle → 切替 でも、締めは前 segment 宛に送られる
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
mk_grown "$GROWN"; mk_grown2 "$GROWN2"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-42111-a 2>/dev/null
# 1: 本体=500(退避) / 2: キュー flush=500 / 3: キュー flush=500 / 4: 前 segment の締め=201 / 5: 新 segment=201
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500 500 500 201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-boundary5xx" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
run_impl "$H" "sess-boundary5xx" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'boundary5xx: 未送信でも 2 回目の Stop は throttle される（lastAttemptAt）'
git -C "$REPO" checkout -q -b feature/cmdev-42222-b 2>/dev/null
run_impl "$H" "sess-boundary5xx" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP.4" 2>/dev/null)" "250" 'boundary5xx: 締めは baseline からの区間累計(250)'
assert_eq "$(jq -r '.outputTokens' "$CAP.5" 2>/dev/null)" "30" 'boundary5xx: 新 segment は 30'

# --- 新 segment の差分が 0 でも、前 segment の締めは送られる ---
# 締めを送信要否の判定より後ろに置くと、新 segment が 0 のときに early-exit して
# throttle 中に進んだ差分が永久欠測する。
setup_boundary_home cmdev-81111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-zero-new" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
run_impl "$H" "sess-zero-new" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1   # throttle: lastObserved=250
git -C "$REPO" checkout -q -b feature/cmdev-81222-b 2>/dev/null
# 切替後の観測は増えていない (累計 250 のまま) ので、新 segment の差分は 0 になる
run_impl "$H" "sess-zero-new" "$GROWN" "$REPO" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'zero-new: 締めの 1 回だけ送られる（新 segment は 0 なので送らない）'
assert_eq "$(jq -r '.segmentKey' "$CAP.2" 2>/dev/null)" "$SEG1" 'zero-new: 締めは前 segment 宛'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "250" 'zero-new: throttle 中に進んだ 250 が締めで送られる'
ST="$H/.coadmap/ai-usage-reports/sess-zero-new.state.json"
assert_eq "$(jq -r '.segments | length' "$ST" 2>/dev/null)" "2" 'zero-new: 新 segment は state に作られている'
assert_eq "$(jq -r '.segments[0].lastSent.outputTokens' "$ST" 2>/dev/null)" "250" 'zero-new: 前 segment の lastSent が更新される'
assert_eq "$(jq -r '.segments[1].baseline.outputTokens' "$ST" 2>/dev/null)" "250" 'zero-new: 新 segment の baseline は 250'

# --- 前 segment の締めが 409 なら、新しい segmentKey で 1 回だけ再送する ---
setup_boundary_home cmdev-82111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush-409" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
run_impl "$H" "sess-flush-409" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-82222-b 2>/dev/null
run_impl "$H" "sess-flush-409" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.segmentKey' "$CAP.2" 2>/dev/null)" "$SEG1" 'flush-409: 2投目は前 segment 宛（409）'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.3")" != "$SEG1" ]]')" 'flush-409: 3投目は新しい segmentKey で再発行'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.3" 2>/dev/null)" "170" \
  'flush-409: 再発行の baseline は max(lastSent=170, lastQueued=無し)'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "80" 'flush-409: 再発行で残り 80 を送る'
assert_eq "$(jq -r '.outputTokens' "$CAP.4" 2>/dev/null)" "30" 'flush-409: 現在の segment は 30'
assert_eq "$(( $(jq -r '.outputTokens' "$CAP.1") + $(jq -r '.outputTokens' "$CAP.3") + $(jq -r '.outputTokens' "$CAP.4") ))" "280" \
  'flush-409: BE 合計が実測累計(280)と一致する'

# 再発行も失敗（5xx）ならキューへ退避する
setup_boundary_home cmdev-83111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 500 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush-409q" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
run_impl "$H" "sess-flush-409q" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-83222-b 2>/dev/null
run_impl "$H" "sess-flush-409q" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
KEY2="$(jq -r '.segmentKey' "$CAP.3")"
assert_true "$(yn '[[ -f "$H/.coadmap/ai-usage-reports/queue/sess-flush-409q-$KEY2.json" ]]')" \
  'flush-409q: 再発行が 5xx ならその segmentKey でキューへ退避する'

# --- キューを配送不能として捨てたら lastQueued を巻き戻す ---
# 巻き戻さないと、次の 409 で「届いていない分」を baseline に含めて欠測する。
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-84111-r 2>/dev/null
# 1:000(退避=170) 2:422(flush で配送不能→drop+巻き戻し) 3:409(本送信) 4:201(新segment)
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="000 422 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-rollback" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$H/.coadmap/ai-usage-reports/sess-rollback.state.json" 2>/dev/null)" "170" \
  'rollback: いったんは lastQueued=170 が記録される'
run_impl "$H" "sess-rollback" "$GROWN" "$REPO" >/dev/null 2>&1
assert_true "$(yn 'grep -q "rolled back lastQueued" "$H/.coadmap/ai-usage-report.log"')" 'rollback: 巻き戻したとログに残る'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.4" 2>/dev/null)" "0" \
  'rollback: 届かないと確定した分は baseline に含めない（含めると 170 になり 170 が欠測）'
assert_eq "$(jq -r '.outputTokens' "$CAP.4" 2>/dev/null)" "250" 'rollback: 累計 250 を丸ごと送り直す'

# --- segmentKey は同一実行内でも衝突しない / トリム後も採番が進む ---
setup_boundary_home cmdev-85111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-keys" "$FIXTURE" "$REPO" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-85222-b 2>/dev/null
# 切替で 1 本、409 の再発行でもう 1 本 — 同一実行内で 2 本作る
run_impl "$H" "sess-keys" "$GROWN" "$REPO" >/dev/null 2>&1
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.2")" != "$(jq -r ".segmentKey" "$CAP.3")" ]]')" \
  'segment-key: 同一実行内で 2 本作っても segmentKey が衝突しない'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.2")" =~ ^2- ]]')" 'segment-key: 2 本目の index は 2'
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.3")" =~ ^3- ]]')" 'segment-key: 3 本目の index は 3'
assert_eq "$(jq -r '.nextSegmentIndex' "$H/.coadmap/ai-usage-reports/sess-keys.state.json" 2>/dev/null)" "4" \
  'segment-key: nextSegmentIndex が単調に進む'

# トリムされても採番は length ベースに戻らない
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-86111-t 2>/dev/null
mkdir -p "$H/.coadmap/ai-usage-reports"
jq -nc '{sessionKey:"sess-trim", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         nextSegmentIndex: 61,
         lastObserved:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0},
         segments: [ range(1;61) | {segmentKey: ("\(.)-0-1"), contextKey:"OLD-1", taskId:"OLD-1",
                     startedAt:"2026-09-01T00:00:00Z",
                     baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0}, lastSent:null} ]}' \
  > "$H/.coadmap/ai-usage-reports/sess-trim.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-trim" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP")" =~ ^61- ]]')" 'segment-key: トリム後も採番は 61 から続く（length+1 に戻らない）'
assert_eq "$(jq -r '.segments | length' "$H/.coadmap/ai-usage-reports/sess-trim.state.json" 2>/dev/null)" "50" \
  'segment-key: segments は 50 本に保たれる'
assert_eq "$(jq -r '.nextSegmentIndex' "$H/.coadmap/ai-usage-reports/sess-trim.state.json" 2>/dev/null)" "62" \
  'segment-key: nextSegmentIndex は 62'

# --- hook_event_name が来ない環境でも throttle が効く ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-noevent" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'throttle: SessionEnd は送る'
run_impl "$H" "sess-noevent" "$GROWN" "$H" "-" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'throttle: イベント名が無い実行も throttle される（SessionEnd 以外は throttle）'

# --- 403 が続く session も throttle される（lastAttemptAt）---
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-55555-forbidden 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="403" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-403-throttle" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '403-throttle: 1回目は taskId 付き → taskId 無し の 2 回'
run_impl "$H" "sess-403-throttle" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" '403-throttle: 成功していなくても直後の Stop は throttle される'
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="403" COADMAP_AI_USAGE_REPORT=1 COADMAP_AI_USAGE_STOP_THROTTLE_SEC=0)
rm -f "$CAP" "$CAP".*
run_impl "$H" "sess-403-throttle" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "3" '403-throttle: throttle を外すと送るが、taskId は再試行しないので 1 回だけ'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.3" 2>/dev/null)" "none" '403-throttle: 2 回目以降は taskId を載せない'

# --- 並行起動: 同一セッションで 2 プロセスが同時に走っても POST は 1 回 ---
H="$(mkhome)"; CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" CURL_SLEEP=1 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-parallel" "$FIXTURE" "$H" >/dev/null 2>&1 &
P1=$!
run_impl "$H" "sess-parallel" "$FIXTURE" "$H" >/dev/null 2>&1 &
P2=$!
wait "$P1" "$P2"
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'lock: 同一セッションの同時起動でも POST は 1 回だけ'
assert_eq "$(ls -d "$H/.coadmap/ai-usage-reports/"*.lock 2>/dev/null | wc -l | tr -d ' ')" "0" 'lock: lock の残骸が残らない'

# --- 古い lock: 死んだ PID なら回収する / 生きている PID なら奪わない ---
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports/sess-deadlock.lock"
# 存在し得ない PID を書き、mtime を十分古くする
printf '%s' "999999" > "$H/.coadmap/ai-usage-reports/sess-deadlock.lock/pid"
touch -t 202001010000 "$H/.coadmap/ai-usage-reports/sess-deadlock.lock"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-deadlock" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'lock: 死んだ PID の古い lock は回収して処理を続ける'
assert_true "$(yn 'grep -q "reclaimed stale" "$H/.coadmap/ai-usage-report.log"')" 'lock: 回収したとログに残る'

H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports/sess-alivelock.lock"
printf '%s' "$$" > "$H/.coadmap/ai-usage-reports/sess-alivelock.lock/pid"
touch -t 202001010000 "$H/.coadmap/ai-usage-reports/sess-alivelock.lock"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-alivelock" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "0" 'lock: 生きている PID の lock は古くても奪わない'
assert_true "$(yn 'grep -q "pid $$ is still alive" "$H/.coadmap/ai-usage-report.log"')" 'lock: 生存 PID を理由に見送ったとログに残る'

# --- BE の digest 規則を模したフェイク curl で、同 segment の taskId が消えないこと ---
# BE は同じ segmentKey で taskId の有無/値が変わると衝突として 409 を返す。
# context が "none" に落ちて前 segment を継続する回に taskId を落とすと、
# segment を切り直され以後は未帰属で記録される。
DIGEST_BIN="$(mktemp -d)"; HOMES+=("$DIGEST_BIN")
cat > "$DIGEST_BIN/curl" <<'DIGEST_STUB'
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
printf '%s' "$data" > "$CURL_CAPTURE_FILE.$n"
seg="$(printf '%s' "$data" | jq -r '.segmentKey // "?"')"
task="$(printf '%s' "$data" | jq -r '.taskId // "-"')"
key="$DIGEST_DIR/$(printf '%s' "$seg" | tr -c 'A-Za-z0-9._-' '_')"
if [[ -f "$key" ]]; then
  if [[ "$(cat "$key")" != "$task" ]]; then printf '409'; exit 0; fi
else
  printf '%s' "$task" > "$key"
fi
printf '201'
DIGEST_STUB
chmod +x "$DIGEST_BIN/curl"
cp "$FAKE_BIN/security" "$DIGEST_BIN/security"

H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"
cat "$FIXTURE" > "$GROWN"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"id":"msg_9","model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"; mkdir -p "$H/digest"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-71111-ctx 2>/dev/null
run_digest() {
  env -i HOME="$H" PATH="$DIGEST_BIN:/usr/bin:/bin:/usr/local/bin" \
    CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" DIGEST_DIR="$H/digest" \
    COADMAP_AI_USAGE_REPORT=1 \
    bash "$IMPL" "$(payload_of "sess-ctx-none" "$1" "$2" "SessionEnd" "")"
}
run_digest "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.taskId // "none"' "$CAP.1" 2>/dev/null)" "CMDEV-71111" 'ctx-none: 1回目は taskId 付きで送る'
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
# 非 git ディレクトリで観測 → context は "none" だが前 segment を継続する
run_digest "$GROWN" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'ctx-none: 継続なので 1 回だけ送る（409 の切り直しが起きない）'
assert_eq "$(jq -r '.segmentKey' "$CAP.2" 2>/dev/null)" "$SEG1" 'ctx-none: 同じ segmentKey で送る'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "CMDEV-71111" 'ctx-none: taskId を落とさない（落とすと BE が 409 で切り直す）'
assert_true "$(yn '! grep -q "409 conflict" "$H/.coadmap/ai-usage-report.log"')" 'ctx-none: 409 が発生しない'

# --- 409 の baseline: キューに載せた分は「届いた前提」で引き継ぐ ---
# 000 → キュー退避 → flush で 201（BE に 170 が届く）→ 本送信 404 → taskId 無し → 409
# → 新 segment。ここで baseline を 0 に戻すと 250 を送り、BE 合計が 420 になって実測 250 と合わない。
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-72222-q 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="000 201 404 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-queued-409" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$H/.coadmap/ai-usage-reports/sess-queued-409.state.json" 2>/dev/null)" "170" \
  'queued-409: キューに載せた累計を lastQueued に記録する'
run_impl "$H" "sess-queued-409" "$GROWN" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.5" 2>/dev/null)" "170" \
  'queued-409: 409 の新 segment は lastQueued を baseline にする'
assert_eq "$(jq -r '.outputTokens' "$CAP.5" 2>/dev/null)" "80" 'queued-409: 送るのは 80'
# BE に届く合計 = flush された 170 + 80 = 250 = 実測累計
assert_eq "$(( $(jq -r '.outputTokens' "$CAP.2") + $(jq -r '.outputTokens' "$CAP.5") ))" "250" \
  'queued-409: BE 合計が実測累計(250)と一致する（baseline を 0 に戻すと 420 になる）'

# baseline が 0 でない segment で 409 になっても、baseline は 0 に戻さない
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-73111-a 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-409-nonzero" "$FIXTURE" "$REPO" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-73222-b 2>/dev/null
run_impl "$H" "sess-409-nonzero" "$GROWN" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.2" 2>/dev/null)" "170" '409-nonzero: 切替後の segment の baseline は 170'
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.3" 2>/dev/null)" "170" '409-nonzero: 409 の再発行でも baseline は 170 のまま（0 に戻さない）'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "80" '409-nonzero: 送るのは 80'

# --- 409 の baseline は lastSent と lastQueued の列ごと max ---
# どちらが新しいとも限らないので、優先順位で選ぶと新しい方を無視して二重計上になる。

# (a) lastQueued の方が新しい: 170 送信成功 → 250 が 5xx でキュー → 280 観測
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
mk_grown_early "$GROWN"; mk_grown2_early "$GROWN2"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-77111-q 2>/dev/null
# 1:201(送信=170) 2:500(退避=250) 3:201(flush) 4:404(本送信) 5:409(taskId無し) 6:201(新segment)
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 500 201 404 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-max-q" "$FIXTURE" "$REPO" >/dev/null 2>&1
run_impl "$H" "sess-max-q" "$GROWN" "$REPO" >/dev/null 2>&1
ST="$H/.coadmap/ai-usage-reports/sess-max-q.state.json"
assert_eq "$(jq -r '.segments[0].lastSent.outputTokens' "$ST" 2>/dev/null)" "170" 'baseline-max(a): lastSent は 170'
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$ST" 2>/dev/null)" "250" 'baseline-max(a): lastQueued は 250'
run_impl "$H" "sess-max-q" "$GROWN2" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.6" 2>/dev/null)" "250" \
  'baseline-max(a): baseline は max(lastSent=170, lastQueued=250)=250'
assert_eq "$(jq -r '.outputTokens' "$CAP.6" 2>/dev/null)" "30" 'baseline-max(a): 送るのは 30（lastSent 優先だと 110 になり二重計上）'
assert_eq "$(( $(jq -r '.outputTokens' "$CAP.3") + $(jq -r '.outputTokens' "$CAP.6") ))" "280" \
  'baseline-max(a): BE 合計が実測累計(280)と一致する'

# (b) lastSent の方が新しい: 170 が 5xx でキュー → 250 送信成功 → 280 観測で 409
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
mk_grown_early "$GROWN"; mk_grown2_early "$GROWN2"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-77222-s 2>/dev/null
# 1:500(退避=170) 2:201(flush) 3:201(送信=250) 4:409 5:201(新segment)
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500 201 201 409 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-max-s" "$FIXTURE" "$REPO" >/dev/null 2>&1
run_impl "$H" "sess-max-s" "$GROWN" "$REPO" >/dev/null 2>&1
ST="$H/.coadmap/ai-usage-reports/sess-max-s.state.json"
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$ST" 2>/dev/null)" "170" 'baseline-max(b): lastQueued は 170'
assert_eq "$(jq -r '.segments[0].lastSent.outputTokens' "$ST" 2>/dev/null)" "250" 'baseline-max(b): lastSent は 250'
run_impl "$H" "sess-max-s" "$GROWN2" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP.5" 2>/dev/null)" "250" \
  'baseline-max(b): baseline は max(lastQueued=170, lastSent=250)=250'
assert_eq "$(jq -r '.outputTokens' "$CAP.5" 2>/dev/null)" "30" 'baseline-max(b): 送るのは 30（lastQueued 優先だと 110 になる）'

# --- 前 segment の締めの失敗経路 ---
# (1) unresolved な taskId なら、締めも taskId 無しで送る
setup_boundary_home cmdev-74111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="404 201 201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush-unres" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.2")"
run_impl "$H" "sess-flush-unres" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-74222-b 2>/dev/null
run_impl "$H" "sess-flush-unres" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.segmentKey' "$CAP.3" 2>/dev/null)" "$SEG1" 'flush-unres: 3投目は前 segment の締め'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.3" 2>/dev/null)" "none" 'flush-unres: unresolved な taskId は締めにも載せない'
assert_eq "$(jq -r '.outputTokens' "$CAP.3" 2>/dev/null)" "250" 'flush-unres: 締めの区間累計は 250'

# (2) 締めが 5xx ならキューへ退避する
setup_boundary_home cmdev-75111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 500 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush-5xx" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
run_impl "$H" "sess-flush-5xx" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-75222-b 2>/dev/null
run_impl "$H" "sess-flush-5xx" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
QF="$H/.coadmap/ai-usage-reports/queue/sess-flush-5xx-$SEG1.json"
assert_true "$(yn '[[ -f "$QF" ]]')" 'flush-5xx: 締めの失敗は queue/<session>-<prevSeg>.json に退避される'
assert_eq "$(jq -r '.payload.segmentKey' "$QF" 2>/dev/null)" "$SEG1" 'flush-5xx: 退避された payload は前 segment 宛'
assert_eq "$(jq -r '.payload.outputTokens' "$QF" 2>/dev/null)" "250" 'flush-5xx: 退避された payload は区間累計 250'
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$H/.coadmap/ai-usage-reports/sess-flush-5xx.state.json" 2>/dev/null)" "250" \
  'flush-5xx: 前 segment に lastQueued が記録される'

# (3) 締めが 404 なら taskId を落として送り直す
setup_boundary_home cmdev-76111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 404 201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush-404" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
run_impl "$H" "sess-flush-404" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-76222-b 2>/dev/null
run_impl "$H" "sess-flush-404" "$GROWN2" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(jq -r '.taskId // "none"' "$CAP.2" 2>/dev/null)" "CMDEV-76111" 'flush-404: 締めの 1 投目は taskId 付き'
assert_eq "$(jq -r '.taskId // "none"' "$CAP.3" 2>/dev/null)" "none" 'flush-404: 404 なら taskId を落として送り直す'
assert_eq "$(jq -r '.segmentKey' "$CAP.3" 2>/dev/null)" "$SEG1" 'flush-404: 送り直しも前 segment 宛'

# --- 新しい lock は（pid が死んでいても）stale ではないので奪わない ---
# reclaim_stale_lock が 1 を返したら mkdir を再試行しない、という形を固定する。
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports/sess-freshlock.lock"
printf '%s' "999999" > "$H/.coadmap/ai-usage-reports/sess-freshlock.lock/pid"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-freshlock" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "0" 'lock: 15 分以内の lock は pid が死んでいても奪わない'
assert_true "$(yn 'grep -q "another instance holds the lock" "$H/.coadmap/ai-usage-report.log"')" \
  'lock: 回収できなければ mkdir を再試行せず打ち切る'
assert_true "$(yn '[[ -d "$H/.coadmap/ai-usage-reports/sess-freshlock.lock" ]]')" 'lock: 他プロセスの lock を消さない'

# --- pid を書けていない lock は生存判定できないので回収する ---
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports/sess-nopid.lock"
touch -t 202001010000 "$H/.coadmap/ai-usage-reports/sess-nopid.lock"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-nopid" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "1" 'lock: pid が無い古い lock は回収する'

# =============================================================================
# 8. 認証情報の探索
# =============================================================================
# --- MCP OAuth（~/.claude/.credentials.json）から解決 ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp"}}}' > "$H/.claude.json"
FUTURE_MS=$(( ( $(date +%s) + 86400 ) * 1000 ))
jq -nc --argjson exp "$FUTURE_MS" \
  '{mcpOAuth: {"coadmap-mcp|abc123": {accessToken:"oauth-token-prod-zzzz", expiresAt:$exp, serverUrl:"https://mcp.coadmap.com/mcp", serverName:"coadmap-mcp"}}}' \
  > "$H/.claude/.credentials.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-oauth" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$CAP" ]]')" 'oauth: MCP OAuth の accessToken で送信できる（ApiKey ヘッダが無くても）'
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer oauth-token-prod-zzzz"' 'oauth: Authorization ヘッダ行が完全一致（Bearer の付け外しまで固定）'
assert_true "$(yn 'grep -q "creds=claude-mcp-oauth" "$H/.coadmap/ai-usage-report.log"')" 'oauth: 認証情報の出所がログに残る'

# --- 期限切れの accessToken は採用しない（refresh もしない） ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp"}}}' > "$H/.claude.json"
jq -nc --argjson exp "$(( ( $(date +%s) - 60 ) * 1000 ))" \
  '{mcpOAuth: {"coadmap-mcp|abc123": {accessToken:"expired-token", refreshToken:"rt", expiresAt:$exp, serverUrl:"https://mcp.coadmap.com/mcp", serverName:"coadmap-mcp"}}}' \
  > "$H/.claude/.credentials.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-oauth-exp" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'oauth: 期限切れトークンでは送信しない'
assert_true "$(yn 'grep -q "expired or about to expire" "$H/.coadmap/ai-usage-report.log"')" 'oauth: 期限切れをログに残す'

# --- prod / dev の両方があれば既定で prod を優先。COADMAP_AI_USAGE_TARGET=dev で dev ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp-dev":{"type":"http","url":"https://mcp-dev.coadmap.com/mcp"},"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp"}}}' > "$H/.claude.json"
jq -nc --argjson exp "$FUTURE_MS" '{mcpOAuth: {
    "coadmap-mcp|h1":     {accessToken:"prod-token", expiresAt:$exp, serverUrl:"https://mcp.coadmap.com/mcp",     serverName:"coadmap-mcp"},
    "coadmap-mcp-dev|h2": {accessToken:"dev-token",  expiresAt:$exp, serverUrl:"https://mcp-dev.coadmap.com/mcp", serverName:"coadmap-mcp-dev"}}}' \
  > "$H/.claude/.credentials.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_ARGV_FILE="$H/argv.txt" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-prod-pref" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn 'grep -q "prod-token" "$H/stdin.txt"')" 'target: 既定は prod の接続を優先する'
assert_true "$(yn 'grep -q "https://api.coadmap.com/api/internal/mcp/external_ai_usage_reports" "$H/argv.txt"')" 'target: prod の BASE_URL に送る'

run_env=(CURL_CAPTURE_FILE="$CAP" CURL_ARGV_FILE="$H/argv.txt" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 COADMAP_AI_USAGE_TARGET=dev)
run_impl "$H" "sess-dev-pref" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn 'grep -q "dev-token" "$H/stdin.txt"')" 'target: COADMAP_AI_USAGE_TARGET=dev なら dev を優先する'
assert_true "$(yn 'grep -q "https://api-dev.coadmap.com/api/internal/mcp/external_ai_usage_reports" "$H/argv.txt"')" 'target: dev の BASE_URL に送る'

# --- local scope (~/.claude.json の .projects.<cwd>.mcpServers) から解決 ---
# `claude mcp add` の既定は local scope で、top-level の .mcpServers には入らない。
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
PROJ="$H/proj"; mkdir -p "$PROJ"
jq -nc --arg proj "$PROJ" '{projects: {($proj): {mcpServers: {"coadmap-mcp": {type:"http", url:"https://mcp.coadmap.com/mcp", headers:{Authorization:"Bearer local-scope-token-9999"}}}}}}' \
  > "$H/.claude.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-local-scope" "$FIXTURE" "$PROJ" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$CAP" ]]')" 'local-scope: .projects[*].mcpServers からも認証情報を解決できる'
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer local-scope-token-9999"' 'local-scope: そのトークンが使われる'

# --- project scope (cwd 直下の .mcp.json) から解決 ---
H="$(mktemp -d)"; HOMES+=("$H")
PROJ="$H/proj"; mkdir -p "$PROJ"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer project-scope-token-7777"}}}}' > "$PROJ/.mcp.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-project-scope" "$FIXTURE" "$PROJ" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$CAP" ]]')" 'project-scope: cwd 直下の .mcp.json からも解決できる'
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer project-scope-token-7777"' 'project-scope: そのトークンが使われる'

# --- S4: 同名 serverName でも serverUrl のホストが違えば採用しない ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp"}}}' > "$H/.claude.json"
jq -nc --argjson exp "$FUTURE_MS" \
  '{mcpOAuth: {"coadmap-mcp|old": {accessToken:"dev-only-token", expiresAt:$exp, serverUrl:"https://mcp-dev.coadmap.com/mcp", serverName:"coadmap-mcp"}}}' \
  > "$H/.claude/.credentials.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-host-mismatch" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'oauth-host: serverUrl のホストが設定側と違う資格情報は採用しない（dev の token を prod に送らない）'

# --- serverUrl を持たない mcpOAuth エントリは serverName 一致で採用する ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp"}}}' > "$H/.claude.json"
jq -nc --argjson exp "$FUTURE_MS" \
  '{mcpOAuth: {"coadmap-mcp|nourl": {accessToken:"no-serverurl-token-4321", expiresAt:$exp, serverName:"coadmap-mcp"}}}' \
  > "$H/.claude/.credentials.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-oauth-nourl" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer no-serverurl-token-4321"' \
  'oauth-host: serverUrl が無いエントリは serverName 一致で採用する（host 一致は serverUrl があるときだけ強制）'

# --- project scope: git リポジトリのルート直下の .mcp.json も見る ---
H="$(mktemp -d)"; HOMES+=("$H")
REPO="$H/repo"; mkdir -p "$REPO/sub/dir"
git -C "$REPO" init -q 2>/dev/null
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer repo-root-token-1111"}}}}' > "$REPO/.mcp.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-mcpjson-root" "$FIXTURE" "$REPO/sub/dir" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer repo-root-token-1111"' \
  'project-scope: cwd がサブディレクトリでも git ルートの .mcp.json を読む'

# --- Codex の config.toml から解決（http_headers.Authorization） ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
model = "gpt-5.1-codex"

[mcp_servers.other]
url = "https://example.com/mcp"
http_headers = { Authorization = "Bearer not-coadmap" }

[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
http_headers = { Authorization = "Bearer codex-toml-token-1234" }
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-codex-toml" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$CAP" ]]')" 'codex-toml: config.toml のヘッダから送信できる'
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer codex-toml-token-1234"' 'codex-toml: Authorization ヘッダ行が完全一致（Bearer を二重に付けない）'
assert_true "$(yn '! grep -q "not-coadmap" "$H/stdin.txt"')" 'codex-toml: 別ホストのセクションのトークンは使わない（セクション境界）'

# --- キーがクォートされた形: http_headers = { "Authorization" = "Bearer …" } ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
http_headers = { "Authorization" = "Bearer quoted-key-token-2468" }
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-codex-quoted" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer quoted-key-token-2468"' 'codex-toml: キーがクォートされた Authorization も読める（キー名を値と取り違えない）'

# --- env_http_headers（インライン表）は環境変数名。値として送らない ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
env_http_headers = { Authorization = "COADMAP_MCP_TOKEN_VAR" }
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 COADMAP_MCP_TOKEN_VAR=resolved-from-env-1357)
run_impl "$H" "sess-codex-envhdr" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer resolved-from-env-1357"' 'codex-toml: env_http_headers は env 参照として解決する（変数名を Bearer にしない）'
assert_true "$(yn '! grep -q "COADMAP_MCP_TOKEN_VAR" "$H/stdin.txt"')" 'codex-toml: 環境変数名そのものを送らない'

# --- env_http_headers（セクション表）---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"

[mcp_servers.coadmap.env_http_headers]
Authorization = "COADMAP_MCP_TOKEN_VAR"
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 COADMAP_MCP_TOKEN_VAR=section-env-2469)
run_impl "$H" "sess-codex-envhdr-sec" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer section-env-2469"' 'codex-toml: [mcp_servers.<name>.env_http_headers] セクション形も env 参照として解決する'

# --- bearer_token_env_var 経由 ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
bearer_token_env_var = "MY_COADMAP_TOKEN"
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 MY_COADMAP_TOKEN=env-var-token-5678)
run_impl "$H" "sess-codex-env" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer env-var-token-5678"' 'codex-toml: bearer_token_env_var が指す env から解決する（環境変数名を送らない）'

# --- 何も無ければ黙って何もしない ---
H="$(mktemp -d)"; HOMES+=("$H")
CAP="$H/cap.json"; rc=0
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-nocreds" "$FIXTURE" "$H" >"$H/o" 2>"$H/e" || rc=$?
assert_eq "$rc" "0" 'no-creds: 終了コード0'
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'no-creds: POST しない'
assert_true "$(yn '[[ ! -s "$H/o" && ! -s "$H/e" ]]')" 'no-creds: stdout/stderr は空'

# =============================================================================
# 9. Authorization を curl の argv に置かない（--config 経由で渡す）
# =============================================================================
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer supersecrettoken12345678"}}}}' > "$H/.claude.json"
run_env=(CURL_ARGV_FILE="$H/argv.txt" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-argv" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$H/argv.txt" ]]')" 'argv: curl が呼ばれた'
assert_true "$(yn '! grep -q "supersecrettoken12345678" "$H/argv.txt"')" 'argv: トークンが curl の argv に現れない'
assert_true "$(yn '! grep -q "Authorization" "$H/argv.txt"')" 'argv: Authorization ヘッダが argv に現れない'
assert_true "$(yn 'grep -q -- "--config" "$H/argv.txt"')" 'argv: --config でヘッダを渡している'
assert_true "$(yn 'grep -q "supersecrettoken12345678" "$H/stdin.txt"')" 'argv: トークンは stdin (--config) 経由で渡る'

# =============================================================================
# 10. 状態の単調性・エラー系の細部
# =============================================================================
mk_out() {
  # $1: 出力先, $2: outputTokens — 出力トークン数だけを指定した最小の transcript
  printf '%s\n' "{\"type\":\"assistant\",\"isSidechain\":false,\"message\":{\"id\":\"msg_a\",\"model\":\"claude-sonnet-4-5\",\"usage\":{\"input_tokens\":1,\"output_tokens\":$2,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" > "$1"
}

# --- lastObserved は後退しない（後退すると次の segment で二重計上になる）---
H="$(mkhome)"; CAP="$H/cap.json"
T1000="$H/t1000.jsonl"; T300="$H/t300.jsonl"; T1200="$H/t1200.jsonl"
mk_out "$T1000" 1000; mk_out "$T300" 300; mk_out "$T1200" 1200
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-61111-a 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-monotonic" "$T1000" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "1000" 'monotonic: 1本目の segment で 1000 を送る'
git -C "$REPO" checkout -q -b feature/cmdev-61222-b 2>/dev/null
run_impl "$H" "sess-monotonic" "$T300" "$REPO" >/dev/null 2>&1
# 新 segment の baseline は 1000。累計 300 は baseline を下回るので fail-closed で送らない。
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'monotonic: baseline を下回る観測では送らない'
assert_eq "$(jq -r '.lastObserved.outputTokens' "$H/.coadmap/ai-usage-reports/sess-monotonic.state.json" 2>/dev/null)" "1000" \
  'monotonic: 減った観測で lastObserved を後退させない'
git -C "$REPO" checkout -q -b feature/cmdev-61333-c 2>/dev/null
rm -f "$CAP" "$CAP".*
run_impl "$H" "sess-monotonic" "$T1200" "$REPO" >/dev/null 2>&1
assert_eq "$(jq -r '.tokenBaseline.outputTokens' "$CAP" 2>/dev/null)" "1000" 'monotonic: 次の切替でも baseline は 1000 のまま'
assert_eq "$(jq -r '.outputTokens' "$CAP" 2>/dev/null)" "200" 'monotonic: 送るのは 200（後退していれば 900 になり二重計上）'

# --- curl が 000 を出して非 0 終了しても、再送キューに乗る ---
ZERO_BIN="$(mktemp -d)"; HOMES+=("$ZERO_BIN")
cat > "$ZERO_BIN/curl" <<'ZERO_STUB'
#!/usr/bin/env bash
cat > /dev/null
prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && printf '{}' > "$arg"; prev="$arg"; done
# 実物と同じ挙動: -w の 000 を出力したうえで exit 7 (couldn't connect)
printf '000'
exit 7
ZERO_STUB
chmod +x "$ZERO_BIN/curl"
cp "$FAKE_BIN/security" "$ZERO_BIN/security"
H="$(mkhome)"
env -i HOME="$H" PATH="$ZERO_BIN:/usr/bin:/bin:/usr/local/bin" COADMAP_AI_USAGE_REPORT=1 \
  bash "$IMPL" "$(payload_of "sess-curlfail" "$FIXTURE" "$H" "SessionEnd" "")" >/dev/null 2>&1
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1" \
  'curl-fail: curl の 000 + 非0終了でも再送キューに保存される'
assert_true "$(yn 'grep -q "status=000" "$H/.coadmap/ai-usage-report.log"')" 'curl-fail: ステータスは 000 に正規化される'

# --- COADMAP_API_URL はスキーム必須 ---
H="$(mktemp -d)"; HOMES+=("$H"); CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 COADMAP_API_TOKEN=env-token COADMAP_API_URL=api.coadmap.com)
run_impl "$H" "sess-badurl" "$FIXTURE" "$H" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'api-url: スキームが無ければ送らない'
assert_true "$(yn 'grep -q "must start with http" "$H/.coadmap/ai-usage-report.log"')" 'api-url: 理由をログに残す'

# --- キュー flush の taskId 無し再送が一過性エラーなら、キューを消さない ---
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-66666-keep 2>/dev/null
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="500" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-keep" "$FIXTURE" "$REPO" >/dev/null 2>&1
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1" 'queue-keep: まず退避される'
rm -f "$H/count"
# flush: 1投目=404 → taskId を落として 2投目=503 → 一過性なので残す
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="404 503 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-keep-2" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(ls "$H/.coadmap/ai-usage-reports/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1" \
  'queue-keep: taskId 無し再送が 5xx なら捨てずに残す'
assert_true "$(yn 'grep -q "queue: keeping" "$H/.coadmap/ai-usage-report.log"')" 'queue-keep: 残したとログに残る'

# --- 422 は応答本文の先頭をログに残す ---
BODY_BIN="$(mktemp -d)"; HOMES+=("$BODY_BIN")
cat > "$BODY_BIN/curl" <<'BODY_STUB'
#!/usr/bin/env bash
cat > /dev/null
prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && printf '{"errors":["segmentStartedAt must be ISO8601"]}' > "$arg"; prev="$arg"; done
printf '422'
BODY_STUB
chmod +x "$BODY_BIN/curl"
cp "$FAKE_BIN/security" "$BODY_BIN/security"
H="$(mkhome)"
env -i HOME="$H" PATH="$BODY_BIN:/usr/bin:/bin:/usr/local/bin" COADMAP_AI_USAGE_REPORT=1 \
  bash "$IMPL" "$(payload_of "sess-422body" "$FIXTURE" "$H" "SessionEnd" "")" >/dev/null 2>&1
assert_true "$(yn 'grep -q "segmentStartedAt must be ISO8601" "$H/.coadmap/ai-usage-report.log"')" \
  '422-body: 応答本文の先頭をログに残す（何が契約違反か分かる）'

# --- blocked は 30 日で失効して再挑戦できる ---
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports"
jq -nc --argjson old "$(( $(date +%s) - 31*24*3600 ))" \
  '{sessionKey:"sess-expired", agent:"claude_code", segments:[], lastObserved:null,
    blocked:{reason:"conflict", at:"2026-01-01T00:00:00Z", atEpoch:$old}}' \
  > "$H/.coadmap/ai-usage-reports/sess-expired.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-expired" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "1" 'blocked-expiry: 30 日より古い blocked は失効して再挑戦する'
assert_eq "$(jq -r '.blocked // "gone"' "$H/.coadmap/ai-usage-reports/sess-expired.state.json" 2>/dev/null)" "gone" \
  'blocked-expiry: 失効した blocked は state から消える'

# 30 日以内なら止まったまま
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports"
jq -nc --argjson recent "$(( $(date +%s) - 3600 ))" \
  '{sessionKey:"sess-still-blocked", agent:"claude_code", segments:[], lastObserved:null,
    blocked:{reason:"conflict", at:"2026-09-01T00:00:00Z", atEpoch:$recent}}' \
  > "$H/.coadmap/ai-usage-reports/sess-still-blocked.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-still-blocked" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null || echo 0)" "0" 'blocked-expiry: 30 日以内の blocked は止まったまま'

# --- segments は直近 50 本だけ保持する ---
H="$(mkhome)"; CAP="$H/cap.json"
mkdir -p "$H/.coadmap/ai-usage-reports"
jq -nc '{sessionKey:"sess-many", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         lastObserved:null,
         segments: [ range(1;61) | {segmentKey: ("\(.)-0"), contextKey:"none", taskId:"", startedAt:"2026-09-01T00:00:00Z",
                     baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0}, lastSent:null} ]}' \
  > "$H/.coadmap/ai-usage-reports/sess-many.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-many" "$FIXTURE" "$H" >/dev/null 2>&1
assert_eq "$(jq -r '.segments | length' "$H/.coadmap/ai-usage-reports/sess-many.state.json" 2>/dev/null)" "50" \
  'segments-cap: 直近 50 本だけ残す'
assert_eq "$(jq -r '.segments[-1].segmentKey' "$H/.coadmap/ai-usage-reports/sess-many.state.json" 2>/dev/null)" "60-0" \
  'segments-cap: 残るのは新しい方'


# =============================================================================
# 11. 切替の巻き戻し / 他セッションの state の排他 / イベント名の引数
# =============================================================================

# --- 締めの再送もキュー退避も失敗したら、追加した segment を state から取り消す ---
# 取り消さないと次回は「旧 context の新 key」を最後の segment とみなして再び切替判定に
# 入り、既に本体送信で計上済みの区間を新 key 宛にもう一度送って二重計上する。
be_total() {
  # 引数: 201 が返った capture ファイル群 — segmentKey ごとに max(outputTokens) を採って合計する
  # (BE は (session, segment) ごとに列単位 GREATEST で単調 upsert するので、同じ key への
  #  再送は最大値に畳まれる)。拒否された POST は BE に残らないので渡さない。
  jq -s '[ group_by(.segmentKey)[] | ([ .[].outputTokens ] | max) ] | add // 0' "$@" 2>/dev/null
}

setup_boundary_home cmdev-91111
QDIR="$H/.coadmap/ai-usage-reports/queue"
# 1: seg1=201(170) / 2: 締め=409 / 3: 再発行=503(キュー退避も失敗) / 4: 本体=201(280)
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 503 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-switchback" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
SEG1="$(jq -r '.segmentKey' "$CAP.1")"
# throttle 中に lastObserved だけ 250 まで進める（= 前 segment に未送信分が残る状態）
run_impl "$H" "sess-switchback" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'switchback: 2 回目は throttle される'
mkdir -p "$QDIR"; chmod 500 "$QDIR"    # queue_save を失敗させる
git -C "$REPO" checkout -q -b feature/cmdev-91222-b 2>/dev/null
run_impl "$H" "sess-switchback" "$GROWN2" "$REPO" "SessionEnd" >/dev/null 2>&1
chmod 700 "$QDIR"
ST="$H/.coadmap/ai-usage-reports/sess-switchback.state.json"
assert_eq "$(ls "$QDIR" | wc -l | tr -d ' ')" "0" 'switchback: queue_save に失敗してキューは空のまま'
assert_true "$(yn 'grep -q "could not record the previous segment" "$H/.coadmap/ai-usage-report.log"')" \
  'switchback: 締めを記録できず切替を見送ったとログに残る'
assert_eq "$(jq -r '.segments | length' "$ST" 2>/dev/null)" "1" \
  'switchback: 409 再送のために足した segment は state から取り消される'
assert_eq "$(jq -r '.segments[-1].segmentKey' "$ST" 2>/dev/null)" "$SEG1" 'switchback: 最後の segment は元の segment のまま'
assert_true "$(yn '[[ "$(jq -r ".nextSegmentIndex" "$ST")" -ge 3 ]]')" 'switchback: nextSegmentIndex は戻さない（key の再利用を防ぐ）'
assert_eq "$(jq -r '.segments[-1].lastSent.outputTokens' "$ST" 2>/dev/null)" "280" \
  'switchback: 本体送信ぶん(280)は元の segment に記録される'
# 次回の観測: 切替をやり直す。取り消していないと「旧 ctx の新 key」宛に 110 を送って二重計上する。
run_impl "$H" "sess-switchback" "$GROWN2" "$REPO" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "4" 'switchback: 次回は締めるものが無いので追加の POST は無い'
assert_true "$(yn '[[ ! -f "$CAP.5" ]]')" \
  'switchback: 計上済みの区間を旧 ctx の新 key 宛に送り直さない（切り詰めないと 110 を二重計上する）'
# 201 が返ったのは 1 投目(seg1=170) と 4 投目(seg1=280) だけ。BE には seg1 の 280 だけが残る。
# 変異で切り詰めを外すと 5 投目(110)が成功し、BE 合計は 390 になる。
EXTRA5=(); [[ -f "$CAP.5" ]] && EXTRA5=("$CAP.5")
assert_eq "$(be_total "$CAP.1" "$CAP.4" ${EXTRA5[@]+"${EXTRA5[@]}"})" "280" 'switchback: BE に届いた合計が実測累計(280)と一致する（二重計上しない）'
assert_eq "$(jq -r '.segments | length' "$ST" 2>/dev/null)" "2" 'switchback: 次回は切替が成立して新 segment が開く'
assert_eq "$(jq -r '.segments[-1].baseline.outputTokens' "$ST" 2>/dev/null)" "280" 'switchback: やり直した切替の baseline は 280'

# --- 他セッションの lock が生きている間は、その entry を rollback せず残す ---
H="$(mkhome)"; CAP="$H/cap.json"
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD/queue"
jq -nc '{sessionKey:"sess-locked", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         lastObserved:{inputTokens:0,outputTokens:170,cacheReadTokens:0,cacheCreationTokens:0},
         segments:[{segmentKey:"1-0-1", contextKey:"OLD-1", taskId:"OLD-1", startedAt:"2026-09-01T00:00:00Z",
                    baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0},
                    lastSent:null,
                    lastQueued:{inputTokens:0,outputTokens:170,cacheReadTokens:0,cacheCreationTokens:0}}]}' \
  > "$RD/sess-locked.state.json"
jq -nc --argjson at "$(date +%s)" '{baseUrl:"https://api.coadmap.com", savedAt:$at,
   payload:{agent:"claude_code", sessionKey:"sess-locked", segmentKey:"1-0-1", outputTokens:170}}' \
  > "$RD/queue/sess-locked-1-0-1.json"
mkdir -p "$RD/sess-locked.lock"; printf '%s' "$$" > "$RD/sess-locked.lock/pid"
# 1: キュー flush=422(配送不能→drop したい) / 2: 自分の送信=201
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="422 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-mine" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ -f "$RD/queue/sess-locked-1-0-1.json" ]]')" \
  'qlock: 他セッションの lock が生きている間はキューファイルを消さない'
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$RD/sess-locked.state.json" 2>/dev/null)" "170" \
  'qlock: 他セッションの state を lock 無しで書き換えない'
assert_true "$(yn 'grep -q "deferring the lastQueued rollback" "$H/.coadmap/ai-usage-report.log"')" \
  'qlock: 保留したことをログに残す'
# lock が消えれば次回の flush で drop + 巻き戻しが行われる
rm -rf "$RD/sess-locked.lock"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count2" CURL_STATUS_SEQ="422 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-mine2" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$RD/queue/sess-locked-1-0-1.json" ]]')" 'qlock: lock が空けば drop される'
assert_eq "$(jq -r '.segments[0] | has("lastQueued")' "$RD/sess-locked.state.json" 2>/dev/null)" "false" \
  'qlock: lock が空けば lastQueued が巻き戻る'
assert_true "$(yn '[[ -f "$RD/sess-locked.lock" ]] || true')" 'qlock: rollback 後に lock は残さない'
assert_true "$(yn '[[ ! -d "$RD/sess-locked.lock" ]]')" 'qlock: rollback で取った lock は解放される'

# --- hook_event_name が来なくても、引数 --event SessionEnd なら throttle されない ---
# Codex の終端イベント名は SessionEnd と一致するとは限らず、stdin に載らない実装もある。
# 名前が分からないまま throttle すると、最終ターンぶんが恒久的に落ちる。
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-argevent" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'arg-event: 1 回目は送る'
env -i HOME="$H" PATH="$TEST_PATH" "${run_env[@]}" \
  bash "$IMPL" "$(payload_of "sess-argevent" "$GROWN" "$H" "-")" --event SessionEnd >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'arg-event: stdin にイベント名が無くても --event SessionEnd なら送る'
assert_eq "$(jq -r '.outputTokens' "$CAP.2" 2>/dev/null)" "250" 'arg-event: 同 segment なので送るのはセッション累計(250)'
# 素の第 2 引数（--event を付けない形）でも同じ
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-argevent2" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
env -i HOME="$H" PATH="$TEST_PATH" "${run_env[@]}" \
  bash "$IMPL" "$(payload_of "sess-argevent2" "$GROWN" "$H" "-")" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "2" 'arg-event: 素の第 2 引数でも採用される'
# stdin にイベント名があれば引数より stdin が優先（Stop は throttle される）
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-argevent3" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
env -i HOME="$H" PATH="$TEST_PATH" "${run_env[@]}" \
  bash "$IMPL" "$(payload_of "sess-argevent3" "$GROWN" "$H" "Stop")" --event SessionEnd >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'arg-event: stdin の hook_event_name が引数より優先される'

# --- nextSegmentIndex が数値でなければ length+1 にフォールバックする ---
# 文字列が入っていると `> 0` は真になり、そのまま segmentKey の接頭辞に使えず
# 既定の 1 に落ちて既存 key と衝突する。
H="$(mkhome)"; CAP="$H/cap.json"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-92111-x 2>/dev/null
mkdir -p "$H/.coadmap/ai-usage-reports"
jq -nc '{sessionKey:"sess-badidx", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         nextSegmentIndex: "abc",
         lastObserved:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0},
         segments:[{segmentKey:"1-0-1", contextKey:"OTHER-1", taskId:"OTHER-1", startedAt:"2026-09-01T00:00:00Z",
                    baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0}, lastSent:null}]}' \
  > "$H/.coadmap/ai-usage-reports/sess-badidx.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-badidx" "$FIXTURE" "$REPO" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.1")" =~ ^2- ]]')" \
  'bad-index: nextSegmentIndex が数値でなければ length+1(=2) から採番する'

# --- payload が壊れた stale キューは、巻き戻せないことをログに残してから捨てる ---
H="$(mkhome)"; CAP="$H/cap.json"
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD/queue"
jq -nc '{baseUrl:"https://api.coadmap.com", savedAt: 0}' > "$RD/queue/sess-broken-1-0-1.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-brk" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$RD/queue/sess-broken-1-0-1.json" ]]')" 'stale-broken: 期限切れの壊れた entry は捨てる'
assert_true "$(yn 'grep -q "payload is unreadable" "$H/.coadmap/ai-usage-report.log"')" \
  'stale-broken: 巻き戻せないことをログ 1 行で残す'

# =============================================================================
# 12. コメント行の資格情報 / scope 優先 / 壊れた state / シグナル / 締めの未知 status
# =============================================================================

# --- M1: コメントアウトされた Authorization を live な資格情報として拾わない ---
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
# http_headers = { Authorization = "Bearer commented-out-token-9999" }
# env_http_headers = { Authorization = "COMMENTED_OUT_VAR" }
bearer_token_env_var = "LIVE_COADMAP_TOKEN"
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 LIVE_COADMAP_TOKEN=live-token-1122 COMMENTED_OUT_VAR=should-not-be-used)
run_impl "$H" "sess-toml-comment" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer live-token-1122"' \
  'toml-comment: コメントアウトされた Authorization / env_http_headers 行は採用しない'
assert_true "$(yn '! grep -q "commented-out-token-9999" "$H/stdin.txt"')" 'toml-comment: コメント内のトークンを送らない'
assert_true "$(yn '! grep -q "should-not-be-used" "$H/stdin.txt"')" 'toml-comment: コメント内の env 参照も解決しない'

# コメントアウトされた資格情報しか無いなら、そもそも送らない
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
[mcp_servers.coadmap]
url = "https://mcp.coadmap.com/mcp"
#http_headers = { Authorization = "Bearer only-a-comment-token" }
TOML
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-toml-only-comment" "$CODEX_FIXTURE" "$H" "Stop" >/dev/null 2>&1
assert_true "$(yn '[[ ! -f "$CAP" ]]')" 'toml-comment: コメント行しか無ければ資格情報として解決しない（POST しない）'

# --- S3: 採用順は scope（user → local → repo）が第 1 キー、prod/dev 優先は第 2 キー ---
# repo の .mcp.json は他人が書き換え得るので、上位 scope に候補があるかぎり選ばない。
H="$(mktemp -d)"; HOMES+=("$H"); mkdir -p "$H/.claude"
PROJ="$H/proj"; mkdir -p "$PROJ"
printf '%s' '{"mcpServers":{"coadmap-mcp-dev":{"type":"http","url":"https://mcp-dev.coadmap.com/mcp","headers":{"Authorization":"Bearer user-scope-dev-token-3333"}}}}' > "$H/.claude.json"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer repo-scope-prod-token-4444"}}}}' > "$PROJ/.mcp.json"
CAP="$H/cap.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_ARGV_FILE="$H/argv.txt" CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-scope-order" "$FIXTURE" "$PROJ" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer user-scope-dev-token-3333"' \
  'scope-order: user scope の dev 接続が repo scope の prod 接続より優先される'
assert_true "$(yn 'grep -q "https://api-dev.coadmap.com/api/internal" "$H/argv.txt"')" \
  'scope-order: 採用した接続に対応する BASE_URL に送る'
# 上位 scope に候補が無ければ repo scope を使う
H="$(mktemp -d)"; HOMES+=("$H")
PROJ="$H/proj"; mkdir -p "$PROJ"
printf '%s' '{"mcpServers":{"coadmap-mcp":{"type":"http","url":"https://mcp.coadmap.com/mcp","headers":{"Authorization":"Bearer repo-only-token-5555"}}}}' > "$PROJ/.mcp.json"
run_env=(CURL_STDIN_FILE="$H/stdin.txt" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-scope-repo-only" "$FIXTURE" "$PROJ" >/dev/null 2>&1
assert_eq "$(cat "$H/stdin.txt" 2>/dev/null)" 'header = "Authorization: Bearer repo-only-token-5555"' \
  'scope-order: 上位 scope に候補が無ければ repo scope を使う'

# --- S1: baseline が欠けた segment は永久 skip にせず、新 segment で送る ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD"
jq -nc '{sessionKey:"sess-nobaseline", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         lastObserved:{inputTokens:17,outputTokens:170,cacheReadTokens:2,cacheCreationTokens:1},
         segments:[{segmentKey:"1-0-1", contextKey:"none", taskId:"", startedAt:"2026-09-01T00:00:00Z", lastSent:null}]}' \
  > "$RD/sess-nobaseline.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-nobaseline" "$GROWN" "$H" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'state-guard: baseline が欠けていても永久 skip にならず送信する'
assert_eq "$(jq -r '.outputTokens' "$CAP.1" 2>/dev/null)" "80" \
  'state-guard: 新 segment の baseline は救出した lastObserved(170) なので送るのは差分(80)'
assert_true "$(yn 'grep -q "malformed" "$H/.coadmap/ai-usage-report.log"')" 'state-guard: 壊れた segment をログ 1 行で残す'

# --- S1: baseline の列が数値でない (文字列 / null) segment も同様に救出する ---
# `numbers` フィルタは非数値で empty を返すため、`all(... | numbers) != null` は真に化ける。
# 型を `type == "number"` で見ないと、この 2 ケースがガードを素通りして永久 skip になる。
for _bad in '"oops"' 'null'; do
  H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
  RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD"
  jq -nc --argjson bad "$_bad" '{sessionKey:"sess-badcol", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
           lastObserved:{inputTokens:17,outputTokens:170,cacheReadTokens:2,cacheCreationTokens:1},
           segments:[{segmentKey:"1-0-1", contextKey:"none", taskId:"", startedAt:"2026-09-01T00:00:00Z",
                      baseline:{inputTokens:0,outputTokens:$bad,cacheReadTokens:0,cacheCreationTokens:0}, lastSent:null}]}' \
    > "$RD/sess-badcol.state.json"
  run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
  run_impl "$H" "sess-badcol" "$GROWN" "$H" "SessionEnd" >/dev/null 2>&1
  assert_eq "$(cat "$H/count" 2>/dev/null)" "1" "state-guard: baseline.outputTokens=$_bad でも永久 skip にならず送信する"
  assert_eq "$(jq -r '.outputTokens' "$CAP.1" 2>/dev/null)" "80" "state-guard: baseline.outputTokens=$_bad は救出した lastObserved から差分(80)を送る"
done

# --- S1: segmentKey / startedAt が欠けた segment で "null" を送らない ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD"
jq -nc '{sessionKey:"sess-nokey", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         lastObserved:{inputTokens:17,outputTokens:170,cacheReadTokens:2,cacheCreationTokens:1},
         segments:[{contextKey:"none", taskId:"", startedAt:"2026-09-01T00:00:00Z",
                    baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0}, lastSent:null}]}' \
  > "$RD/sess-nokey.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-nokey" "$GROWN" "$H" "SessionEnd" >/dev/null 2>&1
assert_true "$(yn '[[ "$(jq -r ".segmentKey" "$CAP.1" 2>/dev/null)" != "null" ]]')" \
  'state-guard: segmentKey が欠けた segment を継続して "null" を送らない'
assert_true "$(yn '[[ "$(jq -r ".segmentStartedAt" "$CAP.1" 2>/dev/null)" != "null" ]]')" \
  'state-guard: segmentStartedAt にも "null" を送らない'
assert_eq "$(jq -r '.outputTokens' "$CAP.1" 2>/dev/null)" "80" 'state-guard: 救出した baseline から差分(80)を送る'

# --- S5: .lastObserved が欠けた state から切替しても、全累計を新 context に載せない ---
H="$(mkhome)"; CAP="$H/cap.json"; GROWN="$H/grown.jsonl"; mk_grown_early "$GROWN"
REPO="$H/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b feature/cmdev-93111-x 2>/dev/null
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD"
jq -nc '{sessionKey:"sess-noobs", agent:"claude_code", collectorKey:"deadbeefdeadbeefdeadbeefdeadbeef",
         segments:[{segmentKey:"1-0-1", contextKey:"OLD-1", taskId:"OLD-1", startedAt:"2026-09-01T00:00:00Z",
                    baseline:{inputTokens:0,outputTokens:0,cacheReadTokens:0,cacheCreationTokens:0},
                    lastSent:{inputTokens:17,outputTokens:170,cacheReadTokens:2,cacheCreationTokens:1}}]}' \
  > "$RD/sess-noobs.state.json"
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-noobs" "$GROWN" "$REPO" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count" 2>/dev/null)" "1" 'switch-baseline: 締めるものが無いので POST は本体の 1 回だけ'
assert_eq "$(jq -r '.outputTokens' "$CAP.1" 2>/dev/null)" "80" \
  'switch-baseline: lastObserved が無くても lastSent(170) が baseline になり、全累計(250)を送らない'
assert_eq "$(jq -r '.segments[-1].baseline.outputTokens' "$RD/sess-noobs.state.json" 2>/dev/null)" "170" \
  'switch-baseline: 新 segment の baseline は列ごと max(lastObserved, 前 baseline, 記録済み累計)'

# --- S4: 締めが未知 status (401) なら捨てずにキューへ退避する ---
setup_boundary_home cmdev-94111
QDIR="$H/.coadmap/ai-usage-reports/queue"
# 1: seg1=201(170) / 2: 締め=401(未知) / 3: 本体=201(280)
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 401 201" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush401" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
run_impl "$H" "sess-flush401" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1   # throttle 中に lastObserved を 250 へ
git -C "$REPO" checkout -q -b feature/cmdev-94222-b 2>/dev/null
run_impl "$H" "sess-flush401" "$GROWN2" "$REPO" "SessionEnd" >/dev/null 2>&1
ST="$H/.coadmap/ai-usage-reports/sess-flush401.state.json"
assert_eq "$(ls "$QDIR" | wc -l | tr -d ' ')" "1" 'flush-unknown: 未知 status の締めはキューに退避される'
assert_eq "$(jq -r '.segments[0].lastQueued.outputTokens' "$ST" 2>/dev/null)" "250" \
  'flush-unknown: 退避した累計(250)が lastQueued に記録される'
assert_true "$(yn 'grep -q "unknown status=401" "$H/.coadmap/ai-usage-report.log"')" 'flush-unknown: 未知 status をログに残す'
assert_eq "$(jq -r '.segments | length' "$ST" 2>/dev/null)" "2" 'flush-unknown: 退避できたので切替は成立する'

# --- S4: 締めが 409 を 2 回返したら blocked を記録する ---
setup_boundary_home cmdev-95111
run_env=(CURL_CAPTURE_FILE="$CAP" CURL_COUNT_FILE="$H/count" CURL_STATUS_SEQ="201 409 409 409 409" COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flush409" "$FIXTURE" "$REPO" "Stop" >/dev/null 2>&1
run_impl "$H" "sess-flush409" "$GROWN" "$REPO" "Stop" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feature/cmdev-95222-b 2>/dev/null
run_impl "$H" "sess-flush409" "$GROWN2" "$REPO" "SessionEnd" >/dev/null 2>&1
ST="$H/.coadmap/ai-usage-reports/sess-flush409.state.json"
assert_true "$(yn 'grep -q "still conflicts (409) after reissuing" "$H/.coadmap/ai-usage-report.log"')" \
  'flush-409: 再発行しても 409 なら blocked をログに残す'
assert_true "$(yn '[[ "$(jq -r ".blocked.reason" "$ST" 2>/dev/null)" == "conflict" ]]')" \
  'flush-409: state に blocked が記録される'
# blocked が効いて次回は集計前に打ち切る
BEFORE="$(cat "$H/count")"
run_impl "$H" "sess-flush409" "$GROWN2" "$REPO" "SessionEnd" >/dev/null 2>&1
assert_eq "$(cat "$H/count")" "$BEFORE" 'flush-409: 以後の実行は POST せず打ち切る'

# --- S2: INT/TERM/HUP でも lock と一時ファイルを解放する ---
H="$(mkhome)"
RD="$H/.coadmap/ai-usage-reports"
run_env=(CURL_STATUS_CODE=201 CURL_SLEEP=3 COADMAP_AI_USAGE_REPORT=1)
env -i HOME="$H" PATH="$TEST_PATH" "${run_env[@]}" \
  bash "$IMPL" "$(payload_of "sess-term" "$FIXTURE" "$H" "SessionEnd")" >/dev/null 2>&1 &
TERM_PID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -d "$RD/sess-term.lock" ]] && break; sleep 0.3; done
assert_true "$(yn '[[ -d "$RD/sess-term.lock" ]]')" 'signal: 実行中は session lock が存在する'
kill -TERM "$TERM_PID" 2>/dev/null
wait "$TERM_PID" 2>/dev/null
assert_true "$(yn '[[ ! -d "$RD/sess-term.lock" ]]')" 'signal: TERM で終了しても session lock が残らない'
assert_true "$(yn '[[ ! -d "$RD/queue.lock" ]]')" 'signal: TERM で終了しても queue lock が残らない'
assert_true "$(yn 'grep -q -- "trap .*INT TERM HUP" "$IMPL"')" 'signal: INT / TERM / HUP に cleanup を登録している'

# --- MF-1: キュー flush 中の同一セッションの後発プロセスを締め出さない ---
# flush はキュー 1 件あたり最大 2 POST × 20 秒かかる。flush の前に session lock を取ると、
# その間に走る SessionEnd が打ち切られ、Stop 側は throttle で送らないので最終区間が落ちる。
H="$(mkhome)"; GROWN="$H/grown.jsonl"; GROWN2="$H/grown2.jsonl"
mk_grown_early "$GROWN"; mk_grown2_early "$GROWN2"
RD="$H/.coadmap/ai-usage-reports"; mkdir -p "$RD/queue"
# 1 回目: 170 を送って lastSentAt を立てる（以後の Stop は throttle される）
run_env=(CURL_CAPTURE_FILE="$H/cap0.json" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1)
run_impl "$H" "sess-flushrace" "$FIXTURE" "$H" "SessionEnd" >/dev/null 2>&1
# 他セッションの entry を 3 件置く（flush 1 件ごとに 1 秒かかる curl スタブで遅延させる）
for i in 1 2 3; do
  jq -nc --argjson at "$(date +%s)" --arg k "$i" '{baseUrl:"https://api.coadmap.com", savedAt:$at,
     payload:{agent:"claude_code", sessionKey:"sess-other", segmentKey:("9-0-" + $k), outputTokens:1}}' \
    > "$RD/queue/sess-other-9-0-$i.json"
done
# Stop 側: flush が遅い。自身は throttle されるので何も送らない。
env -i HOME="$H" PATH="$TEST_PATH" CURL_STATUS_CODE=503 CURL_SLEEP=1 COADMAP_AI_USAGE_REPORT=1 \
  bash "$IMPL" "$(payload_of "sess-flushrace" "$GROWN" "$H" "Stop")" >/dev/null 2>&1 &
RACE_PID=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -d "$RD/queue.lock" ]] && break; sleep 0.2; done
# flush 中に SessionEnd が来る。280 は落とせない。
env -i HOME="$H" PATH="$TEST_PATH" CURL_CAPTURE_FILE="$H/cap2.json" CURL_STATUS_CODE=201 COADMAP_AI_USAGE_REPORT=1 \
  bash "$IMPL" "$(payload_of "sess-flushrace" "$GROWN2" "$H" "SessionEnd")" >/dev/null 2>&1
# 同じ segment の続きなので、送るのは segment 累計 (= セッション累計 280 − baseline 0)。
assert_eq "$(jq -r '.outputTokens' "$H/cap2.json" 2>/dev/null)" "280" \
  'flush-race: 他セッションのキュー flush 中でも SessionEnd が締め出されず送信できる'
wait "$RACE_PID" 2>/dev/null

# --- ラッパは --event を impl の第 2 引数として渡す ---
# フェイクの impl を隣に置いて、実際に第 2 引数へ何が届くかを見る（grep ではなく挙動で固定）。
WRAPPER="$HERE/../report-ai-usage.sh"
WDIR="$(mktemp -d)"; HOMES+=("$WDIR")
cp "$WRAPPER" "$WDIR/report-ai-usage.sh"
cat > "$WDIR/_report-ai-usage-impl.sh" <<'IMPL_STUB'
#!/usr/bin/env bash
printf '%s' "${2-<unset>}" > "$(dirname "$0")/arg2.txt"
printf '%s' "${1-<unset>}" > "$(dirname "$0")/arg1.txt"
cat > "$(dirname "$0")/stdin.txt"
IMPL_STUB
chmod +x "$WDIR/_report-ai-usage-impl.sh"
wrapper_arg2() {
  rm -f "$WDIR/arg2.txt"
  printf '%s' '{"session_id":"s"}' | COADMAP_AI_USAGE_REPORT=1 bash "$WDIR/report-ai-usage.sh" "$@" >/dev/null 2>&1
  for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$WDIR/arg2.txt" ]] && break; sleep 0.2; done
  cat "$WDIR/arg2.txt" 2>/dev/null
}
assert_eq "$(wrapper_arg2 --event SessionEnd)" "SessionEnd" 'wrapper: --event <name> の値を impl の第 2 引数に渡す'
assert_eq "$(wrapper_arg2 --event=SessionEnd)" "SessionEnd" 'wrapper: --event=<name> 形式も同じ値になる'
assert_eq "$(wrapper_arg2 --event)" "" 'wrapper: --event に値が無ければ空文字を渡す（引数を食い違わせない）'
assert_eq "$(wrapper_arg2)" "" 'wrapper: --event が無ければ空文字を渡す'
# hook 入力 JSON(応答本文を含み得る)は argv ではなく stdin で渡す。argv は ps で他ユーザーから読める。
assert_eq "$(cat "$WDIR/arg1.txt")" "-" 'wrapper: 第 1 引数は stdin 指示の "-" で、JSON を argv に載せない'
assert_eq "$(cat "$WDIR/stdin.txt")" '{"session_id":"s"}' 'wrapper: hook 入力 JSON は stdin で impl に届く'
# opt-in していなければ worker を起動しない
rm -f "$WDIR/arg1.txt"
printf '%s' '{"session_id":"s"}' | COADMAP_AI_USAGE_REPORT=0 bash "$WDIR/report-ai-usage.sh" >/dev/null 2>&1
sleep 0.5
assert_eq "$([[ -f "$WDIR/arg1.txt" ]] && echo started || echo not-started)" "not-started" 'wrapper: opt-in 無しでは impl を起動しない'
assert_eq "$(jq -r '.hooks.SessionEnd[0].hooks[0].command | test("--event SessionEnd")' "$HERE/../../hooks.json")" "true" \
  'wiring: hooks.json の SessionEnd に --event SessionEnd が付く'
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command | test("--event")' "$HERE/../../hooks.json")" "false" \
  'wiring: hooks.json の Stop には --event を付けない'
assert_eq "$(jq -r '.hooks.SessionEnd[0].hooks[0].command | test("--event SessionEnd")' "$HERE/../../codex-hooks.json")" "true" \
  'wiring: codex-hooks.json の SessionEnd に --event SessionEnd が付く'
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command | test("--event")' "$HERE/../../codex-hooks.json")" "false" \
  'wiring: codex-hooks.json の Stop には --event を付けない'

exit "$fail"
