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

# Vault entry for a project dir: its detected name, or the folder name when the
# vault only has an entry under that name (saved by envora 0.x, which named
# projects after their folder) that does not belong to another repository.
vault_name_for_dir() {
  local dir="$1" name legacy f saved
  name="$(detect_name "$dir")"
  if [[ ! -d "$ENVORA_VAULT/$name" ]]; then
    legacy="$(main_worktree_name "$dir" 2>/dev/null || basename "$dir")"
    if [[ "$legacy" != "$name" && -d "$ENVORA_VAULT/$legacy" ]] && valid_name "$legacy"; then
      f="$ENVORA_VAULT/$legacy/.origin"
      saved="$(head -n 1 "$f" 2>/dev/null || true)"
      if [[ -z "$saved" || -z "$PROJECT_ORIGIN" ]] ||
        [[ "$(normalize_origin "$saved")" == "$(normalize_origin "$PROJECT_ORIGIN")" ]]; then
        name="$legacy"
      fi
    fi
  fi
  printf '%s' "$name"
}

# Refuse folders that are clearly not one project: a wrong -C (an empty
# argument in a shell function, "..") must never make a hook save, or let a
# caller delete, a whole tree of projects.
guard_project_dir() {
  local d="$PROJECT_DIR" home projects nested
  home="$(abs_dir "$HOME" || printf '%s' "$HOME")"
  projects="$(abs_dir "$ENVORA_PROJECTS" || printf '%s' "$ENVORA_PROJECTS")"
  if [[ "$d" == "/" || "$d" == "$home" || "$d" == "$projects" ]]; then
    err "$(tildify "$d") is not a project folder (it is / , your home or ENVORA_PROJECTS)"
    say "  point -C at one project, e.g. -C $(tildify "$projects")/<name>"
    return 1
  fi
  if [[ $PROJECT_IS_GIT == 0 ]]; then
    nested="$(find "$d" -mindepth 2 -maxdepth $((SCAN_DEPTH + 1)) -name node_modules -prune -o -name .git -print 2>/dev/null | head -n 1 || true)"
    if [[ -n "$nested" ]]; then
      nested="$(dirname "$nested")"
      err "$(tildify "$d") is not a git repository but contains one ($(tildify "$nested")): it looks like a folder of projects"
      say "  point -C at one project instead"
      return 1
    fi
  fi
  return 0
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
    guard_project_dir || return 1
    PROJECT_NAME="${ARG_AS:-${name:-$(vault_name_for_dir "$PROJECT_DIR")}}"
  elif [[ -n "$name" ]]; then
    require_valid_name "$name" || return 1
    if cur="$(git_toplevel "$PWD")" && [[ -n "$cur" ]] &&
      [[ "$(detect_name "$cur")" == "$name" || "$(vault_name_for_dir "$cur")" == "$name" ]]; then
      set_project_dir "$cur" || return 1
    elif [[ -d "$ENVORA_PROJECTS/$name" ]]; then
      set_project_dir "$ENVORA_PROJECTS/$name" || return 1
      guard_project_dir || return 1
      # The folder name is only a way to find the project: its identity in the
      # vault still comes from its git origin (same entry as "ev save" inside it).
      if [[ -z "${ARG_AS:-}" ]]; then
        local detected
        detected="$(vault_name_for_dir "$PROJECT_DIR")"
        if [[ "$detected" != "$name" ]] && valid_name "$detected"; then
          say "${C_DIM}$(tildify "$PROJECT_DIR") is '$detected' in the vault (from its git origin)${C_RST}"
          name="$detected"
        fi
      fi
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
    guard_project_dir || return 1
    PROJECT_NAME="${ARG_AS:-$(vault_name_for_dir "$PROJECT_DIR")}"
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
  PROJECT_NAME="${ARG_AS:-$(vault_name_for_dir "$PROJECT_DIR")}"
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
    git --literal-pathspecs -C "$dir" ls-files -z -- "${args[@]}" 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort -u >"$TMP_ROOT/scan.tracked"
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

# Env files the scan does not reach: deeper than $SCAN_DEPTH levels, or inside
# build/, dist/, vendor/. Generated caches (.next, .vercel...) are ignored.
# Writes $TMP_ROOT/scan.unreached (relpaths, not tracked by git).
scan_unreached() {
  local dir="$1" rel
  : >"$TMP_ROOT/scan.unreached"
  find "$dir" \( -type d \( -name .git -o -name node_modules -o -name .next -o -name .nuxt \
    -o -name .output -o -name .vercel -o -name .turbo -o -name .wrangler -o -name .venv \
    -o -name venv -o -name target -o -name coverage \) -prune \) -o \
    \( -type f -o -type l \) \
    \( -name '.env' -o -name '.env.*' -o -name '.dev.vars' -o -name '.dev.vars.*' \) -print 2>/dev/null |
    while IFS= read -r rel; do
      rel="${rel#"$dir"/}"
      is_env_name "${rel##*/}" || continue
      [[ -f "$dir/$rel" ]] || continue
      grep -Fxq -- "$rel" "$TMP_ROOT/scan.all" 2>/dev/null && continue
      if [[ $PROJECT_IS_GIT == 1 ]] && git --literal-pathspecs -C "$dir" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        continue
      fi
      printf '%s\n' "$rel"
    done | LC_ALL=C sort >"$TMP_ROOT/scan.unreached"
}

# Refuse when the vault entry belongs to another repository, or when it has a
# known origin and this folder cannot show one. An explicit --as skips it.
# check_origin NAME [save|restore|status|export...]
check_origin() {
  local name="$1" cmd="${2:-save}" f="$ENVORA_VAULT/$1/.origin" saved
  [[ -f "$f" ]] || return 0
  [[ -n "${ARG_AS:-}" ]] && return 0
  saved="$(head -n 1 "$f")"
  [[ -z "$saved" ]] && return 0
  if [[ -z "$PROJECT_ORIGIN" ]]; then
    err "the vault entry '$name' belongs to $saved, and $(tildify "$PROJECT_DIR") has no git origin to show it is that project"
  elif [[ "$(normalize_origin "$saved")" != "$(normalize_origin "$PROJECT_ORIGIN")" ]]; then
    err "the vault entry '$name' belongs to another repository"
    say "  vault entry:  $saved"
    say "  this project: $PROJECT_ORIGIN"
  else
    return 0
  fi
  case "$cmd" in
    save) say "  save it under another name: ev save --as <other-name>  (or --as $name if it really is the same project)" ;;
    *) say "  if it really is the same project: ev $cmd --as $name" ;;
  esac
  return 1
}
