#!/usr/bin/env bash
# coadmap-task-workflow: 外部AIエージェント トークン使用量自己申告 の本処理
#
# Claude Code / Codex の hook から `report-ai-usage.sh` 経由でバックグラウンド起動される。
# デバッグ用に第1引数に JSON 文字列を与えれば手動でも実行できる。
#
# --- transcript 形式の判別 ---------------------------------------------------
# hook イベント名ではなく transcript の中身で判別する。Claude Code / Codex の双方が
# SessionEnd と Stop の両方を発火し得るので、イベント名で agent を決めると取り違える。
#   * `type=="assistant"` かつ `.message.usage` を持つ行がある → Claude Code
#   * `type=="session_meta"` の行がある                        → Codex rollout log
#   * どちらでもない                                           → 未対応（送らない）
#
# --- Claude Code の集計方針 --------------------------------------------------
# 同一の assistant message が resume/compaction 等で複数行に重複して出現するため、
# **message.id 単位で dedupe（同一 id は最後の行を採用）してから集計する**。
# dedupe しないとトークン量が実際の数倍に過大計上される（実測で約2.9倍）。
# `isSidechain: true` の行も同一セッションで実際に消費されたトークンなので含める。
# 代表モデルは「dedupe 後、モデルごとに output_tokens を合算して最大のモデル」。
#
# --- Codex の集計方針 --------------------------------------------------------
# rollout log は 1 行 `{"timestamp","type","payload"}`。
#   * session id : **先頭の** session_meta 行の payload.id
#                  (subagent のファイルは 2 行目に親の session_meta が入る)
#   * model      : turn_context 行の payload.model の最頻値（同数なら最後）
#   * token      : event_msg 行の payload.type=="token_count" かつ info != null の
#                  payload.info.total_token_usage が**セッション累計**。各列の max を採る。
#   * 列対応     : inputTokens = input_tokens - cached_input_tokens
#                  (OpenAI の input_tokens は cached を含む)
#                  cacheReadTokens = cached_input_tokens
#                  cacheCreationTokens = cache_write_input_tokens
#                  outputTokens = output_tokens (reasoning_output_tokens 込み。別加算しない)
#
# --- segment 方式 ------------------------------------------------------------
# 1 セッションの中でも作業対象（ブランチ由来の Coadmap タスク）は切り替わる。
# セッション累計をそのまま送ると、切り替え後のタスクに切り替え前の消費まで乗る。
# そこで「同じ contextKey で連続している区間」を segment とし、
#   送信するトークン = セッション累計 − segment 開始時点の累計 (tokenBaseline)
# として区間ぶんだけを送る。BE は (namespace, account, agent, sessionKey, segmentKey)
# を GREATEST で単調 upsert するので、同じ payload の再送は二重計上にならない。
#
# --- 送信先の選定理由 --------------------------------------------------------
# MCP ツールではなく BE の REST エンドポイントを bash から直接 curl で叩く。
# bash hook から streamable-http の MCP セッション（初期化ハンドシェイク・SSE）を
# 張るのは非現実的なため。
set -uo pipefail

# 第 1 引数が `-` なら stdin から読む (hook 経由の通常経路)。JSON を直接渡す形は
# デバッグ・テスト用に残すが、応答本文を含み得る入力を argv に載せないため hook では使わない。
INPUT_JSON="${1:-}"
if [[ "$INPUT_JSON" == "-" ]]; then
  INPUT_JSON="$(cat 2>/dev/null || true)"
fi
# 第 2 引数は hook イベント名の既定値 (`--event <name>` / `--event=<name>` / 素の名前)。
# stdin の `hook_event_name` が空のときだけ採用する。
case "${2:-}" in
  --event)   ARG_EVENT_NAME="${3:-}" ;;
  --event=*) ARG_EVENT_NAME="${2#--event=}" ;;
  *)         ARG_EVENT_NAME="${2:-}" ;;
esac

# --- opt-in ゲート -----------------------------------------------------------
# 明示的に COADMAP_AI_USAGE_REPORT=1 が設定されていない限り、ログファイルの作成すら含めて
# 一切何もしない（再送キューの flush も含む）。MCP 接続はタスク管理のために入れたもので
# あってテレメトリのためではないので、接続をもって送信の同意とみなすのは越権になる。
if [[ "${COADMAP_AI_USAGE_REPORT:-0}" != "1" ]]; then
  exit 0
fi

# --- 0. jq が無ければ黙って終了 ---------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# ログ・状態・キューは自分だけが読めれば十分。他ユーザーに晒さない。
umask 077

# 環境から同名の変数を継承しても挙動が変わらないよう、内部状態は無条件に初期化する。
NEW_SEGMENT=0
LOCKED_SESSION_ID=""
STATE=""
SEGMENT_KEY=""
SEGMENT_STARTED_AT=""
SEGMENT_BASELINE=""
SALVAGED_BASELINE=""
SEGMENT_LAST_SENT="null"
SEGMENT_LAST_QUEUED="null"
SEGMENT_LAST_SENT_AT=0
SEGMENT_LAST_ATTEMPT_AT=0
PREV_SEGMENT_KEY=""
PREV_STARTED_AT=""
PREV_BASELINE=""
PREV_TASK_ID=""
PREV_CONTEXT_KEY=""
PREV_TOKENS=""
PREV_LAST_SENT="null"
PREV_LAST_QUEUED="null"
APPENDED_SEGMENT_KEY=""
APPENDED_SEGMENT_STARTED_AT=""
TASK_ID=""
PAYLOAD_TASK_ID=""
SENT_TASK_ID=""

LOG_DIR="$HOME/.coadmap"
LOG_FILE="$LOG_DIR/ai-usage-report.log"
REPORT_DIR="$LOG_DIR/ai-usage-reports"
QUEUE_DIR="$REPORT_DIR/queue"
mkdir -p "$LOG_DIR" "$REPORT_DIR" "$QUEUE_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf ''
  fi
}

# --- 1. hook 入力をパース -----------------------------------------------------
# 認証情報の探索が hook 入力の cwd（project scope の `.mcp.json`）を見るので、
# creds 解決より前に読む。
if [[ -z "$INPUT_JSON" ]]; then
  log "skip: no hook input JSON"
  exit 0
fi

STDIN_SESSION_ID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT_JSON" | jq -r '.cwd // empty' 2>/dev/null || true)"
STDIN_MODEL="$(printf '%s' "$INPUT_JSON" | jq -r '.model // empty' 2>/dev/null || true)"
HOOK_EVENT_NAME="$(printf '%s' "$INPUT_JSON" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
# stdin にイベント名が乗らない実装 (Codex 等) では、hook の配線から渡された名前を使う。
[[ -z "$HOOK_EVENT_NAME" ]] && HOOK_EVENT_NAME="$ARG_EVENT_NAME"

# --- 2. 認証情報の解決 --------------------------------------------------------
# 探索順:
#   1. env COADMAP_API_TOKEN + COADMAP_API_URL
#   2. Claude Code の MCP OAuth (~/.claude/.credentials.json / macOS keychain)
#   3. MCP 設定に直書きされた ApiKey ヘッダ
#   4. Codex の ~/.codex/config.toml の http_headers.Authorization / bearer_token_env_var
# 本番で 0 件しか届いていなかった主因が「OAuth 接続だと 3 に何も無い」ことなので、
# 2 を 3 より先に見る。
COADMAP_MCP_HOSTS_RE='^(mcp|mcp-dev)\.coadmap\.(com|net)$'

# mcp ホスト → BE の API ホスト
be_url_for_host() {
  case "$1" in
    mcp-dev.coadmap.com|mcp-dev.coadmap.net) printf 'https://api-dev.coadmap.com' ;;
    mcp.coadmap.com|mcp.coadmap.net)         printf 'https://api.coadmap.com' ;;
    *)                                       printf '' ;;
  esac
}

url_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  printf '%s' "${rest%%:*}"
}

# dev を優先するか (COADMAP_AI_USAGE_TARGET=dev)。既定は prod 優先。
preferred_rank() {
  case "$1" in
    mcp-dev.coadmap.com|mcp-dev.coadmap.net)
      [[ "${COADMAP_AI_USAGE_TARGET:-}" == "dev" ]] && printf '0' || printf '1' ;;
    *)
      [[ "${COADMAP_AI_USAGE_TARGET:-}" == "dev" ]] && printf '1' || printf '0' ;;
  esac
}

# フィールド区切りは U+001F (unit separator)。タブは IFS の空白扱いなので、
# 連続する区切り (= 空フィールド) が `read` で潰れて値が 1 つずれる。
FS_SEP=$'\x1f'

