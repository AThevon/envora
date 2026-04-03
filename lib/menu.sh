#!/usr/bin/env bash
# lib/menu.sh - Interactive fzf menus (nixdash-style)

cmd_interactive() {
  local project
  project=$(detect_project)

  if [[ -n "$project" ]]; then
    _menu_project "$project"
  else
    _menu_global
  fi
}

_menu_project() {
  local name="$1"
  local vault_status="not in vault"
  local file_count=0
  if [[ -d "$ENVOY_VAULT/$name" ]]; then
    file_count=$(find_age_files "$ENVOY_VAULT/$name" | wc -l)
    vault_status="$file_count file(s) in vault"
  fi

  ui_header

  local header
  header="$(printf '%b' "${C_2}${name}${C_RESET} ${C_DIM}${vault_status}${C_RESET} │ ${C_DIM}ESC quit${C_RESET}")"

  local ev_bin="${ENVOY_BIN:-$0}"

  local menu_items=(
    "push       │ ${C_2}⊕${C_RESET}  Push all"
    "push-local │ ${C_2}↑${C_RESET}  Push local"
    "push-vercel│ ${C_2}▲${C_RESET}  Push Vercel"
    "pull       │ ${C_2}↓${C_RESET}  Pull"
    "diff       │ ${C_2}◈${C_RESET}  Diff"
    "list       │ ${C_DIM}☰${C_RESET}  Browse vault"
    "clean      │ ${C_DIM}✕${C_RESET}  Clean"
    "config     │ ${C_DIM}⚙${C_RESET}  Config"
    "rotate     │ ${C_DIM}⟳${C_RESET}  Rotate key"
  )

  local tmpfile
  tmpfile="$(mktemp)"

  printf '%s\n' "${menu_items[@]}" \
  | fzf \
    --ansi \
    --no-sort \
    --height=50% \
    --layout=reverse \
    --border \
    --header "$header" \
    --preview "bash '$ev_bin' _hub-preview {1} '$name'" \
    --preview-window "right:50%:wrap" \
    --delimiter "│" \
    --with-nth 2.. \
  > "$tmpfile" || { rm -f "$tmpfile"; return 0; }

  local choice
  choice="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  local cmd
  cmd="$(echo "$choice" | awk -F'│' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"

  case "$cmd" in
    push)         cmd_push "$name" ;;
    push-local)   cmd_push_local "$name" ;;
    push-vercel)  cmd_push_vercel "$name" ;;
    pull)         cmd_pull "$name" ;;
    diff)         cmd_diff "$name" ;;
    list)         _menu_list ;;
    clean)        cmd_clean ;;
    config)       cmd_config ;;
    rotate)       cmd_rotate ;;
  esac
}

_menu_global() {
  ui_header

  local header
  header="$(printf '%b' "${C_2}envoy${C_RESET} ${C_DIM}v${VERSION}${C_RESET} │ ${C_DIM}ESC quit${C_RESET}")"

  local ev_bin="${ENVOY_BIN:-$0}"

  local menu_items=(
    "list       │ ${C_2}☰${C_RESET}  Browse vault"
    "clean      │ ${C_2}✕${C_RESET}  Clean"
    "config     │ ${C_DIM}⚙${C_RESET}  Config"
    "rotate     │ ${C_DIM}⟳${C_RESET}  Rotate key"
  )

  local tmpfile
  tmpfile="$(mktemp)"

  printf '%s\n' "${menu_items[@]}" \
  | fzf \
    --ansi \
    --no-sort \
    --height=40% \
    --layout=reverse \
    --border \
    --header "$header" \
    --preview "bash '$ev_bin' _hub-preview {1}" \
    --preview-window "right:50%:wrap" \
    --delimiter "│" \
    --with-nth 2.. \
  > "$tmpfile" || { rm -f "$tmpfile"; return 0; }

  local choice
  choice="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  local cmd
  cmd="$(echo "$choice" | awk -F'│' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"

  case "$cmd" in
    list)    _menu_list ;;
    clean)   cmd_clean ;;
    config)  cmd_config ;;
    rotate)  cmd_rotate ;;
  esac
}

