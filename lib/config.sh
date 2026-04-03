#!/usr/bin/env bash
# lib/config.sh - Configuration management

ENVOY_RC="$HOME/.envoyrc"

# Defaults
ENVOY_VAULT="${ENVOY_VAULT:-$HOME/.env-vault}"
ENVOY_KEY="${ENVOY_KEY:-$HOME/.age/key.txt}"
ENVOY_PROJECTS="${ENVOY_PROJECTS:-$HOME/projects}"
ENVOY_REPO="${ENVOY_REPO:-}"

load_config() {
  if [[ -f "$ENVOY_RC" ]]; then
    source "$ENVOY_RC"
  fi
}

save_config() {
  cat > "$ENVOY_RC" <<EOF
ENVOY_VAULT="$ENVOY_VAULT"
ENVOY_KEY="$ENVOY_KEY"
ENVOY_PROJECTS="$ENVOY_PROJECTS"
ENVOY_REPO="$ENVOY_REPO"
EOF
}

cmd_config() {
  local header
  header=$(printf '%b' "${C_2}config${C_RESET}  ${C_DIM}${ENVOY_RC}${C_RESET}")

  local entries="ENVOY_VAULT|${ENVOY_VAULT}|Path to the vault directory (git repo with encrypted .env files)
ENVOY_KEY|${ENVOY_KEY}|Path to your age private key (used to encrypt/decrypt)
ENVOY_PROJECTS|${ENVOY_PROJECTS}|Path to your projects directory
ENVOY_REPO|${ENVOY_REPO}|GitHub repo for the vault (user/name)"

  local selected
  selected=$(echo "$entries" | \
    fzf --height=30% \
        --layout=reverse \
        --border \
        --ansi \
        --header="$header" \
        --delimiter='|' \
        --with-nth='1,2' \
        --preview='
          line={};
          key=$(echo "$line" | cut -d"|" -f1);
          val=$(echo "$line" | cut -d"|" -f2);
          desc=$(echo "$line" | cut -d"|" -f3);
          printf "\033[1m%s\033[0m\n\n" "$key";
          printf "\033[38;2;52;211;153mCurrent:\033[0m %s\n\n" "$val";
          printf "%s\n" "$desc"
        ' \
        --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return 0

  local key
  key=$(echo "$selected" | cut -d'|' -f1)
  local current
  current=$(echo "$selected" | cut -d'|' -f2)

  local new_value
  new_value=$(gum input --prompt="$key: " --value="$current") || return 0

  case "$key" in
    ENVOY_VAULT)    ENVOY_VAULT="$new_value" ;;
    ENVOY_KEY)      ENVOY_KEY="$new_value" ;;
    ENVOY_PROJECTS) ENVOY_PROJECTS="$new_value" ;;
    ENVOY_REPO)     ENVOY_REPO="$new_value" ;;
  esac

  save_config
  ui_success "Config saved"
}