# ~/.claude.json / ~/.claude/settings.json から
# 「coadmap の MCP サーバ」エントリを `<scopeRank>/<serverName>/<host>/<inlineToken>` で列挙する。
# scopeRank は user=0 / local=1 / repo(.mcp.json)=2。採用側はこれを第 1 キーにするので、
# 上位 scope に候補があるかぎり repo scope の設定は選ばれない。
list_coadmap_mcp_servers() {
  # Claude Code の MCP 設定は 3 スコープある。user scope は `.mcpServers` だが、
  # **local scope は `~/.claude.json` の `.projects.<cwd>.mcpServers` に入る**ので、
  # top-level だけを見ると `claude mcp add` の既定 (local) で繋いだ接続を丸ごと見落とす。
  # project scope は repo 直下の `.mcp.json`。3 つとも列挙する。
  # scope の優先順位は user scope → local scope → repo の .mcp.json。
  # repo 由来の設定は他人が書き換え得るので最後に置く。
  local cfg scope srank
  for scope in user local; do
    if [[ "$scope" == "user" ]]; then srank=0; else srank=1; fi
    for cfg in "$HOME/.claude.json" "$HOME/.claude/settings.json"; do
      [[ -f "$cfg" ]] || continue
      jq -r --arg scope "$scope" --arg srank "$srank" '
        def entries($m):
          ($m // {}) | to_entries[]
          | select((.value.type // "http") == "http")
          | [ $srank,
              .key,
              ((.value.url // .value.env.COADMAP_API_URL // "") | capture("^[a-z]+://(?<h>[^/:]+)").h? // ""),
              ((.value.headers.Authorization // .value.env.COADMAP_API_TOKEN // "") | sub("^Bearer +"; ""))
            ]
          | select(.[2] | test("^(mcp|mcp-dev)\\.coadmap\\.(com|net)$"))
          | join("\u001f");
        if $scope == "user" then entries(.mcpServers)
        else ((.projects // {}) | to_entries[] | entries(.value.mcpServers)) end
      ' "$cfg" 2>/dev/null || true
    done
  done
  # project scope: 作業ディレクトリ直下と、git リポジトリのルート直下の .mcp.json
  local proj_dirs=() d toplevel
  [[ -n "${CWD:-}" ]] && proj_dirs+=("$CWD")
  if [[ -n "${CWD:-}" && -d "$CWD" ]]; then
    toplevel="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$toplevel" && "$toplevel" != "$CWD" ]] && proj_dirs+=("$toplevel")
  fi
  for d in ${proj_dirs[@]+"${proj_dirs[@]}"}; do
    [[ -f "$d/.mcp.json" ]] || continue
    jq -r '
      (.mcpServers // {}) | to_entries[]
      | select((.value.type // "http") == "http")
      | [ "2",
          .key,
          ((.value.url // .value.env.COADMAP_API_URL // "") | capture("^[a-z]+://(?<h>[^/:]+)").h? // ""),
          ((.value.headers.Authorization // .value.env.COADMAP_API_TOKEN // "") | sub("^Bearer +"; ""))
        ]
      | select(.[2] | test("^(mcp|mcp-dev)\\.coadmap\\.(com|net)$"))
      | join("\u001f")
    ' "$d/.mcp.json" 2>/dev/null || true
  done
}

# Claude Code の OAuth 資格情報ストアを JSON で取り出す。
read_claude_credentials() {
  local f="$HOME/.claude/.credentials.json"
  if [[ -f "$f" ]]; then
    cat "$f" 2>/dev/null
    return 0
  fi
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true
  fi
}

# Codex の ~/.codex/config.toml から [mcp_servers.<name>] を簡易パースし、
# `<host>/<token>/<tokenEnvVar>` (U+001F 区切り) を列挙する。セクション境界を正しく扱う。
list_codex_mcp_servers() {
  local f="$HOME/.codex/config.toml"
  [[ -f "$f" ]] || return 0
  # `[mcp_servers.<name>]` の url / Authorization / bearer_token_env_var だけを拾う簡易パーサ。
  # `http_headers = { Authorization = "..." }` のインライン表と
  # `[mcp_servers.<name>.http_headers]` のセクション表の両方を扱えるよう、
  # サーバ名でまとめてから最後にまとめて出力する（セクション境界で値を落とさない）。
  awk -v SEP="$FS_SEP" '
    function qval(s) {
      if (match(s, /"[^"]*"/)) return substr(s, RSTART + 1, RLENGTH - 2)
      return ""
    }
    # キー自体がクォートされている形 (`"Authorization" = "Bearer x"`) では、最初の
    # クォート文字列はキー名になる。`=` より右側の最初のクォート文字列を値とする。
    function rhs_qval(s,   i) {
      i = index(s, "Authorization")
      if (i > 0) s = substr(s, i + length("Authorization"))
      i = index(s, "=")
      if (i > 0) s = substr(s, i + 1)
      return qval(s)
    }
    # 行頭が # の行は TOML のコメント行なので、内容を見る前に捨てる。
    # 値のクォート内に現れる # は行頭には来ないので、この判定では巻き込まない。
    # これが無いと、下の「トークンを持つ行は触らない」規則が
    # `# Authorization = "Bearer OLD"` のようなコメントアウト行を live な資格情報として拾う。
    /^[ \t]*#/ { next }
    # コメント除去。ただしトークンを持つ行はクォート内の # を潰しかねないので触らない。
    { if ($0 !~ /Authorization/ && $0 !~ /bearer_token_env_var/) sub(/#.*$/, "", $0) }
    /^[ \t]*\[/ {
      line = $0
      gsub(/^[ \t]*\[+|\]+[ \t]*$/, "", line)
      gsub(/[ \t"]/, "", line)
      cur = ""
      in_env_headers = 0
      if (line ~ /^mcp_servers\./) {
        split(line, a, ".")
        cur = a[2]
        if (line ~ /\.env_http_headers$/) in_env_headers = 1
        if (!(cur in seen)) { seen[cur] = 1; order[++n] = cur }
      }
      next
    }
    cur == "" { next }
    /^[ \t]*url[ \t]*=/ { url[cur] = qval($0); next }
    # env_http_headers は「ヘッダ値」ではなく「環境変数名」を持つ。先に判定しないと
    # 変数名そのものを Bearer として送ってしまう。
    /env_http_headers/ && /"?Authorization"?[ \t]*=/ { envvar[cur] = rhs_qval($0); next }
    in_env_headers && /"?Authorization"?[ \t]*=/     { envvar[cur] = rhs_qval($0); next }
    /"?Authorization"?[ \t]*=/ { v = rhs_qval($0); sub(/^Bearer +/, "", v); auth[cur] = v; next }
    /bearer_token_env_var[ \t]*=/ { envvar[cur] = qval($0); next }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (url[k] == "") continue
        host = url[k]
        sub(/^[a-z]+:\/\//, "", host)
        sub(/[\/:].*$/, "", host)
        printf "%s%s%s%s%s\n", host, SEP, auth[k], SEP, envvar[k]
      }
    }
  ' "$f" 2>/dev/null || true
}

RESOLVED_TOKEN=""
RESOLVED_BASE_URL=""
CREDS_SOURCE=""

discover_coadmap_creds() {
  # 1. env
  if [[ -n "${COADMAP_API_TOKEN:-}" && -n "${COADMAP_API_URL:-}" ]]; then
    if [[ ! "$COADMAP_API_URL" =~ ^https?:// ]]; then
      log "skip: COADMAP_API_URL must start with http:// or https:// (got: $COADMAP_API_URL)"
      return 1
    fi
    RESOLVED_TOKEN="$COADMAP_API_TOKEN"
    local rest="${COADMAP_API_URL#*://}"
    RESOLVED_BASE_URL="${COADMAP_API_URL%%"${rest}"*}${rest%%/*}"
    CREDS_SOURCE="env"
    [[ -n "$RESOLVED_BASE_URL" ]] && return 0
  fi

  local servers creds now_ms best_rank best_token best_host best_srank
  local srank name host inline rank
  # 採用キーは (scope, preferred_rank) の辞書順。scope を第 1 キーにしないと、
  # repo の .mcp.json に書かれた prod 接続が user scope の dev 接続を押しのける。
  servers="$(list_coadmap_mcp_servers)"
  [[ -z "$servers" ]] && servers=""

  # 2. Claude Code の MCP OAuth
  creds="$(read_claude_credentials)"
  if [[ -n "$creds" ]]; then
    now_ms=$(( $(now_epoch) * 1000 ))
    best_srank=9; best_rank=9; best_token=""; best_host=""
    local entry token expires_at
    while IFS="$FS_SEP" read -r srank name host inline; do
      [[ -z "$name" ]] && continue
      [[ "$srank" =~ ^[0-9]+$ ]] || continue
      [[ "$host" =~ $COADMAP_MCP_HOSTS_RE ]] || continue
      # serverName の一致だけだと、同名で別環境 (dev) に繋ぎ直した資格情報が
      # prod 宛に使われる。serverUrl のホストが設定側のホストと一致するものだけ採る。
      entry="$(printf '%s' "$creds" | jq -c --arg n "$name" --arg h "$host" '
        (.mcpOAuth // {}) | to_entries
        | map(select((.key | split("|")[0]) == $n) | .value)
        | map(select((.serverUrl // "") == ""
                     or (((.serverUrl // "") | capture("^[a-z]+://(?<h>[^/:]+)").h? // "") == $h)))
        | first // empty
      ' 2>/dev/null || true)"
      [[ -z "$entry" || "$entry" == "null" ]] && continue
      token="$(printf '%s' "$entry" | jq -r '.accessToken // empty' 2>/dev/null)"
      [[ -z "$token" ]] && continue
      expires_at="$(printf '%s' "$entry" | jq -r '.expiresAt // empty' 2>/dev/null)"
      if [[ -n "$expires_at" && "$expires_at" =~ ^[0-9]+$ ]]; then
        # refresh はしない (rotation で Claude Code 側のセッションを壊すため)
        if (( expires_at <= now_ms + 60000 )); then
          log "skip: MCP OAuth token for $name is expired or about to expire; not refreshing"
          continue
        fi
      fi
      rank="$(preferred_rank "$host")"
      if (( srank < best_srank || ( srank == best_srank && rank < best_rank ) )); then
        best_srank="$srank"; best_rank="$rank"; best_token="$token"; best_host="$host"
      fi
    done <<< "$servers"
    if [[ -n "$best_token" ]]; then
      RESOLVED_TOKEN="$best_token"
      RESOLVED_BASE_URL="$(be_url_for_host "$best_host")"
      CREDS_SOURCE="claude-mcp-oauth"
      [[ -n "$RESOLVED_BASE_URL" ]] && return 0
    fi
  fi

  # 3. MCP 設定に直書きされた ApiKey ヘッダ
  best_srank=9; best_rank=9; best_token=""; best_host=""
  while IFS="$FS_SEP" read -r srank name host inline; do
    [[ -z "$name" || -z "$inline" ]] && continue
    [[ "$srank" =~ ^[0-9]+$ ]] || continue
    [[ "$host" =~ $COADMAP_MCP_HOSTS_RE ]] || continue
    rank="$(preferred_rank "$host")"
    if (( srank < best_srank || ( srank == best_srank && rank < best_rank ) )); then
      best_srank="$srank"; best_rank="$rank"; best_token="$inline"; best_host="$host"
    fi
  done <<< "$servers"
  if [[ -n "$best_token" ]]; then
    RESOLVED_TOKEN="$best_token"
    RESOLVED_BASE_URL="$(be_url_for_host "$best_host")"
    CREDS_SOURCE="claude-mcp-header"
    [[ -n "$RESOLVED_BASE_URL" ]] && return 0
  fi

  # 4. Codex の config.toml
  # Codex 自身の OAuth (暗号化 keychain) は未対応。読めない場合は fail-closed。
  local ctoken cenv
  best_rank=9; best_token=""; best_host=""
  while IFS="$FS_SEP" read -r host ctoken cenv; do
    [[ -z "$host" ]] && continue
    [[ "$host" =~ $COADMAP_MCP_HOSTS_RE ]] || continue
    if [[ -z "$ctoken" && -n "$cenv" ]]; then
      ctoken="$(printenv "$cenv" 2>/dev/null || true)"
      ctoken="${ctoken#Bearer }"
    fi
    [[ -z "$ctoken" ]] && continue
    rank="$(preferred_rank "$host")"
    if (( rank < best_rank )); then
      best_rank="$rank"; best_token="$ctoken"; best_host="$host"
    fi
  done <<< "$(list_codex_mcp_servers)"
  if [[ -n "$best_token" ]]; then
    RESOLVED_TOKEN="$best_token"
    RESOLVED_BASE_URL="$(be_url_for_host "$best_host")"
    CREDS_SOURCE="codex-config-toml"
    [[ -n "$RESOLVED_BASE_URL" ]] && return 0
  fi

  return 1
}

if ! discover_coadmap_creds; then
  log "skip: could not resolve Coadmap API credentials (env / Claude Code MCP OAuth / MCP header / Codex config.toml)"
  exit 0
fi
BASE_URL="$RESOLVED_BASE_URL"
API_TOKEN="$RESOLVED_TOKEN"

# --- 3. 送信ヘルパ ------------------------------------------------------------
# 応答本文の置き場は mktemp で取る。固定パスだと並行セッション同士で踏み合う。
RESP_FILE="$(mktemp -t coadmap-ai-usage-report.XXXXXX 2>/dev/null || echo /dev/null)"

SESSION_LOCK=""
QUEUE_LOCK=""
# rollback_last_queued が一時的に取る「他セッションの lock」。異常終了しても残さない
# よう、保持している間だけここに積む (解放時に取り除くので、cleanup が後から別プロセス
# の取り立ての lock を消すことはない)。
EXTRA_LOCKS=()
cleanup() {
  local l
  [[ "$RESP_FILE" != "/dev/null" ]] && rm -f "$RESP_FILE"
  [[ -n "$SESSION_LOCK" ]] && rm -rf "$SESSION_LOCK" 2>/dev/null
  [[ -n "$QUEUE_LOCK" ]] && rm -rf "$QUEUE_LOCK" 2>/dev/null
  for l in ${EXTRA_LOCKS[@]+"${EXTRA_LOCKS[@]}"}; do
    rm -rf "$l" 2>/dev/null
  done
  return 0
}
# EXIT だけだと、hook を抱えたシェルごと落とされた (INT/TERM/HUP) ときに lock ディレクトリと
# 一時ファイルが残り、同じセッションの次の実行が 15 分間 skip される。
trap cleanup EXIT
trap 'cleanup; exit 143' INT TERM HUP

# Authorization を curl の argv に置かない。argv は ps auxww / /proc/<pid>/cmdline から
# 同一ホストの他ユーザーに平文で読める。--config で stdin から渡せば argv に出ない。
post_report() {
  local status
  # curl は接続失敗でも `-w` の `000` を出力したうえで非 0 終了する。`|| echo 000` を
  # 足すと出力が `000\n000` になり、後段の 000 判定に一致せず再送キューに乗らない。
  # 出力はそのまま受け取り、3 桁でなければ 000 に正規化する。
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" \
    | curl -sS --max-time 20 -o "$RESP_FILE" -w '%{http_code}' \
        --config - \
        -X POST "$BASE_URL/api/internal/mcp/external_ai_usage_reports" \
        -H "Content-Type: application/json" \
        --data "$1" 2>/dev/null)"
  [[ "$status" =~ ^[0-9]{3}$ ]] || status="000"
  printf '%s' "$status"
}

# 失敗した payload を再送キューに退避する。トークンは保存しない。
queue_save() {
  local key="$1" payload="$2" tmp
  tmp="$QUEUE_DIR/.$key.tmp.$$"
  local ok=1
  jq -nc --arg baseUrl "$BASE_URL" --argjson payload "$payload" --argjson savedAt "$(now_epoch)" \
    '{baseUrl: $baseUrl, payload: $payload, savedAt: $savedAt}' >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$QUEUE_DIR/$key.json" 2>/dev/null && ok=0
  rm -f "$tmp" 2>/dev/null
  return "$ok"
}

# ===== S6: 配送を諦めたキューは、その segment の lastQueued を巻き戻す =====
# lastQueued は「flush で届き得る累計」なので、届かないと確定したら消しておく。
# ただしこの巻き戻しが効くのは **まだ baseline として消費されていない lastQueued** だけ。
# flush が遅れている間 (queue.lock を取れなかった等) に本流の 409 が先に走ると、
# その lastQueued は既に新しい segment の baseline に混ざった後なので、ここで消しても
# その区間は届かないままになる (最大 1 区間ぶんの欠測。README の「既知の制約」)。
# キューには他セッションの entry も入るので、対象 session の state を lock 無しで
# read-modify-write すると、そのセッション自身の save_state と競合して巻き戻しごと
# 消える (逆に相手の更新を消す)。lock が取れないときは巻き戻さず、呼び出し側に
# 「このキューファイルはまだ捨てるな」と伝える (次回の flush でやり直す)。
# 戻り値: 0 = 巻き戻した / 巻き戻す対象が無い、1 = lock が取れず保留した。
rollback_last_queued() {
  local payload="$1" sk seg f tmp lk=""
  sk="$(printf '%s' "$payload" | jq -r '.sessionKey // empty' 2>/dev/null || true)"
  seg="$(printf '%s' "$payload" | jq -r '.segmentKey // empty' 2>/dev/null || true)"
  [[ -n "$sk" && -n "$seg" ]] || return 0
  [[ "$sk" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  f="$REPORT_DIR/$sk.state.json"
  [[ -f "$f" ]] || return 0
  # 自セッションぶんは既にこのプロセスが lock を持っている。取り直そうとすると
  # 自分の lock で必ず失敗するので、保持済みかどうかで分岐する。
  if [[ -z "$LOCKED_SESSION_ID" || "$sk" != "$LOCKED_SESSION_ID" ]]; then
    if ! acquire_lock "$REPORT_DIR/$sk.lock" lk; then
      log "queue: session $sk is locked by another instance; deferring the lastQueued rollback for $seg"
      return 1
    fi
    EXTRA_LOCKS+=("$lk")
  fi
  tmp="$f.tmp.$$"
  jq -c --arg k "$seg" \
    '.segments = (.segments | map(if .segmentKey == $k then del(.lastQueued) else . end))' \
    "$f" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  [[ -n "$lk" ]] && release_extra_lock "$lk"
  log "queue: rolled back lastQueued for $sk / $seg (the entry will never be delivered)"
  return 0
}

# --- blocked セッションの判定 -------------------------------------------------
# BE 側で mode が固定済み (legacy な unsegmented で受理済み等) のセッションは、
# 新しい segmentKey を発行しても 409 が返り続ける。毎回 2 回 POST して segments を
# 肥大させ続けても回復しないので、2 回目の 409 で状態ファイルに blocked を記録し、
# 以後は集計に入る前に打ち切る。
# --- lock ヘルパ --------------------------------------------------------------
# lock ディレクトリには自分の PID を残す。15 分より古い lock でも、その PID が
# 生きているなら奪わない（長いセッションの正当な lock を横取りしない）。
# 実際に回収したときだけ 0 を返す。
reclaim_stale_lock() {
  local d="$1" pid
  [[ -d "$d" ]] || return 1
  [[ -n "$(find "$d" -maxdepth 0 -type d -mmin +15 2>/dev/null)" ]] || return 1
  pid="$(cat "$d/pid" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    log "lock: not reclaiming $(basename "$d"); pid $pid is still alive"
    return 1
  fi
  rm -rf "$d" 2>/dev/null || true
  log "lock: reclaimed stale $(basename "$d")"
  return 0
}

# 先に mkdir を試し、失敗したときだけ stale 判定に進む。先に回収してから mkdir すると、
# 2 プロセスが同時に stale と判定した場合に、片方が相手の取り立ての lock を消す。
# $1: lock ディレクトリ, $2: 取得できたら代入するグローバル変数名。
# 取得と変数代入の間に窓を作らない (窓があるとその間に落ちた lock が回収されるまで残る)。
acquire_lock() {
  local d="$1" var="$2"
  if mkdir "$d" 2>/dev/null; then
    printf -v "$var" '%s' "$d"
    printf '%s' "$$" >"$d/pid" 2>/dev/null || true
    return 0
  fi
  reclaim_stale_lock "$d" || return 1
  mkdir "$d" 2>/dev/null || return 1
  printf -v "$var" '%s' "$d"
  printf '%s' "$$" >"$d/pid" 2>/dev/null || true
  return 0
}

release_lock() {
  [[ -n "$1" ]] && rm -rf "$1" 2>/dev/null
  return 0
}

# EXTRA_LOCKS から取り除いてから解放する。残したままにすると、同じパスの lock を
# その後に別プロセスが取り直したとき、こちらの cleanup がそれを消してしまう。
release_extra_lock() {
  local l keep=()
  for l in ${EXTRA_LOCKS[@]+"${EXTRA_LOCKS[@]}"}; do
    [[ "$l" == "$1" ]] || keep+=("$l")
  done
  EXTRA_LOCKS=(${keep[@]+"${keep[@]}"})
  release_lock "$1"
}

is_blocked() {
  local sid="$1" f
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  f="$REPORT_DIR/$sid.state.json"
  [[ -f "$f" ]] || return 1
  jq -e '.blocked != null' "$f" >/dev/null 2>&1 || return 1
  # BE 側の状態は変わり得るので、30 日経ったら失効させて再挑戦する。
  local at now
  at="$(jq -r '.blocked.atEpoch // 0' "$f" 2>/dev/null || echo 0)"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  now="$(now_epoch)"
  if (( at > 0 && now - at > 30 * 24 * 3600 )); then
    log "note: blocked marker for $sid expired (older than 30 days); retrying"
    return 1
  fi
  return 0
}

# --- 4. 再送キューの flush ----------------------------------------------------
QUEUE_MAX_FLUSH=20
QUEUE_MAX_AGE_SEC=$(( 7 * 24 * 3600 ))

flush_queue() {
  if ! acquire_lock "$REPORT_DIR/queue.lock" QUEUE_LOCK; then
    return 0
  fi

  local n=0 f saved payload stale_payload qbase age status retry_payload retry_status
  local now; now="$(now_epoch)"
  for f in "$QUEUE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    (( n >= QUEUE_MAX_FLUSH )) && break
    saved="$(jq -r '.savedAt // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$saved" =~ ^[0-9]+$ ]] || saved=0
    age=$(( now - saved ))
    if (( age > QUEUE_MAX_AGE_SEC )); then
      stale_payload="$(jq -c '.payload // empty' "$f" 2>/dev/null || true)"
      if [[ -z "$stale_payload" ]]; then
        # payload が壊れていると sessionKey/segmentKey が読めず lastQueued を戻せない。
        # 黙って捨てると、その segment は「届いた前提」のまま残って欠測になる。
        log "queue: dropping stale entry $(basename "$f") whose payload is unreadable; its lastQueued cannot be rolled back (age=${age}s)"
        rm -f "$f"
        continue
      fi
      if rollback_last_queued "$stale_payload"; then
        rm -f "$f"
        log "queue: dropped stale entry $(basename "$f") (age=${age}s)"
      else
        log "queue: keeping stale entry $(basename "$f") until its session lock is free (age=${age}s)"
      fi
      continue
    fi
    qbase="$(jq -r '.baseUrl // empty' "$f" 2>/dev/null || true)"
    # 宛先が今の認証情報と違うものは、そのトークンで送れないので残す (期限切れで消える)
    [[ "$qbase" != "$BASE_URL" ]] && continue
    payload="$(jq -c '.payload // empty' "$f" 2>/dev/null || true)"
    if [[ -z "$payload" ]]; then
      rm -f "$f"
      continue
    fi
    n=$(( n + 1 ))
    status="$(post_report "$payload")"
    case "$status" in
      200|201)
        rm -f "$f"
        log "queue: flushed $(basename "$f") (status=$status)"
        ;;
      404|403)
        # 紐付けだけが失敗している可能性がある。taskId を落として 1 回だけ試す。
        retry_payload="$(printf '%s' "$payload" | jq -c 'del(.taskId)' 2>/dev/null || true)"
        if [[ -n "$retry_payload" && "$retry_payload" != "$payload" ]]; then
          n=$(( n + 1 ))
          retry_status="$(post_report "$retry_payload")"
          case "$retry_status" in
            200|201)
              rm -f "$f"
              log "queue: flushed $(basename "$f") without taskId (first status=$status)"
              ;;
            000|5??|429)
              # 一過性の失敗。捨てずに残して次回また試す。
              log "queue: keeping $(basename "$f") (retry without taskId=$retry_status)"
              ;;
            *)
              if rollback_last_queued "$payload"; then
                rm -f "$f"
                log "queue: dropped $(basename "$f") (status=$status, retry without taskId=$retry_status)"
              else
                log "queue: keeping $(basename "$f") until its session lock is free (status=$status, retry without taskId=$retry_status)"
              fi
              ;;
          esac
        else
          if rollback_last_queued "$payload"; then
            rm -f "$f"
            log "queue: dropped $(basename "$f") (status=$status, no taskId to drop)"
          else
            log "queue: keeping $(basename "$f") until its session lock is free (status=$status, no taskId to drop)"
          fi
        fi
        ;;
      422)
        if rollback_last_queued "$payload"; then
          rm -f "$f"
          log "queue: dropped $(basename "$f") (status=422, not retryable)"
        else
          log "queue: keeping $(basename "$f") until its session lock is free (status=422)"
        fi
        ;;
      409)
        if rollback_last_queued "$payload"; then
          rm -f "$f"
          log "queue: dropped $(basename "$f") (status=409 segment conflict; a fresh segment will be issued on the next observation)"
        else
          log "queue: keeping $(basename "$f") until its session lock is free (status=409)"
        fi
        ;;
      *)
        log "queue: keeping $(basename "$f") (status=$status)"
        ;;
    esac
  done

  release_lock "$QUEUE_LOCK"
  QUEUE_LOCK=""
}

# --- 4b. 再送キューを flush する ---------------------------------------------
# ここでは session lock を取らない。flush はキュー 1 件あたり最大 2 POST × 20 秒
# かかり得るので、先に session lock を取ると、同じセッションの後発プロセス
# (Stop の flush 中に走る SessionEnd など) が `another instance holds the lock` で
# 打ち切られる。Stop 側は throttle で送らないので、セッション最終区間が丸ごと落ちる。
# flush が自セッションの state に触るのは rollback_last_queued だけで、そこは
# 「lock を取れたときだけ巻き戻し、取れなければ次回に持ち越す」ようになっている
# (LOCKED_SESSION_ID がまだ空なので、自セッションぶんもその経路を通る)。
flush_queue

# transcript を読む前に打ち切る。blocked なセッションは何度集計しても送れない。
if [[ -n "$STDIN_SESSION_ID" ]] && is_blocked "$STDIN_SESSION_ID"; then
  log "skip: session $STDIN_SESSION_ID is blocked by a persistent segment conflict; not reporting again"
  exit 0
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  log "skip: transcript not found ($TRANSCRIPT_PATH)"
  exit 0
fi

# --- 5. transcript の形式判別と集計 ------------------------------------------
# 1 パスで JSONL を正規化してから、形式ごとの集計にかける。
NORM_FILE="$(mktemp -t coadmap-ai-usage-norm.XXXXXX 2>/dev/null || echo "")"
if [[ -z "$NORM_FILE" ]]; then
  log "skip: could not create a temporary file"
  exit 0
fi
trap 'rm -f "$NORM_FILE"; cleanup' EXIT
trap 'rm -f "$NORM_FILE"; cleanup; exit 143' INT TERM HUP

jq -R -c 'fromjson? // empty | select(type == "object")' "$TRANSCRIPT_PATH" >"$NORM_FILE" 2>/dev/null

FORMAT="unsupported"
if jq -e -s 'any(.[]; .type == "assistant" and (.message.usage? != null))' "$NORM_FILE" >/dev/null 2>&1; then
  FORMAT="claude_code"
elif jq -e -s 'any(.[]; .type == "session_meta")' "$NORM_FILE" >/dev/null 2>&1; then
  FORMAT="codex"
fi

USAGE_JSON=""
case "$FORMAT" in
  claude_code)
    AGENT="claude_code"
    USAGE_JSON="$(
      jq -cs '
        map(select(.type == "assistant" and (.message.id? != null) and (.message.usage? != null)))
        | group_by(.message.id)
        | map(.[-1])
        | {
            recordCount: length,
            inputTokens: ([ .[].message.usage.input_tokens // 0 ] | add // 0),
            outputTokens: ([ .[].message.usage.output_tokens // 0 ] | add // 0),
            cacheCreationTokens: ([ .[].message.usage.cache_creation_input_tokens // 0 ] | add // 0),
            cacheReadTokens: ([ .[].message.usage.cache_read_input_tokens // 0 ] | add // 0),
            sessionId: "",
            monotonic: true,
            modelName: (
              (group_by(.message.model)
                | map({model: .[0].message.model, out: ([ .[].message.usage.output_tokens // 0 ] | add // 0)})
                | sort_by([.out, .model])
                | last
              ) as $top
              | ($top.model // "unknown")
            )
          }
      ' "$NORM_FILE" 2>>"$LOG_FILE"
    )"
    ;;
  codex)
    AGENT="codex"
    USAGE_JSON="$(
      jq -cs --arg fallbackModel "$STDIN_MODEL" '
        # total_token_usage は原則セッション累計だが、Codex 旧版には途中で累計が
        # リセットされる rollout が実在する (例: output 282904 → 34980 → 再増加)。
        # 列ごとの max だとリセット前の山だけを見てリセット後の消費を丸ごと落とす。
        # そこで「減少点で区切った単調増加区間ごとの終値の和」を採る。
        # 区切りの判定は**行単位**で行い、その位置を全列で共有する。列ごとに独立して
        # 区切ると、リセット点が列でずれたときに input と cached が別の行から来て
        # `input - cached` が負に潰れる。
        def rowkey: (.total_tokens // .output_tokens // 0);
        {
          sessionId: ([ .[] | select(.type == "session_meta") | .payload.id? // empty ] | first // ""),
          models:    [ .[] | select(.type == "turn_context") | .payload.model? // empty ],
          counts:    [ .[]
                       | select(.type == "event_msg"
                                and (.payload.type? == "token_count")
                                and (.payload.info? != null))
                       | .payload.info.total_token_usage // {} ]
        }
        | . as $d
        | $d.counts as $c
        | (if ($c | length) == 0 then []
           else (reduce range(1; ($c | length)) as $i ([];
                   if (($c[$i] | rowkey) < ($c[$i - 1] | rowkey)) then . + [$i - 1] else . end))
                + [($c | length) - 1]
           end) as $ends
        | def colsum($k): if ($ends | length) == 0 then 0
                          else ([ $ends[] | ($c[.] | .[$k] // 0) ] | add) end;
          {
            recordCount: ($c | length),
            rawInput:            colsum("input_tokens"),
            cacheReadTokens:     colsum("cached_input_tokens"),
            cacheCreationTokens: colsum("cache_write_input_tokens"),
            outputTokens:        colsum("output_tokens"),
            sessionId: $d.sessionId,
            monotonic: (($ends | length) <= 1),
            modelName: (
              $d.models as $m
              | if ($m | length) == 0 then (if $fallbackModel != "" then $fallbackModel else "unknown" end)
                else ($m | to_entries
                        | group_by(.value)
                        | map({model: .[0].value, c: length, lastIndex: ([ .[].key ] | max)})
                        | sort_by([.c, .lastIndex, .model])
                        | last | .model)
                end
            )
          }
        | .inputTokens = (if (.rawInput - .cacheReadTokens) < 0 then 0 else (.rawInput - .cacheReadTokens) end)
      ' "$NORM_FILE" 2>>"$LOG_FILE"
    )"
    ;;
  *)
    log "skip: unsupported transcript format (neither Claude Code assistant usage records nor a Codex session_meta line in $TRANSCRIPT_PATH)"
    exit 0
    ;;
esac

if [[ -z "$USAGE_JSON" ]]; then
  log "skip: usage aggregation failed (format=$FORMAT)"
  exit 0
fi

RECORD_COUNT="$(printf '%s' "$USAGE_JSON" | jq -r '.recordCount // 0')"
INPUT_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.inputTokens // 0')"
OUTPUT_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.outputTokens // 0')"
CACHE_CREATION_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.cacheCreationTokens // 0')"
CACHE_READ_TOKENS="$(printf '%s' "$USAGE_JSON" | jq -r '.cacheReadTokens // 0')"
MODEL_NAME="$(printf '%s' "$USAGE_JSON" | jq -r '.modelName // "unknown"')"
TRANSCRIPT_SESSION_ID="$(printf '%s' "$USAGE_JSON" | jq -r '.sessionId // ""')"
# `.monotonic // true` は false を「空」とみなして true に化けるので使わない。
MONOTONIC="$(printf '%s' "$USAGE_JSON" | jq -r 'if has("monotonic") then .monotonic else true end')"

for _v in RECORD_COUNT INPUT_TOKENS OUTPUT_TOKENS CACHE_CREATION_TOKENS CACHE_READ_TOKENS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || printf -v "$_v" '%s' 0
done

if [[ "$FORMAT" == "codex" ]]; then
  RAW_INPUT="$(printf '%s' "$USAGE_JSON" | jq -r '.rawInput // 0')"
  if [[ "$RAW_INPUT" =~ ^[0-9]+$ && "$RAW_INPUT" -lt "$CACHE_READ_TOKENS" ]]; then
    log "warn: codex input_tokens($RAW_INPUT) < cached_input_tokens($CACHE_READ_TOKENS); clamped inputTokens to 0"
  fi
  if [[ "$MONOTONIC" != "true" ]]; then
    log "warn: codex token_count totals are not monotonic (cumulative counter reset); summing each monotonic run"
  fi
fi

# token_count / assistant usage が 1 件も無いのは「使わなかった」ではなく
# 「この transcript からは読めていない」。0 のレポートは嘘のレコードになる。
if [[ "$RECORD_COUNT" -eq 0 ]]; then
  log "skip: no usage records found (format=$FORMAT, transcript=$TRANSCRIPT_PATH)"
  exit 0
fi

if [[ "$OUTPUT_TOKENS" -eq 0 ]]; then
  log "skip: aggregated outputTokens=0, refusing to send an empty usage report (format=$FORMAT records=$RECORD_COUNT)"
  exit 0
fi

# --- 6. sessionKey の決定 -----------------------------------------------------
# stdin の session_id を正とし、transcript 側と食い違ったらログに残す
# (stdin が空のときだけ transcript 側を使う)。
SESSION_ID="$STDIN_SESSION_ID"
if [[ -n "$TRANSCRIPT_SESSION_ID" && -n "$STDIN_SESSION_ID" && "$TRANSCRIPT_SESSION_ID" != "$STDIN_SESSION_ID" ]]; then
  log "warn: session id mismatch (stdin=$STDIN_SESSION_ID transcript=$TRANSCRIPT_SESSION_ID); using the stdin one"
fi
[[ -z "$SESSION_ID" ]] && SESSION_ID="$TRANSCRIPT_SESSION_ID"

if [[ -z "$SESSION_ID" ]]; then
  log "skip: no session id (it is the idempotency key; BE upserts on it)"
  exit 0
fi
# sessionKey は状態ファイル名になるので、パスとして安全な形だけ通す。
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log "skip: unexpected session_id format, refusing to use it as a path component"
  exit 0
fi

# --- 7. 排他 -----------------------------------------------------------------
# Stop と SessionEnd の両方が同一セッションで走り得るため必須。
# 取得はここが最初の機会 (キュー flush 中は敢えて保持しない。4b の注記を参照)。
if [[ "$SESSION_ID" != "$LOCKED_SESSION_ID" ]]; then
  release_lock "$SESSION_LOCK"
  SESSION_LOCK=""
  LOCKED_SESSION_ID=""
  if ! acquire_lock "$REPORT_DIR/$SESSION_ID.lock" SESSION_LOCK; then
    log "skip: another instance holds the lock for session $SESSION_ID"
    exit 0
  fi
  LOCKED_SESSION_ID="$SESSION_ID"
fi

# sessionKey を transcript から採った場合はここが最初の判定機会になる。
if is_blocked "$SESSION_ID"; then
  log "skip: session $SESSION_ID is blocked by a persistent segment conflict; not reporting again"
  exit 0
fi

# --- 8. contextKey (ブランチ由来の Coadmap タスク displayId) ------------------
# Coadmap 側の displayId 解決は namespace 部分の大小文字を区別する。ブランチ名は
# 慣例上小文字 (feature/cmdev-10660-...) なので、大文字化したものを正規形とする。
CONTEXT_KEY="none"
TASK_ID=""
if [[ -n "$CWD" && -d "$CWD" ]]; then
  BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
  if [[ -n "$BRANCH" ]]; then
    TASK_ID="$(printf '%s' "$BRANCH" | grep -oE '[A-Za-z][A-Za-z0-9_]+-[0-9]+' | head -1 || true)"
    TASK_ID="$(printf '%s' "$TASK_ID" | tr '[:lower:]' '[:upper:]')"
  fi
fi
[[ -n "$TASK_ID" ]] && CONTEXT_KEY="$TASK_ID"

# --- 9. collectorKey ----------------------------------------------------------
# 非可逆 digest。hostname / user 名そのものは送らない。
COLLECTOR_KEY="$(sha256_hex "$(hostname 2>/dev/null || echo unknown):${USER:-unknown}:$AGENT")"
COLLECTOR_KEY="${COLLECTOR_KEY:0:32}"
if [[ ! "$COLLECTOR_KEY" =~ ^[0-9a-f]{16,64}$ ]]; then
  log "skip: could not compute collectorKey (no shasum/sha256sum available)"
  exit 0
fi

# --- 10. segment 状態の読み書き ----------------------------------------------
# 旧 `<session>.done` (segment 以前の形式) は読まない。segmented mode では
# session 内の区間を新しい契約で切り直すため、混ぜると baseline の意味が壊れる。
# 旧マーカーが残っていても無害なので消さずに放置する。
STATE_FILE="$REPORT_DIR/$SESSION_ID.state.json"
STATE=""
if [[ -f "$STATE_FILE" ]]; then
  STATE="$(jq -c '.' "$STATE_FILE" 2>/dev/null || true)"
fi
# 失効した blocked は落としておく (is_blocked が false を返した後にしかここへ来ない)。
if [[ -n "$STATE" ]]; then
  STATE="$(printf '%s' "$STATE" | jq -c 'del(.blocked)')"
fi
if [[ -z "$STATE" ]]; then
  STATE="$(jq -nc --arg sessionKey "$SESSION_ID" --arg agent "$AGENT" --arg collectorKey "$COLLECTOR_KEY" \
    '{sessionKey: $sessionKey, agent: $agent, collectorKey: $collectorKey, segments: [], lastObserved: null}')"
fi

# 404/403 を返した taskId は同じ session では以後送らない。ブランチ名からの推定は
# `release-20260904` のような誤検出を含み、毎回 2 リクエストを無駄にするため。
task_is_unresolved() {
  [[ -n "$1" ]] || return 1
  printf '%s\n' "$(printf '%s' "$STATE" | jq -r '(.unresolvedTaskIds // [])[]' 2>/dev/null)" \
    | grep -qxF "$1"
}

mark_task_unresolved() {
  STATE="$(printf '%s' "$STATE" | jq -c --arg t "$1" \
    '.unresolvedTaskIds = (((.unresolvedTaskIds // []) + [$t]) | unique)')"
}

CURRENT="$(jq -nc \
  --argjson i "$INPUT_TOKENS" --argjson o "$OUTPUT_TOKENS" \
  --argjson cr "$CACHE_READ_TOKENS" --argjson cc "$CACHE_CREATION_TOKENS" \
  '{inputTokens: $i, outputTokens: $o, cacheReadTokens: $cr, cacheCreationTokens: $cc}')"

ZERO_BASELINE='{"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheCreationTokens":0}'

LAST_SEGMENT="$(printf '%s' "$STATE" | jq -c '.segments[-1] // empty')"
LAST_OBSERVED="$(printf '%s' "$STATE" | jq -c '.lastObserved // empty')"
[[ -z "$LAST_OBSERVED" || "$LAST_OBSERVED" == "null" ]] && LAST_OBSERVED="$ZERO_BASELINE"

# --- 11. segment の決定と、前 segment の締め --------------------------------
# 送るキーはここに並ぶものが全て。transcript の本文は一切載せない。
build_payload() {
  # $1: taskId ("" なら載せない), $2: segmentKey, $3: startedAt, $4: baseline, $5: segment tokens
  jq -nc \
    --arg agent "$AGENT" \
    --arg modelName "$MODEL_NAME" \
    --arg sessionKey "$SESSION_ID" \
    --arg taskId "${1:-}" \
    --arg segmentKey "$2" \
    --arg segmentStartedAt "$3" \
    --argjson tokenBaseline "$4" \
    --argjson tokens "$5" \
    --arg collectorKey "$COLLECTOR_KEY" \
    '{
       agent: $agent,
       modelName: $modelName,
       inputTokens: $tokens.inputTokens,
       outputTokens: $tokens.outputTokens,
       cacheReadTokens: $tokens.cacheReadTokens,
       cacheCreationTokens: $tokens.cacheCreationTokens,
       sessionKey: $sessionKey,
       segmentKey: $segmentKey,
       segmentStartedAt: $segmentStartedAt,
       tokenBaseline: $tokenBaseline,
       collectorKey: $collectorKey
     } + (if $taskId != "" then {taskId: $taskId} else {} end)'
}

record_sent() {
  # $1: segmentKey — 送信成功した segment の lastSent をセッション累計で記録する
  mark_segment_sent "$1" "$CURRENT"
}

# $1: baseline JSON, $2: contextKey, $3: taskId
# STATE に segment を 1 本足し、その key と開始時刻を APPENDED_SEGMENT_* に返す。
append_segment() {
  local idx started
  # nextSegmentIndex は state ファイル由来なので、数値以外 (文字列 / null / 破損) が
  # 入っていても `> 0` の比較で真になり得る。numbers で型を絞ってから使う。
  idx="$(printf '%s' "$STATE" | jq -r '
    ((.nextSegmentIndex | numbers | floor) // 0) as $n
    | if $n > 0 then $n else ((.segments | length) + 1) end')"
  [[ "$idx" =~ ^[0-9]+$ ]] || idx=1
  started="$(now_epoch)"
  # 採番を `length + 1` にすると、segments をトリムした後に同じ値へ張り付く。
  # 409 リトライと context 切替が同一実行内で続くと同じ秒に 2 本作るので、
  # 単調カウンタ (nextSegmentIndex) と PID を混ぜて衝突させない。
  APPENDED_SEGMENT_KEY="${idx}-${started}-$$"
  APPENDED_SEGMENT_STARTED_AT="$(now_iso)"
  STATE="$(printf '%s' "$STATE" | jq -c \
    --arg k "$APPENDED_SEGMENT_KEY" --arg ctx "$2" --arg t "${3:-}" \
    --arg s "$APPENDED_SEGMENT_STARTED_AT" --argjson b "$1" --argjson next "$(( idx + 1 ))" \
    '.segments += [{segmentKey: $k, contextKey: $ctx, taskId: $t, startedAt: $s, baseline: $b, lastSent: null}]
     | .nextSegmentIndex = $next')"
}

new_segment() {
  # $1: baseline JSON — 新しい segment を「現在の」 segment として開く
  NEW_SEGMENT=1
  append_segment "$1" "$CONTEXT_KEY" "${TASK_ID:-}"
  SEGMENT_KEY="$APPENDED_SEGMENT_KEY"
  SEGMENT_STARTED_AT="$APPENDED_SEGMENT_STARTED_AT"
  SEGMENT_BASELINE="$1"
  SEGMENT_LAST_SENT="null"
  SEGMENT_LAST_QUEUED="null"
}

continue_last_segment() {
  SEGMENT_KEY="$(printf '%s' "$LAST_SEGMENT" | jq -r '.segmentKey')"
  SEGMENT_STARTED_AT="$(printf '%s' "$LAST_SEGMENT" | jq -r '.startedAt')"
  SEGMENT_BASELINE="$(printf '%s' "$LAST_SEGMENT" | jq -c '.baseline')"
  SEGMENT_LAST_SENT="$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastSent // null')"
  SEGMENT_LAST_QUEUED="$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastQueued // null')"
  SEGMENT_LAST_SENT_AT="$(printf '%s' "$LAST_SEGMENT" | jq -r '.lastSentAt // 0')"
  SEGMENT_LAST_ATTEMPT_AT="$(printf '%s' "$LAST_SEGMENT" | jq -r '.lastAttemptAt // 0')"
}

# 「BE に届いた可能性がある最大の累計」。$1=lastSent, $2=lastQueued (どちらも null 可)、
# $3=どちらも無いときの既定値。
resume_baseline() {
  local sent="$1" queued="$2" fallback="$3"
  if [[ ( "$sent" == "null" || -z "$sent" ) && ( "$queued" == "null" || -z "$queued" ) ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  [[ "$sent" == "null" || -z "$sent" ]] && sent="$ZERO_BASELINE"
  [[ "$queued" == "null" || -z "$queued" ]] && queued="$ZERO_BASELINE"
  jq -nc --argjson s "$sent" --argjson q "$queued" '
    ["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens"]
    | map({key: ., value: ([($s[.] // 0), ($q[.] // 0)] | max)})
    | from_entries'
}

# 任意個の累計 JSON を列ごとに max して 1 本の baseline にする。
# 空文字 / null / オブジェクト以外 / 数値でない列は候補から外す (state ファイル由来の値は
# 手で編集されたり途中で壊れたりし得るので、型を確かめてから使う)。
colmax() {
  local a vs="[]"
  for a in "$@"; do
    [[ -z "$a" || "$a" == "null" ]] && continue
    vs="$(jq -nc --argjson acc "$vs" --argjson x "$a" '$acc + [$x]' 2>/dev/null || printf '%s' "$vs")"
  done
  jq -nc --argjson vs "$vs" '
    [ $vs[] | select(type == "object") ] as $o
    | ["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens"]
    | map(. as $k | {key: $k, value: ([0] + [ $o[] | (.[$k] | numbers) ] | max)})
    | from_entries'
}

# state から読んだ segment が、そのまま送信に使える形かを確かめる。
# segmentKey / startedAt が欠けていると payload に "null" という文字列が載り、
# baseline が欠けていると segment_tokens が空を返して以後ずっと outputTokens=0 として
# skip され続ける (永久に何も送らない)。
segment_state_is_valid() {
  printf '%s' "$1" | jq -e '. as $s
    | (($s.segmentKey | strings) // "") != ""
      and (($s.startedAt | strings) // "") != ""
      and (($s.baseline | objects) != null)
      and (["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens"]
           | all(.[]; ($s.baseline[.] | type) == "number"))' >/dev/null 2>&1
}

segment_tokens() {
  # $1: 現在の累計, $2: baseline
  jq -nc --argjson c "$1" --argjson b "$2" '
    {
      inputTokens:         ($c.inputTokens - $b.inputTokens),
      outputTokens:        ($c.outputTokens - $b.outputTokens),
      cacheReadTokens:     ($c.cacheReadTokens - $b.cacheReadTokens),
      cacheCreationTokens: ($c.cacheCreationTokens - $b.cacheCreationTokens)
    }'
}

mark_segment_sent() {
  # $1: segmentKey, $2: 送信した時点のセッション累計
  STATE="$(printf '%s' "$STATE" | jq -c --arg k "$1" --argjson sent "$2" --argjson at "$(now_epoch)" \
    '.segments = (.segments | map(if .segmentKey == $k then (.lastSent = $sent | .lastSentAt = $at) else . end))')"
}

mark_segment_queued() {
  # $1: segmentKey, $2: キューに載せた時点のセッション累計
  STATE="$(printf '%s' "$STATE" | jq -c --arg k "$1" --argjson q "$2" \
    '.segments = (.segments | map(if .segmentKey == $k then (.lastQueued = $q) else . end))')"
}

# context 切替の直前に、前 segment の区間累計 (lastObserved − 前 baseline) を
# 前 segment の segmentKey 宛に 1 回送る。BE は segmentKey ごとに単調 upsert するので、
# 既に送った分と重なっても二重計上しない。
# 戻り値: 0 = 記録できた (送信成功 / キュー退避成功 / 送る必要が無い / 恒久エラー)、
#         1 = キュー退避にも失敗し、この差分をどこにも記録できていない。
flush_previous_segment() {
  local task payload status base2 tokens2 key2 started2
  if printf '%s' "$PREV_TOKENS" | jq -e 'any(.[]; . < 0)' >/dev/null 2>&1; then
    log "skip: previous segment $PREV_SEGMENT_KEY would be negative; not flushing it"
    return 0
  fi
  if [[ "$(printf '%s' "$PREV_TOKENS" | jq -r '.outputTokens')" -eq 0 ]]; then
    return 0
  fi
  task="$PREV_TASK_ID"
  task_is_unresolved "$task" && task=""
  payload="$(build_payload "$task" "$PREV_SEGMENT_KEY" "$PREV_STARTED_AT" "$PREV_BASELINE" "$PREV_TOKENS")"
  status="$(post_report "$payload")"
  if [[ ( "$status" == "404" || "$status" == "403" ) && -n "$task" ]]; then
    mark_task_unresolved "$task"
    task=""
    payload="$(build_payload "" "$PREV_SEGMENT_KEY" "$PREV_STARTED_AT" "$PREV_BASELINE" "$PREV_TOKENS")"
    status="$(post_report "$payload")"
  fi

  # 409 = その segmentKey では受け付けられない。本流と同じく新しい segmentKey で
  # 1 回だけ再送する。baseline は「届いた可能性がある最大の累計」。
  if [[ "$status" == "409" ]]; then
    base2="$(resume_baseline "$PREV_LAST_SENT" "$PREV_LAST_QUEUED" "$PREV_BASELINE")"
    tokens2="$(segment_tokens "$LAST_OBSERVED" "$base2")"
    if printf '%s' "$tokens2" | jq -e 'any(.[]; . < 0)' >/dev/null 2>&1 \
       || [[ "$(printf '%s' "$tokens2" | jq -r '.outputTokens')" -eq 0 ]]; then
      log "abort: previous segment $PREV_SEGMENT_KEY conflicted (409) and there is nothing left to resend"
      return 0
    fi
    append_segment "$base2" "$PREV_CONTEXT_KEY" "$task"
    key2="$APPENDED_SEGMENT_KEY"
    started2="$APPENDED_SEGMENT_STARTED_AT"
    log "retry: previous segment $PREV_SEGMENT_KEY conflicted (409); reissuing it as $key2"
    PREV_SEGMENT_KEY="$key2"
    PREV_STARTED_AT="$started2"
    PREV_BASELINE="$base2"
    PREV_TOKENS="$tokens2"
    payload="$(build_payload "$task" "$key2" "$started2" "$base2" "$tokens2")"
    status="$(post_report "$payload")"
  fi

  case "$status" in
    200|201)
      mark_segment_sent "$PREV_SEGMENT_KEY" "$LAST_OBSERVED"
      log "ok: flushed the previous segment before switching context (session=$SESSION_ID segment=$PREV_SEGMENT_KEY out=$(printf '%s' "$PREV_TOKENS" | jq -r '.outputTokens'))"
      return 0
      ;;
    000|5??|429)
      if queue_save "$SESSION_ID-$PREV_SEGMENT_KEY" "$payload"; then
        mark_segment_queued "$PREV_SEGMENT_KEY" "$LAST_OBSERVED"
        log "queued: could not flush the previous segment (status=$status, session=$SESSION_ID segment=$PREV_SEGMENT_KEY)"
        return 0
      fi
      log "abort: could not flush or queue the previous segment (status=$status, session=$SESSION_ID segment=$PREV_SEGMENT_KEY)"
      return 1
      ;;
    409)
      # 新しい segmentKey で再発行してもなお 409 = BE 側で session の mode が固定済み。
      # 本流と同じく blocked を記録して、以後は集計に入る前に打ち切る。切替そのものは
      # 確定させる (この session ではもう何も送れないので、締めを待っても回復しない)。
      STATE="$(printf '%s' "$STATE" | jq -c --arg at "$(now_iso)" --argjson atEpoch "$(now_epoch)" \
        '.blocked = {reason: "conflict", at: $at, atEpoch: $atEpoch}')"
      log "abort: the previous segment still conflicts (409) after reissuing it; marking session as blocked (session=$SESSION_ID segment=$PREV_SEGMENT_KEY)"
      return 0
      ;;
    *)
      # 401 など既知でない status。恒久エラーとは限らないので捨てずにキューへ退避する
      # (退避できたぶんは lastQueued として baseline に織り込まれ、flush で届き得る)。
      if queue_save "$SESSION_ID-$PREV_SEGMENT_KEY" "$payload"; then
        mark_segment_queued "$PREV_SEGMENT_KEY" "$LAST_OBSERVED"
        log "queued: could not flush the previous segment (unknown status=$status, session=$SESSION_ID segment=$PREV_SEGMENT_KEY)"
        return 0
      fi
      log "abort: could not flush or queue the previous segment (unknown status=$status, session=$SESSION_ID segment=$PREV_SEGMENT_KEY)"
      return 1
      ;;
  esac
}

if [[ -n "$LAST_SEGMENT" ]] && ! segment_state_is_valid "$LAST_SEGMENT"; then
  log "warn: the last segment in the state file is malformed (segmentKey / startedAt / baseline); \
opening a fresh segment instead of reusing it (session=$SESSION_ID)"
  # 壊れた segment でも lastSent / lastQueued は「BE に届いた可能性がある累計」なので、
  # 読める分は新しい baseline の候補に残す (0 から開き直すと計上済みの分を再送する)。
  SALVAGED_BASELINE="$(colmax "$LAST_OBSERVED" \
    "$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastSent // null' 2>/dev/null || true)" \
    "$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastQueued // null' 2>/dev/null || true)")"
  LAST_SEGMENT=""
fi

if [[ -z "$LAST_SEGMENT" ]]; then
  # セッション最初の観測。session 開始時点からの区間なので baseline = 0。
  new_segment "${SALVAGED_BASELINE:-$ZERO_BASELINE}"
else
  LAST_CONTEXT="$(printf '%s' "$LAST_SEGMENT" | jq -r '.contextKey // "none"')"
  # detached HEAD や非 git ディレクトリでは context が "none" に落ちる。これを切替と
  # みなすと毎ターン新 segment が生まれるので、「task → none」は変化なしとして前の
  # segment を継続する (none → task は本物の切替なので新 segment)。
  if [[ "$CONTEXT_KEY" == "none" && "$LAST_CONTEXT" != "none" ]]; then
    log "note: no task context at this observation; continuing segment of $LAST_CONTEXT (session=$SESSION_ID)"
    CONTEXT_KEY="$LAST_CONTEXT"
    TASK_ID="$(printf '%s' "$LAST_SEGMENT" | jq -r '.taskId // ""')"
  fi
  if [[ "$LAST_CONTEXT" != "$CONTEXT_KEY" ]]; then
    # context が切り替わった。切り替え直前の観測累計を新 segment の baseline にする。
    # ただし前 segment に「観測したが送っていない分」が残っていることがある
    # (throttle で lastObserved だけ進んだ場合など)。新 segment の baseline を
    # lastObserved にすると、その差分をどの segment も報告しなくなり欠測する。
    # そこで **新 segment を開く前に** 前 segment 宛の締めを送る。ここを後段の
    # 送信要否の判定より後ろに置くと、新 segment の差分が 0 のときに early-exit して
    # 締めが永久に送られない。
    PREV_SEGMENT_KEY="$(printf '%s' "$LAST_SEGMENT" | jq -r '.segmentKey')"
    # PREV_SEGMENT_KEY は 409 の再発行で新しい key に差し替わる。切替を見送るときは
    # その key ごと切り詰めるので、ログには実際に残るほうの key を出す。
    _orig_segment_key="$PREV_SEGMENT_KEY"
    PREV_STARTED_AT="$(printf '%s' "$LAST_SEGMENT" | jq -r '.startedAt')"
    PREV_BASELINE="$(printf '%s' "$LAST_SEGMENT" | jq -c '.baseline')"
    PREV_TASK_ID="$(printf '%s' "$LAST_SEGMENT" | jq -r '.taskId // ""')"
    PREV_CONTEXT_KEY="$LAST_CONTEXT"
    PREV_LAST_SENT="$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastSent // null')"
    PREV_LAST_QUEUED="$(printf '%s' "$LAST_SEGMENT" | jq -c '.lastQueued // null')"
    _prev_recorded="$(resume_baseline "$PREV_LAST_SENT" "$PREV_LAST_QUEUED" "$PREV_BASELINE")"
    # 締めの 409 リトライは append_segment で STATE に新しい key を足してから再送する。
    # 再送にも失敗して切替を見送るとき、その key を残したまま保存すると、次回は
    # 「.segments[-1] = 旧 context の新 key」と現在の context を比べて再び切替と判定し、
    # まだ届いていない区間を新 key 宛にもう一度送って二重計上する。切替前の本数を控え、
    # 見送るときはそこまで巻き戻す (nextSegmentIndex は進めたままでよい。key の再利用を
    # 防ぐための単調カウンタなので、戻すほうが衝突を招く)。
    _seg_len_before="$(printf '%s' "$STATE" | jq -r '.segments | length')"
    [[ "$_seg_len_before" =~ ^[0-9]+$ ]] || _seg_len_before=0
    _switch_ok=1
    if [[ "$(printf '%s' "$_prev_recorded" | jq -cS '.')" != "$(printf '%s' "$LAST_OBSERVED" | jq -cS '.')" ]]; then
      PREV_TOKENS="$(segment_tokens "$LAST_OBSERVED" "$PREV_BASELINE")"
        flush_previous_segment || _switch_ok=0
    fi
    if [[ "$_switch_ok" == "1" ]]; then
      # baseline を lastObserved だけで決めると、state の .lastObserved が欠けている
      # (壊れた / 旧形式) ときに 0 になり、セッション累計まるごとが新しい context に乗る。
      # 前 segment の baseline と「記録済みの累計」も候補に入れて列ごと max を採る。
      new_segment "$(colmax "$LAST_OBSERVED" "$PREV_BASELINE" "$_prev_recorded")"
    else
      # 締めをどこにも記録できていない。ここで新 segment を確定させると、その差分は
      # 二度と報告されない。context の切替は見送り、次回の実行でやり直す。
      log "skip: could not record the previous segment's closing report; keeping segment $_orig_segment_key and retrying next time"
      STATE="$(printf '%s' "$STATE" | jq -c --argjson n "$_seg_len_before" '.segments = .segments[0:$n]')"
      CONTEXT_KEY="$PREV_CONTEXT_KEY"
      TASK_ID="$PREV_TASK_ID"
      continue_last_segment
    fi
  else
    continue_last_segment
  fi
fi
[[ "${SEGMENT_LAST_SENT_AT:-}" =~ ^[0-9]+$ ]] || SEGMENT_LAST_SENT_AT=0
[[ "${SEGMENT_LAST_ATTEMPT_AT:-}" =~ ^[0-9]+$ ]] || SEGMENT_LAST_ATTEMPT_AT=0

# 送信に載せる taskId は **segment が確定した後** に決める。context が "none" に落ちて
# 前 segment を継続する分岐で TASK_ID が差し替わるため、ここより前に決めると同じ
# segmentKey に taskId 無しの payload を送ってしまう。BE は同 segment で taskId が
# 変わると衝突として 409 を返すので、segment を切り直したうえ以後は未帰属になる。
PAYLOAD_TASK_ID="$TASK_ID"
if task_is_unresolved "$TASK_ID"; then
  log "note: taskId=$TASK_ID was rejected earlier in this session; not sending it again"
  PAYLOAD_TASK_ID=""
fi

save_state() {
  local tmp="$STATE_FILE.tmp.$$"
  # lastObserved は「次の context 切替で baseline になる値」なので後退させてはいけない。
  # 累計が減った観測 (fail-closed で送信を見送る場合など) で上書きすると、次の segment の
  # baseline が小さくなり、計上済みの分をもう一度送ってしまう。列ごと max で単調更新する。
  # segments は際限なく伸びるので直近 50 本だけ残す。
  printf '%s' "$STATE" | jq -c \
    --argjson observed "$CURRENT" --arg collectorKey "$COLLECTOR_KEY" --arg agent "$AGENT" \
    '(.lastObserved // {}) as $old
     | .lastObserved = (
         ["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens"]
         | map({key: ., value: ([($old[.] // 0), ($observed[.] // 0)] | max)})
         | from_entries)
     | .collectorKey = $collectorKey
     | .agent = $agent
     | .segments = (.segments | if length > 50 then .[-50:] else . end)' >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATE_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

# --- 11. 送信要否の判定 -------------------------------------------------------
# 前回送信値 (segment ではなくセッション累計で持つ) と全列同じなら送らない。
if [[ "$SEGMENT_LAST_SENT" != "null" && -n "$SEGMENT_LAST_SENT" ]]; then
  if [[ "$(printf '%s' "$SEGMENT_LAST_SENT" | jq -cS '.')" == "$(printf '%s' "$CURRENT" | jq -cS '.')" ]]; then
    log "skip: no new usage since the last report (session=$SESSION_ID segment=$SEGMENT_KEY)"
    save_state
    exit 0
  fi
fi

# segment 累計 = セッション累計 − baseline。1 列でも負なら fail-closed でスキップ。
SEGMENT_TOKENS="$(segment_tokens "$CURRENT" "$SEGMENT_BASELINE")"

if printf '%s' "$SEGMENT_TOKENS" | jq -e 'any(.[]; . < 0)' >/dev/null 2>&1; then
  log "skip: segment tokens went negative (session cumulative decreased below the segment baseline); \
refusing to send (session=$SESSION_ID segment=$SEGMENT_KEY current=$CURRENT baseline=$SEGMENT_BASELINE)"
  save_state
  exit 0
fi

if [[ "$(printf '%s' "$SEGMENT_TOKENS" | jq -r '.outputTokens')" -eq 0 ]]; then
  log "skip: segment outputTokens=0, refusing to send an empty usage report (session=$SESSION_ID segment=$SEGMENT_KEY)"
  save_state
  exit 0
fi

# --- 12b. Stop の throttle ----------------------------------------------------
# `Stop` は毎ターン発火する。毎ターン POST すると BE に無意味な負荷をかけるだけなので、
# 同じ segment・context が続いている間は前回送信から一定時間まで送らず、状態
# (lastObserved) だけ更新する。判定は「`SessionEnd` ではない」で行う。イベント名が
# 渡ってこない環境でも既定で throttle が効くようにするため、`Stop` の一致では見ない。
# `SessionEnd` と、context 切替で新しい segment を起こした回は必ず送る
# （セッションの終わりと区間の切れ目は落とせない）。
STOP_THROTTLE_SEC="${COADMAP_AI_USAGE_STOP_THROTTLE_SEC:-600}"
[[ "$STOP_THROTTLE_SEC" =~ ^[0-9]+$ ]] || STOP_THROTTLE_SEC=600
# 前回「送信した」時刻が無ければ、前回「送信を試みた」時刻を使う。
THROTTLE_FROM="$SEGMENT_LAST_SENT_AT"
(( THROTTLE_FROM == 0 )) && THROTTLE_FROM="$SEGMENT_LAST_ATTEMPT_AT"
if [[ "$HOOK_EVENT_NAME" != "SessionEnd" && "$NEW_SEGMENT" != "1" && "$THROTTLE_FROM" -gt 0 ]]; then
  _elapsed=$(( $(now_epoch) - THROTTLE_FROM ))
  if (( _elapsed < STOP_THROTTLE_SEC )); then
    log "skip: throttled (${_elapsed}s since the last report < ${STOP_THROTTLE_SEC}s; event=${HOOK_EVENT_NAME:-unknown} session=$SESSION_ID segment=$SEGMENT_KEY)"
    save_state
    exit 0
  fi
fi

# --- 13. 送信 -----------------------------------------------------------------
# $1: taskId — SENT_PAYLOAD を組み立てて POST し、STATUS を設定する。
# post_report をコマンド置換で呼ぶと subshell になり payload を持ち帰れないので、
# payload の組み立てはここ（親シェル）で行う。
SENT_PAYLOAD=""
STATUS=""
send_once() {
  SENT_PAYLOAD="$(build_payload "$1" "$SEGMENT_KEY" "$SEGMENT_STARTED_AT" "$SEGMENT_BASELINE" "$SEGMENT_TOKENS")"
  STATUS="$(post_report "$SENT_PAYLOAD")"
  # 送信を試みたこと自体を残す。403/404 が続く segment は lastSent が付かないので、
  # これが無いと Stop の throttle が効かず毎ターン POST し続ける。
  STATE="$(printf '%s' "$STATE" | jq -c --arg k "$SEGMENT_KEY" --argjson at "$(now_epoch)" \
    '.segments = (.segments | map(if .segmentKey == $k then (.lastAttemptAt = $at) else . end))')"
}

# taskId 付きで送り、404 (= taskId 未解決) なら taskId を落として同じ segment で
# 1 回だけ送り直す。使用量の記録が主目的なので、紐付けのために使用量ごと捨てない。
# 409 再送後にも同じ 404 が起こり得るので、1 回目と共通の手順にしてある。
send_with_task_fallback() {
  SENT_TASK_ID="$PAYLOAD_TASK_ID"
  send_once "$PAYLOAD_TASK_ID"
  # 404 = taskId 未解決 / 403 = その Task への権限が無い。どちらも「紐付けだけが
  # 失敗している」ので、使用量まで捨てずに taskId を落として送り直す。
  # 同じ session で同じ taskId を何度も試さないよう、state に記録する。
  if [[ ( "$STATUS" == "404" || "$STATUS" == "403" ) && -n "$PAYLOAD_TASK_ID" ]]; then
    log "retry: taskId=$PAYLOAD_TASK_ID rejected ($STATUS); resending without it (session=$SESSION_ID segment=$SEGMENT_KEY)"
    mark_task_unresolved "$PAYLOAD_TASK_ID"
    PAYLOAD_TASK_ID=""
    SENT_TASK_ID=""
    send_once ""
  fi
}

send_with_task_fallback

# 409 = 同 segmentKey でのコンテキスト衝突、または session の mode 衝突。
# 新しい segmentKey を発行して 1 回だけ再送する。baseline は直前に送った累計、
# 無ければ直前の観測累計。
if [[ "$STATUS" == "409" ]]; then
  # 新 segment は「衝突した segment がまだ送れていない分」をそのまま引き継ぐ。
  # 送信済みなら続きは lastSent から、未送信ならその segment の baseline から。
  # ここで lastObserved を使うと、未送信のまま観測だけ進んでいた分を取りこぼす。
  # 「BE に届いた可能性がある最大の累計」から続ける。送信できた累計 (lastSent) と、
  # 送信できずキューに載せた累計 (lastQueued。flush で届き得る) はどちらが新しいとも
  # 限らないので、優先順位で選ばず列ごとの max を採る。
  CONFLICT_BASELINE="$(resume_baseline "$SEGMENT_LAST_SENT" "${SEGMENT_LAST_QUEUED:-null}" "$SEGMENT_BASELINE")"
  log "retry: 409 conflict on segment $SEGMENT_KEY; issuing a fresh segment (session=$SESSION_ID)"
  new_segment "$CONFLICT_BASELINE"
  SEGMENT_TOKENS="$(segment_tokens "$CURRENT" "$SEGMENT_BASELINE")"
  if printf '%s' "$SEGMENT_TOKENS" | jq -e 'any(.[]; . < 0)' >/dev/null 2>&1; then
    log "skip: segment tokens went negative after the 409 retry; not resending (session=$SESSION_ID)"
    save_state
    exit 0
  fi
  send_with_task_fallback
fi

case "$STATUS" in
  200|201)
    record_sent "$SEGMENT_KEY"
    save_state
    log "ok: reported usage (agent=$AGENT model=$MODEL_NAME creds=$CREDS_SOURCE \
in=$(printf '%s' "$SEGMENT_TOKENS" | jq -r '.inputTokens') \
out=$(printf '%s' "$SEGMENT_TOKENS" | jq -r '.outputTokens') \
cacheRead=$(printf '%s' "$SEGMENT_TOKENS" | jq -r '.cacheReadTokens') \
cacheCreate=$(printf '%s' "$SEGMENT_TOKENS" | jq -r '.cacheCreationTokens') \
session=$SESSION_ID segment=$SEGMENT_KEY task=${SENT_TASK_ID:-none})"
    ;;
  422)
    save_state
    # 契約違反の中身が分からないと直せない。応答本文の先頭だけ残す
    # (このエンドポイントの応答にトークンは含まれない)。
    log "abort: contract violation (422); not queueing for resend (session=$SESSION_ID segment=$SEGMENT_KEY) body=$(head -c 500 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
    ;;
  404|403)
    save_state
    log "abort: POST returned $STATUS even without a taskId (session=$SESSION_ID segment=$SEGMENT_KEY)"
    ;;
  409)
    # 新しい segmentKey でも 409 = BE 側で mode が固定済み。次回以降は集計前に打ち切る。
    STATE="$(printf '%s' "$STATE" | jq -c --arg at "$(now_iso)" --argjson atEpoch "$(now_epoch)" \
      '.blocked = {reason: "conflict", at: $at, atEpoch: $atEpoch}')"
    save_state
    log "abort: still 409 after issuing a fresh segment; marking session as blocked (session=$SESSION_ID segment=$SEGMENT_KEY)"
    ;;
  000|5??|429)
    # キューに載った payload は後で flush されて BE に届き得る。届いた前提で次の
    # baseline を決めないと、409 で segment を切り直したときに同じ区間をもう一度送る。
    if queue_save "$SESSION_ID-$SEGMENT_KEY" "$SENT_PAYLOAD"; then
      mark_segment_queued "$SEGMENT_KEY" "$CURRENT"
    fi
    save_state
    log "queued: transient failure (status=$STATUS), saved for resend (session=$SESSION_ID segment=$SEGMENT_KEY)"
    ;;
  *)
    save_state
    log "abort: POST failed (status=$STATUS, session=$SESSION_ID segment=$SEGMENT_KEY agent=$AGENT)"
    ;;
esac

exit 0
