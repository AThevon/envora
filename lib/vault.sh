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

vgit() {
  GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 git -C "$ENVORA_VAULT" "$@"
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

# Leave no half-finished git operation behind; commit stray changes.
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
  if [[ -n "$(vgit status --porcelain 2>/dev/null)" ]]; then
    vault_identity
    vgit add -A -f -- . >/dev/null 2>&1 &&
      vgit commit -q -m "envora: record changes left uncommitted" >/dev/null 2>&1 || true
  fi
}

# Bring the vault up to date with GitHub before reading it.
vault_pull() {
  SYNC_PULLED=0
  vault_repair || return 1
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
    warn "cannot reach the vault remote ($(head -n 1 "$TMP_ROOT/fetch.err")): using the local vault as is"
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
  elif ! vgit rebase -q "$up" >"$TMP_ROOT/git.err" 2>&1; then
    vgit rebase --abort >/dev/null 2>&1 || true
    vault_merge_resolve "$up" || return 1
  fi
  SYNC_PULLED="$behind"
  return 0
}

# Integrate diverging histories when a rebase conflicts: per conflicting
# encrypted file, identical plaintexts are merged silently, otherwise the most
# recently committed version wins and the other stays in git history.
vault_merge_resolve() {
  local up="$1" p resolved=()
  vgit merge --no-ff --no-commit -q "$up" >"$TMP_ROOT/merge.out" 2>&1 || true
  local conflicts
  conflicts="$(vgit diff --name-only --diff-filter=U 2>/dev/null)"
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
  if [[ -n "$(vgit diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
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

vault_resolve_age() {
  local up="$1" p="$2" stages has2=0 has3=0
  stages="$(vgit ls-files -u -- "$p" | awk '{print $3}')"
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
  local f_ours="$TMP_ROOT/conflict.ours" f_theirs="$TMP_ROOT/conflict.theirs" same=0 cmp_ok=1
  vgit show ":2:$p" 2>/dev/null | age -d -i "$ENVORA_KEY" >"$f_ours" 2>/dev/null || cmp_ok=0
  vgit show ":3:$p" 2>/dev/null | age -d -i "$ENVORA_KEY" >"$f_theirs" 2>/dev/null || cmp_ok=0
  if [[ $cmp_ok == 1 ]] && cmp -s "$f_ours" "$f_theirs"; then
    same=1
  fi
  if [[ $same == 1 ]]; then
    vgit checkout -q --ours -- "$p" && vgit add -f -- "$p"
    rm -f "$f_ours" "$f_theirs"
    return 0
  fi
  local t_ours t_theirs keep other_ref other_label kept_label
  t_ours="$(vgit log -1 --format=%ct HEAD -- "$p" 2>/dev/null || echo 0)"
  t_theirs="$(vgit log -1 --format=%ct "$up" -- "$p" 2>/dev/null || echo 0)"
  if [[ "${t_ours:-0}" -gt "${t_theirs:-0}" ]]; then
    keep=ours other_ref="$up" kept_label="this machine's" other_label="the other machine"
  else
    keep=theirs other_ref="HEAD" kept_label="other machine's" other_label="this machine"
  fi
  vgit checkout -q "--$keep" -- "$p" && vgit add -f -- "$p" || return 1
  local other_commit details=""
  other_commit="$(vgit log -1 --format=%h "$other_ref" -- "$p" 2>/dev/null)"
  if [[ $cmp_ok == 1 ]]; then
    details="$({ dotenv_json a <"$f_ours"; dotenv_json b <"$f_theirs"; } | dotenv_diff_stream | key_diff_summary "this machine" "the other machine")"
  else
    details="could not decrypt both versions to compare them"
  fi
  rm -f "$f_ours" "$f_theirs"
  warn "conflict on $p: kept the $kept_label version (most recent save); $details. The version from $other_label stays in git history (commit $other_commit)."
  return 0
}

# commit_paths "message" path... -> 0 committed, 1 nothing to commit, 2 error
vault_commit() {
  local message="$1"
  shift
  vault_identity
  vgit add -A -f -- "$@" 2>"$TMP_ROOT/git.err" || {
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
  local ab ahead behind
  if ! vault_has_remote; then
    printf 'no GitHub remote'
    return 0
  fi
  if [[ "$SYNC_STATE" == offline ]]; then
    printf 'offline'
    return 0
  fi
  ab="$(vault_ahead_behind)"
  ahead="${ab% *}"
  behind="${ab#* }"
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
    err "no vault at $ENVORA_VAULT (run 'ev init')"
    return 1
  fi
  return 0
}
