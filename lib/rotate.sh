#!/usr/bin/env bash
# lib/rotate.sh - replace the key and re-encrypt the whole vault
#
# Safe order:
#   1. the new key and the re-encrypted files are written next to the
#      originals and verified (nothing changed yet)
#   2. the old key is copied to <key>.bak-<date>
#   3. with INT / TERM / HUP ignored: the new key is installed FIRST, then
#      .recipient, then the files are moved into place. At any point every file
#      is encrypted either for the old key (kept in .bak) or for the installed
#      new key, so no interruption can lose a secret. A failed move rolls back.
#   4. commit, push; files another machine saved with the old key meanwhile
#      are re-encrypted too.
# Decryption uses the current key and every <key>.bak-*: running rotate again
# finishes an interrupted rotation.

# Re-encrypt the vault files that the current key cannot open but an old key
# can (saved by another machine during the rotation, or left by a crash).
# rotate_fixup -> sets FIXED and UNREADABLE (relpaths, one per line)
rotate_fixup() {
  local f rel
  FIXED="" UNREADABLE=""
  load_identities
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    decrypts_with_key "$f" && continue
    rel="${f#"$ENVORA_VAULT"/}"
    if age -d "${ID_ARGS[@]}" "$f" 2>/dev/null | age -r "$KEY_PUB" -o "$f.envora-new" 2>/dev/null &&
      decrypts_with_key "$f.envora-new"; then
      mv -f "$f.envora-new" "$f"
      FIXED="$FIXED$rel"$'\n'
    else
      rm -f "$f.envora-new"
      UNREADABLE="$UNREADABLE$rel"$'\n'
    fi
  done < <(find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' | LC_ALL=C sort)
}

# Put the default signal handlers back (see ev_setup_tmp).
rotate_restore_traps() {
  trap 'ev_cleanup; trap - EXIT; exit 130' INT
  trap 'ev_cleanup; trap - EXIT; exit 143' TERM
  trap 'ev_cleanup; trap - EXIT; exit 129' HUP
}

cmd_rotate() {
  local pq=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pq) pq=1 ;;
      *) err "unknown option for rotate: $1"; return 1 ;;
    esac
    shift
  done
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient write || return 1

  local files="$TMP_ROOT/rotate.list" new_key="$ENVORA_KEY.new"
  find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' | LC_ALL=C sort >"$files"
  local total
  total="$(grep -c . "$files" || true)"
  if [[ "$total" -eq 0 ]]; then
    warn "the vault has no encrypted files: nothing to rotate"
    return 0
  fi
  if [[ -e "$new_key" ]]; then
    err "$(tildify "$new_key") already exists (left by an interrupted rotation?): check it, delete it, then retry"
    return 1
  fi
  vault_release
  if ! confirm "Create a new key and re-encrypt the $(plural "$total" file) of the vault?" no; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to rotate without confirmation: add --yes"
    return 1
  fi
  if [[ "$VAULT_RELEASED" == 1 ]]; then
    VAULT_RELEASED=0
    vault_pull || return 1
    check_recipient write || return 1
    find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' | LC_ALL=C sort >"$files"
    total="$(grep -c . "$files" || true)"
  fi

  local keygen_args=()
  [[ $pq == 1 ]] && keygen_args=(-pq)
  register_cleanup "$new_key"
  if ! age-keygen ${keygen_args[@]+"${keygen_args[@]}"} -o "$new_key" 2>"$TMP_ROOT/keygen.err"; then
    err "cannot generate a new key: $(head -n 1 "$TMP_ROOT/keygen.err")"
    return 1
  fi
  chmod 600 "$new_key"
  local new_pub old_pub="$KEY_PUB"
  new_pub="$(pubkey_of "$new_key")" || { err "the new key is unreadable"; return 1; }

  # 1. Re-encrypt every file to "<file>.envora-new", plaintext only in pipes.
  load_identities
  local f failed=0 done_n=0 a b
  while IFS= read -r f; do
    register_cleanup "$f.envora-new"
    if ! age -d "${ID_ARGS[@]}" "$f" 2>"$TMP_ROOT/age.err" | age -r "$new_pub" -o "$f.envora-new" 2>>"$TMP_ROOT/age.err"; then
      err "cannot re-encrypt ${f#"$ENVORA_VAULT"/}: $(head -n 1 "$TMP_ROOT/age.err")"
      failed=$((failed + 1))
      continue
    fi
    a="$(age -d "${ID_ARGS[@]}" "$f" 2>/dev/null | cksum)" || a="old-failed"
    b="$(age -d -i "$new_key" "$f.envora-new" 2>/dev/null | cksum)" || b="new-failed"
    if [[ "$a" != "$b" ]]; then
      err "verification failed for ${f#"$ENVORA_VAULT"/}"
      failed=$((failed + 1))
      continue
    fi
    done_n=$((done_n + 1))
  done <"$files"
  if [[ $failed -gt 0 ]]; then
    err "rotation aborted: $(plural "$failed" file) failed. Your key and the vault are unchanged."
    return 1
  fi

  # 2. Keep the old key.
  local bak n=1
  bak="$ENVORA_KEY.bak-$(now_stamp)"
  while [[ -e "$bak" ]]; do n=$((n + 1)); bak="$ENVORA_KEY.bak-$(now_stamp)-$n"; done
  if ! cp -p "$ENVORA_KEY" "$bak" || ! chmod 600 "$bak" || ! cmp -s "$ENVORA_KEY" "$bak"; then
    err "cannot back up the old key to $(tildify "$bak"); nothing changed"
    return 1
  fi

  # 3. Switch, without interruption.
  trap '' INT TERM HUP
  if ! mv -f "$new_key" "$ENVORA_KEY"; then
    rotate_restore_traps
    err "cannot install the new key at $(tildify "$ENVORA_KEY"); nothing changed (old key also kept at $(tildify "$bak"))"
    return 1
  fi
  unregister_cleanup "$new_key"
  KEY_PUB="$new_pub"
  local moved=() mv_failed=""
  if ! { printf '%s\n' "$new_pub" >"$ENVORA_VAULT/.recipient.envora-new" &&
    mv -f "$ENVORA_VAULT/.recipient.envora-new" "$ENVORA_VAULT/.recipient"; }; then
    mv_failed=".recipient"
  else
    while IFS= read -r f; do
      if mv -f "$f.envora-new" "$f" 2>"$TMP_ROOT/mv.err"; then
        unregister_cleanup "$f.envora-new"
        moved[${#moved[@]}]="${f#"$ENVORA_VAULT"/}"
      else
        mv_failed="${f#"$ENVORA_VAULT"/}"
        break
      fi
    done <"$files"
  fi
  if [[ -n "$mv_failed" ]]; then
    # Roll back: committed (old key) versions of the moved files, then the old key.
    if { [[ ${#moved[@]} -eq 0 ]] || vgit checkout -q -- "${moved[@]}" 2>/dev/null; } &&
      printf '%s\n' "$old_pub" >"$ENVORA_VAULT/.recipient" && cp -p "$bak" "$ENVORA_KEY"; then
      KEY_PUB="$old_pub"
      rotate_restore_traps
      err "rotation rolled back: cannot replace $mv_failed ($(head -n 1 "$TMP_ROOT/mv.err" 2>/dev/null)). Your old key and the vault are as before."
    else
      rotate_restore_traps
      err "rotation interrupted at $mv_failed: the new key is installed, some files still use the old one ($(tildify "$bak"))"
      say "  nothing is lost: run 'ev rotate' again to finish (it reads the old key too)"
    fi
    return 1
  fi
  rotate_restore_traps
  load_identities # the old key is now one of the .bak files

  # 4. Commit and push.
  vault_commit "rotate: re-encrypt $(plural "$done_n" file) for a new key" . >/dev/null || true
  local push_rc=0
  SYNC_PULLED=0
  vault_push || push_rc=$?
  if [[ "${SYNC_PULLED:-0}" -gt 0 ]]; then
    # Another machine saved during the rotation, still with the old key.
    rotate_fixup
    if [[ -n "$FIXED" ]]; then
      warn "re-encrypted $(plural "$(printf '%s' "$FIXED" | grep -c .)" file) saved meanwhile by another machine with the old key"
      vault_commit "rotate: re-encrypt files saved during the rotation" . >/dev/null || true
      push_rc=0
      vault_push || push_rc=$?
    fi
    if [[ -n "$UNREADABLE" ]]; then
      err "these files open with none of your keys: $(printf '%s' "$UNREADABLE" | tr '\n' ' ')"
      push_rc=1
    fi
  fi

  if [[ $push_rc == 1 ]]; then
    partial "key rotated, but some files are not readable with it (see above)"
  else
    result "$push_rc" "key rotated: $(plural "$done_n" file) re-encrypted and verified$(push_suffix "$push_rc")"
  fi
  say "  old key kept at $(tildify "$bak") (backups made by ev restore until now need it)"
  say ""
  say "${C_BOLD}Save this new key in your password manager now (shown once):${C_RST}"
  say ""
  if [[ "${QUIET:-0}" == 1 ]]; then
    cat "$ENVORA_KEY" >&2
  else
    sed 's/^/    /' "$ENVORA_KEY" >&2
  fi
  say ""
  warn "old ciphertexts remain in git history: if your key leaked, also rotate the secrets themselves at their providers"
  say "  other machines need the new key: ev init --import-key (paste it; their old key is kept as .bak)"
  return "$push_rc"
}
