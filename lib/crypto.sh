#!/usr/bin/env bash
# lib/crypto.sh - age key, vault recipient, encryption helpers

KEY_PUB=""

key_exists() {
  [[ -f "$ENVORA_KEY" ]]
}

# Public key of a private key file (first identity).
pubkey_of() {
  local out
  out="$(age-keygen -y "$1" 2>/dev/null)" || return 1
  out="$(printf '%s\n' "$out" | head -n 1)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

require_key() {
  [[ -n "$KEY_PUB" ]] && return 0
  if ! key_exists; then
    err "no envora key at $(tildify "$ENVORA_KEY")"
    say "  run 'ev init' to import your existing key or create one"
    return 1
  fi
  if [[ ! -r "$ENVORA_KEY" ]]; then
    err "the key at $(tildify "$ENVORA_KEY") is not readable"
    return 1
  fi
  KEY_PUB="$(pubkey_of "$ENVORA_KEY")" || {
    err "$(tildify "$ENVORA_KEY") is not a valid age key"
    return 1
  }
  load_identities
}

vault_recipient() {
  local f="$ENVORA_VAULT/.recipient"
  [[ -f "$f" ]] || return 1
  head -n 1 "$f" | tr -d '[:space:]'
}

# key_matches_vault -> 0 when the vault is encrypted for this key (or empty).
# The vault's .recipient says which key it uses; a vault saved by envora 0.x
# has none, so one of its files is decrypted instead.
# Sets VAULT_EXPECTED (public key from .recipient) or VAULT_SAMPLE (a vault
# file this key cannot decrypt).
VAULT_EXPECTED="" VAULT_SAMPLE=""
key_matches_vault() {
  local rec sample
  VAULT_EXPECTED="" VAULT_SAMPLE=""
  if rec="$(vault_recipient)" && [[ -n "$rec" ]]; then
    VAULT_EXPECTED="$rec"
    [[ "$rec" == "$KEY_PUB" ]]
    return
  fi
  sample="$(find "$ENVORA_VAULT" -name '*.age' -type f ! -path '*/.git/*' 2>/dev/null | LC_ALL=C sort | head -n 1)"
  if [[ -n "$sample" ]] && ! decrypts_with_key "$sample"; then
    VAULT_SAMPLE="${sample#"$ENVORA_VAULT"/}"
    return 1
  fi
  return 0
}

# A key kept as <key>.bak-* (by ev rotate or ev init --import-key) that
# matches this vault, or nothing.
matching_backup_key() {
  local f
  for f in "$ENVORA_KEY".bak-*; do
    [[ -f "$f" && -r "$f" ]] || continue
    if [[ -n "$VAULT_EXPECTED" ]]; then
      [[ "$(pubkey_of "$f" 2>/dev/null || true)" == "$VAULT_EXPECTED" ]] && { printf '%s' "$f"; return 0; }
    elif [[ -n "$VAULT_SAMPLE" ]]; then
      age -d -i "$f" "$ENVORA_VAULT/$VAULT_SAMPLE" >/dev/null 2>&1 && { printf '%s' "$f"; return 0; }
    fi
  done
  return 1
}

# recipient_mismatch_message [init]: "init" leaves out "Nothing was changed"
# (init may have just installed a key).
recipient_mismatch_message() {
  local bak=""
  bak="$(matching_backup_key || true)"
  if [[ -n "$VAULT_EXPECTED" ]]; then
    err "this vault is encrypted for a different key than yours (rotated elsewhere? run: ev init --import-key)"
    say "  vault expects: $(printf '%.24s' "$VAULT_EXPECTED")..."
  else
    err "your key cannot decrypt the files already in the vault (e.g. $VAULT_SAMPLE): it is not the key this vault was made with (run: ev init --import-key)"
  fi
  say "  your key:      $(printf '%.24s' "$KEY_PUB")... ($(tildify "$ENVORA_KEY"))"
  if [[ -n "$bak" ]]; then
    say "  your previous key $(tildify "$bak") matches this vault. To put it back:"
    say "    cp -p $(tildify "$bak") $(tildify "$ENVORA_KEY")"
  else
    say "  Two usual causes:"
    say "    - the key was rotated on another machine (ev rotate): import the new key"
    say "    - this machine generated its own key instead of importing your envora key"
    say "  Fix: ev init --import-key   (paste the right key; the current one is kept as .bak)"
  fi
  [[ "${1:-}" == init ]] || say "  Nothing was changed."
}

# Check the vault is encrypted for the local key.
# With "write": record .recipient when it is missing.
check_recipient() {
  local mode="${1:-read}"
  require_key || return 1
  if ! key_matches_vault; then
    recipient_mismatch_message
    return 1
  fi
  if [[ "$mode" == write && -z "$VAULT_EXPECTED" ]]; then
    printf '%s\n' "$KEY_PUB" >"$ENVORA_VAULT/.recipient"
  fi
  return 0
}

# decrypt_stream file.age -> plaintext on stdout. Old keys kept by a
# rotation are tried too: a file another machine saved with the previous key
# stays readable until it is re-encrypted.
decrypt_stream() {
  decrypt_any "$1"
}

# Every key this machine has: the current one, then the old ones kept by
# "ev rotate" (<key>.bak-<date>). Sets ID_ARGS to "-i file" pairs.
ID_ARGS=()
load_identities() {
  local f
  ID_ARGS=(-i "$ENVORA_KEY")
  for f in "$ENVORA_KEY".bak-*; do
    [[ -f "$f" && -r "$f" ]] || continue
    pubkey_of "$f" >/dev/null || continue
    ID_ARGS[${#ID_ARGS[@]}]="-i"
    ID_ARGS[${#ID_ARGS[@]}]="$f"
  done
}

# Decrypt with the current key or any old one.
decrypt_any() {
  [[ ${#ID_ARGS[@]} -gt 0 ]] || load_identities
  age -d "${ID_ARGS[@]}" "$1"
}

# True when the current key decrypts FILE.
decrypts_with_key() {
  age -d -i "$ENVORA_KEY" "$1" >/dev/null 2>&1
}

# encrypt_file src dest.age (atomic: temp file next to dest, then mv)
encrypt_file() {
  local src="$1" dest="$2" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$dest.envora-XXXXXX")" || return 1
  register_cleanup "$tmp"
  if ! age -r "$KEY_PUB" -o "$tmp" "$src" 2>"$TMP_ROOT/age.err"; then
    rm -f "$tmp"
    err "encryption failed for $src: $(head -n 1 "$TMP_ROOT/age.err")"
    return 1
  fi
  mv -f "$tmp" "$dest"
  unregister_cleanup "$tmp"
}

# encrypt_stdin dest.age (atomic)
encrypt_stdin() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$dest.envora-XXXXXX")" || return 1
  register_cleanup "$tmp"
  if ! age -r "$KEY_PUB" -o "$tmp" 2>"$TMP_ROOT/age.err"; then
    rm -f "$tmp"
    err "encryption failed for $dest: $(head -n 1 "$TMP_ROOT/age.err")"
    return 1
  fi
  mv -f "$tmp" "$dest"
  unregister_cleanup "$tmp"
}

# same_plaintext file.age plainfile -> 0 if identical
same_plaintext() {
  decrypt_stream "$1" 2>/dev/null | cmp -s - "$2"
}
