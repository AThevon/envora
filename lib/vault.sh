#!/usr/bin/env bash
# lib/vault.sh - Vault operations (push, pull, diff, list, clean, init)

vault_exists() {
  [[ -d "$ENVOY_VAULT/.git" ]]
}

# Detect current project name from git repo
detect_project() {
  local dir="${1:-$PWD}"
  if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
    local root
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
    basename "$root"
  fi
}

# Resolve project name: explicit arg, detected from git, or fail
resolve_project() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(detect_project)
  fi
  if [[ -z "$name" ]]; then
    ui_error "Not in a git repo. Specify a project name: ev <command> <project>"
    return 1
  fi
  echo "$name"
}

# Resolve project source dir
resolve_source() {
  local name="$1"
  local dir="$ENVOY_PROJECTS/$name"
  if [[ "$PWD" == *"/$name"* ]]; then
    # We're inside the project
    git rev-parse --show-toplevel 2>/dev/null || echo "$dir"
  else
    echo "$dir"
  fi
}

run_init() {
  msg "${C_BOLD}Setting up envoy vault${C_RESET}"
  msg ""

  # 1. Age key
  if [[ -f "$ENVOY_KEY" ]]; then
    msg "Age key found at ${C_2}$ENVOY_KEY${C_RESET}"
  else
    msg "Generating age key..."
    mkdir -p "$(dirname "$ENVOY_KEY")"
    age-keygen -o "$ENVOY_KEY" 2>&1 >&2
    chmod 600 "$ENVOY_KEY"
    msg ""
    msg "${C_BOLD}Save this key in your password manager:${C_RESET}"
    msg ""
    cat "$ENVOY_KEY" >&2
    msg ""
    if ! ui_confirm "Key saved? Continue?"; then
      return 1
    fi
  fi

  # 2. Vault repo
  if vault_exists; then
    msg "Vault found at ${C_2}$ENVOY_VAULT${C_RESET}"
  else
    msg ""
    local choice
    choice=$(printf "Create new private repo\nLink existing repo" | gum filter --prompt="Vault repo > " --height=5) || return 1

    if [[ "$choice" == "Create new private repo" ]]; then
      local repo_name
      repo_name=$(gum input --prompt="Repo name: " --value="env-vault") || return 1
      msg "Creating private repo..."
      ENVOY_REPO=$(gh repo create "$repo_name" --private --description "Encrypted env vault managed by envoy" --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
      if [[ -z "$ENVOY_REPO" ]]; then
        ui_error "Failed to create repo. Check gh auth."
        return 1
      fi
      git clone "git@github.com:$ENVOY_REPO.git" "$ENVOY_VAULT" 2>/dev/null
      ui_success "Created and cloned $ENVOY_REPO"
    else
      ENVOY_REPO=$(gum input --prompt="GitHub repo (user/name): ") || return 1
      git clone "git@github.com:$ENVOY_REPO.git" "$ENVOY_VAULT" 2>/dev/null
      ui_success "Cloned $ENVOY_REPO"
    fi
  fi

  # 3. Save config
  save_config
  msg ""
  ui_success "Vault ready at $ENVOY_VAULT"
}

# Push everything: local .env files + Vercel if detected
cmd_push() {
  local name
  name=$(resolve_project "${1:-}") || return 1
  local source
  source=$(resolve_source "$name")
  local total=0

  # 1. Push local .env files
  local local_count
  local_count=$(_push_local_files "$name" "$source")
  total=$((total + local_count))

  # 2. Detect Vercel and offer to push
  if _is_vercel_project "$source"; then
    msg ""
    msg "  ${C_2}Vercel project detected${C_RESET}"
    if ui_confirm "Also pull env vars from Vercel?"; then
      local vercel_count
      vercel_count=$(_push_vercel_files "$name" "$source")
      total=$((total + vercel_count))
    fi
  fi

  if [[ $total -eq 0 ]]; then
    ui_warn "No .env files found"
    return 1
  fi

  _vault_commit_push "push: $name ($total files)"
  ui_success "Pushed $total file(s) for $name"
}

# Push only local .env files
cmd_push_local() {
  local name
  name=$(resolve_project "${1:-}") || return 1
  local source
  source=$(resolve_source "$name")

  local count
  count=$(_push_local_files "$name" "$source")

  if [[ $count -eq 0 ]]; then
    ui_warn "No .env files found in $source"
    return 1
  fi

  _vault_commit_push "push-local: $name ($count files)"
  ui_success "Pushed $count local file(s) for $name"
}

# Push only Vercel env vars
cmd_push_vercel() {
  local name
  name=$(resolve_project "${1:-}") || return 1
  local source
  source=$(resolve_source "$name")

  local count
  count=$(_push_vercel_files "$name" "$source")

  if [[ $count -eq 0 ]]; then
    ui_warn "No env vars pulled from Vercel"
    return 1
  fi

  _vault_commit_push "push-vercel: $name ($count envs)"
  ui_success "Pushed $count Vercel env(s) for $name"
}

# --- Internal helpers ---

_is_vercel_project() {
  local source="$1"
  [[ -d "$source/.vercel" ]] || npx vercel ls --token="" 2>/dev/null | grep -q "." 2>/dev/null
  # Simple check: .vercel dir exists (linked project)
  [[ -d "$source/.vercel" ]]
}

_push_local_files() {
  local name="$1" source="$2"
  local vault_dir="$ENVOY_VAULT/$name"
  local files
  files=$(find_env_files "$source")
  [[ -z "$files" ]] && echo 0 && return

  mkdir -p "$vault_dir"
  local count=0
  while IFS= read -r f; do
    local fname
    fname=$(basename "$f")
    encrypt_file "$f" "$vault_dir/${fname}.age"
    msg "  ${C_2}+${C_RESET} $fname"
    count=$((count + 1))
  done <<< "$files"
  echo "$count"
}

_push_vercel_files() {
  local name="$1" source="$2"
  local vault_dir="$ENVOY_VAULT/$name"

  # Auto-link if needed
  if [[ ! -d "$source/.vercel" ]]; then
    msg "  Linking to Vercel..."
    (cd "$source" && npx vercel link --yes) || { echo 0; return; }
  fi

  mkdir -p "$vault_dir"
  local tmpdir
  tmpdir=$(mktemp -d)
  local count=0

  for env in development preview production; do
    local fname=".env.$env"
    msg "  Pulling $env..."
    if (cd "$source" && npx vercel env pull "$tmpdir/$fname" --environment "$env" 2>/dev/null) && [[ -f "$tmpdir/$fname" ]]; then
      encrypt_file "$tmpdir/$fname" "$vault_dir/${fname}.age"
      msg "  ${C_2}+${C_RESET} $fname"
      count=$((count + 1))
    fi
  done
  rm -rf "$tmpdir"
  echo "$count"
}

_vault_commit_push() {
  local message="$1"
  git -C "$ENVOY_VAULT" add -f -A
  git -C "$ENVOY_VAULT" commit -m "$message" -q 2>/dev/null
  git -C "$ENVOY_VAULT" push -q 2>/dev/null
}

cmd_pull() {
  local name
  name=$(resolve_project "${1:-}") || return 1
  local dest
  dest=$(resolve_source "$name")
  local vault_dir="$ENVOY_VAULT/$name"

  if [[ ! -d "$vault_dir" ]]; then
    ui_warn "No vault entry for $name"
    return 1
  fi

  local files
  files=$(find_age_files "$vault_dir")
  if [[ -z "$files" ]]; then
    ui_warn "No encrypted files for $name"
    return 1
  fi

  local count=0
  while IFS= read -r f; do
    local fname
    fname=$(basename "$f" .age)
    decrypt_file "$f" "$dest/$fname"
    msg "  ${C_2}+${C_RESET} $fname"
    count=$((count + 1))
  done <<< "$files"

  ui_success "Pulled $count file(s) for $name"
}

cmd_diff() {
  local name
  name=$(resolve_project "${1:-}") || return 1
  local source
  source=$(resolve_source "$name")
  local vault_dir="$ENVOY_VAULT/$name"

  if [[ ! -d "$vault_dir" ]]; then
    ui_warn "No vault entry for $name (nothing to diff)"
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local has_diff=false

  # Decrypt vault files to temp
  local age_files
  age_files=$(find_age_files "$vault_dir")
  if [[ -n "$age_files" ]]; then
    while IFS= read -r f; do
      local fname
      fname=$(basename "$f" .age)
      decrypt_file "$f" "$tmpdir/$fname" 2>/dev/null
    done <<< "$age_files"
  fi

  # Compare local vs vault
  while IFS= read -r f; do
    local fname
    fname=$(basename "$f")
    if [[ -f "$tmpdir/$fname" ]]; then
      if ! diff -q "$f" "$tmpdir/$fname" &>/dev/null; then
        msg "${C_BOLD}$fname${C_RESET} (modified)"
        diff --color=always "$tmpdir/$fname" "$f" >&2 || true
        msg ""
        has_diff=true
      fi
    else
      msg "${C_BOLD}$fname${C_RESET} ${C_2}(new - not in vault)${C_RESET}"
      has_diff=true
    fi
  done < <(find_env_files "$source")

  # Check for files in vault but not local
  if [[ -n "$age_files" ]]; then
    while IFS= read -r f; do
      local fname
      fname=$(basename "$f" .age)
      if [[ ! -f "$source/$fname" ]]; then
        msg "${C_BOLD}$fname${C_RESET} ${C_1}(in vault but missing locally)${C_RESET}"
        has_diff=true
      fi
    done <<< "$age_files"
  fi

  rm -rf "$tmpdir"

  if ! $has_diff; then
    ui_success "$name: in sync with vault"
  fi
}

cmd_list() {
  local projects=()
  for dir in "$ENVOY_VAULT"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    [[ "$name" == ".git" ]] && continue
    local files
    files=$(find_age_files "$dir" | xargs -I{} basename {} .age | tr '\n' ' ')
    projects+=("$name  ${C_DIM}$files${C_RESET}")
  done

  if [[ ${#projects[@]} -eq 0 ]]; then
    ui_warn "Vault is empty"
    return 0
  fi

  msg "${C_BOLD}Projects in vault${C_RESET}"
  msg ""
  for p in "${projects[@]}"; do
    msg "  ${C_2}*${C_RESET} $p"
  done
}

cmd_clean() {
  local entries=()
  for dir in "$ENVOY_VAULT"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    [[ "$name" == ".git" ]] && continue
    local files
    files=$(find_age_files "$dir" | xargs -I{} basename {} .age 2>/dev/null | tr '\n' ' ')
    local count
    count=$(find_age_files "$dir" | wc -l)
    entries+=("${name}|${count} file(s)|${files}")
  done

  if [[ ${#entries[@]} -eq 0 ]]; then
    ui_warn "Vault is empty"
    return 0
  fi

  local header
  header=$(printf '%b' "${C_1}clean${C_RESET}  ${C_DIM}select project to remove${C_RESET}")

  local selected
  selected=$(printf '%s\n' "${entries[@]}" | \
    fzf --height=40% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --delimiter='|' \
        --with-nth=1 \
        --preview='
          name=$(echo {} | cut -d"|" -f1);
          count=$(echo {} | cut -d"|" -f2);
          files=$(echo {} | cut -d"|" -f3);
          printf "\033[1m%s\033[0m\n%s\n\n" "$name" "$count";
          printf "\033[38;2;52;211;153mFiles:\033[0m\n";
          for f in $files; do
            printf "  %s\n" "$f";
          done;
          printf "\n\033[2mThis action is permanent.\033[0m\n"
        ' \
        --preview-window=right:50%:wrap) || return 0

  [[ -z "$selected" ]] && return 0

  local name
  name=$(echo "$selected" | cut -d'|' -f1)

  if ! ui_confirm "Remove $name from the vault?"; then
    return 0
  fi

  rm -rf "$ENVOY_VAULT/$name"
  git -C "$ENVOY_VAULT" add -A
  git -C "$ENVOY_VAULT" commit -m "clean: remove $name" -q 2>/dev/null
  git -C "$ENVOY_VAULT" push -q 2>/dev/null

  ui_success "Removed $name from vault"
}
