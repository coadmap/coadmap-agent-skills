#!/usr/bin/env bash
# coadmap-task-workflow: 外部AIエージェント トークン使用量自己申告 の本処理
#
# Claude Code SessionEnd hook / Codex Stop hook から `report-ai-usage.sh` 経由で
# バックグラウンド起動される。デバッグ用に第1引数に JSON 文字列を与えれば手動でも実行できる。
#
# --- 代表モデルの決定方針 ---------------------------------------------------
# transcript (JSONL) の各行は `type == "assistant"` のとき `message.id` /
# `message.model` / `message.usage.{input_tokens,output_tokens,
# cache_creation_input_tokens,cache_read_input_tokens}` を持つ。同一の
# assistant message が resume/compaction 等で複数行に重複して出現するため、
# **message.id 単位で dedupe（同一 id は最後の行を採用）してから集計する**。
# dedupe しないとトークン量が実際の数倍に過大計上される（実測で約2.9倍）。
# `isSidechain: true` の行も同一セッションで実際に消費されたトークンなので
# 除外せず含める。
# セッションの代表モデルは「dedupe 後、モデルごとに output_tokens を合算し、
# 合計が最大のモデル」とする（＝そのセッションで最もトークンを消費したモデル）。
#
# --- 送信先の選定理由 --------------------------------------------------------
# MCP ツール `report_coadmap_ai_usage` ではなく BE の REST エンドポイントを
# bash から直接 curl で叩く。bash hook から streamable-http の MCP セッション
# （初期化ハンドシェイク・SSE）を張るのは非現実的で、同じ理由で
# Coadmap の他の hook 群も REST を直接叩いており、本 hook もその前例に倣う。
set -uo pipefail

INPUT_JSON="${1:-}"

# --- opt-in ゲート -----------------------------------------------------------
# 明示的に COADMAP_AI_USAGE_REPORT=1 が設定されていない限り、ログファイルの作成すら含めて
# 一切何もしない。MCP 接続はタスク管理のために入れたものであってテレメトリのためではないので、
# 接続をもって送信の同意とみなすのは越権になる。有効化の判断は実行者側に残す。
# ログを出さないのも意図的で、有効化していない環境に痕跡を残さない。
if [[ "${COADMAP_AI_USAGE_REPORT:-0}" != "1" ]]; then
  exit 0
fi

