#!/usr/bin/env bash
# lib/doctor.sh - checks with a fix for each problem

DOCTOR_FAIL=0

doc_ok() { out "  ${C_ACC}✓${C_RST} $1"; }
doc_bad() {
  out "  ${C_ERR}✗${C_RST} $1"
  [[ -n "${2:-}" ]] && out "      ${C_DIM}fix: $2${C_RST}"
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
}
doc_warn() {
  out "  ${C_WARN}!${C_RST} $1"
  [[ -n "${2:-}" ]] && out "      ${C_DIM}fix: $2${C_RST}"
  return 0
}
doc_info() { out "  ${C_DIM}· $1${C_RST}"; }

# Every encrypted file must open with the current key.
doctor_decrypt_all() {
  local f rel total=0 old=() lost=()
  load_identities
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    total=$((total + 1))
    decrypts_with_key "$f" && continue
    rel="${f#"$ENVORA_VAULT"/}"
    if age -d "${ID_ARGS[@]}" "$f" >/dev/null 2>&1; then
      old[${#old[@]}]="$rel"
    else
      lost[${#lost[@]}]="$rel"
    fi
  done < <(find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' 2>/dev/null)
  if [[ ${#lost[@]} -gt 0 ]]; then
    doc_bad "$(plural ${#lost[@]} file) open with none of your keys: $(short_list 3 "${lost[@]}")" "import the key they were saved with (ev init --import-key), or take them from git history"
  fi
  if [[ ${#old[@]} -gt 0 ]]; then
    doc_warn "$(plural ${#old[@]} file) still encrypted for an old key: $(short_list 3 "${old[@]}")" "ev rotate (re-encrypts them for the current key)"
  fi
  if [[ ${#lost[@]} -eq 0 && ${#old[@]} -eq 0 && $total -gt 0 ]]; then
    doc_ok "all $(plural "$total" "encrypted file") open with your key"
  fi
}

cmd_doctor() {
  [[ $# -eq 0 ]] || { err "usage: ev doctor"; return 1; }
  DOCTOR_FAIL=0
  local t
  out "${C_BOLD}tools${C_RST}"
  for t in age age-keygen git jq fzf gum; do
    if [[ "$t" == fzf ]] && has fzf && ! fzf_recent; then
      doc_warn "fzf $(fzf_version) is too old for the menu (needs $FZF_MIN or newer)" "upgrade fzf (brew upgrade fzf / nix)"
    elif has "$t"; then
      doc_ok "$t"
    else
      case "$t" in
        fzf|gum) doc_warn "$t missing (needed for the interactive menu)" "install $t (brew install $t / nix)" ;;
        *) doc_bad "$t missing" "install $t (brew install ${t%-keygen} / nix)" ;;
      esac
    fi
  done
  if has vercel; then doc_ok "vercel (optional)"; else doc_info "vercel not installed (optional: npx vercel@$VERCEL_PINNED is used)"; fi
  if has wrangler; then doc_ok "wrangler (optional)"; else doc_info "wrangler not installed (optional: npx wrangler@$WRANGLER_PINNED is used)"; fi
  if has gh; then doc_ok "gh (optional, used by ev init)"; else doc_info "gh not installed (optional, used by ev init)"; fi

  out ""
  out "${C_BOLD}key${C_RST}  ${C_DIM}$(tildify "$ENVORA_KEY")${C_RST}"
  local key_ok=0
  if ! key_exists; then
    doc_bad "no key file" "ev init (import your key from your password manager)"
  elif ! KEY_PUB="$(pubkey_of "$ENVORA_KEY")"; then
    KEY_PUB=""
    doc_bad "the key file is not a valid age key" "restore it from your password manager"
  else
    key_ok=1
    doc_ok "key readable ($(printf '%.20s' "$KEY_PUB")...)"
    if [[ -n "$(find "$ENVORA_KEY" -prune \( -perm -040 -o -perm -004 \) 2>/dev/null)" ]]; then
      doc_warn "the key file is readable by other users" "chmod 600 $ENVORA_KEY"
    fi
  fi

  out ""
  out "${C_BOLD}vault${C_RST}  ${C_DIM}$(tildify "$ENVORA_VAULT")${C_RST}"
  if ! vault_exists; then
    doc_bad "no vault git repo" "ev init"
  else
    doc_ok "vault is a git repo"
    local rec
    if rec="$(vault_recipient)" && [[ -n "$rec" ]]; then
      if [[ $key_ok == 1 && "$rec" == "$KEY_PUB" ]]; then
        doc_ok "your key matches the vault (.recipient)"
      elif [[ $key_ok == 1 ]]; then
        doc_bad "your key does NOT match the vault (.recipient)" "ev init --import-key (the key was rotated elsewhere, or this machine made its own)"
      fi
    elif [[ $key_ok == 1 ]] && ! key_matches_vault; then
      doc_bad "your key cannot decrypt the vault files (e.g. $VAULT_SAMPLE)" "ev init --import-key (paste the key this vault was made with)"
    else
      doc_info "no .recipient yet (written by the next save)"
    fi
    if vault_has_remote; then
      doc_ok "remote: $(sanitize_origin "$(vgit remote get-url origin)")"
      vault_net_defaults
      if [[ "${NO_SYNC:-0}" != 1 ]] && ! vgit fetch -q origin 2>"$TMP_ROOT/fetch.err"; then
        SYNC_STATE=offline
        doc_warn "cannot reach GitHub: $(head -n 1 "$TMP_ROOT/fetch.err")" "check your network / SSH key, then ev sync"
      else
        local label
        label="$(vault_sync_label)"
        case "$label" in
          ✓*) doc_ok "${label#✓ }" ;;
          *) doc_warn "$label" "ev sync" ;;
        esac
      fi
    else
      doc_bad "the vault has no remote: nothing is backed up off this machine" "git -C $ENVORA_VAULT remote add origin <url> && ev sync"
    fi
    if [[ -n "$(vgit status --porcelain 2>/dev/null)" ]]; then
      doc_warn "uncommitted changes in the vault" "ev sync"
    fi
    [[ $key_ok == 1 ]] && doctor_decrypt_all
  fi

  if detect_current_project 2>/dev/null; then
    out ""
    out "${C_BOLD}project${C_RST}  ${C_DIM}$PROJECT_NAME · $(tildify "$PROJECT_DIR")${C_RST}"
    scan_project "$PROJECT_DIR"
    local rel n=0
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      n=$((n + 1))
      if [[ $PROJECT_IS_GIT == 1 ]] && ! git -C "$PROJECT_DIR" check-ignore -q -- "$rel" 2>/dev/null; then
        doc_bad "$rel is not ignored by git: it could be committed by mistake" "echo '$rel' >> .gitignore"
      fi
    done <"$TMP_ROOT/scan.files"
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      doc_warn "$rel is tracked by git: envora skips it (it is in your git history)" "git rm --cached '$rel' && echo '$rel' >> .gitignore, then ev save"
    done <"$TMP_ROOT/scan.tracked"
    # Env files a save would miss: the wipe hook refuses the folder for them.
    scan_unreached "$PROJECT_DIR"
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      doc_bad "$rel is NOT reached by envora ($(unreached_reason "$rel")): ev save leaves it out and exits 1" "move it up, or list it in .envoraignore if it holds no secret of yours"
    done <"$TMP_ROOT/scan.unreached"
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      doc_bad "$rel cannot be saved: a newline or tab in its path" "rename it"
    done <"$TMP_ROOT/scan.badnames"
    [[ $n -gt 0 ]] && doc_ok "$(plural "$n" "env file") handled by envora"
    [[ $n -eq 0 ]] && doc_info "no env files in this project"
    if vault_exists && [[ $key_ok == 1 && -d "$ENVORA_VAULT/$PROJECT_NAME" ]]; then
      check_origin "$PROJECT_NAME" >/dev/null 2>&1 || doc_bad "the vault entry '$PROJECT_NAME' belongs to another repository" "ev save --as <other-name> (or ev save --as $PROJECT_NAME --force if it is the same repo, renamed or moved)"
      local legacy
      for legacy in .env.development .env.preview .env.production; do
        [[ -f "$ENVORA_VAULT/$PROJECT_NAME/$legacy.age" ]] || continue
        is_legacy_vercel_copy "$legacy" || continue
        doc_warn "vault/$PROJECT_NAME/$legacy is a Vercel snapshot saved by envora 0.x: restore writes it into the project, where Next.js loads it" \
          "ev import vercel (snapshots now live apart, in @vercel/), then ev forget $PROJECT_NAME $legacy"
      done
    fi
  fi

  out ""
  if [[ $DOCTOR_FAIL -eq 0 ]]; then
    out "${C_ACC}all good${C_RST}"
    return 0
  fi
  out "$(plural "$DOCTOR_FAIL" problem) found"
  return 1
}
