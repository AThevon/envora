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
    err "no envora key at $ENVORA_KEY"
    say "  run 'ev init' to import your existing key or create one"
    return 1
  fi
  if [[ ! -r "$ENVORA_KEY" ]]; then
    err "the key at $ENVORA_KEY is not readable"
    return 1
  fi
  KEY_PUB="$(pubkey_of "$ENVORA_KEY")" || {
    err "$ENVORA_KEY is not a valid age key"
    return 1
  }
}

vault_recipient() {
  local f="$ENVORA_VAULT/.recipient"
  [[ -f "$f" ]] || return 1
  head -n 1 "$f" | tr -d '[:space:]'
}

recipient_mismatch_message() {
  local expected="$1"
  err "this vault is encrypted for a different key"
  say "  vault expects: $(printf '%.24s' "$expected")..."
  say "  your key:      $(printf '%.24s' "$KEY_PUB")... ($ENVORA_KEY)"
  say "  This usually means this machine has a new key instead of your envora key."
  say "  Fix: put your existing key at $ENVORA_KEY (ev init > 'I already have an envora key'),"
  say "  or point ENVORA_KEY to it. Nothing was changed."
}

# Check the vault recipient matches the local key.
# With "write": record it when missing (after checking existing files decrypt).
check_recipient() {
  local mode="${1:-read}" rec
  require_key || return 1
  if rec="$(vault_recipient)" && [[ -n "$rec" ]]; then
    if [[ "$rec" != "$KEY_PUB" ]]; then
      recipient_mismatch_message "$rec"
      return 1
    fi
    return 0
  fi
  [[ "$mode" == write ]] || return 0
  # No .recipient yet (older vault): make sure existing files are ours.
  local sample
  sample="$(find "$ENVORA_VAULT" -name '*.age' -type f ! -path '*/.git/*' 2>/dev/null | head -n 1)"
  if [[ -n "$sample" ]] && ! age -d -i "$ENVORA_KEY" "$sample" >/dev/null 2>&1; then
    err "your key cannot decrypt the files already in the vault (${sample#"$ENVORA_VAULT"/})"
    say "  This machine probably has a different key. Import your envora key with 'ev init'."
    return 1
  fi
  printf '%s\n' "$KEY_PUB" >"$ENVORA_VAULT/.recipient"
}

# decrypt_to_stdout file.age
decrypt_stream() {
  age -d -i "$ENVORA_KEY" "$1"
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
