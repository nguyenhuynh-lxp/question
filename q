#!/usr/bin/env bash
set -euo pipefail

# q  <question>              Ask a new question (creates a new session)
# q -m <question>            Same, but inject relevant notes from memory.md
# fq <question>              Follow up on the most recent session
# fq <session-id> <question> Follow up on a specific session (id from mq)
# lq                         List the 10 newest sessions and stay interactive:
#                            0-9 copies that session id to the clipboard, q quits
# lq --flush [days]          Distill sessions older than [days] (default 30)
#                            into memory.md, then delete them

Q_HOME="${Q_HOME:-$HOME/.q}"
Q_SESSION_DIR="$Q_HOME/sessions"
Q_MEMORY_FILE="$Q_HOME/memory.md"

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-$SCRIPT_DIR/SYSTEM-PROMPT.md}"

mkdir -p "$Q_SESSION_DIR"

read_prompt() {
  prompt="$*"
  if [ ! -t 0 ]; then
    stdin="$(cat)"
    if [ -n "$prompt" ]; then
      prompt="$prompt

$stdin"
    else
      prompt="$stdin"
    fi
  fi
}

# Newest session file in the store, empty string if none.
latest_session() {
  ls -t "$Q_SESSION_DIR"/*.jsonl 2>/dev/null | head -1 || true
}

# Resolve a (partial) session id to its file, empty string if no match.
resolve_session() {
  local id="$1"
  ls -t "$Q_SESSION_DIR"/*"$id"*.jsonl 2>/dev/null | head -1 || true
}

spinner() {
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  while :; do
    printf '\r%s Thinking...' "${frames[i]}" >&2
    i=$(((i + 1) % ${#frames[@]}))
    sleep 0.1
  done
}

cleanup_spinner() {
  if [ -n "${spinner_pid:-}" ]; then
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    spinner_pid=""
  fi
  printf '\r\033[K' >&2
}

# Run pi in print mode with the q system prompt, streaming the answer with a
# spinner while waiting for the first byte. Extra pi args are passed through.
run_pi() {
  cd "$HOME"

  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  trap 'cleanup_spinner; rm -f "$fifo"' EXIT INT TERM

  pi -p \
    --system-prompt "$(cat "$SYSTEM_PROMPT_FILE")" \
    --no-context-files \
    --no-approve \
    --session-dir "$Q_SESSION_DIR" \
    "$@" \
    "$prompt" >"$fifo" 2>&1 &
  pi_pid=$!

  spinner &
  spinner_pid=$!

  exec 3<"$fifo"

  if IFS= read -r -n 1 first_byte <&3; then
    cleanup_spinner
    if command -v glow >/dev/null 2>&1 && [ "${Q_GLOW:-1}" != "0" ]; then
      { printf '%s' "$first_byte"; cat <&3; } | glow -
    else
      printf -- '---\n'
      printf '%s' "$first_byte"
      cat <&3
      printf -- '\n---\n'
    fi
  else
    cleanup_spinner
  fi

  wait "$pi_pid"
  exit $?
}

# Print memory.md sections (## blocks) matching any keyword (4+ letters) of
# the question, case-insensitively. Prints nothing when there is no match.
memory_context() {
  local question="$1"
  [ -s "$Q_MEMORY_FILE" ] || return 0

  local regex
  regex="$(printf '%s' "$question" |
    tr -cs '[:alnum:]' '\n' |
    awk 'length($0) >= 4 { print tolower($0) }' |
    sort -u | paste -sd'|' -)"
  [ -n "$regex" ] || return 0

  awk -v re="$regex" '
    /^## / { if (matched) printf "%s", buf; buf = ""; matched = 0 }
    { buf = buf $0 "\n"; if (tolower($0) ~ re) matched = 1 }
    END { if (matched) printf "%s", buf }
  ' "$Q_MEMORY_FILE"
}

cmd_q() {
  local use_memory=0
  if [ "${1:-}" = "-m" ]; then
    use_memory=1
    shift
  fi

  read_prompt "$@"
  if [ -z "$prompt" ]; then
    echo "usage: q [-m] <question>" >&2
    exit 1
  fi

  if [ "$use_memory" = 1 ]; then
    local mem
    mem="$(memory_context "$prompt")"
    if [ -n "$mem" ]; then
      prompt="Notes distilled from my past Q&A sessions, use them if relevant:

$mem
---

$prompt"
    else
      echo "(no relevant memory found, asking without it)" >&2
    fi
  fi

  run_pi
}

cmd_fq() {
  local session_file=""

  # fq <session-id> <question>: first arg matches a stored session
  if [ $# -ge 2 ]; then
    session_file="$(resolve_session "$1")"
    if [ -n "$session_file" ]; then
      shift
    fi
  fi

  if [ -z "$session_file" ]; then
    session_file="$(latest_session)"
  fi

  read_prompt "$@"
  if [ -z "$prompt" ]; then
    echo "usage: fq [session-id] <question>" >&2
    exit 1
  fi

  if [ -z "$session_file" ]; then
    echo "(no previous q session found, starting a new one)" >&2
    run_pi
  fi

  run_pi --session "$session_file"
}

# Summary of a session: its name if set, else the first user message.
session_summary() {
  jq -rs '
    ([.[] | select(.type == "session_info") | .name | select(. != null)] | last)
    // ([.[] | select(.type == "message" and .message.role == "user")
        | [.message.content[]? | select(.type == "text") | .text] | join(" ")
        | select(. != "")] | first)
    // "(empty session)"
    | gsub("\\s+"; " ") | gsub("^ | $"; "")
  ' "$1" 2>/dev/null || echo "(unreadable session)"
}

session_id() {
  basename "$1" .jsonl | sed 's/^[^_]*_//'
}

cmd_lq() {
  if [ "${1:-}" = "--flush" ]; then
    cmd_mq_flush "${2:-30}"
    return
  fi

  local files
  files="$(ls -t "$Q_SESSION_DIR"/*.jsonl 2>/dev/null | head -10 || true)"
  if [ -z "$files" ]; then
    echo "no q sessions yet" >&2
    return
  fi

  local -a ids
  local f id summary bg reset=$'\033[0m'
  local i=0
  while IFS= read -r f; do
    id="$(session_id "$f")"
    ids[i]="$id"
    summary="$(session_summary "$f")"
    if [ $((i % 2)) -eq 0 ]; then
      bg=$'\033[48;5;236m'
    else
      bg=$'\033[48;5;238m'
    fi
    printf '%s%d - %s - %.80s\033[K%s\n' "$bg" "$i" "${id##*-}" "$summary" "$reset"
    i=$((i + 1))
  done <<<"$files"

  # Interactive picker: a digit copies that session's full id, q quits.
  local choice
  while :; do
    printf '(0-%d: copy session id, q: quit) > ' "$((i - 1))" >&2
    IFS= read -r choice </dev/tty || break
    case "$choice" in
    q) break ;;
    [0-9])
      if [ "$choice" -lt "$i" ]; then
        if command -v pbcopy >/dev/null 2>&1; then
          printf '%s' "${ids[choice]}" | pbcopy
          echo "copied ${ids[choice]} — paste with: fq <cmd+v> <question>" >&2
        else
          echo "${ids[choice]}" >&2
        fi
      else
        echo "no session $choice" >&2
      fi
      ;;
    *) echo "enter a number 0-$((i - 1)) or q" >&2 ;;
    esac
  done
}

cmd_mq_flush() {
  local days="$1"
  local old_files
  old_files="$(find "$Q_SESSION_DIR" -name '*.jsonl' -mtime +"$days" 2>/dev/null || true)"
  if [ -z "$old_files" ]; then
    echo "no sessions older than $days days" >&2
    return
  fi

  local f id transcript distilled
  while IFS= read -r f; do
    id="$(session_id "$f")"
    echo "distilling $id ..." >&2
    transcript="$(jq -r '
      select(.type == "message" and (.message.role == "user" or .message.role == "assistant"))
      | .message.role + ": " + ([.message.content[]? | select(.type == "text") | .text] | join(" "))
    ' "$f" 2>/dev/null || true)"
    if [ -n "$transcript" ]; then
      distilled="$(printf '%s' "$transcript" | pi -p \
        --no-context-files --no-approve --no-session \
        "Distill the key facts, decisions, and answers from this Q&A transcript into a few terse bullet points worth remembering. Output only the bullets." \
        2>/dev/null || true)"
      if [ -n "$distilled" ]; then
        {
          printf '\n## %s (%s, flushed %s)\n\n%s\n' \
            "$(session_summary "$f" | cut -c1-80)" "$id" "$(date +%Y-%m-%d)" "$distilled"
        } >>"$Q_MEMORY_FILE"
      fi
    fi
    rm -f "$f"
    echo "flushed $id" >&2
  done <<<"$old_files"
  echo "distilled notes: $Q_MEMORY_FILE" >&2
}

case "$(basename "$0")" in
q) cmd_q "$@" ;;
fq) cmd_fq "$@" ;;
lq) cmd_lq "$@" ;;
*)
  echo "unknown command: $(basename "$0") (expected q, fq, or lq)" >&2
  exit 1
  ;;
esac
