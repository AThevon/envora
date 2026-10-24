#!/usr/bin/env bash
# lib/commands.sh - save, restore, status, list, forget, sync
#
# Three places:
#   PROJECT    the .env files in your working copy (not tracked by git)
#   VAULT      encrypted copies, a git repo synced with GitHub
#   PLATFORMS  Vercel, Cloudflare

# --- shared ------------------------------------------------------------------

# Compute what "save" would do for PROJECT_NAME / PROJECT_DIR.
# Writes $TMP_ROOT/plan.save: "<status>\t<relpath>", status in
#   new | changed | same | tracked | vaultonly
save_plan() {
  local base="$ENVORA_VAULT/$PROJECT_NAME" rel plan="$TMP_ROOT/plan.save"
  scan_project "$PROJECT_DIR"
  : >"$plan"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ -f "$base/$rel.age" ]]; then
      if same_plaintext "$base/$rel.age" "$PROJECT_DIR/$rel"; then
        printf 'same\t%s\n' "$rel" >>"$plan"
      else
        printf 'changed\t%s\n' "$rel" >>"$plan"
      fi
    else
      printf 'new\t%s\n' "$rel" >>"$plan"
    fi
  done <"$TMP_ROOT/scan.files"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    printf 'tracked\t%s\n' "$rel" >>"$plan"
  done <"$TMP_ROOT/scan.tracked"
  vault_project_files "$PROJECT_NAME" >"$TMP_ROOT/vault.files"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    grep -Fxq -- "$rel" "$TMP_ROOT/scan.all" && continue
    printf 'vaultonly\t%s\n' "$rel" >>"$plan"
  done <"$TMP_ROOT/vault.files"
}

# Compute what "restore" would do. Writes $TMP_ROOT/plan.restore:
#   new | same | differs | tracked | invalid
restore_plan() {
  local base="$ENVORA_VAULT/$PROJECT_NAME" rel target plan="$TMP_ROOT/plan.restore"
  : >"$plan"
  vault_project_files "$PROJECT_NAME" >"$TMP_ROOT/vault.files"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if ! valid_relpath "$rel"; then
      printf 'invalid\t%s\n' "$rel" >>"$plan"
      continue
    fi
    target="$PROJECT_DIR/$rel"
    if [[ $PROJECT_IS_GIT == 1 ]] && git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      printf 'tracked\t%s\n' "$rel" >>"$plan"
    elif [[ ! -e "$target" ]]; then
      printf 'new\t%s\n' "$rel" >>"$plan"
    elif same_plaintext "$base/$rel.age" "$target"; then
      printf 'same\t%s\n' "$rel" >>"$plan"
    else
      printf 'differs\t%s\n' "$rel" >>"$plan"
    fi
  done <"$TMP_ROOT/vault.files"
}

plan_count() {
  # plan_count file status
  grep -c "^$2"$'\t' "$1" 2>/dev/null || true
}

plan_list() {
  # plan_list file status -> relpaths
  grep "^$2"$'\t' "$1" 2>/dev/null | cut -f2- || true
}

# Key-level comparison of the project file and the vault copy.
# key_diff_line relpath -> "1 key only in project (X) · ..."
key_diff_line() {
  local rel="$1" diff
  if diff="$({
    dotenv_json a <"$PROJECT_DIR/$rel"
    decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$rel.age" 2>/dev/null | dotenv_json b
  } | dotenv_diff_stream 2>/dev/null)"; then
    printf '%s\n' "$diff" | key_diff_summary "project" "vault"
  else
    printf 'could not compare the keys'
  fi
}

push_suffix() {
  case "$1" in
    0)
      if [[ "${SYNC_PUSHED:-0}" -gt 0 ]]; then printf ' · pushed to GitHub'; fi
      ;;
    3) printf ' · NOT pushed to GitHub' ;;
  esac
}

