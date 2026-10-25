#!/usr/bin/env bash
# lib/init.sh - first-time or new-machine setup

# vault_accepts_key PUB KEYFILE -> 0 when the vault (if there is one) is
# encrypted for this key: its .recipient, or GitHub's after a fetch (the key
# was rotated on another machine and this vault did not pull it yet), else a
# vault file it decrypts. Sets VAULT_EXPECTED when it refuses.
vault_accepts_key() {
  local pub="$1" keyfile="$2" rec="" rrec="" up sample
  VAULT_EXPECTED=""
  vault_exists || return 0
  rec="$(vault_recipient || true)"
  [[ -n "$rec" && "$rec" == "$pub" ]] && return 0
  if vault_has_remote && [[ "${NO_SYNC:-0}" != 1 ]]; then
    vault_net_defaults
    vgit fetch -q origin >/dev/null 2>&1 || true
  fi
  if up="$(vault_upstream)"; then
    rrec="$(vgit show "$up:.recipient" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
    [[ -n "$rrec" && "$rrec" == "$pub" ]] && return 0
  fi
  if [[ -n "$rec$rrec" ]]; then
    VAULT_EXPECTED="${rrec:-$rec}"
    return 1
  fi
  sample="$(find "$ENVORA_VAULT" -name '*.age' -type f ! -path '*/.git/*' 2>/dev/null | LC_ALL=C sort | head -n 1)"
  [[ -z "$sample" ]] && return 0
  age -d -i "$keyfile" "$sample" >/dev/null 2>&1
}

# Install the AGE-SECRET-KEY-... found anywhere in pasted text (a single-line
# prompt turns the newlines of a pasted key file into spaces). A key that does
# not match the vault is refused before anything changes. An existing,
# different key is kept as <key>.bak-<date>: envora still reads old files with it.
install_key_from_text() {
  local text="$1" secret pub old_pub bak n=1 tmp="$ENVORA_KEY.envora-tmp"
  secret="$(printf '%s\n' "$text" | tr -d '\r' | grep -oE 'AGE-SECRET-KEY-[A-Z0-9-]+' || true)"
  if [[ -z "$secret" ]]; then
    err "no AGE-SECRET-KEY-... found in what you pasted"
    return 1
  fi
  pub="$(printf '%s\n' "$secret" | age-keygen -y 2>/dev/null | head -n 1)" || pub=""
  [[ -n "$pub" ]] || { err "this is not a valid age key"; return 1; }
  mkdir -p "$(dirname "$ENVORA_KEY")" || return 1
  chmod 700 "$(dirname "$ENVORA_KEY")" 2>/dev/null || true
  if key_exists; then
    old_pub="$(pubkey_of "$ENVORA_KEY" || true)"
    if [[ "$old_pub" == "$pub" ]]; then
      KEY_PUB="$pub"
      ok "this key is already in place ($(printf '%.20s' "$pub")...)"
      return 0
    fi
  fi
  register_cleanup "$tmp"
  {
    printf '# envora key, imported %s\n' "$(date +%Y-%m-%dT%H:%M:%S)"
    printf '# public key: %s\n' "$pub"
    printf '%s\n' "$secret"
  } >"$tmp"
  chmod 600 "$tmp"
  if ! vault_accepts_key "$pub" "$tmp"; then
    rm -f "$tmp"
    unregister_cleanup "$tmp"
    if [[ -n "$VAULT_EXPECTED" ]]; then
      err "this key is not your vault's key (the vault expects $(printf '%.24s' "$VAULT_EXPECTED")..., this key is $(printf '%.24s' "$pub")...)"
    else
      err "this key cannot decrypt the files of your vault: it is not your vault's key"
    fi
    if key_exists; then
      say "  nothing changed: your current key stays in place"
    fi
    return 1
  fi
  if key_exists; then
    bak="$ENVORA_KEY.bak-$(now_stamp)"
    while [[ -e "$bak" ]]; do n=$((n + 1)); bak="$ENVORA_KEY.bak-$(now_stamp)-$n"; done
    if ! cp -p "$ENVORA_KEY" "$bak" || ! chmod 600 "$bak"; then
      rm -f "$tmp"
      err "cannot keep the current key as $(tildify "$bak"): nothing changed"
      return 1
    fi
    say "${C_DIM}the previous key is kept at $(tildify "$bak")${C_RST}"
  fi
  mv -f "$tmp" "$ENVORA_KEY"
  unregister_cleanup "$tmp"
  KEY_PUB="$pub"
  ID_ARGS=()
  ok "key saved to $(tildify "$ENVORA_KEY") ($(printf '%.20s' "$pub")...)"
}

