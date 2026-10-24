#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/util.sh - temp files with cleanup, names, paths, dotenv parsing

TMP_ROOT=""
CLEANUP_LIST=""

ev_cleanup() {
  local p old_ifs="$IFS"
  set -f
  IFS=$'\n'
  for p in $CLEANUP_LIST; do
    [[ -n "$p" ]] && rm -rf -- "$p" 2>/dev/null
  done
  IFS="$old_ifs"
  set +f
  CLEANUP_LIST=""
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT" 2>/dev/null
  fi
  return 0
}

# Every run gets one private temp dir, removed on exit or signal.
ev_setup_tmp() {
  umask 077
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/envora.XXXXXX")" || {
    printf 'ev: error: cannot create a temp dir\n' >&2
    exit 1
  }
  trap 'ev_cleanup' EXIT
  trap 'ev_cleanup; trap - EXIT; exit 130' INT
  trap 'ev_cleanup; trap - EXIT; exit 143' TERM
  trap 'ev_cleanup; trap - EXIT; exit 129' HUP
}

# Remove this path on exit (only works from the main shell, not in $(...)).
register_cleanup() {
  CLEANUP_LIST="$CLEANUP_LIST"$'\n'"$1"
}

unregister_cleanup() {
  local p res="" old_ifs="$IFS"
  set -f
  IFS=$'\n'
  for p in $CLEANUP_LIST; do
    [[ "$p" == "$1" || -z "$p" ]] && continue
    res="$res"$'\n'"$p"
  done
  IFS="$old_ifs"
  set +f
  CLEANUP_LIST="$res"
}

tmpfile() {
  mktemp "$TMP_ROOT/${1:-f}.XXXXXX"
}

# Project names: ^[A-Za-z0-9._-]+$, not starting with "."
valid_name() {
  local re='^[A-Za-z0-9._-]+$'
  [[ "$1" =~ $re ]] || return 1
  [[ "$1" != .* ]] || return 1
  return 0
}

require_valid_name() {
  valid_name "$1" && return 0
  err "invalid project name '$1': use letters, digits, '.', '_' or '-', not starting with '.'"
  return 1
}

# File names envora manages.
is_env_name() {
  case "$1" in
    *.example|*.sample|*.template|*.dist|*.defaults|*.age|.envrc|*.envora-*) return 1 ;;
    .env|.env.*|.dev.vars|.dev.vars.*) return 0 ;;
  esac
  return 1
}

# A relative path coming from the vault: no "..", no absolute path, env name.
valid_relpath() {
  local p="$1" c old_ifs="$IFS" bad=0
  [[ -n "$p" ]] || return 1
  case "$p" in
    /*|*//*|*$'\n'*) return 1 ;;
  esac
  set -f
  IFS=/
  for c in $p; do
    if [[ -z "$c" || "$c" == "." || "$c" == ".." ]]; then bad=1; fi
  done
  IFS="$old_ifs"
  set +f
  [[ $bad == 0 ]] || return 1
  is_env_name "${p##*/}"
}

# Physical absolute path of an existing directory.
abs_dir() {
  (cd -P -- "$1" 2>/dev/null && pwd)
}

