#!/usr/bin/env bash
# PreToolUse hook。Coadmap タスク作業セッション中の PR 作成(`gh pr create` / `gh pr new`、
# MCP の *__create_pull_request ツール)を検査し、body に Coadmap タスクURL が無ければ exit 2 で
# ブロックしてタスクリンクの付与を強制する。タスクと無関係な PR は COADMAP_PR_NO_TASK=1 でバイパス可。
#
# 狙いは付け忘れなどの正直なミスで、意図的な回避(python -c や gh api での作成、作成後に
# gh pr edit で本文を書き換える等)は防がない。PR 作成後に skill が body を読み戻して確かめるのが二段目の検査。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../skills/coadmap-task-workflow/scripts/lib/task-link.sh
source "$HERE/../../skills/coadmap-task-workflow/scripts/lib/task-link.sh"
input="$(cat)"

# このセッションで Coadmap タスクが検出されていなければ対象外
# （マーカーは detect-task-id.sh が UserPromptSubmit 時に作成する）
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
marker="${COADMAP_RUN_DIR:-$HOME/.coadmap/run}/${session}.injected"
[[ -f "$marker" ]] || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
# Claude Code は command を文字列で渡すが、シェルツールの実装によっては argv 配列で来る。
# 配列を文字列化しないと `gh` が先頭語として認識されず、検査が黙って素通りする。
cmd="$(printf '%s' "$input" | jq -r '
  (.tool_input.command // .tool_input.cmd // empty)
  | if type == "array" then map(tostring) | join(" ") else . end
' 2>/dev/null || true)"
if [[ "$tool_name" != *__create_pull_request ]]; then
  # 以下の字句解析は 1 文字ずつ読むので長いコマンドでは遅い。gh pr を含み得ないコマンドはここで返す。
  [[ "$cmd" == *gh* && "$cmd" == *pr* ]] || exit 0
fi

# taskHosts は利用者リポの設定なので、hook プロセスの cwd よりセッションの cwd を優先して探す。
config_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -n "$config_dir" && -d "$config_dir" ]] || config_dir="."
# 実在するタスクの ID は Relay の global ID("Task:<n>" の base64)で最短でも 8 文字になる。
# 長さを見ないと /tasks/x のような書きかけの URL で検査を通せてしまう。
task_link_re="$(coadmap_task_url_prefix_regex "$(coadmap_task_host_pattern "$config_dir")")[A-Za-z0-9=_%~+-]{8,}"
# grep -q は一致した時点で入力を読み捨てるので、長い本文だと書き手が SIGPIPE で落ち、
# pipefail によって「リンク無し」と判定されてしまう。最後まで読ませる。
has_task_link() { LC_ALL=C grep -E "$task_link_re" >/dev/null; }