init_import_key() {
  local text="" try=1
  if ! is_interactive; then
    text="$(cat)"
    install_key_from_text "$text"
    return
  fi
  say "Paste your envora key: the AGE-SECRET-KEY-... line (pasting the whole key file works too)."
  while [[ $try -le 3 ]]; do
    if has gum; then
      # No length limit: a post-quantum key file (ev rotate --pq) is ~2 KB.
      text="$(gum input --password --char-limit 0 --placeholder "AGE-SECRET-KEY-..." --width 80 </dev/tty)" || return 1
    else
      printf 'key: ' >&2
      IFS= read -rs text </dev/tty || return 1
      printf '\n' >&2
    fi
    install_key_from_text "$text" && return 0
    try=$((try + 1))
    [[ $try -le 3 ]] && say "try again (Esc to stop)"
  done
  return 1
}

init_generate_key() {
  local keygen_args=()
  [[ "${INIT_PQ:-0}" == 1 ]] && keygen_args=(-pq)
  mkdir -p "$(dirname "$ENVORA_KEY")" || return 1
  chmod 700 "$(dirname "$ENVORA_KEY")" 2>/dev/null || true
  age-keygen ${keygen_args[@]+"${keygen_args[@]}"} -o "$ENVORA_KEY" 2>"$TMP_ROOT/keygen.err" || {
    err "cannot generate a key: $(head -n 1 "$TMP_ROOT/keygen.err")"
    return 1
  }
  chmod 600 "$ENVORA_KEY"
  KEY_PUB="$(pubkey_of "$ENVORA_KEY")"
  say ""
  say "${C_BOLD}Your new envora key. Save it in your password manager now (shown once):${C_RST}"
  say ""
  sed 's/^/    /' "$ENVORA_KEY" >&2
  say ""
  say "Without it, nobody (not even you) can decrypt the vault on another machine."
  if is_interactive && ! confirm "I saved the key in my password manager"; then
    warn "keep it safe: it is in $(tildify "$ENVORA_KEY")"
  fi
  return 0
}

# repo spec -> clone URL
repo_clone_url() {
  local r="$1" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  if [[ "$r" =~ $re ]]; then
    printf 'git@github.com:%s.git' "$r"
  else
    printf '%s' "$r"
  fi
}