# Parse "--as NAME" and a single positional NAME. Sets POS_NAME.
parse_name_args() {
  local cmd="$1"
  shift
  POS_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as)
        [[ $# -ge 2 ]] || { err "--as needs a name"; return 1; }
        ARG_AS="$2"
        shift
        ;;
      --as=*) ARG_AS="${1#--as=}" ;;
      --force) ARG_FORCE=1 ;;
      --values) ARG_VALUES=1 ;;
      -*)
        err "unknown option for $cmd: $1 (see: ev help $cmd)"
        return 1
        ;;
      *)
        if [[ -n "$POS_NAME" ]]; then
          err "too many arguments for $cmd (see: ev help $cmd)"
          return 1
        fi
        POS_NAME="$1"
        ;;
    esac
    shift
  done
  if [[ -n "${ARG_AS:-}" ]]; then
    require_valid_name "$ARG_AS" || return 1
  fi
  return 0
}

# --- save: project -> vault --------------------------------------------------

cmd_save() {
  parse_name_args save "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient write || return 1
  resolve_project "$POS_NAME" || return 1
  check_origin "$PROJECT_NAME" || return 1

  save_plan
  local plan="$TMP_ROOT/plan.save" base="$ENVORA_VAULT/$PROJECT_NAME"
  local rel st saved=() failed=0 n_new=0 n_changed=0
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      new|changed)
        if encrypt_file "$PROJECT_DIR/$rel" "$base/$rel.age"; then
          saved[${#saved[@]}]="$rel"
          if [[ "$st" == new ]]; then
            n_new=$((n_new + 1))
            step "$rel  ${C_DIM}new → vault${C_RST}"
          else
            n_changed=$((n_changed + 1))
            step "$rel  ${C_DIM}changed → vault${C_RST}"
          fi
        else
          failed=$((failed + 1))
        fi
        ;;
    esac
  done <"$plan"

  local tracked vaultonly
  tracked="$(plan_list "$plan" tracked)"
  vaultonly="$(plan_list "$plan" vaultonly)"
  if [[ -n "$tracked" ]]; then
    say "${C_DIM}skipped (tracked by git, git already has them): $(printf '%s' "$tracked" | tr '\n' ' ')${C_RST}"
  fi
  if [[ -n "$vaultonly" ]]; then
    while IFS= read -r rel; do
      say "${C_DIM}kept in the vault, missing here: $rel (remove with: ev forget $PROJECT_NAME $rel)${C_RST}"
    done <<EOF
$vaultonly
EOF
  fi

  local n_files commit_rc=1
  n_files="$(vault_project_files "$PROJECT_NAME" | grep -c . || true)"
  if [[ "$n_files" -gt 0 ]]; then
    if [[ -n "$PROJECT_ORIGIN" && ! -f "$base/.origin" ]]; then
      printf '%s\n' "$PROJECT_ORIGIN" >"$base/.origin"
    fi
    vault_gitattributes
    local msg="save: $PROJECT_NAME"
    [[ ${#saved[@]} -gt 0 ]] && msg="save: $PROJECT_NAME ($(short_list 5 "${saved[@]}"))"
    commit_rc=0
    vault_commit "$msg" "$PROJECT_NAME" .recipient .gitattributes || commit_rc=$?
    [[ $commit_rc == 2 ]] && return 1
  else
    vault_commit "envora: record the vault public key" .recipient >/dev/null || true
  fi

  local push_rc=0
  vault_push || push_rc=$?

  if [[ $failed -gt 0 ]]; then
    err "$(plural "$failed" file) could not be encrypted: the vault is NOT complete"
    return 1
  fi
  local total=$((n_new + n_changed))
  if [[ $total -gt 0 ]]; then
    ok "$(plural "$total" file) saved to the vault ($PROJECT_NAME)$(push_suffix "$push_rc")"
  elif [[ "$n_files" -eq 0 ]]; then
    say "nothing to save: no env files found in $(tildify "$PROJECT_DIR")"
  else
    ok "nothing changed: the vault already has these $(plural "$n_files" file)$(push_suffix "$push_rc")"
  fi
  return "$push_rc"
}

# --- restore: vault -> project -----------------------------------------------

BACKUP_DIR=""

backup_file() {
  local rel="$1" path="$2" root
  root="$ENVORA_STATE/backups/$PROJECT_NAME"
  if [[ -z "$BACKUP_DIR" ]]; then
    local stamp n=1
    stamp="$(now_stamp)"
    BACKUP_DIR="$root/$stamp"
    while [[ -e "$BACKUP_DIR" ]]; do
      n=$((n + 1))
      BACKUP_DIR="$root/$stamp-$n"
    done
    mkdir -p "$BACKUP_DIR" || { err "cannot create $BACKUP_DIR"; return 1; }
  fi
  encrypt_file "$path" "$BACKUP_DIR/$rel.age" || return 1
  # Keep the 10 most recent backups of this project.
  local old
  old="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | awk -v keep=10 '{a[NR]=$0} END {for (i = 1; i <= NR - keep; i++) print a[i]}')"
  if [[ -n "$old" ]]; then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] && rm -rf -- "$rel"
    done <<EOF
$old
EOF
  fi
  return 0
}

# Atomically write the vault version of REL into the project.
write_restored() {
  local rel="$1" target="$PROJECT_DIR/$1" dir probe phys tmp
  if [[ -L "$target" ]]; then
    target="$(resolve_symlink "$target")"
  else
    probe="$(dirname "$target")"
    while [[ ! -d "$probe" ]]; do probe="$(dirname "$probe")"; done
    phys="$(abs_dir "$probe")"
    case "$phys/" in
      "$PROJECT_DIR"/*) ;;
      *)
        err "refusing to restore $rel: it would land outside $PROJECT_DIR"
        return 1
        ;;
    esac
  fi
  dir="$(dirname "$target")"
  mkdir -p "$dir" || { err "cannot create $dir"; return 1; }
  tmp="$(mktemp "$dir/.$(basename "$target").envora-XXXXXX")" || { err "cannot write in $dir"; return 1; }
  register_cleanup "$tmp"
  if ! decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$rel.age" >"$tmp" 2>"$TMP_ROOT/age.err"; then
    rm -f "$tmp"
    unregister_cleanup "$tmp"
    err "cannot decrypt $rel: $(head -n 1 "$TMP_ROOT/age.err")"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
  unregister_cleanup "$tmp"
}

cmd_restore() {
  ARG_FORCE=0
  parse_name_args restore "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient read || return 1
  resolve_project "$POS_NAME" || return 1

  restore_plan
  local plan="$TMP_ROOT/plan.restore"
  if [[ ! -s "$plan" ]]; then
    say "nothing to restore: the vault has no files for $PROJECT_NAME"
    return 0
  fi

  local st rel written=() skipped_same=0 kept=0 failed=0 backed=0 bad=0 overwrite
  # The plan is read on fd 3 so prompts keep the terminal on stdin.
  while IFS=$'\t' read -r st rel <&3; do
    case "$st" in
      invalid)
        err "refusing to restore '$rel' from the vault: not an env file name or not a safe path"
        bad=$((bad + 1))
        ;;
      same)
        skipped_same=$((skipped_same + 1))
        ;;
      tracked)
        say "${C_DIM}$rel is tracked by git here: not overwritten${C_RST}"
        ;;
      new)
        if write_restored "$rel"; then
          written[${#written[@]}]="$rel"
          step "$rel  ${C_DIM}vault → project (new file)${C_RST}"
        else
          failed=$((failed + 1))
        fi
        ;;
      differs)
        overwrite=0
        if [[ "${ARG_FORCE:-0}" == 1 || "${ASSUME_YES:-0}" == 1 ]] || ! is_interactive; then
          overwrite=1
        else
          say "$rel differs from the vault: $(key_diff_line "$rel")"
          if confirm "Overwrite $rel with the vault version? (the current file is backed up)"; then
            overwrite=1
          fi
        fi
        if [[ $overwrite == 1 ]]; then
          if backup_file "$rel" "$PROJECT_DIR/$rel" && write_restored "$rel"; then
            written[${#written[@]}]="$rel"
            backed=$((backed + 1))
            step "$rel  ${C_DIM}vault → project (replaced, backup kept)${C_RST}"
          else
            failed=$((failed + 1))
          fi
        else
          kept=$((kept + 1))
          step "$rel  ${C_DIM}kept as is${C_RST}"
        fi
        ;;
    esac
  done 3<"$plan"

  if [[ $backed -gt 0 ]]; then
    say "${C_DIM}previous versions backed up (encrypted) in $(tildify "$BACKUP_DIR")${C_RST}"
  fi
  if [[ ${#written[@]} -gt 0 ]]; then
    ok "$(plural ${#written[@]} file) restored into $(tildify "$PROJECT_DIR")"
  elif [[ $failed -eq 0 && $bad -eq 0 ]]; then
    if [[ $kept -gt 0 ]]; then
      ok "nothing written: you kept your local versions"
    else
      ok "already up to date: $(plural "$skipped_same" file) identical to the vault"
    fi
  fi
  if [[ $failed -gt 0 || $bad -gt 0 ]]; then
    err "$(plural $((failed + bad)) file) not restored"
    return 1
  fi
  return 0
}

# --- status: project <-> vault -----------------------------------------------

cmd_status() {
  ARG_VALUES=0
  parse_name_args status "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient read || return 1
  resolve_project "$POS_NAME" || return 1
  save_plan
  status_report
}

status_report() {
  local plan="$TMP_ROOT/plan.save" st rel line w=10
  while IFS=$'\t' read -r st rel; do
    [[ ${#rel} -gt $w ]] && w=${#rel}
  done <"$plan"
  out "${C_BOLD}$PROJECT_NAME${C_RST}  ${C_DIM}$(tildify "$PROJECT_DIR")${C_RST}"
  out ""
  out "${C_DIM}project ↔ vault${C_RST}"
  if [[ ! -s "$plan" ]]; then
    out "  no env files here and nothing in the vault"
  fi
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      same) line="${C_ACC}✓${C_RST} $(printf "%-${w}s" "$rel")  in sync" ;;
      changed) line="${C_WARN}~${C_RST} $(printf "%-${w}s" "$rel")  changed: $(key_diff_line "$rel")" ;;
      new) line="${C_WARN}+${C_RST} $(printf "%-${w}s" "$rel")  only in project (not saved yet)" ;;
      vaultonly) line="${C_WARN}-${C_RST} $(printf "%-${w}s" "$rel")  only in vault (missing here)" ;;
      tracked) line="${C_DIM}· $(printf "%-${w}s" "$rel")  tracked by git, envora skips it${C_RST}" ;;
      *) continue ;;
    esac
    out "  $line"
    if [[ "$st" == changed && "${ARG_VALUES:-0}" == 1 ]]; then
      diff -u --label "vault/$rel" --label "project/$rel" \
        <(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$rel.age") "$PROJECT_DIR/$rel" | sed 's/^/      /' || true
    fi
  done <"$plan"
  local snaps
  snaps="$(vault_snapshot_files "$PROJECT_NAME")"
  if [[ -n "$snaps" ]]; then
    out ""
    out "${C_DIM}platform snapshots in the vault${C_RST}"
    printf '%s\n' "$snaps" | sed 's/^/  ▲ /'
  fi
  out ""
  out "${C_DIM}vault ↔ GitHub${C_RST}  $(vault_sync_label)"
}

# --- list --------------------------------------------------------------------

cmd_list() {
  [[ $# -eq 0 ]] || { err "usage: ev list"; return 1; }
  vault_ready || return 1
  vault_pull || return 1
  local names name n date where snaps
  names="$(vault_projects)"
  if [[ -z "$names" ]]; then
    out "the vault is empty: run 'ev save' inside a project"
    return 0
  fi
  out "${C_BOLD}projects in the vault${C_RST}  ${C_DIM}$(tildify "$ENVORA_VAULT") · $(vault_sync_label)${C_RST}"
  out ""
  while IFS= read -r name; do
    n="$(vault_project_files "$name" | grep -c . || true)"
    date="$(vgit log -1 --format=%cd --date=short -- "$name" 2>/dev/null)"
    if [[ -d "$ENVORA_PROJECTS/$name" ]]; then where="here: $(tildify "$ENVORA_PROJECTS/$name")"; else where="not on this machine"; fi
    snaps="$(vault_snapshot_files "$name" | sed 's|^@\([^/]*\)/.*|\1|' | LC_ALL=C sort -u | tr '\n' ' ')"
    out "  $(printf '%-24s %-9s %-11s' "$name" "$(plural "$n" file)" "${date:-unsaved}")  ${C_DIM}${where}${snaps:+ · snapshots: $snaps}${C_RST}"
  done <<EOF
$names
EOF
}

# --- forget ------------------------------------------------------------------

valid_vault_file_arg() {
  local p="$1"
  case "$p" in
    @*/*)
      local rest="${p#@*/}"
      case "$rest" in
        *..*|/*|'') return 1 ;;
      esac
      return 0
      ;;
  esac
  valid_relpath "$p"
}

cmd_forget() {
  local name="${1:-}" file="${2:-}"
  [[ $# -ge 1 && $# -le 2 ]] || { err "usage: ev forget <name> [file]"; return 1; }
  require_valid_name "$name" || return 1
  if [[ -n "$file" ]] && ! valid_vault_file_arg "$file"; then
    err "invalid file '$file'"
    return 1
  fi
  vault_ready || return 1
  vault_pull || return 1
  local target what
  if [[ -n "$file" ]]; then
    target="$name/$file.age"
    what="$file of $name"
  else
    target="$name"
    what="$name ($(plural "$(vault_project_files "$name" | grep -c . || true)" file))"
  fi
  if [[ ! -e "$ENVORA_VAULT/$target" ]]; then
    err "not in the vault: ${file:+$file of }$name"
    return 1
  fi
  if ! confirm "Remove $what from the vault? (old versions stay in git history)" no; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to remove without confirmation: add --yes"
    return 1
  fi
  vgit rm -r -q -- "$target" >/dev/null 2>"$TMP_ROOT/git.err" || {
    err "cannot remove $target: $(head -n 1 "$TMP_ROOT/git.err")"
    return 1
  }
  rm -rf -- "${ENVORA_VAULT:?}/$target"
  local msg="forget: $name"
  [[ -n "$file" ]] && msg="forget: $name ($file)"
  vault_identity
  vgit commit -q -m "$msg" 2>"$TMP_ROOT/git.err" || {
    err "cannot commit in the vault: $(head -n 1 "$TMP_ROOT/git.err")"
    return 1
  }
  local push_rc=0
  vault_push || push_rc=$?
  ok "removed $what from the vault$(push_suffix "$push_rc")"
  return "$push_rc"
}

# --- sync: vault <-> GitHub --------------------------------------------------

cmd_sync() {
  [[ $# -eq 0 ]] || { err "usage: ev sync"; return 1; }
  vault_ready || return 1
  key_exists && require_key >/dev/null 2>&1 || true
  if [[ "${NO_SYNC:-0}" == 1 ]]; then
    warn "--no-sync: nothing to do"
    return 0
  fi
  if ! vault_has_remote; then
    err "the vault has no remote: set one with 'git -C $ENVORA_VAULT remote add origin <url>'"
    return 1
  fi
  vault_pull || return 1
  if [[ "$SYNC_STATE" == offline ]]; then
    local ab
    ab="$(vault_ahead_behind)"
    [[ "${ab% *}" -gt 0 ]] && err "offline: $(plural "${ab% *}" commit) waiting to be pushed"
    return 3
  fi
  local push_rc=0
  vault_push || push_rc=$?
  local parts=()
  [[ "$SYNC_PULLED" -gt 0 ]] && parts[${#parts[@]}]="↓ $(plural "$SYNC_PULLED" commit) from GitHub"
  [[ "$SYNC_PUSHED" -gt 0 ]] && parts[${#parts[@]}]="↑ $(plural "$SYNC_PUSHED" commit) to GitHub"
  if [[ $push_rc == 0 ]]; then
    if [[ ${#parts[@]} -gt 0 ]]; then
      ok "$(join_by ' · ' "${parts[@]}") · vault in sync"
    else
      ok "already in sync with GitHub"
    fi
  fi
  return "$push_rc"
}
