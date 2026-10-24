#!/usr/bin/env bash
# shellcheck disable=SC2034  # colors are used by the other modules
# lib/ui.sh - output, colors and prompts
#
# Conventions:
#   - say/ok/step: progress and results, on stderr, silenced by --quiet
#   - warn/err:    always printed on stderr, one line each
#   - out:         command output meant to be read or piped, on stdout

ui_init_colors() {
  C_ACC="" C_DIM="" C_BOLD="" C_WARN="" C_ERR="" C_RST=""
  local want=0
  if [[ -n "${ENVORA_COLOR:-}" ]]; then
    [[ "$ENVORA_COLOR" == "1" ]] && want=1
  elif [[ -z "${NO_COLOR:-}" && -t 1 && -t 2 ]]; then
    want=1
  fi
  if [[ $want == 1 ]]; then
    C_ACC=$'\033[38;2;111;207;124m'
    C_DIM=$'\033[38;2;128;136;148m'
    C_BOLD=$'\033[1m'
    C_WARN=$'\033[38;2;229;192;123m'
    C_ERR=$'\033[38;2;224;108;117m'
    C_RST=$'\033[0m'
  fi
}

say() {
  [[ "${QUIET:-0}" == 1 ]] && return 0
  printf '%s\n' "$*" >&2
}

ok() {
  [[ "${QUIET:-0}" == 1 ]] && return 0
  printf '%s✓%s %s\n' "$C_ACC" "$C_RST" "$*" >&2
}

# Like ok, but for a result that is only partly done (e.g. not pushed).
partial() {
  [[ "${QUIET:-0}" == 1 ]] && return 0
  printf '%s!%s %s\n' "$C_WARN" "$C_RST" "$*" >&2
}

# result RC message: ✓ when RC is 0, ! otherwise (exit 3: saved, not pushed).
result() {
  local rc="$1"
  shift
  if [[ "$rc" == 0 ]]; then ok "$@"; else partial "$@"; fi
}

step() {
  [[ "${QUIET:-0}" == 1 ]] && return 0
  printf '%s·%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
}

warn() {
  if [[ "${QUIET:-0}" == 1 ]]; then
    printf 'ev: warning: %s\n' "$*" >&2
  else
    printf '%s!%s %s\n' "$C_WARN" "$C_RST" "$*" >&2
  fi
}

err() {
  if [[ "${QUIET:-0}" == 1 ]]; then
    printf 'ev: error: %s\n' "$*" >&2
  else
    printf '%s✗%s %s\n' "$C_ERR" "$C_RST" "$*" >&2
  fi
}

die() {
  err "$@"
  exit 1
}

out() {
  printf '%s\n' "$*"
}

has() {
  command -v "$1" >/dev/null 2>&1
}

# True when we may ask the user something.
is_interactive() {
  [[ "${ASSUME_YES:-0}" != 1 && -t 0 && -t 2 ]]
}

# confirm "question" [no] -> 0 for yes. With --yes: yes. Without a TTY: no.
# A second argument "no" makes No the preselected answer.
confirm() {
  local q="$1" def="true"
  [[ "${2:-}" == no ]] && def="false"
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  is_interactive || return 1
  if has gum; then
    gum confirm --default="$def" --prompt.foreground="#6fcf7c" \
      --selected.background="#2b3a2e" --selected.foreground="#6fcf7c" "$q" </dev/tty
  else
    local a=""
    printf '%s [y/N] ' "$q" >&2
    IFS= read -r a </dev/tty || return 1
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
}

# choose "header" item... -> prints the chosen item (one per line menus)
choose() {
  local header="$1"
  shift
  is_interactive || return 1
  if has gum; then
    gum choose --header="$header" --cursor.foreground="#6fcf7c" \
      --header.foreground="#808894" "$@" </dev/tty
  else
    local i=1 item a=""
    printf '%s\n' "$header" >&2
    for item in "$@"; do
      printf '  %d) %s\n' "$i" "$item" >&2
      i=$((i + 1))
    done
    printf '> ' >&2
    IFS= read -r a </dev/tty || return 1
    case "$a" in ''|*[!0-9]*) return 1 ;; esac
    [[ $a -ge 1 && $a -le $# ]] || return 1
    local items=("$@")
    printf '%s\n' "${items[$((a - 1))]}"
  fi
}

# ask "prompt" [default] -> prints the answer
ask() {
  local prompt="$1" def="${2:-}"
  is_interactive || return 1
  if has gum; then
    gum input --prompt="$prompt " --value="$def" --prompt.foreground="#6fcf7c" </dev/tty
  else
    local a=""
    printf '%s [%s] ' "$prompt" "$def" >&2
    IFS= read -r a </dev/tty || return 1
    printf '%s\n' "${a:-$def}"
  fi
}

# join_by sep items...
join_by() {
  local sep="$1" first=1 item res=""
  shift
  for item in "$@"; do
    if [[ $first == 1 ]]; then res="$item"; first=0; else res="$res$sep$item"; fi
  done
  printf '%s' "$res"
}

# Compact list for messages: "a, b, c +2 more"
short_list() {
  local max="$1"
  shift
  local n=$# shown=() i=0 item
  for item in "$@"; do
    [[ $i -ge $max ]] && break
    shown[${#shown[@]}]="$item"
    i=$((i + 1))
  done
  local res
  res="$(join_by ', ' ${shown[@]+"${shown[@]}"})"
  if [[ $n -gt $max ]]; then
    res="$res +$((n - max)) more"
  fi
  printf '%s' "$res"
}

plural() {
  # plural N word -> "1 file" / "2 files"
  if [[ "$1" == 1 ]]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

ui_logo() {
  [[ "${QUIET:-0}" == 1 ]] && return 0
  cat >&2 <<EOF
${C_ACC} ▄▄▄▄▄▄▄ ▄▄▄    ▄▄▄ ▄▄▄▄  ▄▄▄▄   ▄▄▄▄▄   ▄▄▄▄▄▄▄     ▄▄▄▄
███▀▀▀▀▀ ████▄  ███ ▀███  ███▀ ▄███████▄ ███▀▀███▄ ▄██▀▀██▄
███▄▄    ███▀██▄███  ███  ███  ███   ███ ███▄▄███▀ ███  ███
███      ███  ▀████  ███▄▄███  ███▄▄▄███ ███▀▀██▄  ███▀▀███
▀███████ ███    ███   ▀████▀    ▀█████▀  ███  ▀███ ███  ███${C_RST}
${C_DIM}                encrypted .env vault${C_RST}
EOF
}
