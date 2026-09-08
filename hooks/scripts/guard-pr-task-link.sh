#!/usr/bin/env bash
# PreToolUse(Bash) hook。Coadmap タスク作業セッション中の `gh pr create` を検査し、
# body に Coadmap タスクURL(coadmap.com の /tasks/ リンク)が無ければ exit 2 でブロックして
# タスクリンクの付与を強制する。タスクと無関係な PR は COADMAP_PR_NO_TASK=1 でバイパス可。
set -euo pipefail
input="$(cat)"
# Claude Code は command を文字列で渡すが、シェルツールの実装によっては argv 配列で来る。
# 配列を文字列化しないと `gh` が先頭語として認識されず、検査が黙って素通りする。
cmd="$(printf '%s' "$input" | jq -r '
  (.tool_input.command // .tool_input.cmd // empty)
  | if type == "array" then map(tostring) | join(" ") else . end
' 2>/dev/null || true)"
[[ -n "$cmd" ]] || exit 0

# このセッションで Coadmap タスクが検出されていなければ対象外
# （マーカーは detect-task-id.sh が UserPromptSubmit 時に作成する）
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
marker="${COADMAP_RUN_DIR:-$HOME/.coadmap/run}/${session}.injected"
[[ -f "$marker" ]] || exit 0

# タスクURL判定: coadmap.com ドメインの /tasks/ リンク
has_task_link() { grep -Eq 'https?://[^[:space:])"'"'"']*coadmap\.com/([^[:space:])"'"'"']*/)?tasks/' ; }

# コマンドを実行せず、quote-aware に shell word へ分割する。
# kind: 1=unquoted で始まる word、0=quoted で始まる word、-1=制御演算子。
shell_words=()
shell_word_kinds=()
append_shell_word() {
  [[ $word_started -eq 1 ]] || return 0
  local index="${#shell_words[@]}"
  shell_words[$index]="$word"
  shell_word_kinds[$index]="$word_kind"
  word=""
  word_started=0
  word_kind=0
}

append_shell_operator() {
  local index="${#shell_words[@]}"
  shell_words[$index]="$1"
  shell_word_kinds[$index]=-1
}

tokenize_command() {
  local source="$1" state=unquoted char next i
  word=""
  word_started=0
  word_kind=0
  shell_words=()
  shell_word_kinds=()

  for ((i = 0; i < ${#source}; i++)); do
    char="${source:i:1}"
    case "$state" in
      single)
        if [[ "$char" == "'" ]]; then
          state=unquoted
        else
          word+="$char"
        fi
        ;;
      double)
        if [[ "$char" == '"' ]]; then
          state=unquoted
        elif [[ "$char" == "\\" && $((i + 1)) -lt ${#source} ]]; then
          next="${source:i+1:1}"
          case "$next" in
            '"'|'$'|'`'|'\\') word+="$next"; i=$((i + 1)) ;;
            $'\n') i=$((i + 1)) ;;
            *) word+="\\" ;;
          esac
        else
          word+="$char"
        fi
        ;;
      unquoted)
        if [[ "$char" == ' ' || "$char" == $'\t' || "$char" == $'\r' ]]; then
          append_shell_word
        elif [[ "$char" == $'\n' ]]; then
          append_shell_word
          append_shell_operator "$char"
        else
          case "$char" in
            '#')
              if [[ $word_started -eq 0 ]]; then
                while [[ $((i + 1)) -lt ${#source} && "${source:i+1:1}" != $'\n' ]]; do
                  i=$((i + 1))
                done
              else
                word+="$char"
              fi
              ;;
            "'"|'"')
              if [[ $word_started -eq 0 ]]; then
                word_started=1
                word_kind=0
              fi
              [[ "$char" == "'" ]] && state=single || state=double
              ;;
            '\\')
              if [[ $((i + 1)) -lt ${#source} ]]; then
                next="${source:i+1:1}"
                if [[ "$next" == $'\n' ]]; then
                  i=$((i + 1))
                  continue
                fi
                if [[ $word_started -eq 0 ]]; then
                  word_started=1
                  word_kind=1
                fi
                word+="$next"
                i=$((i + 1))
              fi
              ;;
            ';'|'|'|'&'|'('|')'|'<'|'>')
              append_shell_word
              append_shell_operator "$char"
              ;;
            *)
              if [[ $word_started -eq 0 ]]; then
                word_started=1
                word_kind=1
              fi
              word+="$char"
              ;;
          esac
        fi
        ;;
    esac
  done
  append_shell_word
}

find_pr_create() {
  local at_command_start=1 skip_redirect_target=0 prefix_bypass=0 i word kind command_name
  pr_args_index=-1
  task_bypass=0
  tokenize_command "$cmd"

  for ((i = 0; i < ${#shell_words[@]}; i++)); do
    word="${shell_words[$i]}"
    kind="${shell_word_kinds[$i]}"

    if [[ $kind -eq -1 ]]; then
      case "$word" in
        '<'|'>') skip_redirect_target=1 ;;
        *) at_command_start=1; skip_redirect_target=0; prefix_bypass=0 ;;
      esac
      continue
    fi

    if [[ $skip_redirect_target -eq 1 ]]; then
      skip_redirect_target=0
      continue
    fi

    [[ $at_command_start -eq 1 ]] || continue
    if [[ $kind -eq 1 && "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      [[ "$word" == "COADMAP_PR_NO_TASK=1" ]] && prefix_bypass=1
      continue
    fi

    # IO-number redirect（例: 2>/dev/null）は command word より前に置ける。
    if [[ $kind -eq 1 && "$word" =~ ^[0-9]+$ \
      && ${shell_word_kinds[$((i + 1))]:--1} -eq -1 \
      && ( "${shell_words[$((i + 1))]:-}" == "<" || "${shell_words[$((i + 1))]:-}" == ">" ) ]]; then
      continue
    fi

    command_name="${word##*/}"
    case "$command_name" in
      if|while|until|then|do|else|elif|'!'|time|command|env|sudo|builtin|exec|nohup)
        continue
        ;;
    esac

    if [[ "$command_name" == "gh" \
      && ${shell_word_kinds[$((i + 1))]:--1} -ne -1 && "${shell_words[$((i + 1))]:-}" == "pr" \
      && ${shell_word_kinds[$((i + 2))]:--1} -ne -1 && "${shell_words[$((i + 2))]:-}" == "create" ]]; then
      pr_args_index=$((i + 3))
      task_bypass=$prefix_bypass
      return 0
    fi

    at_command_start=0
  done
  return 1
}

inspect_pr_options() {
  local i word kind next_index
  body=""
  body_file=""
  body_seen=0
  body_file_seen=0

  for ((i = pr_args_index; i < ${#shell_words[@]}; i++)); do
    word="${shell_words[$i]}"
    kind="${shell_word_kinds[$i]}"
    if [[ $kind -eq -1 ]]; then
      case "$word" in
        '<'|'>')
          while [[ ${shell_word_kinds[$((i + 1))]:--1} -eq -1 \
            && ( "${shell_words[$((i + 1))]:-}" == "<" \
              || "${shell_words[$((i + 1))]:-}" == ">" \
              || "${shell_words[$((i + 1))]:-}" == "&" ) ]]; do
            i=$((i + 1))
          done
          next_index=$((i + 1))
          [[ ${shell_word_kinds[$next_index]:--1} -eq -1 ]] || i=$next_index
          continue
          ;;
        *) break ;;
      esac
    fi

    case "$word" in
      --) break ;;
      --body|-b)
        body_seen=1
        next_index=$((i + 1))
        if [[ ${shell_word_kinds[$next_index]:--1} -ne -1 ]]; then
          body="${shell_words[$next_index]:-}"
          i=$next_index
        fi
        ;;
      --body=*) body_seen=1; body="${word#--body=}" ;;
      -b?*) body_seen=1; body="${word#-b}" ;;
      --body-file|-F)
        body_file_seen=1
        next_index=$((i + 1))
        if [[ ${shell_word_kinds[$next_index]:--1} -ne -1 ]]; then
          body_file="${shell_words[$next_index]:-}"
          i=$next_index
        fi
        ;;
      --body-file=*) body_file_seen=1; body_file="${word#--body-file=}" ;;
      -F=*) body_file_seen=1; body_file="${word#-F=}" ;;
      -F?*) body_file_seen=1; body_file="${word#-F}" ;;
      --assignee|-a|--base|-B|--head|-H|--label|-l|--milestone|-m|--project|-p|--recover|--reviewer|-r|--template|-T|--title|-t)
        next_index=$((i + 1))
        [[ ${shell_word_kinds[$next_index]:--1} -eq -1 ]] || i=$next_index
        ;;
    esac
  done
}

