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
    # A plain list of words (split on spaces, no shell parsing): quotes would
    # be passed literally, so they are refused; use a wrapper script instead.
    case "$override" in
      *\"*|*\'*|*\\*)
        err "ENVORA_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_CMD: quotes and backslashes are not supported (words are split on spaces)"
        say "  put the command in a small script and point the setting at it"
        return 1
        ;;
    esac
    local w
    set -f
    for w in $(expand_cmd "$override"); do PCMD[${#PCMD[@]}]="$w"; done
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

# Human label of a project-relative dir: "." is the project root.
dir_label() {
  if [[ "$1" == "." ]]; then printf 'project root'; else printf '%s' "$1"; fi
}

# A line of a provider plan: command output (stdout). Shown even with --quiet
# when it is all the user asked for (--dry-run).
plan_line() {
  if [[ "${QUIET:-0}" == 1 && "${P_DRY:-0}" != 1 ]]; then return 0; fi
  out "$*"
}

# Prefix a file name with a project-relative dir ("." -> none).
in_dir() {
  if [[ "$1" == "." ]]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

# pick_dir "label" "dirs (one per line)" -> chosen absolute dir
# The deepest one holding -C <dir> (or the current directory), so running
# envora inside apps/web of a monorepo targets apps/web; the project root is
# only picked that way when -C names it or it is the only one. Else the only
# one, else asks (or fails without a terminal).
pick_dir() {
  local label="$1" list="$2" cand count here best=""
  [[ -n "$list" ]] || return 1
  count="$(printf '%s\n' "$list" | grep -c .)"
  if [[ -n "${ARG_C:-}" ]]; then
    here="$(abs_dir "$ARG_C" || true)"
  else
    here="$(pwd -P 2>/dev/null || true)"
  fi
  while IFS= read -r cand; do
    case "$here/" in
      "$cand"/*) [[ ${#cand} -gt ${#best} ]] && best="$cand" ;;
    esac
  done <<<"$list"
  if [[ -n "$best" ]] && { [[ "$best" != "$PROJECT_DIR" || "$count" -eq 1 ]] ||
    [[ -n "${ARG_C:-}" && "$here" == "$best" ]]; }; then
    printf '%s' "$best"
    return 0
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

# local_vs_vault REL -> same | stale (the vault is newer) | edited (the local
# copy has changes the vault does not) | none (no local copy)
local_vs_vault() {
  local rel="$1"
  [[ -f "$PROJECT_DIR/$rel" ]] || { printf 'none'; return 0; }
  same_plaintext "$ENVORA_VAULT/$PROJECT_NAME/$rel.age" "$PROJECT_DIR/$rel" && { printf 'same'; return 0; }
  if [[ "$(classify_change "$rel")" == stale ]]; then printf 'stale'; else printf 'edited'; fi
}

# Warn when the project file differs from the vault copy. Returns 1 to stop.
warn_if_local_differs() {
  local rel="$1"
  case "$(local_vs_vault "$rel")" in
    stale)
      warn "the vault has a newer $rel than your local file ($(key_diff_line "$rel")): the vault version is what gets sent (ev restore brings it here)"
      ;;
    edited)
      warn "your local $rel has changes the vault does not have ($(key_diff_line "$rel")): only the vault version is sent. Save first? (ev save)"
      if is_interactive; then
        vault_release
        confirm "Continue with the vault version?" || return 1
      fi
      ;;
  esac
  return 0
}

# Variable names a platform accepts. Anything else (e.g. a line "--scope=x"
# in a dotenv file) is never passed to a CLI: it would be read as an option.
valid_var_name() {
  local re='^[A-Za-z_][A-Za-z0-9_]*$'
  [[ "$1" =~ $re ]]
}

# split_var_names "keys (one per line)" -> sets VALID_KEYS / BAD_KEYS
VALID_KEYS="" BAD_KEYS=()
split_var_names() {
  local k
  VALID_KEYS="" BAD_KEYS=()
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if valid_var_name "$k"; then
      VALID_KEYS="$VALID_KEYS$k"$'\n'
    else
      BAD_KEYS[${#BAD_KEYS[@]}]="$k"
    fi
  done <<<"$1"
  VALID_KEYS="${VALID_KEYS%$'\n'}"
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

# Shared option parsing for provider commands. The second argument lists the
# options this command accepts (others are refused, never silently ignored):
#   --env --file --dry-run --update-shared (+ --as and --force everywhere)
# P_ENV_SET is 1 when --env was given, even empty (--env= : no environment).
P_ENV="" P_ENV_SET=0 P_FILE="" P_DRY=0 P_SHARED=0
parse_provider_args() {
  local cmd="$1" allowed=" $2 --as --force " opt
  shift 2
  P_ENV="" P_ENV_SET=0 P_FILE="" P_DRY=0 P_SHARED=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env|-e|--env=*) opt=--env ;;
      --file|-f|--file=*) opt=--file ;;
      --dry-run|-n) opt=--dry-run ;;
      --as|--as=*) opt=--as ;;
      *) opt="$1" ;;
    esac
    case "$allowed" in
      *" $opt "*) ;;
      *)
        case "$opt" in
          --dry-run) err "--dry-run is not used by $cmd: it only writes to the vault, never to your files or the platform" ;;
          --file) err "--file is not used by $cmd" ;;
          *) err "unknown option for $cmd: $1 (see: ev help $cmd)" ;;
        esac
        return 1
        ;;
    esac
    case "$1" in
      --env|-e) [[ $# -ge 2 ]] || { err "--env needs a value"; return 1; }; P_ENV="$2"; P_ENV_SET=1; shift ;;
      --env=*) P_ENV="${1#--env=}"; P_ENV_SET=1 ;;
      --file|-f) [[ $# -ge 2 ]] || { err "--file needs a value"; return 1; }; P_FILE="$2"; shift ;;
      --file=*) P_FILE="${1#--file=}" ;;
      --dry-run|-n) P_DRY=1 ;;
      --update-shared) P_SHARED=1 ;;
      --as) [[ $# -ge 2 ]] || { err "--as needs a name"; return 1; }; ARG_AS="$2"; shift ;;
      --as=*) ARG_AS="${1#--as=}" ;;
      --force) ARG_FORCE=1 ;;
    esac
    shift
  done
  if [[ -n "${ARG_AS:-}" ]]; then
    require_valid_name "$ARG_AS" || return 1
  fi
  if [[ -n "$P_ENV" ]]; then
    # Never starts with "-": it is passed to vercel / wrangler.
    local re='^[A-Za-z0-9_][A-Za-z0-9._-]*$'
    [[ "$P_ENV" =~ $re && "$P_ENV" != *..* ]] || { err "invalid environment name: $P_ENV"; return 1; }
  fi
  if [[ -n "$P_FILE" ]]; then
    P_FILE="${P_FILE#./}"
    valid_relpath "$P_FILE" || { err "invalid file '$P_FILE' (a project-relative env file path)"; return 1; }
  fi
  return 0
}
