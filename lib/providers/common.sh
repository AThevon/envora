#!/usr/bin/env bash
# lib/providers/common.sh - what every platform module shares
#
# Contract of a provider module (lib/providers/<name>.sh):
#   <name>_dirs          absolute dirs of the project configured for the platform
#   <name>_menu_items    menu lines for the interactive menu (empty if not relevant)
#   <name>_preview ITEM  live plan shown in the menu preview
# plus the commands it implements (import / export).
#
# Platform secrets are write-only (Vercel Secrets, Cloudflare secrets): only names
# can be read back. The vault is the source of truth.

VERCEL_PINNED="58.4.0"
WRANGLER_PINNED="4.132.0"

PCMD=()

# provider_cmd vercel|wrangler -> sets PCMD (override > PATH > pinned npx)
provider_cmd() {
  local tool="$1" override="" pinned=""
  case "$tool" in
    vercel) override="$ENVORA_VERCEL_CMD" pinned="$VERCEL_PINNED" ;;
    wrangler) override="$ENVORA_WRANGLER_CMD" pinned="$WRANGLER_PINNED" ;;
  esac
  PCMD=()
  if [[ -n "$override" ]]; then
    local w
    set -f
    for w in $override; do PCMD[${#PCMD[@]}]="$w"; done
    set +f
  elif has "$tool"; then
    PCMD=("$tool")
  elif has npx; then
    PCMD=(npx -y "$tool@$pinned")
  else
    err "$tool is not installed and npx is not available (install $tool or Node.js)"
    return 1
  fi
}

# find_marked_dirs FILE... -> dirs (absolute, sorted) under PROJECT_DIR holding one of FILE
find_marked_dirs() {
  local d prune_expr=() names=() n
  for d in $PRUNE_DIRS; do
    [[ ${#prune_expr[@]} -gt 0 ]] && prune_expr[${#prune_expr[@]}]="-o"
    prune_expr[${#prune_expr[@]}]="-name"
    prune_expr[${#prune_expr[@]}]="$d"
  done
  for n in "$@"; do
    [[ ${#names[@]} -gt 0 ]] && names[${#names[@]}]="-o"
    names[${#names[@]}]="-name"
    names[${#names[@]}]="$n"
  done
  find "$PROJECT_DIR" -maxdepth "$SCAN_DEPTH" \
    \( -type d \( "${prune_expr[@]}" \) -prune \) -o \
    \( -type f \( "${names[@]}" \) -print \) 2>/dev/null |
    while IFS= read -r d; do dirname "$d"; done | LC_ALL=C sort -u
}

rel_of_dir() {
  if [[ "$1" == "$PROJECT_DIR" ]]; then printf '.'; else printf '%s' "${1#"$PROJECT_DIR"/}"; fi
}

# Prefix a file name with a project-relative dir ("." -> none).
in_dir() {
  if [[ "$1" == "." ]]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

# pick_dir "label" dirs-on-stdin -> chosen absolute dir
# Uses -C <dir> when it is one of them, else the only one, else asks.
pick_dir() {
  local label="$1" list cand c_abs="" count
  list="$(cat)"
  [[ -n "$list" ]] || return 1
  count="$(printf '%s\n' "$list" | grep -c .)"
  if [[ -n "${ARG_C:-}" ]]; then
    c_abs="$(abs_dir "$ARG_C" || true)"
    while IFS= read -r cand; do
      if [[ "$cand" == "$c_abs" ]]; then
        printf '%s' "$cand"
        return 0
      fi
    done <<EOF
$list
EOF
  fi
  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$list"
    return 0
  fi
  local rels=() r
  while IFS= read -r cand; do rels[${#rels[@]}]="$(rel_of_dir "$cand")"; done <<EOF
$list
EOF
  if is_interactive; then
    r="$(choose "Several $label configs in this project. Which one?" "${rels[@]}")" || return 1
    if [[ "$r" == "." ]]; then printf '%s' "$PROJECT_DIR"; else printf '%s/%s' "$PROJECT_DIR" "$r"; fi
    return 0
  fi
  err "several $label configs in this project: $(join_by ', ' "${rels[@]}")"
  say "  pick one with -C <dir>"
  return 1
}

# Warn when the project file differs from the vault copy. Returns 1 to stop.
warn_if_local_differs() {
  local rel="$1" vf="$ENVORA_VAULT/$PROJECT_NAME/$1.age"
  [[ -f "$PROJECT_DIR/$rel" ]] || return 0
  same_plaintext "$vf" "$PROJECT_DIR/$rel" && return 0
  warn "your local $rel differs from the vault copy ($(key_diff_line "$rel")). Save first? (ev save)"
  if is_interactive; then
    confirm "Continue with the vault version?" || return 1
  fi
  return 0
}

# Show the last lines of a tool's output, indented.
show_tool_output() {
  if [[ "${QUIET:-0}" == 1 ]]; then
    grep -v '^ *$' "$1" | tail -n 1 | sed 's/^/ev: /' >&2 || true
  else
    sed 's/^/    /' "$1" | grep -v '^ *$' | tail -n "${2:-6}" >&2 || true
  fi
}

cmd_import() {
  local what="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$what" in
    vercel) vercel_import "$@" ;;
    cloudflare)
      err "Cloudflare secrets are write-only: they cannot be imported (only their names can be listed)"
      say "  keep the values in the vault (ev save) and send them with: ev export cloudflare"
      return 1
      ;;
    *) err "usage: ev import vercel [--env e]"; return 1 ;;
  esac
}

cmd_export() {
  local what="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$what" in
    cloudflare|cf) cloudflare_export "$@" ;;
    vercel) vercel_export "$@" ;;
    *) err "usage: ev export cloudflare|vercel [--env e] [--file f] [--dry-run]"; return 1 ;;
  esac
}

# Shared option parsing for provider commands: --env --file --dry-run
P_ENV="" P_FILE="" P_DRY=0
parse_provider_args() {
  local cmd="$1"
  shift
  P_ENV="" P_FILE="" P_DRY=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env|-e) [[ $# -ge 2 ]] || { err "--env needs a value"; return 1; }; P_ENV="$2"; shift ;;
      --env=*) P_ENV="${1#--env=}" ;;
      --file|-f) [[ $# -ge 2 ]] || { err "--file needs a value"; return 1; }; P_FILE="$2"; shift ;;
      --file=*) P_FILE="${1#--file=}" ;;
      --dry-run|-n) P_DRY=1 ;;
      *) err "unknown option for $cmd: $1 (see: ev help $cmd)"; return 1 ;;
    esac
    shift
  done
  if [[ -n "$P_ENV" ]]; then
    local re='^[A-Za-z0-9._-]+$'
    [[ "$P_ENV" =~ $re ]] || { err "invalid environment name: $P_ENV"; return 1; }
  fi
  if [[ -n "$P_FILE" ]]; then
    P_FILE="${P_FILE#./}"
    valid_relpath "$P_FILE" || { err "invalid file '$P_FILE' (a project-relative env file path)"; return 1; }
  fi
  return 0
}