# 実行される gh pr create が無ければ対象外。引用符内・コメント内の文字列は無視する。
find_pr_create || exit 0

# 明示バイパスは gh の直前に置かれた shell assignment だけを認める。
[[ $task_bypass -eq 1 ]] && exit 0

inspect_pr_options
if [[ $body_seen -eq 1 ]] && printf '%s' "$body" | has_task_link; then
  exit 0
fi

# --body-file / -F は読み取れる実パスだけを厳格検査する。hook は実行前に
# 動くため、シェル変数や stdin は eval せず、理由付き警告で gh に委ねる。
if [[ $body_file_seen -eq 1 ]]; then
  if [[ "$body_file" == "-" || ! -f "$body_file" || ! -r "$body_file" ]]; then
    printf >&2 '[coadmap-task-workflow] 警告: PR 本文ファイルを読み取れないため、ブロックせず続行します: %q\n' "$body_file"
    exit 0
  fi

  has_task_link < "$body_file" && exit 0
fi

cat >&2 <<'EOF'
[coadmap-task-workflow] PR body に Coadmap タスクリンクがありません。
このセッションは Coadmap タスク作業中です。PR body の先頭1行目に必ずタスクリンクを入れて再実行してください:

  [[<TASK_ID>] <TASK_TITLE>](<https://coadmap.com/.../tasks/... のタスクURL>)

タスクURLが未取得なら coadmap-task-workflow skill の references/00-orientation.md に従って MCP で取得してください。
この PR が Coadmap タスクと無関係な場合のみ、コマンド先頭に COADMAP_PR_NO_TASK=1 を付けてバイパスできます。
EOF
exit 2