# Follow a chain of symlinks (BSD readlink has no -f).
resolve_symlink() {
  local p="$1" n=0 target dir
  while [[ -L "$p" && $n -lt 40 ]]; do
    dir="$(cd -P -- "$(dirname -- "$p")" && pwd)"
    target="$(readlink -- "$p")"
    case "$target" in
      /*) p="$target" ;;
      *) p="$dir/$target" ;;
    esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}

# /Users/me/x -> ~/x (display only)
# shellcheck disable=SC2088  # a literal ~ is the point here
tildify() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

now_stamp() {
  date +%Y%m%d-%H%M%S
}

# --- dotenv ------------------------------------------------------------------
#
# dotenv_json TAG < file  ->  one JSON object per variable: {"s":TAG,"k":..,"v":..}
# Same rules as the dotenv package that wrangler and Next.js use, so what envora
# sends to a platform is what `wrangler dev` / `next dev` read locally:
#   - optional "export ", KEY = value, comments start with # (even mid-value
#     when the value is not quoted)
#   - '...' and `...` are literal; "..." only turns \n and \r into newlines
#   - a quoted value may span lines when its closing quote ends a line
#   - an unclosed quote is a literal value on its own line (it never swallows
#     the following lines)
#   - a UTF-8 BOM and CRLF line endings are ignored

DOTENV_AWK='
function jesc(s,   out, i, c, n) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else if (c in ctl) out = out sprintf("\\u%04x", ctl[c])
    else out = out c
  }
  return out
}
function emit(k, v) { printf "{\"s\":\"%s\",\"k\":\"%s\",\"v\":\"%s\"}\n", tag, jesc(k), jesc(v) }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function dq_escapes(s,   out, i, n, c, c2) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      c2 = substr(s, i + 1, 1)
      if (c2 == "n") { out = out "\n"; i++; continue }
      if (c2 == "r") { out = out "\r"; i++; continue }
    }
    out = out c
  }
  return out
}
# Find the closing quote q of a value starting on line li at column col.
# Sets CL (line) and CP (column) and returns 1, or returns 0.
function closing(q, li, col,   l, s, n, j, c) {
  for (l = li; l <= nl; l++) {
    s = L[l]; n = length(s)
    j = (l == li) ? col : 1
    while (j <= n) {
      c = substr(s, j, 1)
      if (c == "\\" && j < n && substr(s, j + 1, 1) == q) { j += 2; continue }
      if (c == q) { CL = l; CP = j; return 1 }
      j++
    }
  }
  return 0
}
BEGIN {
  for (i = 1; i < 32; i++) if (i != 9 && i != 10 && i != 13) ctl[sprintf("%c", i)] = i
}
{
  line = $0
  if (NR == 1 && substr(line, 1, 3) == "\357\273\277") line = substr(line, 4)
  sub(/\r$/, "", line)
  L[NR] = line
}
END {
  nl = NR
  i = 1
  while (i <= nl) {
    line = L[i]
    sub(/^[ \t]+/, "", line)
    sub(/^export[ \t]+/, "", line)
    if (!match(line, /^[A-Za-z0-9_.-]+[ \t]*=/)) { i++; continue }
    key = substr(line, 1, RLENGTH)
    sub(/[ \t]*=$/, "", key)
    rest = substr(line, RLENGTH + 1)
    sub(/^[ \t]+/, "", rest)
    off = length(L[i]) - length(rest)
    q = substr(rest, 1, 1)
    if ((q == "\"" || q == "\047" || q == "`") && closing(q, i, off + 2)) {
      after = substr(L[CL], CP + 1)
      if (after ~ /^[ \t]*(#.*)?$/) {
        if (CL == i) {
          val = substr(L[i], off + 2, CP - off - 2)
        } else {
          val = substr(L[i], off + 2)
          for (l = i + 1; l < CL; l++) val = val "\n" L[l]
          val = val "\n" substr(L[CL], 1, CP - 1)
        }
        if (q == "\"") val = dq_escapes(val)
        emit(key, val)
        i = CL + 1
        continue
      }
    }
    # Unquoted (or a quote that does not close properly): up to #, trimmed.
    val = rest
    p = index(val, "#")
    if (p > 0) val = substr(val, 1, p - 1)
    val = trim(val)
    c = substr(val, 1, 1)
    if (length(val) >= 2 && (c == "\"" || c == "\047" || c == "`") && substr(val, length(val), 1) == c) {
      val = substr(val, 2, length(val) - 2)
    }
    if (c == "\"") val = dq_escapes(val)
    emit(key, val)
    i++
  }
}
'

dotenv_json() {
  LC_ALL=C awk -v tag="${1:-x}" "$DOTENV_AWK"
}

# Variable names of a dotenv stream, sorted, one per line.
dotenv_keys() {
  dotenv_json k | jq -r '.k' | LC_ALL=C sort -u
}

# Compare two JSON streams tagged "a" and "b" on stdin.
# Prints lines: "a KEY" only in a, "b KEY" only in b, "~ KEY" different value.
DOTENV_DIFF_JQ='
  (map(select(.s=="a")) | map({(.k): .v}) | add // {}) as $A |
  (map(select(.s=="b")) | map({(.k): .v}) | add // {}) as $B |
  ([$A | keys[] as $k | select($B | has($k) | not) | "a " + $k]) +
  ([$B | keys[] as $k | select($A | has($k) | not) | "b " + $k]) +
  ([$A | keys[] as $k | select(($B | has($k)) and $B[$k] != $A[$k]) | "~ " + $k])
  | .[]'

dotenv_diff_stream() {
  jq -rs "$DOTENV_DIFF_JQ"
}

# key_diff_summary <diff lines on stdin> <label for a> <label for b>
# -> "2 keys only in project (A, B) · 1 only in vault (C) · 1 changed (D)"
key_diff_summary() {
  local la="$1" lb="$2" line a=() b=() c=() parts=()
  while IFS= read -r line; do
    case "$line" in
      "a "*) a[${#a[@]}]="${line#a }" ;;
      "b "*) b[${#b[@]}]="${line#b }" ;;
      "~ "*) c[${#c[@]}]="${line#\~ }" ;;
    esac
  done
  [[ ${#a[@]} -gt 0 ]] && parts[${#parts[@]}]="$(plural ${#a[@]} key) only in $la ($(short_list 4 "${a[@]}"))"
  [[ ${#b[@]} -gt 0 ]] && parts[${#parts[@]}]="$(plural ${#b[@]} key) only in $lb ($(short_list 4 "${b[@]}"))"
  [[ ${#c[@]} -gt 0 ]] && parts[${#parts[@]}]="$(plural ${#c[@]} value) changed ($(short_list 4 "${c[@]}"))"
  if [[ ${#parts[@]} -eq 0 ]]; then
    printf 'same keys and values, formatting differs'
  else
    join_by ' · ' "${parts[@]}"
  fi
}
