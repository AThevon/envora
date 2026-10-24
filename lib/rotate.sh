#!/usr/bin/env bash
# lib/rotate.sh - replace the key and re-encrypt the whole vault
#
# Safe order: the new key and the re-encrypted files are written next to the
# originals and verified first. Only when everything checks out is the old key
# copied to <key>.bak-<date> and the new files moved into place.

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

  local list="$TMP_ROOT/rotate.list" new_key="$ENVORA_KEY.new"
  find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' | LC_ALL=C sort >"$list"
  local total
  total="$(grep -c . "$list" || true)"
  if [[ "$total" -eq 0 ]]; then
    warn "the vault has no encrypted files: nothing to rotate"
    return 0
  fi
  if [[ -e "$new_key" ]]; then
    err "$new_key already exists (left by an interrupted rotation?): check it, delete it, then retry"
    return 1
  fi
  if ! confirm "Create a new key and re-encrypt the $(plural "$total" file) of the vault?"; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to rotate without confirmation: add --yes"
    return 1
  fi

  local keygen_args=()
  [[ $pq == 1 ]] && keygen_args=(-pq)
  register_cleanup "$new_key"
  if ! age-keygen ${keygen_args[@]+"${keygen_args[@]}"} -o "$new_key" 2>"$TMP_ROOT/keygen.err"; then
    err "cannot generate a new key: $(head -n 1 "$TMP_ROOT/keygen.err")"
    return 1
  fi
  chmod 600 "$new_key"
  local new_pub
  new_pub="$(pubkey_of "$new_key")" || { err "the new key is unreadable"; return 1; }

  # Re-encrypt every file to "<file>.envora-new", plaintext only in pipes.
  local f failed=0 done_n=0 a b
  while IFS= read -r f; do
    register_cleanup "$f.envora-new"
    if ! age -d -i "$ENVORA_KEY" "$f" 2>"$TMP_ROOT/age.err" | age -r "$new_pub" -o "$f.envora-new" 2>>"$TMP_ROOT/age.err"; then
      err "cannot re-encrypt ${f#"$ENVORA_VAULT"/}: $(head -n 1 "$TMP_ROOT/age.err")"
      failed=$((failed + 1))
      continue
    fi
    a="$(age -d -i "$ENVORA_KEY" "$f" 2>/dev/null | cksum)" || a="old-failed"
    b="$(age -d -i "$new_key" "$f.envora-new" 2>/dev/null | cksum)" || b="new-failed"
    if [[ "$a" != "$b" ]]; then
      err "verification failed for ${f#"$ENVORA_VAULT"/}"
      failed=$((failed + 1))
      continue
    fi
    done_n=$((done_n + 1))
  done <"$list"

  if [[ $failed -gt 0 ]]; then
    err "rotation aborted: $(plural "$failed" file) failed. Your key and the vault are unchanged."
    return 1
  fi

  # Everything verified: switch.
  local bak
  bak="$ENVORA_KEY.bak-$(now_stamp)"
  cp -p "$ENVORA_KEY" "$bak" || { err "cannot back up the old key to $bak; nothing changed"; return 1; }
  chmod 600 "$bak"
  while IFS= read -r f; do
    mv -f "$f.envora-new" "$f"
  done <"$list"
  mv -f "$new_key" "$ENVORA_KEY"
  KEY_PUB="$new_pub"
  printf '%s\n' "$new_pub" >"$ENVORA_VAULT/.recipient"

  vault_commit "rotate: re-encrypt $(plural "$done_n" file) for a new key" . >/dev/null || true
  local push_rc=0
  vault_push || push_rc=$?

  ok "key rotated: $(plural "$done_n" file) re-encrypted and verified$(push_suffix "$push_rc")"
  say "  old key kept at $bak"
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
  say "  other machines need the new key: ev init > 'I already have an envora key'"
  return "$push_rc"
}
