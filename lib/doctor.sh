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

cmd_doctor() {
  [[ $# -eq 0 ]] || { err "usage: ev doctor"; return 1; }
  DOCTOR_FAIL=0
  local t
  out "${C_BOLD}tools${C_RST}"
  for t in age age-keygen git jq fzf gum; do
    if has "$t"; then
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
        doc_bad "your key does NOT match the vault (.recipient)" "import the key this vault was made with: ev init"
      fi
    else
      doc_info "no .recipient yet (written by the next save)"
    fi
    if vault_has_remote; then
      doc_ok "remote: $(vgit remote get-url origin)"
      vault_net_defaults
      if [[ "${NO_SYNC:-0}" != 1 ]] && ! vgit fetch -q origin 2>"$TMP_ROOT/fetch.err"; then
        SYNC_STATE=offline
        doc_warn "cannot reach GitHub: $(head -n 1 "$TMP_ROOT/fetch.err")" "check your network / SSH key, then ev sync"
      else
        local label
        label="$(vault_sync_label)"
        case "$label" in
          ✓*) doc_ok "$label" ;;
          *) doc_warn "$label" "ev sync" ;;
        esac
      fi
    else
      doc_bad "the vault has no remote: nothing is backed up off this machine" "git -C $ENVORA_VAULT remote add origin <url> && ev sync"
    fi
    if [[ -n "$(vgit status --porcelain 2>/dev/null)" ]]; then
      doc_warn "uncommitted changes in the vault" "ev sync"
    fi
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
    [[ $n -gt 0 ]] && doc_ok "$(plural "$n" env file) handled by envora"
    [[ $n -eq 0 ]] && doc_info "no env files in this project"
    if vault_exists && [[ $key_ok == 1 && -d "$ENVORA_VAULT/$PROJECT_NAME" ]]; then
      check_origin "$PROJECT_NAME" >/dev/null 2>&1 || doc_bad "the vault entry '$PROJECT_NAME' belongs to another repository" "ev save --as <other-name>"
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