LOG_DIR="$HOME/.coadmap"
LOG_FILE="$LOG_DIR/ai-usage-report.log"
REPORT_DIR="$LOG_DIR/ai-usage-reports"
mkdir -p "$LOG_DIR" "$REPORT_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# --- discover_coadmap_creds ---------------------------------------------------
# Coadmap の他の hook 群と同じ探索ロジック。
# 同じ環境変数名 (COADMAP_API_TOKEN / COADMAP_API_URL) ・同じ探索順を使う
# （新しい規約を作らない）。Claude Code の MCP 設定 (`~/.claude.json`) から
# Coadmap MCP の認証情報を取り出し、env が未設定の場合のみ補う。
discover_coadmap_creds() {
  if [[ -n "${COADMAP_API_TOKEN:-}" && -n "${COADMAP_API_URL:-}" ]]; then
    return 0
  fi

  # サーバー名は利用者が自由に付けるので固定名では探さない。user スコープと project スコープの
  # mcpServers を全部なめて、名前か url に coadmap を含むものを候補にする。
  local cfg name entry token mcp_url be_url
  cfg="$HOME/.claude.json"
  [[ -f "$cfg" ]] || return 0
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == "null" ]] && continue
    name="$(printf '%s' "$entry" | jq -r '.name // empty' 2>/dev/null)"

    token="$(printf '%s' "$entry" \
      | jq -r '.headers.Authorization // .env.COADMAP_API_TOKEN // empty' 2>/dev/null \
      | sed 's/^Bearer //')"
    [[ -z "$token" || "$token" == "null" ]] && continue

    mcp_url="$(printf '%s' "$entry" \
      | jq -r '.url // .env.COADMAP_API_URL // empty' 2>/dev/null)"

    case "$mcp_url" in
      *mcp-dev.coadmap.net*) be_url="https://api-dev.coadmap.com" ;;
      *mcp.coadmap.net*)     be_url="https://api.coadmap.com" ;;
      http*)                 be_url="$mcp_url" ;;
      *)
        case "$name" in
          *dev*) be_url="https://api-dev.coadmap.com" ;;
          *)     be_url="https://api.coadmap.com" ;;
        esac
        ;;
    esac

    [[ -z "${COADMAP_API_TOKEN:-}" ]] && export COADMAP_API_TOKEN="$token"
    [[ -z "${COADMAP_API_URL:-}" ]] && export COADMAP_API_URL="$be_url"
    return 0
  done < <(jq -c '
    [ (.mcpServers // {}), ((.projects // {}) | .[]? | .mcpServers // {}) ]
    | map(to_entries[]) | .[]
    | select((.key | test("coadmap"; "i")) or ((.value.url // "") | test("coadmap"; "i")))
    | .value + {name: .key}
  ' "$cfg" 2>/dev/null || true)
}

# --- 0. jq が無ければ黙って終了 ---------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# --- 1. 認証情報チェック ------------------------------------------------------
discover_coadmap_creds
if [[ -z "${COADMAP_API_TOKEN:-}" || -z "${COADMAP_API_URL:-}" ]]; then
  log "skip: COADMAP_API_TOKEN or COADMAP_API_URL missing (and could not auto-discover from MCP config)"
  exit 0
fi

# origin (scheme://host[:port]) だけを取り出す。perl 等の外部コマンドに依存させない。
BASE_URL=""
case "$COADMAP_API_URL" in
  http://*|https://*)
    _rest="${COADMAP_API_URL#*://}"
    BASE_URL="${COADMAP_API_URL%%"${_rest}"*}${_rest%%/*}"
    ;;
esac
if [[ -z "$BASE_URL" ]]; then
  log "skip: failed to extract origin from COADMAP_API_URL=$COADMAP_API_URL"
  exit 0
fi

if [[ -z "$INPUT_JSON" ]]; then
  log "skip: no hook input JSON"
  exit 0
fi

# --- 2. hook 入力をパース ---------------------------------------------------
SESSION_ID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
HOOK_EVENT_NAME="$(printf '%s' "$INPUT_JSON" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT_JSON" | jq -r '.cwd // empty' 2>/dev/null || true)"

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  log "skip: transcript not found ($TRANSCRIPT_PATH)"
  exit 0
fi

# SESSION_ID は .done / .lock のファイル名になるので、パスとして安全な形だけ通す。
# 外れた場合は二重投稿ガードが効かないため、送信自体を諦める (誤って多重計上するより送らない)。
if [[ -n "$SESSION_ID" && ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log "skip: unexpected session_id format, refusing to use it as a path component"
  exit 0
fi
if [[ -z "$SESSION_ID" ]]; then
  log "skip: no session_id (idempotency key is required; BE upserts on it)"
  exit 0
fi

# エージェント判定。Codex は Stop で配線しているが、将来 SessionEnd に寄せた時にも
# 壊れないよう、イベント名より transcript 自体の形式を優先する:
#   - Codex の rollout log は先頭行が session_meta レコード
#   - 置き場が ~/.codex/ 配下 (CODEX_HOME を変えていると当てにならないので補助)
# どちらにも当たらなければイベント名で決める。
if head -c 4096 "$TRANSCRIPT_PATH" 2>/dev/null | head -1 | grep -q '"session_meta"'; then
  AGENT="codex"
else
  case "$TRANSCRIPT_PATH" in
    */.codex/*) AGENT="codex" ;;
    *)
      case "$HOOK_EVENT_NAME" in
        SessionEnd) AGENT="claude_code" ;;
        Stop)       AGENT="codex" ;;
        *)          AGENT="other" ;;
      esac
      ;;
  esac
fi

# --- 3. 二重投稿ガード（アトミック claim）------------------------------------
# SessionEnd と Stop の両方が同一セッションで走り得るため必須。
# .done = 送信済みの永続マーカー、.lock = 実行中の一時 claim（mkdir のアトミック性で排他）。
#
# .done は「送信済み」フラグではなく前回送信した output トークン数の記録にする。
# BE 側は加算せず上書きする upsert なので、同一 session_id のまま作業が続いた場合
# (/clear や --resume) に再送しないと、最初の時点の部分累計が最終値として固定されてしまう。
# 値が増えていれば送り直し、増えていなければ送らない (値ベースなので session_id が
# 維持されてもされなくても正しく動く)。増減の判定は集計後に行う。
SESSION_LOCK=""
if [[ -n "$SESSION_ID" ]]; then
  # 前回の SIGKILL 等で残った stale lock を掃除してから claim する。
  find "$REPORT_DIR" -maxdepth 1 -name "$SESSION_ID.lock" -type d -mmin +15 -exec rmdir {} + 2>/dev/null || true
  if ! mkdir "$REPORT_DIR/$SESSION_ID.lock" 2>/dev/null; then
    log "skip: another instance holds lock for session $SESSION_ID"
    exit 0
  fi
  SESSION_LOCK="$REPORT_DIR/$SESSION_ID.lock"
  trap 'rmdir "$SESSION_LOCK" 2>/dev/null || true' EXIT
fi

# --- 4. transcript を集計（message.id で dedupe。isSidechain も含める）------
# 1段目: 行ごとに fromjson を試み、パース不能行（末尾切断など）は静かに捨てる。
# 2段目: 配列化して message.id で group_by → 各グループの最後の行を採用 → 集計。
# recordCount は dedupe 後の assistant message 数。0 なら「この transcript は
# Claude Code 形式ではない」= 形式未対応であって「使用量が 0 だった」ではないので、
# 両者を後段で区別して扱う。
USAGE_JSON="$(
  jq -R -c 'fromjson? // empty | select(type == "object")' "$TRANSCRIPT_PATH" 2>>"$LOG_FILE" \
    | jq -cs '
        map(select(.type == "assistant" and (.message.id? != null) and (.message.usage? != null)))
        | group_by(.message.id)
        | map(.[-1])
        | {
            recordCount: length,
            inputTokens: ([ .[].message.usage.input_tokens // 0 ] | add // 0),
            outputTokens: ([ .[].message.usage.output_tokens // 0 ] | add // 0),
            cacheCreationTokens: ([ .[].message.usage.cache_creation_input_tokens // 0 ] | add // 0),
            cacheReadTokens: ([ .[].message.usage.cache_read_input_tokens // 0 ] | add // 0),
            modelName: (
              (group_by(.message.model)
                | map({model: .[0].message.model, out: ([ .[].message.usage.output_tokens // 0 ] | add // 0)})
                | sort_by(.out)
                | last
              ) as $top
              | ($top.model // "unknown")
            )
          }
      ' 2>>"$LOG_FILE"
)"

if [[ -z "$USAGE_JSON" ]]; then
  log "skip: usage aggregation failed (session=$SESSION_ID)"
  exit 0
fi

RECORD_COUNT="$(printf '%s' "$USAGE_JSON" | jq -r '.recordCount // 0')"
INPUT_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.inputTokens // 0')"
OUTPUT_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.outputTokens // 0')"
CACHE_CREATION_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.cacheCreationTokens // 0')"
CACHE_READ_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.cacheReadTokens // 0')"
MODEL_NAME="$(printf '%s' "$USAGE_JSON" | jq -r '.modelName // "unknown"')"

# jq が数値以外を返した場合も 0 扱いにして、以降の数値比較を壊さない。
for _v in RECORD_COUNT INPUT_TOKENS OUTPUT_TOKENS CACHE_CREATION_TOKENS CACHE_READ_TOKENS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || printf -v "$_v" '%s' 0
done

# transcript の形式を判別する。usage を持つ assistant レコードが 1 件も無いのは
# 「使わなかった」ではなく「この形式を読めていない」であって、0 のレポートを送ると
# ai_tokens_total に「使ったが 0 トークン」という嘘のレコードが残る。
# Codex の rollout log (~/.codex/sessions) は現状ここで止まる。
if [[ "$RECORD_COUNT" -eq 0 ]]; then
  log "skip: unsupported transcript format (no Claude Code style assistant usage records in $TRANSCRIPT_PATH; session=$SESSION_ID agent=$AGENT). Codex rollout logs are not supported yet."
  exit 0
fi

# 形式は読めたが集計が 0 出力トークンになるセッション (中身の無いセッション等) も送らない。
# 送っても計測上の意味が無く、0 のレコードが平均値を歪める。
if [[ "$OUTPUT_TOKENS" -eq 0 ]]; then
  log "skip: aggregated outputTokens=0, refusing to send an empty usage report (session=$SESSION_ID records=$RECORD_COUNT)"
  exit 0
fi

# --- 4b. 前回送信値との比較（S3: 値ベースの再送判定）--------------------------
# transcript から読む値はそのセッションの累計なので、前回より増えていなければ送る意味が無い。
LAST_SENT_OUTPUT=0
if [[ -f "$REPORT_DIR/$SESSION_ID.done" ]]; then
  LAST_SENT_OUTPUT="$(jq -r '.outputTokens // 0' "$REPORT_DIR/$SESSION_ID.done" 2>/dev/null || echo 0)"
  [[ "$LAST_SENT_OUTPUT" =~ ^[0-9]+$ ]] || LAST_SENT_OUTPUT=0
fi
if [[ "$OUTPUT_TOKENS" -le "$LAST_SENT_OUTPUT" ]]; then
  log "skip: no new usage since last report (session=$SESSION_ID last=$LAST_SENT_OUTPUT current=$OUTPUT_TOKENS)"
  exit 0
fi

# --- 5. taskId（分かる場合のみ・best-effort）---------------------------------
# detect-task-id.sh が UserPromptSubmit 時に残すマーカー
# (${TMPDIR}/coadmap-task-workflow/<session>.injected) は「タスクが検出された」
# という bool フラグのみで、実際の displayId 文字列は保持していないため再利用できない。
# 同ディレクトリの extract-task-id.sh（chat prompt からの抽出用）も試したが、
# 偽陽性対策で「prefix が英大文字のみ、またはアンダースコアを含む」場合しか
# マッチしない仕様のため、このリポの実際のブランチ命名（例:
# `feature/cmdev-10660-...` のような小文字 displayId）を取りこぼす。
# そのため、coadmap-session-recorder の _save-session-impl.sh が使っている
# ブランチ名からの抽出（大文字小文字を問わない単純な displayId 正規表現）を
# 同じ形でここでも用いる。
TASK_ID=""
if [[ -n "$CWD" && -d "$CWD" ]]; then
  BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
  if [[ -n "$BRANCH" ]]; then
    TASK_ID="$(printf '%s' "$BRANCH" | grep -oE '[A-Za-z][A-Za-z0-9_]+-[0-9]+' | head -1 || true)"
  fi
fi

# BE の displayId 解決 (Task.find_by_id_or_display_id!) は workspace 名を
# `find_by!(name: ...)` で引くため大小文字を区別する。ブランチ名は慣例上小文字
# (feature/cmdev-10660-...) なので、verbatim だけだと workspace 名 `CMDEV` に一致せず
# 必ず 404 になる。coadmap-session-recorder が同じ問題を verbatim → 大文字化 の順で
# 解決しているので、同じ形に揃える。
TASK_ID_UPPER="$(printf '%s' "$TASK_ID" | tr '[:lower:]' '[:upper:]')"
TASK_ID_CANDS=()
[[ -n "$TASK_ID" ]] && TASK_ID_CANDS+=("$TASK_ID")
[[ -n "$TASK_ID" && "$TASK_ID_UPPER" != "$TASK_ID" ]] && TASK_ID_CANDS+=("$TASK_ID_UPPER")

# --- 6. payload 組み立て・送信 ------------------------------------------------
# 送るキーはここに並ぶものが全て。transcript の本文は一切載せない。
build_payload() {
  jq -nc \
    --arg agent "$AGENT" \
    --arg modelName "$MODEL_NAME" \
    --argjson inputTokens "${INPUT_TOKENS:-0}" \
    --argjson outputTokens "${OUTPUT_TOKENS:-0}" \
    --argjson cacheReadTokens "${CACHE_READ_TOKENS:-0}" \
    --argjson cacheCreationTokens "${CACHE_CREATION_TOKENS:-0}" \
    --arg sessionKey "$SESSION_ID" \
    --arg taskId "${1:-}" \
    '{
       agent: $agent,
       modelName: $modelName,
       inputTokens: $inputTokens,
       outputTokens: $outputTokens,
       cacheReadTokens: $cacheReadTokens,
       cacheCreationTokens: $cacheCreationTokens,
       sessionKey: $sessionKey
     } + (if $taskId != "" then {taskId: $taskId} else {} end)'
}

# 応答本文の置き場は mktemp で取る。固定パスだと並行セッション同士で踏み合い、
# /tmp の予測可能なパスを掴むことにもなる。
RESP_FILE="$(mktemp -t coadmap-ai-usage-report.XXXXXX 2>/dev/null || echo /dev/null)"
[[ "$RESP_FILE" != "/dev/null" ]] && trap 'rm -f "$RESP_FILE"; [[ -n "$SESSION_LOCK" ]] && rmdir "$SESSION_LOCK" 2>/dev/null || true' EXIT

# --max-time を付けないと、応答しない相手にぶら下がったまま常駐し得る
# (detach 済みでエージェントは止めないが、プロセスが残り続ける)。
# Authorization を curl の argv に置かない。argv は ps auxww / /proc/<pid>/cmdline から
# 同一ホストの他ユーザーに平文で読める (Linux では /proc/*/cmdline は既定で world-readable)。
# --config で stdin からヘッダを渡せば argv に出ない。
post_report() {
  printf 'header = "Authorization: Bearer %s"\n' "$COADMAP_API_TOKEN" \
    | curl -sS --max-time 20 -o "$RESP_FILE" -w '%{http_code}' \
        --config - \
        -X POST "$BASE_URL/api/internal/mcp/external_ai_usage_reports" \
        -H "Content-Type: application/json" \
        --data "$1" || echo "000"
}

# taskId はブランチ名からの best-effort 推定なので、BE が解決できず 404 を返し得る。
# 候補 (verbatim → 大文字化) を順に試し、どれも駄目なら taskId を落として送る。
# 主目的は使用量の記録でタスク紐付けは付随情報なので、紐付けのために使用量ごと捨てない。
SENT_TASK_ID=""
# 空 = まだ 1 度も送っていない。"000" (curl 自体の失敗) と区別する必要がある:
# taskId 候補が無い場合はループ本体が回らないので、初期値を "000" にすると
# 「送っていない」が「タイムアウトした」と誤判定される
HTTP_STATUS=""
for cand in "${TASK_ID_CANDS[@]:-}"; do
  [[ -z "$cand" ]] && continue
  PAYLOAD="$(build_payload "$cand")"
  HTTP_STATUS="$(post_report "$PAYLOAD")"
  if [[ "$HTTP_STATUS" != "404" ]]; then
    SENT_TASK_ID="$cand"
    break
  fi
  log "retry: taskId=$cand unresolved (404) (session=$SESSION_ID)"
done

# 000 (curl 自体の失敗 = 主にタイムアウト) は 404 と別に扱う。サーバ側で commit 済みだった
# 場合に taskId 無しで再送すると、成功していた紐付けを NULL に上書きしてしまう。
# 「解決できなかった」ことが確実な 404 のときだけ taskId を落として送り直す。
if [[ -z "$HTTP_STATUS" || "$HTTP_STATUS" == "404" ]]; then
  PAYLOAD="$(build_payload "")"
  HTTP_STATUS="$(post_report "$PAYLOAD")"
  SENT_TASK_ID=""
fi

if [[ "$HTTP_STATUS" == "000" ]]; then
  log "abort: request failed before a status was returned (timeout?). Not resending without taskId, \
because the server may have committed it (session=$SESSION_ID)"
  exit 0
fi

if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  log "abort: POST failed (status=$HTTP_STATUS, session=$SESSION_ID, agent=$AGENT)"
  exit 0
fi

# .done には送信済みの累計を残す。次回はこの値と比較して、増えていれば送り直す
# (BE は加算せず上書きするので、送り直しても二重計上にならない)。
jq -nc --argjson outputTokens "${OUTPUT_TOKENS:-0}" --arg reportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{outputTokens: $outputTokens, reportedAt: $reportedAt}' \
  >"$REPORT_DIR/$SESSION_ID.done" 2>/dev/null || true
log "ok: reported usage (agent=$AGENT model=$MODEL_NAME in=$INPUT_TOKENS out=$OUTPUT_TOKENS cacheRead=$CACHE_READ_TOKENS cacheCreate=$CACHE_CREATION_TOKENS session=$SESSION_ID task=${SENT_TASK_ID:-none})"
exit 0
