#!/usr/bin/env bash
# lib/vault.sh - the vault git repo: pull before reading, commit + push after writing
#
# Exit code contract used by write commands:
#   0  written and pushed to GitHub (or nothing to do)
#   3  committed locally but NOT pushed (offline, rejected, --no-sync, no remote)
#   1  failure

SYNC_STATE=""      # synced | offline | skipped | noremote | empty
SYNC_PULLED=0      # commits integrated by the last pull
SYNC_PUSHED=0      # commits pushed by the last push

# Paths are literal (a folder named "[x]" is not a glob) and printed raw
# (core.quotePath=false); lists of paths are always read NUL-separated, so
# names with accents, quotes or spaces are handled like any other.
vgit() {
  GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_LITERAL_PATHSPECS=1 \
    git -c core.quotePath=false -C "$ENVORA_VAULT" "$@"
}

# NUL-separated git output -> one path per line (envora refuses newlines in paths)
nul_lines() {
  tr '\0' '\n'
}

# A git operation that must never be left half done (see ev_cleanup).
VAULT_GIT_OP=""
vault_abort_op() {
  local op="$VAULT_GIT_OP"
  VAULT_GIT_OP=""
  case "$op" in
    rebase) vgit rebase --abort >/dev/null 2>&1 || true ;;
    merge) vgit merge --abort >/dev/null 2>&1 || true ;;
  esac
}

# Blobs of files whose version from this machine lost a sync conflict: such a
# file is never "unchanged here, newer in the vault" (it was edited here).
lost_file() {
  printf '%s/lost-blobs' "$ENVORA_STATE"
}

lost_record() {
  local f
  [[ -n "$1" ]] || return 0
  f="$(lost_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$f" 2>/dev/null || return 0
  if [[ "$(grep -c . "$f" 2>/dev/null || echo 0)" -gt 500 ]]; then
    tail -n 300 "$f" >"$f.envora-tmp" 2>/dev/null && mv -f "$f.envora-tmp" "$f"
  fi
  return 0
}

is_lost_blob() {
  [[ -n "$1" ]] && grep -Fxq -- "$1" "$(lost_file)" 2>/dev/null
}

vault_exists() {
  [[ -d "$ENVORA_VAULT/.git" ]]
}

vault_has_remote() {
  vgit remote get-url origin >/dev/null 2>&1
}

vault_branch() {
  vgit symbolic-ref --short -q HEAD 2>/dev/null || printf 'main'
}

vault_has_commits() {
  vgit rev-parse -q --verify HEAD >/dev/null 2>&1
}

vault_upstream() {
  local up
  up="origin/$(vault_branch)"
  vgit rev-parse -q --verify "refs/remotes/$up" >/dev/null 2>&1 || return 1
  printf '%s' "$up"
}

# Commits ahead / behind the remote-tracking branch: "A B"
vault_ahead_behind() {
  local up
  if ! vault_has_commits; then
    printf '0 0'
    return 0
  fi
  if up="$(vault_upstream)"; then
    vgit rev-list --left-right --count "HEAD...$up" 2>/dev/null | awk '{print $1, $2}'
  else
    printf '%s 0' "$(vgit rev-list --count HEAD 2>/dev/null || echo 0)"
  fi
}

# Use a fallback identity when git has none, so commits never fail on it.
vault_identity() {
  if [[ -z "$(vgit config user.email 2>/dev/null)" ]]; then
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-envora}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-envora@localhost}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-envora}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-envora@localhost}"
  fi
}

vault_gitattributes() {
  local f="$ENVORA_VAULT/.gitattributes"
  if [[ ! -f "$f" ]] || ! grep -qx '\*\.age binary' "$f"; then
    printf '*.age binary\n' >>"$f"
  fi
}

# Paths envora writes in the vault. Nothing else is ever committed by envora.
is_managed_path() {
  case "$1" in
    .recipient|.gitattributes|*.age) return 0 ;;
    */*/.origin) return 1 ;;
    */.origin) return 0 ;;
  esac
  return 1
}

# Changed paths (modified, deleted, untracked) under the given pathspecs.
vault_changed_paths() {
  vgit status --porcelain -z --untracked-files=all --no-renames -- "$@" 2>/dev/null |
    tr '\0' '\n' | cut -c 4-
}