# Hub preview - called by fzf via ev.sh dispatch
hub_preview() {
  local key="$1"
  local project="${2:-}"
  # Colors for preview (subprocess, need to redefine)
  local G=$'\033[38;2;52;211;153m' R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'

  case "$key" in
    push)
      echo -e "${G}⊕${R}  Push all"
      echo ""
      echo "Encrypt local .env files and pull Vercel"
      echo "envs (if detected). Saves everything to"
      echo "the vault in one go."
      echo ""
      echo "• Detects .env, .env.local, .env.* files"
      echo "• Auto-detects Vercel projects"
      echo "• Encrypts with age before pushing"
      ;;
    push-local)
      echo -e "${G}↑${R}  Push local"
      echo ""
      echo "Encrypt only local .env files and save"
      echo "them to the vault."
      echo ""
      echo "• .env, .env.local, and other .env.* files"
      echo "• Excludes .env.example"
      echo "• Does not touch Vercel"
      ;;
    push-vercel)
      echo -e "${G}▲${R}  Push Vercel"
      echo ""
      echo "Pull environment variables from Vercel"
      echo "and save them encrypted to the vault."
      echo ""
      echo "• development, preview, production"
      echo "• Auto-links project if needed"
      echo "• Requires npx (vercel CLI)"
      ;;
    pull)
      echo -e "${G}↓${R}  Pull"
      echo ""
      echo "Decrypt .env files from the vault and"
      echo "restore them into your project."
      echo ""
      echo "• Overwrites existing local .env files"
      echo "• Only pulls what's in the vault"
      ;;
    diff)
      echo -e "${G}◈${R}  Diff"
      echo ""
      echo "Line-by-line comparison between your"
      echo "local .env files and the vault."
      echo ""
      echo "• Color-coded diff (red/green)"
      echo "• Shows new, modified, and missing files"
      ;;
    list)
      echo -e "${G}☰${R}  Browse vault"
      echo ""
      echo "Browse all projects stored in the vault"
      echo "and select one to manage."
      echo ""
      echo "• Pull, diff, or remove projects"
      echo "• Preview encrypted file list"
      ;;
    clean)
      echo -e "${G}✕${R}  Clean"
      echo ""
      echo "Select a project to permanently remove"
      echo "from the vault."
      echo ""
      echo "• Confirmation required"
      echo "• Commits and pushes the change"
      ;;
    config)
      echo -e "${D}⚙${R}  Config"
      echo ""
      echo "View and edit envoy settings."
      echo ""
      echo "• Vault path"
      echo "• Age key path"
      echo "• Projects directory"
      echo "• GitHub repo"
      ;;
    rotate)
      echo -e "${D}⟳${R}  Rotate key"
      echo ""
      echo "Generate a new age key and re-encrypt"
      echo "all files in the vault."
      echo ""
      echo "• Decrypts everything with old key"
      echo "• Generates new key"
      echo "• Re-encrypts and pushes"
      echo "• ${B}Save the new key in your password manager${R}"
      ;;
  esac
}

_menu_list() {
  local entries=()
  for dir in "$ENVOY_VAULT"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    [[ "$name" == ".git" ]] && continue
    local count
    count=$(find_age_files "$dir" | wc -l)
    entries+=("${name}     │ ${C_DIM}${count} file(s)${C_RESET}")
  done

  if [[ ${#entries[@]} -eq 0 ]]; then
    ui_warn "Vault is empty"
    return 0
  fi

  local ev_bin="${ENVOY_BIN:-$0}"
  local header
  header="$(printf '%b' "${C_2}vault${C_RESET} │ ${C_DIM}select a project${C_RESET}")"

  local tmpfile
  tmpfile="$(mktemp)"

  printf '%s\n' "${entries[@]}" | \
    fzf \
      --ansi \
      --no-sort \
      --height=50% \
      --layout=reverse \
      --border \
      --header "$header" \
      --preview "bash '$ev_bin' _list-preview {1}" \
      --preview-window "right:50%:wrap" \
      --delimiter "│" \
      --with-nth 2.. \
    > "$tmpfile" || { rm -f "$tmpfile"; return 0; }

  local choice
  choice="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  [[ -z "$choice" ]] && return 0

  local name
  name="$(echo "$choice" | awk -F'│' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"

  _menu_vault_project "$name"
}

# List preview - called by fzf
list_preview() {
  local name="$1"
  local vault_dir="${ENVOY_VAULT:-$HOME/.env-vault}/$name"
  local G=$'\033[38;2;52;211;153m' R=$'\033[0m' B=$'\033[1m'

  echo -e "${B}${name}${R}"
  echo ""
  echo -e "${G}Encrypted files:${R}"
  if [[ -d "$vault_dir" ]]; then
    find "$vault_dir" -maxdepth 1 -name "*.age" -type f 2>/dev/null | sort | while read -r f; do
      echo "  $(basename "$f" .age)"
    done
  fi
}

_menu_vault_project() {
  local name="$1"
  local file_count
  file_count=$(find_age_files "$ENVOY_VAULT/$name" | wc -l)

  local header
  header="$(printf '%b' "${C_2}${name}${C_RESET} ${C_DIM}${file_count} file(s)${C_RESET}")"

  local ev_bin="${ENVOY_BIN:-$0}"

  local menu_items=(
    "pull  │ ${C_2}↓${C_RESET}  Pull"
    "diff  │ ${C_2}◈${C_RESET}  Diff"
    "clean │ ${C_1}✕${C_RESET}  Remove from vault"
  )

  local tmpfile
  tmpfile="$(mktemp)"

  printf '%s\n' "${menu_items[@]}" \
  | fzf \
    --ansi \
    --no-sort \
    --height=30% \
    --layout=reverse \
    --border \
    --header "$header" \
    --preview "bash '$ev_bin' _hub-preview {1} '$name'" \
    --preview-window "right:50%:wrap" \
    --delimiter "│" \
    --with-nth 2.. \
  > "$tmpfile" || { rm -f "$tmpfile"; return 0; }

  local choice
  choice="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  local cmd
  cmd="$(echo "$choice" | awk -F'│' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"

  case "$cmd" in
    pull) cmd_pull "$name" ;;
    diff) cmd_diff "$name" ;;
    clean)
      if ui_confirm "Remove $name from the vault?"; then
        rm -rf "$ENVOY_VAULT/$name"
        git -C "$ENVOY_VAULT" add -A
        git -C "$ENVOY_VAULT" commit -m "clean: remove $name" -q 2>/dev/null
        git -C "$ENVOY_VAULT" push -q 2>/dev/null
        ui_success "Removed $name from vault"
      fi
      ;;
  esac
}
