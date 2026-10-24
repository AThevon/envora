#!/usr/bin/env bash
# lib/project.sh - project identity, project directory, env file discovery

PROJECT_NAME=""
PROJECT_DIR=""
PROJECT_ORIGIN=""
PROJECT_IS_GIT=0

PRUNE_DIRS=".git node_modules vendor dist build .next .nuxt .output .turbo .vercel .wrangler .venv venv target coverage"
SCAN_DEPTH=4

git_toplevel() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

origin_url_of() {
  git -C "$1" remote get-url origin 2>/dev/null
}

# git@github.com:me/repo.git, https://github.com/me/repo/ -> repo
repo_name_from_url() {
  local u="$1"
  while [[ "$u" == */ ]]; do u="${u%/}"; done
  u="${u%.git}"
  u="${u##*/}"
  u="${u##*:}"
  printf '%s' "$u"
}

# Comparable form of an origin URL: host/path, lowercase host, no .git
normalize_origin() {
  local u="$1" host path
  while [[ "$u" == */ ]]; do u="${u%/}"; done
  u="${u%.git}"
  case "$u" in
    *://*)
      u="${u#*://}"
      u="${u#*@}"
      host="${u%%/*}"
      path="${u#*/}"
      host="${host%%:*}"
      ;;
    *@*:*)
      u="${u#*@}"
      host="${u%%:*}"
      path="${u#*:}"
      ;;
    *)
      printf '%s' "$u"
      return 0
      ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  printf '%s/%s' "$host" "$path"
}

# Name of the main worktree directory (worktrees share it).
main_worktree_name() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  if [[ "$(basename "$common")" == ".git" ]]; then
    basename "$(dirname "$common")"
  else
    local b
    b="$(basename "$common")"
    printf '%s' "${b%.git}"
  fi
}

# Detect the vault name of a project directory.
detect_name() {
  local dir="$1" url
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    url="$(origin_url_of "$dir")"
    if [[ -n "$url" ]]; then
      repo_name_from_url "$url"
      return 0
    fi
    main_worktree_name "$dir" && return 0
  fi
  basename "$dir"
}

# set_project_dir DIR: normalizes to the git toplevel when inside a repo.
set_project_dir() {
  local d top
  d="$(abs_dir "$1")" || { err "no such directory: $1"; return 1; }
  if top="$(git_toplevel "$d")" && [[ -n "$top" ]]; then
    PROJECT_DIR="$(abs_dir "$top")"
    PROJECT_IS_GIT=1
    PROJECT_ORIGIN="$(origin_url_of "$PROJECT_DIR" || true)"
  else
    PROJECT_DIR="$d"
    PROJECT_IS_GIT=0
    PROJECT_ORIGIN=""
  fi
}

# resolve_project [NAME]
#   -C dir        -> that dir (its git toplevel); name from --as, NAME or detection
#   NAME          -> current project if its name is NAME, else $ENVORA_PROJECTS/NAME
#   nothing       -> current git toplevel
resolve_project() {
  local name="${1:-}" cur
  if [[ -n "${ARG_C:-}" ]]; then
    set_project_dir "$ARG_C" || return 1
    PROJECT_NAME="${ARG_AS:-${name:-$(detect_name "$PROJECT_DIR")}}"
  elif [[ -n "$name" ]]; then
    require_valid_name "$name" || return 1
    if cur="$(git_toplevel "$PWD")" && [[ -n "$cur" && "$(detect_name "$cur")" == "$name" ]]; then
      set_project_dir "$cur" || return 1
    elif [[ -d "$ENVORA_PROJECTS/$name" ]]; then
      set_project_dir "$ENVORA_PROJECTS/$name" || return 1
    else
      err "no local folder for '$name': it is not the current project and $ENVORA_PROJECTS/$name does not exist"
      say "  clone it first, or pass the folder with -C <dir>"
      if [[ -f "$ENVORA_VAULT/$name/.origin" ]]; then
        say "  git clone $(head -n 1 "$ENVORA_VAULT/$name/.origin") $ENVORA_PROJECTS/$name"
      fi
      return 1
    fi
    PROJECT_NAME="${ARG_AS:-$name}"
  else
    if ! cur="$(git_toplevel "$PWD")" || [[ -z "$cur" ]]; then
      err "not inside a project (no git repository here)"
      say "  cd into a project, or use: ev <command> <name>  /  ev <command> -C <dir>"
      return 1
    fi
    set_project_dir "$cur" || return 1
    PROJECT_NAME="${ARG_AS:-$(detect_name "$PROJECT_DIR")}"
  fi
  require_valid_name "$PROJECT_NAME" || return 1
}