# Stage the envora-managed changes under PATHS (default: the whole vault).
# Managed files are encrypted, so they are staged even if a .gitignore matches
# them; anything else (a stray plaintext file, a README) is never staged: it is
# listed in $TMP_ROOT/unmanaged instead.
vault_stage_managed() {
  local p staged=()
  [[ $# -gt 0 ]] || set -- .
  : >"$TMP_ROOT/unmanaged"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if is_managed_path "$p"; then
      staged[${#staged[@]}]="$p"
    else
      printf '%s\n' "$p" >>"$TMP_ROOT/unmanaged"
    fi
  done < <(vault_changed_paths "$@")
  while IFS= read -r p; do
    [[ -n "$p" ]] && is_managed_path "$p" && staged[${#staged[@]}]="$p"
  done < <(vgit ls-files -z -o -i --exclude-standard -- "$@" 2>/dev/null | tr '\0' '\n')
  [[ ${#staged[@]} -gt 0 ]] || return 0
  vgit add -A -f -- "${staged[@]}" 2>"$TMP_ROOT/git.err"
}

# Leave no half-finished git operation behind; commit stray envora changes
# (an interrupted save), but only encrypted files this machine can decrypt.
vault_repair() {
  local gd
  gd="$(vgit rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
    warn "the vault was left in the middle of a rebase: aborting it"
    vgit rebase --abort >/dev/null 2>&1 || true
  fi
  if [[ -f "$gd/MERGE_HEAD" ]]; then
    warn "the vault was left in the middle of a merge: aborting it"
    vgit merge --abort >/dev/null 2>&1 || true
  fi
  find "$ENVORA_VAULT" -name '*.envora-*' -type f ! -path '*/.git/*' -exec rm -f {} + 2>/dev/null || true
  [[ -n "$(vgit status --porcelain --untracked-files=all 2>/dev/null)" ]] || return 0
  vault_identity
  local p
  vault_stage_managed || {
    err "cannot record the uncommitted changes of the vault: $(head -n 1 "$TMP_ROOT/git.err")"
    return 1
  }
  if [[ -s "$TMP_ROOT/unmanaged" ]]; then
    local u=()
    while IFS= read -r p; do u[${#u[@]}]="$p"; done <"$TMP_ROOT/unmanaged"
    say "${C_DIM}the vault holds files envora does not manage (left uncommitted): $(short_list 3 "${u[@]}")${C_RST}"
  fi
  vgit diff --cached --quiet 2>/dev/null && return 0
  local unreadable=()
  while IFS= read -r p; do
    case "$p" in *.age) ;; *) continue ;; esac
    decrypts_with_key "$ENVORA_VAULT/$p" || unreadable[${#unreadable[@]}]="$p"
  done < <(vgit diff --cached --name-only -z --diff-filter=AM 2>/dev/null | nul_lines)
  if [[ ${#unreadable[@]} -gt 0 ]]; then
    vgit reset -q -- . >/dev/null 2>&1 || true
    err "the vault has $(plural ${#unreadable[@]} file) left uncommitted that your key cannot decrypt: $(short_list 3 "${unreadable[@]}")"
    say "  envora will not commit them. Run 'ev doctor'. To go back to the committed versions:"
    say "  git -C $(tildify "$ENVORA_VAULT") checkout -- $(short_list 3 "${unreadable[@]}")"
    return 1
  fi
  vgit commit -q -m "envora: record changes left uncommitted" >/dev/null 2>&1 || true
}

# One ev at a time touches the vault's git state (hooks may run in parallel).
VAULT_LOCK=""
vault_lock() {
  [[ -n "$VAULT_LOCK" ]] && return 0
  local gd lock pid n=0 who
  gd="$(vgit rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  lock="$gd/envora.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    n=$((n + 1))
    if [[ $n -ge 300 ]]; then
      who="$(head -n 1 "$lock/cmd" 2>/dev/null || true)"
      err "the vault is busy: '${who:-another ev}' (pid ${pid:-?}) is still running; retry when it is done"
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$lock/pid"
  printf '%s\n' "${ENVORA_CMDLINE:-ev}" >"$lock/cmd"
  VAULT_LOCK="$lock"
  register_cleanup "$lock"
}

vault_unlock() {
  [[ -n "$VAULT_LOCK" ]] || return 0
  rm -rf "$VAULT_LOCK"
  unregister_cleanup "$VAULT_LOCK"
  VAULT_LOCK=""
}

# A prompt never holds the vault: a clone / wipe hook in another terminal must
# not wait for an answer. Call vault_release before asking, vault_reacquire after.
VAULT_RELEASED=0
vault_release() {
  VAULT_RELEASED=0
  [[ -n "$VAULT_LOCK" ]] || return 0
  VAULT_RELEASED=1
  vault_unlock
}

vault_reacquire() {
  [[ "$VAULT_RELEASED" == 1 ]] || return 0
  VAULT_RELEASED=0
  vault_lock
}

# Fail fast instead of hanging when the network is down (hooks run unattended).
vault_net_defaults() {
  if [[ -z "${GIT_SSH_COMMAND:-}" && -z "$(vgit config --get core.sshCommand 2>/dev/null)" ]]; then
    export GIT_SSH_COMMAND="ssh -o ConnectTimeout=15"
  fi
  export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
  export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-20}"
}

# Bring the vault up to date with GitHub before reading it.
vault_pull() {
  SYNC_PULLED=0
  vault_lock || return 1
  vault_repair || return 1
  vault_net_defaults
  if [[ "${NO_SYNC:-0}" == 1 ]]; then
    SYNC_STATE=skipped
    return 0
  fi
  if ! vault_has_remote; then
    SYNC_STATE=noremote
    return 0
  fi
  if ! vgit fetch -q origin 2>"$TMP_ROOT/fetch.err"; then
    SYNC_STATE=offline
    warn "cannot reach GitHub ($(head -n 1 "$TMP_ROOT/fetch.err")): using the local vault as is"
    return 0
  fi
  SYNC_STATE=synced
  local up ab ahead behind
  if ! up="$(vault_upstream)"; then
    SYNC_STATE=empty
    return 0
  fi
  if ! vault_has_commits; then
    vgit checkout -q -B "$(vault_branch)" "$up" 2>"$TMP_ROOT/git.err" || {
      err "cannot check out the vault: $(head -n 1 "$TMP_ROOT/git.err")"
      return 1
    }
    SYNC_PULLED=1
    return 0
  fi
  ab="$(vault_ahead_behind)"
  ahead="${ab% *}"
  behind="${ab#* }"
  [[ "$behind" -gt 0 ]] || return 0
  vault_identity
  if [[ "$ahead" -eq 0 ]]; then
    vgit merge -q --ff-only "$up" 2>"$TMP_ROOT/git.err" || {
      err "cannot update the vault: $(head -n 1 "$TMP_ROOT/git.err")"
      return 1
    }
  else
    VAULT_GIT_OP=rebase
    if ! vgit rebase -q --autostash "$up" >"$TMP_ROOT/git.err" 2>&1; then
      vault_abort_op
      VAULT_GIT_OP=merge
      if ! vault_merge_resolve "$up"; then
        VAULT_GIT_OP=""
        return 1
      fi
    fi
    VAULT_GIT_OP=""
  fi
  SYNC_PULLED="$behind"
  return 0
}

# Integrate diverging histories when a rebase conflicts. Per conflicting
# encrypted file, the plaintexts are compared three ways (with the common
# ancestor): a side that did not change the content (identical, or only
# re-encrypted by ev rotate) gives way to the side that did. Only when both
# changed it does the most recently committed version win; the other one
# stays in git history and the differing keys are listed.
vault_merge_resolve() {
  local up="$1" p resolved=()
  vgit merge --no-ff --no-commit -q "$up" >"$TMP_ROOT/merge.out" 2>&1 || true
  local conflicts
  conflicts="$(vgit diff --name-only -z --diff-filter=U 2>/dev/null | nul_lines)"
  if [[ -z "$conflicts" ]]; then
    if [[ -f "$(vgit rev-parse --absolute-git-dir)/MERGE_HEAD" ]]; then
      vgit commit -q -m "sync: merge changes from another machine" 2>"$TMP_ROOT/git.err" || {
        vgit merge --abort >/dev/null 2>&1 || true
        err "cannot merge the vault: $(head -n 1 "$TMP_ROOT/git.err")"
        return 1
      }
    fi
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    case "$p" in
      .recipient)
        vgit merge --abort >/dev/null 2>&1 || true
        err "the vault key changed on another machine (.recipient conflict): run 'ev sync' after importing the new key"
        return 1
        ;;
      *.age)
        vault_resolve_age "$up" "$p" || {
          vgit merge --abort >/dev/null 2>&1 || true
          return 1
        }
        ;;
      *)
        vgit checkout -q --theirs -- "$p" 2>/dev/null || vgit rm -q -- "$p" >/dev/null 2>&1 || true
        vgit add -f -- "$p" 2>/dev/null || true
        ;;
    esac
    resolved[${#resolved[@]}]="$p"
  done <<EOF
$conflicts
EOF
  if [[ -n "$(vgit diff --name-only -z --diff-filter=U 2>/dev/null | nul_lines)" ]]; then
    vgit merge --abort >/dev/null 2>&1 || true
    err "could not resolve the vault conflict automatically; the vault is unchanged"
    return 1
  fi
  vgit commit -q -m "sync: merge, conflicts resolved ($(short_list 3 "${resolved[@]}"))" 2>"$TMP_ROOT/git.err" || {
    vgit merge --abort >/dev/null 2>&1 || true
    err "cannot commit the vault merge: $(head -n 1 "$TMP_ROOT/git.err")"
    return 1
  }
  return 0
}

# Plaintext of a conflict stage (1 ancestor, 2 this machine, 3 the other one),
# in a pipe: never written to disk.
stage_plain() {
  vgit show ":$1:$2" 2>/dev/null | age -d "${ID_ARGS[@]}" 2>/dev/null
}

vault_resolve_age() {
  local up="$1" p="$2" stages has1=0 has2=0 has3=0
  stages="$(vgit ls-files -u -z -- "$p" | nul_lines | awk '{print $3}')"
  case "$stages" in *1*) has1=1 ;; esac
  case "$stages" in *2*) has2=1 ;; esac
  case "$stages" in *3*) has3=1 ;; esac
  if [[ $has2 == 0 ]]; then
    vgit checkout -q --theirs -- "$p" && vgit add -f -- "$p"
    warn "conflict on $p: deleted here, changed on another machine: kept the changed version"
    return 0
  fi
  if [[ $has3 == 0 ]]; then
    vgit checkout -q --ours -- "$p" && vgit add -f -- "$p"
    warn "conflict on $p: deleted on another machine, changed here: kept the changed version"
    return 0
  fi
  [[ ${#ID_ARGS[@]} -gt 0 ]] || load_identities
  local s_ours s_theirs s_base=""
  if ! s_ours="$(stage_plain 2 "$p" | cksum)" || ! s_theirs="$(stage_plain 3 "$p" | cksum)"; then
    err "conflict on $p: one of the two versions is encrypted for a key this machine does not have, so they cannot be compared"
    say "  the vault is unchanged. Import the right key (ev init --import-key), then run ev sync"
    return 1
  fi
  if [[ $has1 == 1 ]]; then
    s_base="$(stage_plain 1 "$p" | cksum)" || s_base=""
  fi
  local keep=""
  if [[ "$s_ours" == "$s_theirs" ]]; then
    keep=ours
  elif [[ -n "$s_base" && "$s_ours" == "$s_base" ]]; then
    keep=theirs # only the other machine changed the content
  elif [[ -n "$s_base" && "$s_theirs" == "$s_base" ]]; then
    keep=ours # only this machine changed it
  fi
  if [[ -n "$keep" ]]; then
    vgit checkout -q "--$keep" -- "$p" && vgit add -f -- "$p" || return 1
    return 0
  fi
  # Both machines changed the content: the most recent save wins.
  local t_ours t_theirs other_ref other_label kept_label
  t_ours="$(vgit log -1 --format=%ct HEAD -- "$p" 2>/dev/null || echo 0)"
  t_theirs="$(vgit log -1 --format=%ct "$up" -- "$p" 2>/dev/null || echo 0)"
  if [[ "${t_ours:-0}" -gt "${t_theirs:-0}" ]]; then
    keep=ours other_ref="$up" kept_label="this machine's version" other_label="the other machine"
  else
    keep=theirs other_ref="HEAD" kept_label="the other machine's version" other_label="this machine"
    # Remember it: the project copy that made this version is not "unchanged".
    lost_record "$(vgit rev-parse -q --verify ":2:$p" 2>/dev/null || true)"
    printf '%s\n' "$p" >>"$TMP_ROOT/conflict.lost"
  fi
  local other_commit details=""
  other_commit="$(vgit log -1 --format=%h "$other_ref" -- "$p" 2>/dev/null)"
  details="$({ stage_plain 2 "$p" | dotenv_json a; stage_plain 3 "$p" | dotenv_json b; } | dotenv_diff_stream | key_diff_summary "this machine" "the other machine")"
  vgit checkout -q "--$keep" -- "$p" && vgit add -f -- "$p" || return 1
  warn "conflict on $p: kept $kept_label (most recent save); $details. The version from $other_label stays in git history (commit $other_commit)."
  return 0
}

# commit_paths "message" path... -> 0 committed, 1 nothing to commit, 2 error
vault_commit() {
  local message="$1"
  shift
  vault_identity
  vault_stage_managed "$@" || {
    err "git add failed in the vault: $(head -n 1 "$TMP_ROOT/git.err")"
    return 2
  }
  if vgit diff --cached --quiet 2>/dev/null; then
    return 1
  fi
  vgit commit -q -m "$message" 2>"$TMP_ROOT/git.err" || {
    err "git commit failed in the vault: $(head -n 1 "$TMP_ROOT/git.err")"
    return 2
  }
  return 0
}

# Push local vault commits. Returns 0 (pushed or nothing to push) or 3.
vault_push() {
  SYNC_PUSHED=0
  local ab ahead
  ab="$(vault_ahead_behind)"
  ahead="${ab% *}"
  [[ "${ahead:-0}" -gt 0 ]] || return 0
  if [[ "${NO_SYNC:-0}" == 1 ]]; then
    warn "vault not pushed to GitHub (--no-sync): $(plural "$ahead" commit) only on this machine"
    return 3
  fi
  if ! vault_has_remote; then
    warn "the vault has no remote: $(plural "$ahead" commit) only on this machine"
    return 3
  fi
  local try=1
  while true; do
    if vgit push -q -u origin HEAD 2>"$TMP_ROOT/push.err"; then
      SYNC_PUSHED="$ahead"
      return 0
    fi
    [[ $try -ge 2 ]] && break
    try=$((try + 1))
    # Rejected because the remote moved: integrate and retry once.
    if vgit fetch -q origin 2>/dev/null; then
      vault_pull || break
      ab="$(vault_ahead_behind)"
      ahead="${ab% *}"
    else
      break
    fi
  done
  err "PUSH FAILED: the vault was saved on this machine but NOT sent to GitHub"
  if [[ "${QUIET:-0}" != 1 ]]; then
    sed 's/^/  git: /' "$TMP_ROOT/push.err" | grep -v '^  git: *$' | head -n 5 >&2 || true
  fi
  say "  run 'ev sync' when you are back online"
  return 3
}

# One line describing vault <-> GitHub.
vault_sync_label() {
  local ab ahead behind state=""
  if ! vault_has_remote; then
    printf 'no GitHub remote: nothing leaves this machine'
    return 0
  fi
  ab="$(vault_ahead_behind)"
  ahead="${ab% *}"
  behind="${ab#* }"
  case "$SYNC_STATE" in
    offline) state="offline" ;;
    skipped) state="not checked with GitHub (--no-sync)" ;;
  esac
  if [[ -n "$state" ]]; then
    if [[ "${ahead:-0}" -gt 0 ]]; then
      printf '%s · ↑ %s to push (not on GitHub yet)' "$state" "$ahead"
    else
      printf '%s' "$state"
    fi
    return 0
  fi
  if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
    printf '✓ synced with GitHub'
  elif [[ "$behind" -eq 0 ]]; then
    printf '↑ %s to push' "$ahead"
  elif [[ "$ahead" -eq 0 ]]; then
    printf '↓ %s to pull' "$behind"
  else
    printf '↑ %s to push · ↓ %s to pull' "$ahead" "$behind"
  fi
}

# Everything a command needs before touching the vault.
vault_ready() {
  if ! vault_exists; then
    err "no vault at $(tildify "$ENVORA_VAULT") (run 'ev init')"
    return 1
  fi
  return 0
}