block() {
  cat >&2 <<'EOF'
[coadmap-task-workflow] PR body に Coadmap タスクリンクがありません。
このセッションは Coadmap タスク作業中です。PR body の先頭1行目に必ずタスクリンクを入れて再実行してください:

  [[<TASK_ID>] <TASK_TITLE>](<https://coadmap.com/.../tasks/... のタスクURL>)

タスクURLが未取得なら coadmap-task-workflow skill の references/00-orientation.md に従って MCP で取得してください。
EOF
  if [[ "${1:-}" == mcp ]]; then
    cat >&2 <<'EOF'
この PR が Coadmap タスクと無関係な場合は、gh CLI で COADMAP_PR_NO_TASK=1 gh pr create ... として作成してください。
EOF
  else
    cat >&2 <<'EOF'
この PR が Coadmap タスクと無関係な場合のみ、コマンド先頭に COADMAP_PR_NO_TASK=1 を付けてバイパスできます
(例: COADMAP_PR_NO_TASK=1 gh pr create ...。export では効きません)。
EOF
  fi
  exit 2
}

if [[ "$tool_name" == *__create_pull_request ]]; then
  pr_body="$(printf '%s' "$input" | jq -r '.tool_input.body // empty | if type == "string" then . else tojson end' 2>/dev/null || true)"
  printf '%s' "$pr_body" | has_task_link && exit 0
  block mcp
fi

whole_cmd="$cmd"
gh_pr_create_re='(^|[^A-Za-z0-9_.-])gh([[:space:]]+[^[:space:]]+)*[[:space:]]+pr[[:space:]]+(create|new)([^A-Za-z0-9_-]|$)'

# コマンドを実行せず、quote-aware に shell word へ分割する。
# kind: 1=unquoted で始まる word、0=quoted で始まる word、-1=制御演算子。
# コマンド置換の中身は subst_texts に、heredoc の本文は heredoc_texts に分けて取り出し、
# どちらも word としては扱わない(heredoc 本文に書かれた文字列をコマンドと誤認しないため)。
shell_words=()
shell_word_kinds=()
subst_texts=()
heredoc_texts=()
heredoc_ops=()
pending_delims=()
pending_strip=()
pending_quoted=()
pending_ops=()

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

# usage: parse_heredoc_delim <"<<" の直後の位置>
#   -> hd_delim / hd_strip(<<- なら 1) / hd_quoted(区切りを引用していれば 1) / hd_next(区切り語の直後の位置)
parse_heredoc_delim() {
  local p="$1" c
  hd_delim=""
  hd_strip=0
  hd_quoted=0
  if [[ "${src:p:1}" == '-' ]]; then
    hd_strip=1
    p=$((p + 1))
  fi
  while [[ "${src:p:1}" == ' ' || "${src:p:1}" == $'\t' ]]; do p=$((p + 1)); done
  while ((p < ${#src})); do
    c="${src:p:1}"
    case "$c" in
      ' '|$'\t'|$'\n'|';'|'|'|'&'|'('|')'|'<'|'>') break ;;
      "'"|'"')
        hd_quoted=1
        p=$((p + 1))
        while ((p < ${#src})) && [[ "${src:p:1}" != "$c" ]]; do
          hd_delim+="${src:p:1}"
          p=$((p + 1))
        done
        ;;
      "\\")
        hd_quoted=1
        p=$((p + 1))
        hd_delim+="${src:p:1}"
        ;;
      *) hd_delim+="$c" ;;
    esac
    p=$((p + 1))
  done
  hd_next=$p
}

# usage: read_heredoc_body <本文の先頭位置> <区切り語> <strip>
#   -> hd_body / hd_next(区切り行の直後の位置)
read_heredoc_body() {
  local pos="$1" rest line cmp
  hd_body=""
  while ((pos < ${#src})); do
    rest="${src:pos}"
    line="${rest%%$'\n'*}"
    pos=$((pos + ${#line} + 1))
    cmp="$line"
    if [[ $3 -eq 1 ]]; then
      while [[ "$cmp" == $'\t'* ]]; do cmp="${cmp#$'\t'}"; done
    fi
    [[ "$cmp" == "$2" ]] && break
    hd_body+="$line"$'\n'
  done
  hd_next=$pos
}

# usage: read_dollar_paren <pos of $>  -> subst_body / subst_end(閉じ括弧の位置)
# 中の heredoc 本文は読み飛ばす。本文の括弧や引用符を数えると、よく使われる
# --body "$(cat <<'EOF' ... EOF)" で置換の終わりを見誤る。
read_dollar_paren() {
  local j=$(($1 + 2)) depth=1 quote="" c k
  local delims=() strips=()
  while ((j < ${#src})); do
    c="${src:j:1}"
    if [[ "$quote" == "'" ]]; then
      [[ "$c" == "'" ]] && quote=""
    elif [[ "$quote" == '"' ]]; then
      if [[ "$c" == "\\" ]]; then
        j=$((j + 1))
      elif [[ "$c" == '"' ]]; then
        quote=""
      fi
    else
      case "$c" in
        "'"|'"') quote="$c" ;;
        "\\") j=$((j + 1)) ;;
        '(') depth=$((depth + 1)) ;;
        ')')
          depth=$((depth - 1))
          [[ $depth -eq 0 ]] && break
          ;;
        '<')
          if [[ "${src:j+1:1}" == '<' && "${src:j+2:1}" != '<' ]]; then
            parse_heredoc_delim $((j + 2))
            delims[${#delims[@]}]="$hd_delim"
            strips[${#strips[@]}]="$hd_strip"
            j=$((hd_next - 1))
          fi
          ;;
        $'\n')
          for ((k = 0; k < ${#delims[@]}; k++)); do
            read_heredoc_body $((j + 1)) "${delims[k]}" "${strips[k]}"
            j=$((hd_next - 1))
          done
          delims=()
          strips=()
          ;;
      esac
    fi
    j=$((j + 1))
  done
  subst_body="${src:$1+2:j-$1-2}"
  subst_end=$j
}

# usage: read_backtick <pos of `>  -> subst_body / subst_end
read_backtick() {
  local j=$(($1 + 1)) c
  while ((j < ${#src})); do
    c="${src:j:1}"
    if [[ "$c" == "\\" ]]; then
      j=$((j + 2))
      continue
    fi
    [[ "$c" == '`' ]] && break
    j=$((j + 1))
  done
  subst_body="${src:$1+1:j-$1-1}"
  subst_end=$j
}

# 現在位置 i が $( か ` ならコマンド置換として読み、word に原文のまま足す。
take_substitution() {
  local c="${src:i:1}"
  if [[ "$c" == '$' && "${src:i+1:1}" == '(' ]]; then
    read_dollar_paren "$i"
  elif [[ "$c" == '`' ]]; then
    read_backtick "$i"
  else
    return 1
  fi
  subst_texts[${#subst_texts[@]}]="$subst_body"
  word+="${src:i:subst_end-i+1}"
  i=$subst_end
}

# 区切りを引用した heredoc(<<'EOF')は本文が展開されない。引用しない場合だけ本文中の
# コマンド置換が実行されるので、そこだけ拾う。
collect_heredoc_substitutions() {
  local saved_src="$src" p c
  src="$1"
  for ((p = 0; p < ${#src}; p++)); do
    c="${src:p:1}"
    if [[ "$c" == "\\" ]]; then
      p=$((p + 1))
    elif [[ "$c" == '$' && "${src:p+1:1}" == '(' ]]; then
      read_dollar_paren "$p"
      subst_texts[${#subst_texts[@]}]="$subst_body"
      p=$subst_end
    elif [[ "$c" == '`' ]]; then
      read_backtick "$p"
      subst_texts[${#subst_texts[@]}]="$subst_body"
      p=$subst_end
    fi
  done
  src="$saved_src"
}

# 改行の直後から、保留中の heredoc 本文を区切り行まで読み飛ばす。
consume_heredocs() {
  local k pos=$((i + 1)) index
  for ((k = 0; k < ${#pending_delims[@]}; k++)); do
    read_heredoc_body "$pos" "${pending_delims[k]}" "${pending_strip[k]}"
    pos=$hd_next
    index="${#heredoc_texts[@]}"
    heredoc_texts[$index]="$hd_body"
    heredoc_ops[$index]="${pending_ops[k]}"
    [[ ${pending_quoted[k]} -eq 1 ]] || collect_heredoc_substitutions "$hd_body"
  done
  pending_delims=()
  pending_strip=()
  pending_quoted=()
  pending_ops=()
  i=$((pos - 1))
}

# 現在位置 i の "<<" から区切り語を読み、本文は次の改行で consume_heredocs に任せる。
start_heredoc() {
  local index
  append_shell_word
  index="${#shell_words[@]}"
  append_shell_operator '<'
  parse_heredoc_delim $((i + 2))
  i=$((hd_next - 1))
  word="$hd_delim"
  word_started=1
  word_kind=0
  append_shell_word
  pending_delims[${#pending_delims[@]}]="$hd_delim"
  pending_strip[${#pending_strip[@]}]="$hd_strip"
  pending_quoted[${#pending_quoted[@]}]="$hd_quoted"
  pending_ops[${#pending_ops[@]}]="$index"
}

tokenize_command() {
  local state=unquoted char next
  src="$1"
  i=0
  word=""
  word_started=0
  word_kind=0
  shell_words=()
  shell_word_kinds=()
  subst_texts=()
  heredoc_texts=()
  heredoc_ops=()

  for ((i = 0; i < ${#src}; i++)); do
    char="${src:i:1}"
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
        elif [[ "$char" == "\\" && $((i + 1)) -lt ${#src} ]]; then
          next="${src:i+1:1}"
          case "$next" in
            '"'|'$'|'`'|"\\") word+="$next"; i=$((i + 1)) ;;
            $'\n') i=$((i + 1)) ;;
            *) word+="\\" ;;
          esac
        elif ! take_substitution; then
          word+="$char"
        fi
        ;;
      unquoted)
        if [[ "$char" == ' ' || "$char" == $'\t' || "$char" == $'\r' ]]; then
          append_shell_word
        elif [[ "$char" == $'\n' ]]; then
          append_shell_word
          append_shell_operator "$char"
          [[ ${#pending_delims[@]} -eq 0 ]] || consume_heredocs
        else
          case "$char" in
            '#')
              if [[ $word_started -eq 0 ]]; then
                while [[ $((i + 1)) -lt ${#src} && "${src:i+1:1}" != $'\n' ]]; do
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
            "\\")
              if [[ $((i + 1)) -lt ${#src} ]]; then
                next="${src:i+1:1}"
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
            '<')
              if [[ "${src:i+1:1}" == '<' && "${src:i+2:1}" != '<' ]]; then
                start_heredoc
              else
                append_shell_word
                append_shell_operator '<'
                # here-string(<<<)は後続 word 1 つが入力になる。redirect と同じく target として読み飛ばす。
                [[ "${src:i+1:2}" == '<<' ]] && i=$((i + 2))
              fi
              ;;
            ';'|'|'|'&'|'('|')'|'>')
              append_shell_word
              append_shell_operator "$char"
              ;;
            '$'|'`')
              if [[ $word_started -eq 0 ]]; then
                word_started=1
                word_kind=1
              fi
              take_substitution || word+="$char"
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

# gh や shell の前に置けるラッパーコマンドのうち、値を取るオプション。
# 値を読み飛ばさないと値の方をコマンド名と取り違えて、後ろの gh pr create を見失う。
wrapper_option_takes_value() {
  case "$1:$2" in
    timeout:-s|timeout:-k|timeout:--signal|timeout:--kill-after) return 0 ;;
    nice:-n|nice:--adjustment) return 0 ;;
    env:-u|env:--unset|env:-C|env:--chdir|env:-S|env:--split-string) return 0 ;;
    stdbuf:-i|stdbuf:-o|stdbuf:-e|stdbuf:--input|stdbuf:--output|stdbuf:--error) return 0 ;;
    xargs:-I|xargs:-J|xargs:-L|xargs:-n|xargs:-P|xargs:-R|xargs:-S|xargs:-s|xargs:-E|xargs:-d|xargs:-a) return 0 ;;
    xargs:--max-args|xargs:--max-lines|xargs:--max-procs|xargs:--max-chars|xargs:--delimiter|xargs:--arg-file) return 0 ;;
    sudo:-u|sudo:-g|sudo:-h|sudo:-p|sudo:-C|sudo:-D|sudo:-R|sudo:-T|sudo:-U|sudo:-r|sudo:-t) return 0 ;;
    sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|sudo:--chdir|sudo:--other-user) return 0 ;;
    exec:-a) return 0 ;;
    ionice:-c|ionice:-n|ionice:-p|ionice:-P|ionice:-u) return 0 ;;
  esac
  return 1
}

# 文字列として実行される部分(eval / sh -c / シェルの標準入力に渡す heredoc)は静的に追えない。
# gh pr create/new が含まれていれば、コマンド全体にタスクリンクが無い限りブロックする(fail-close)。
opaque_pr_create=0
check_opaque_text() {
  printf '%s' "$1" | grep -E "$gh_pr_create_re" >/dev/null && opaque_pr_create=1
  return 0
}

# usage: command_end <index>  -> command_end_index(simple command の直後の制御演算子の位置)
command_end() {
  local j="$1"
  while ((j < ${#shell_words[@]})); do
    if [[ ${shell_word_kinds[$j]} -eq -1 && "${shell_words[$j]}" != '<' && "${shell_words[$j]}" != '>' ]]; then
      break
    fi
    j=$((j + 1))
  done
  command_end_index=$j
}

# usage: inspect_opaque_command <command word index> <command name>
inspect_opaque_command() {
  local start=$(($1 + 1)) j text="" has_c=0 k
  command_end "$start"
  for ((j = start; j < command_end_index; j++)); do
    [[ ${shell_word_kinds[$j]} -eq -1 ]] && continue
    text+="${shell_words[$j]} "
    [[ "${shell_words[$j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]] && has_c=1
  done
  case "$2" in
    eval) check_opaque_text "$text" ;;
    *)
      if [[ $has_c -eq 1 ]]; then
        check_opaque_text "$text"
      else
        for ((k = 0; k < ${#heredoc_texts[@]}; k++)); do
          if [[ ${heredoc_ops[k]} -gt $1 && ${heredoc_ops[k]} -lt $command_end_index ]]; then
            check_opaque_text "${heredoc_texts[k]}"
          fi
        done
      fi
      ;;
  esac
  return 0
}

# usage: gh_pr_create_args <gh word index>  -> 0 なら pr_args_index に pr create/new 直後の位置
gh_pr_create_args() {
  local j=$(($1 + 1))
  # gh のグローバルオプション(--repo owner/name, -R x, --hostname h 等)は pr の前に置ける。
  # 値を取るものは次の word ごと読み飛ばす。
  while [[ ${shell_word_kinds[$j]:--1} -ne -1 && "${shell_words[$j]:-}" == -* ]]; do
    case "${shell_words[$j]}" in
      --repo|-R|--hostname) j=$((j + 2)) ;;
      *) j=$((j + 1)) ;;
    esac
  done
  [[ ${shell_word_kinds[$j]:--1} -ne -1 && "${shell_words[$j]:-}" == "pr" ]] || return 1
  case "${shell_words[$((j + 1))]:-}" in
    create|new) [[ ${shell_word_kinds[$((j + 1))]:--1} -ne -1 ]] || return 1 ;;
    *) return 1 ;;
  esac
  pr_args_index=$((j + 2))
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
  [[ $body_seen -eq 1 ]] && body_substitution_as_file
  return 0
}

# --body "$(cat <path>)" / --body "$(< <path>)" は --body-file <path> と同じ意味なので、同じ扱いにする。
body_substitution_as_file() {
  local re='^\$\([[:space:]]*(cat[[:space:]]+|<[[:space:]]*)([^[:space:]]|[^[:space:]].*[^[:space:]])[[:space:]]*\)$'
  local unsafe='[][:space:];|&<>()`"'"'"']' path
  [[ "$body" =~ $re ]] || return 0
  path="${BASH_REMATCH[2]}"
  if [[ ${#path} -ge 2 && ( "$path" == \"*\" || "$path" == \'*\' ) ]]; then
    path="${path:1:${#path}-2}"
    [[ "$path" =~ [\"\'\`] ]] && return 0
  elif [[ "$path" =~ $unsafe ]]; then
    return 0
  fi
  [[ "${path:0:1}" == "~" && "${path:1:1}" == / ]] && path="$HOME/${path:2}"
  body_seen=0
  body=""
  body_file_seen=1
  body_file="$path"
}

# usage: check_pr_create <task_bypass>
check_pr_create() {
  # 明示バイパスは gh の直前に置かれた shell assignment だけを認める。
  [[ $1 -eq 1 ]] && return 0

  inspect_pr_options
  if [[ $body_seen -eq 1 ]] && printf '%s' "$body" | has_task_link; then
    return 0
  fi

  # --body-file / -F は読み取れる実パスだけを厳格検査する。hook は実行前に
  # 動くため、シェル変数や stdin は eval せず、理由付き警告で gh に委ねる。
  if [[ $body_file_seen -eq 1 ]]; then
    if [[ "$body_file" == "-" || ! -f "$body_file" || ! -r "$body_file" ]]; then
      printf >&2 '[coadmap-task-workflow] 警告: PR 本文ファイルを読み取れないため、ブロックせず続行します: %q\n' "$body_file"
      return 0
    fi
    has_task_link < "$body_file" && return 0
  fi

  block
}

# 実行される gh pr create/new を全件検査する。引用符内・コメント内・heredoc 本文の文字列は無視する。
scan_commands() {
  local i word kind command_name at_command_start=1 skip_redirect_target=0 prefix_bypass=0
  local wrapper="" wrapper_positional=0

  for ((i = 0; i < ${#shell_words[@]}; i++)); do
    word="${shell_words[$i]}"
    kind="${shell_word_kinds[$i]}"

    if [[ $kind -eq -1 ]]; then
      case "$word" in
        '<'|'>') skip_redirect_target=1 ;;
        *) at_command_start=1; skip_redirect_target=0; prefix_bypass=0; wrapper="" ;;
      esac
      continue
    fi

    if [[ $skip_redirect_target -eq 1 ]]; then
      skip_redirect_target=0
      continue
    fi

    [[ $at_command_start -eq 1 ]] || continue

    if [[ -n "$wrapper" ]]; then
      if [[ "$word" == -* ]]; then
        if wrapper_option_takes_value "$wrapper" "$word"; then
          [[ "$wrapper" == env && ( "$word" == -S || "$word" == --split-string ) ]] \
            && check_opaque_text "${shell_words[$((i + 1))]:-}"
          i=$((i + 1))
        fi
        continue
      fi
      # timeout は最初の非オプション引数が DURATION
      if [[ "$wrapper" == timeout && $wrapper_positional -eq 0 ]]; then
        wrapper_positional=1
        continue
      fi
    fi

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
      if|while|until|then|do|else|elif|'!'|'{'|builtin|nohup)
        continue
        ;;
      time|command|env|sudo|exec|timeout|nice|xargs|stdbuf|ionice)
        wrapper="$command_name"
        wrapper_positional=0
        continue
        ;;
    esac
    wrapper=""
    at_command_start=0

    case "$command_name" in
      gh)
        gh_pr_create_args "$i" && check_pr_create "$prefix_bypass"
        ;;
      eval|sh|bash|zsh|dash|ksh)
        inspect_opaque_command "$i" "$command_name"
        ;;
    esac
  done
  return 0
}

analyze_command() {
  local k rc
  tokenize_command "$1"
  # コマンド置換の中身は実行されるシェルコードなので、同じ規則で再帰的に検査する。
  # 大域変数を共有しているのでサブシェルで隔離する。
  for ((k = 0; k < ${#subst_texts[@]}; k++)); do
    rc=0
    (analyze_command "${subst_texts[k]}") || rc=$?
    [[ $rc -eq 2 ]] && exit 2
  done
  scan_commands
  if [[ $opaque_pr_create -eq 1 ]] && ! printf '%s' "$whole_cmd" | has_task_link; then
    printf >&2 '[coadmap-task-workflow] eval / sh -c / シェルに渡す heredoc 内の gh pr create は検査できないため、タスクリンクが確認できる形で実行してください。\n'
    block
  fi
  return 0
}

analyze_command "$cmd"
exit 0