init_clone() {
  local repo="$1" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  mkdir -p "$(dirname "$ENVORA_VAULT")" || return 1
  step "cloning $repo into $(tildify "$ENVORA_VAULT")"
  if [[ "$repo" =~ $re ]] && has gh && gh auth status >/dev/null 2>&1; then
    gh repo clone "$repo" "$ENVORA_VAULT" -- -q 2>"$TMP_ROOT/clone.err" || {
      err "cannot clone $repo: $(tail -n 1 "$TMP_ROOT/clone.err")"
      return 1
    }
  else
    git clone -q "$(repo_clone_url "$repo")" "$ENVORA_VAULT" 2>"$TMP_ROOT/clone.err" || {
      err "cannot clone $repo: $(tail -n 1 "$TMP_ROOT/clone.err")"
      return 1
    }
  fi
  case "$repo" in
    */*) [[ "$repo" =~ $re ]] && ENVORA_REPO="$repo" ;;
  esac
  ok "vault cloned"
}

init_create() {
  local name="$1" full
  has gh || { err "creating a repo needs the GitHub CLI (gh)"; return 1; }
  valid_name "$name" || { err "invalid repo name: $name"; return 1; }
  step "creating the private repo $name on GitHub"
  gh repo create "$name" --private --description "Encrypted env vault managed by envora" >/dev/null 2>"$TMP_ROOT/gh.err" || {
    err "gh repo create failed: $(tail -n 1 "$TMP_ROOT/gh.err")"
    return 1
  }
  full="$(gh repo view "$name" --json nameWithOwner -q .nameWithOwner 2>"$TMP_ROOT/gh.err")" || full=""
  if [[ -z "$full" ]]; then
    err "repo created but its full name could not be read: $(tail -n 1 "$TMP_ROOT/gh.err")"
    return 1
  fi
  init_clone "$full" || return 1
  ENVORA_REPO="$full"
}

init_pick_repo() {
  local choice repo
  choice="$(choose "Where is your vault?" \
    "Clone my existing vault repo" \
    "Create a new private repo on GitHub")" || return 1
  case "$choice" in
    Clone*)
      if has gh && gh auth status >/dev/null 2>&1 && has fzf; then
        repo="$(gh repo list --limit 200 --json nameWithOwner,isPrivate -q '.[] | select(.isPrivate) | .nameWithOwner' 2>/dev/null |
          fzf --height=~40% --layout=reverse --border=rounded --border-label=" your private repos " \
            --print-query --header="pick the vault repo, or type user/name" --color="$FZF_COLORS" | tail -n 1)" || true
      fi
      [[ -n "${repo:-}" ]] || repo="$(ask "Vault repo (user/name or git URL):" "${ENVORA_REPO:-}")" || return 1
      [[ -n "$repo" ]] || return 1
      init_clone "$repo"
      ;;
    Create*)
      local name
      name="$(ask "New repo name:" "env-vault")" || return 1
      init_create "$name"
      ;;
    *) return 1 ;;
  esac
}

run_init() {
  local key_mode="" repo="" create=""
  INIT_PQ=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --import-key) key_mode=import ;;
      --generate-key) key_mode=generate ;;
      --pq) INIT_PQ=1 ;;
      --repo) [[ $# -ge 2 ]] || { err "--repo needs a value"; return 1; }; repo="$2"; shift ;;
      --create) [[ $# -ge 2 ]] || { err "--create needs a name"; return 1; }; create="$2"; shift ;;
      *) err "unknown option for init: $1"; return 1 ;;
    esac
    shift
  done

  say "${C_BOLD}1. your key${C_RST}  ${C_DIM}$(tildify "$ENVORA_KEY")${C_RST}"
  if key_exists && [[ "$key_mode" == import ]]; then
    # Replace the key on purpose (rotated elsewhere, wrong key on this machine).
    init_import_key || return 1
  elif key_exists; then
    require_key || return 1
    ok "key found ($(printf '%.20s' "$KEY_PUB")...)"
  else
    if [[ -z "$key_mode" ]]; then
      if is_interactive; then
        local c
        c="$(choose "No envora key on this machine." \
          "I already have an envora key (paste it from your password manager)" \
          "Generate a new key (first time using envora)")" || return 1
        case "$c" in
          I*) key_mode=import ;;
          *) key_mode=generate ;;
        esac
      else
        err "no key at $(tildify "$ENVORA_KEY"): use --import-key (key on stdin) or --generate-key"
        return 1
      fi
    fi
    case "$key_mode" in
      import) init_import_key || return 1 ;;
      generate) init_generate_key || return 1 ;;
    esac
  fi

  say ""
  say "${C_BOLD}2. your vault${C_RST}  ${C_DIM}$(tildify "$ENVORA_VAULT")${C_RST}"
  if vault_exists; then
    ok "vault found"
    # A key rotated on another machine: its new .recipient comes from GitHub.
    vault_pull >/dev/null || true
    vault_unlock
    if [[ -z "$ENVORA_REPO" ]]; then
      local url
      url="$(vgit remote get-url origin 2>/dev/null || true)"
      case "$url" in
        *github.com*)
          ENVORA_REPO="$(printf '%s' "$url" | sed 's|.*github\.com[:/]||;s|\.git$||')"
          ;;
      esac
    fi
  elif [[ -e "$ENVORA_VAULT" && -n "$(ls -A "$ENVORA_VAULT" 2>/dev/null)" ]]; then
    err "$(tildify "$ENVORA_VAULT") exists but is not a git repo: move it away or set another path (ev config set vault ...)"
    return 1
  elif [[ -n "$create" ]]; then
    init_create "$create" || return 1
  elif [[ -n "$repo" ]]; then
    init_clone "$repo" || return 1
  elif is_interactive; then
    init_pick_repo || return 1
  else
    err "no vault at $(tildify "$ENVORA_VAULT"): use --repo user/name (clone) or --create name"
    return 1
  fi

  # The vault must be encrypted for this key.
  local c
  while ! key_matches_vault; do
    recipient_mismatch_message init
    is_interactive || return 1
    c="$(choose "What now?" \
      "Paste the right key now (the current one is kept as .bak)" \
      "Stop here")" || return 1
    case "$c" in
      Paste*) init_import_key || return 1 ;;
      *) return 1 ;;
    esac
  done

  [[ -n "$ENVORA_REPO" ]] && config_mark ENVORA_REPO
  [[ "$ENVORA_VAULT" != "$HOME/.env-vault" ]] && config_mark ENVORA_VAULT
  [[ "$ENVORA_KEY" != "$HOME/.age/key.txt" ]] && config_mark ENVORA_KEY
  [[ "$ENVORA_PROJECTS" != "$HOME/projects" ]] && config_mark ENVORA_PROJECTS
  save_config || warn "cannot write $(config_rc_path)"
  say ""
  ok "envora is ready: vault $(tildify "$ENVORA_VAULT")${ENVORA_REPO:+ ($ENVORA_REPO)}"
  return 0
}