# Quiet variant for menus/previews: succeeds only inside a project.
detect_current_project() {
  local cur
  if [[ -n "${ARG_C:-}" ]]; then
    set_project_dir "$ARG_C" 2>/dev/null || return 1
  else
    cur="$(git_toplevel "$PWD")" || return 1
    [[ -n "$cur" ]] || return 1
    set_project_dir "$cur" || return 1
  fi
  PROJECT_NAME="${ARG_AS:-$(detect_name "$PROJECT_DIR")}"
  valid_name "$PROJECT_NAME"
}

# --- file discovery ----------------------------------------------------------

# scan_project DIR -> writes $TMP_ROOT/scan.files (handled) and scan.tracked
scan_project() {
  local dir="$1" f rel prune_expr=() d
  for d in $PRUNE_DIRS; do
    [[ ${#prune_expr[@]} -gt 0 ]] && prune_expr[${#prune_expr[@]}]="-o"
    prune_expr[${#prune_expr[@]}]="-name"
    prune_expr[${#prune_expr[@]}]="$d"
  done
  : >"$TMP_ROOT/scan.all"
  find "$dir" -maxdepth "$SCAN_DEPTH" \
    \( -type d \( "${prune_expr[@]}" \) -prune \) -o \
    \( -type f -o -type l \) \
    \( -name '.env' -o -name '.env.*' -o -name '.dev.vars' -o -name '.dev.vars.*' \) -print 2>/dev/null |
    while IFS= read -r f; do
      rel="${f#"$dir"/}"
      is_env_name "${rel##*/}" || continue
      [[ -f "$f" ]] || continue
      printf '%s\n' "$rel"
    done | LC_ALL=C sort -u >"$TMP_ROOT/scan.all"

  : >"$TMP_ROOT/scan.tracked"
  if [[ -s "$TMP_ROOT/scan.all" ]] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    local args=()
    while IFS= read -r rel; do args[${#args[@]}]="$rel"; done <"$TMP_ROOT/scan.all"
    git -C "$dir" ls-files -z -- "${args[@]}" 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort -u >"$TMP_ROOT/scan.tracked"
  fi
  if [[ -s "$TMP_ROOT/scan.tracked" ]]; then
    LC_ALL=C comm -23 "$TMP_ROOT/scan.all" "$TMP_ROOT/scan.tracked" >"$TMP_ROOT/scan.files"
  else
    cp "$TMP_ROOT/scan.all" "$TMP_ROOT/scan.files"
  fi
}

# vault_project_files NAME -> relpaths stored for NAME (provider snapshots excluded)
vault_project_files() {
  local base="$ENVORA_VAULT/$1" f
  [[ -d "$base" ]] || return 0
  find "$base" -type f -name '*.age' ! -path "$base/@vercel/*" 2>/dev/null |
    while IFS= read -r f; do
      f="${f#"$base"/}"
      printf '%s\n' "${f%.age}"
    done | LC_ALL=C sort
}

# vault_snapshot_files NAME -> platform snapshots (e.g. @vercel/production.env)
vault_snapshot_files() {
  local base="$ENVORA_VAULT/$1" f
  [[ -d "$base" ]] || return 0
  find "$base" -type f -name '*.age' -path "$base/@vercel/*" 2>/dev/null |
    while IFS= read -r f; do
      f="${f#"$base"/}"
      printf '%s\n' "${f%.age}"
    done | LC_ALL=C sort
}

vault_projects() {
  local d n
  for d in "$ENVORA_VAULT"/*/; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    valid_name "$n" || continue
    printf '%s\n' "$n"
  done
}

# Refuse when the vault entry belongs to another repository.
check_origin() {
  local name="$1" f="$ENVORA_VAULT/$1/.origin" saved
  [[ -n "$PROJECT_ORIGIN" && -f "$f" ]] || return 0
  saved="$(head -n 1 "$f")"
  [[ -z "$saved" ]] && return 0
  if [[ "$(normalize_origin "$saved")" != "$(normalize_origin "$PROJECT_ORIGIN")" ]]; then
    err "the vault entry '$name' belongs to another repository"
    say "  vault entry: $saved"
    say "  this project: $PROJECT_ORIGIN"
    say "  save it under another name: ev save --as <other-name>"
    return 1
  fi
}
