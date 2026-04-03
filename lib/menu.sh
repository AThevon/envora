#!/usr/bin/env bash
# lib/menu.sh - Interactive fzf menus with preview panels

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

  local header
  header=$(printf '%b' "${C_2}${name}${C_RESET}  ${C_DIM}${vault_status}${C_RESET}")
  local footer="Enter select"

  local actions="push|Push all .env files (local + Vercel)|Pushes local .env files and, if a Vercel project is detected, offers to pull and save Vercel envs too.
push-local|Push local .env files only|Encrypts .env* files from your project and saves them to the vault.
push-vercel|Push Vercel env vars only|Downloads development, preview, and production env vars from Vercel, encrypts and saves to vault.
pull|Restore .env files from the vault|Decrypts .env files from the vault and copies them into your project.
diff|Compare local vs vault|Shows line-by-line differences between your local .env files and what's in the vault.
---|──────────────|
list|All projects in vault|Browse all projects stored in the vault.
clean|Remove a project from vault|Select a project to permanently remove from the vault (with confirmation).
config|View and edit settings|Modify vault path, key path, projects directory, and repo settings.
rotate|Generate new age key|Creates a new age key, re-encrypts all vault files, and displays the new key to save."

  local selected
  selected=$(echo "$actions" | \
    fzf --height=60% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --footer="$footer" \
        --delimiter='|' \
        --with-nth=1 \
        --preview='
          line={};
          desc=$(echo "$line" | cut -d"|" -f2);
          detail=$(echo "$line" | cut -d"|" -f3);
          printf "\033[1m%s\033[0m\n\n%s\n" "$desc" "$detail"
        ' \
        --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return 0

  local cmd
  cmd=$(echo "$selected" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

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
  local header
  header=$(printf '%b' "${C_2}envoy${C_RESET}  ${C_DIM}encrypted .env vault${C_RESET}")

  local actions="list|All projects in vault|Browse all projects stored in the vault and select one to manage.
clean|Remove a project from vault|Select a project to permanently remove from the vault (with confirmation).
config|View and edit settings|Modify vault path, key path, projects directory, and repo settings.
rotate|Generate new age key|Creates a new age key, re-encrypts all vault files, and displays the new key to save."

  local selected
  selected=$(echo "$actions" | \
    fzf --height=40% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --delimiter='|' \
        --with-nth=1 \
        --preview='
          line={};
          desc=$(echo "$line" | cut -d"|" -f2);
          detail=$(echo "$line" | cut -d"|" -f3);
          printf "\033[1m%s\033[0m\n\n%s\n" "$desc" "$detail"
        ' \
        --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return 0

  local cmd
  cmd=$(echo "$selected" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  case "$cmd" in
    list)    _menu_list ;;
    clean)   cmd_clean ;;
    config)  cmd_config ;;
    rotate)  cmd_rotate ;;
  esac
}

_menu_list() {
  local entries=()
  for dir in "$ENVOY_VAULT"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    [[ "$name" == ".git" ]] && continue
    local files
    files=$(find_age_files "$dir" | xargs -I{} basename {} .age 2>/dev/null | tr '\n' ' ')
    entries+=("${name}|${files}")
  done

  if [[ ${#entries[@]} -eq 0 ]]; then
    ui_warn "Vault is empty"
    return 0
  fi

  local header
  header=$(printf '%b' "${C_2}vault${C_RESET}  ${C_DIM}select a project${C_RESET}")

  local selected
  selected=$(printf '%s\n' "${entries[@]}" | \
    fzf --height=50% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --delimiter='|' \
        --with-nth=1 \
        --preview='
          name=$(echo {} | cut -d"|" -f1);
          files=$(echo {} | cut -d"|" -f2);
          printf "\033[1m%s\033[0m\n\n" "$name";
          printf "\033[38;2;52;211;153mFiles:\033[0m\n";
          for f in $files; do
            printf "  %s\n" "$f";
          done
        ' \
        --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return 0

  local name
  name=$(echo "$selected" | cut -d'|' -f1)

  # Show actions for this project
  _menu_vault_project "$name"
}

_menu_vault_project() {
  local name="$1"
  local file_count
  file_count=$(find_age_files "$ENVOY_VAULT/$name" | wc -l)

  local header
  header=$(printf '%b' "${C_2}${name}${C_RESET}  ${C_DIM}${file_count} file(s)${C_RESET}")

  local actions="pull|Restore .env files|Decrypts and copies .env files into ~/projects/${name}
diff|Compare with local|Shows line-by-line differences between local and vault versions.
clean|Remove from vault|Permanently deletes ${name} from the vault (with confirmation)."

  local selected
  selected=$(echo "$actions" | \
    fzf --height=30% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --delimiter='|' \
        --with-nth=1 \
        --preview='
          line={};
          desc=$(echo "$line" | cut -d"|" -f2);
          detail=$(echo "$line" | cut -d"|" -f3);
          printf "\033[1m%s\033[0m\n\n%s\n" "$desc" "$detail"
        ' \
        --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return 0

  local cmd
  cmd=$(echo "$selected" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  case "$cmd" in
    pull)   cmd_pull "$name" ;;
    diff)   cmd_diff "$name" ;;
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
