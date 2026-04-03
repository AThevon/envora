#!/usr/bin/env bash
# lib/ui.sh - UI functions using gum

# Emerald green gradient
C_1=$'\033[38;2;16;185;129m'   # #10B981
C_2=$'\033[38;2;52;211;153m'   # #34D399
C_3=$'\033[38;2;110;231;183m'  # #6EE7B7
C_4=$'\033[38;2;167;243;208m'  # #A7F3D0
C_5=$'\033[38;2;209;250;229m'  # #D1FAE5
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

msg() {
  echo "$@" >&2
}

ui_success() {
  gum log --level info "$@" >&2
}

ui_warn() {
  gum log --level warn "$@" >&2
}

ui_error() {
  gum log --level error "$@" >&2
}

ui_spin() {
  local title="$1"
  shift
  gum spin --spinner dot --title "$title" -- "$@"
}

ui_confirm() {
  gum confirm \
    --prompt.foreground="10" \
    --selected.background="10" \
    --selected.foreground="0" \
    "$@"
}

ui_header() {
  cat >&2 <<EOF
${C_1} ▄▄▄▄▄▄▄${C_2} ▄▄▄    ▄▄▄${C_3} ▄▄▄▄  ▄▄▄▄${C_4}   ▄▄▄▄▄${C_5}   ▄▄▄   ▄▄▄${C_RESET}
${C_1}███▀▀▀▀▀${C_2} ████▄  ███${C_3} ▀███  ███▀${C_4} ▄███████▄${C_5} ███   ███${C_RESET}
${C_1}███▄▄   ${C_2} ███▀██▄███${C_3}  ███  ███${C_4}  ███   ███${C_5} ▀███▄███▀${C_RESET}
${C_1}███     ${C_2} ███  ▀████${C_3}  ███▄▄███${C_4}  ███▄▄▄███${C_5}   ▀███▀${C_RESET}
${C_1}▀███████${C_2} ███    ███${C_3}   ▀████▀${C_4}    ▀█████▀${C_5}     ███${C_RESET}
${C_DIM}                encrypted .env vault${C_RESET}
EOF
}

show_help() {
  ui_header
  cat >&2 <<EOF

${C_BOLD}USAGE${C_RESET}
  ev                   Interactive mode (context-aware)
  ev <command>         Run a specific command

${C_BOLD}COMMANDS${C_RESET}
  ${C_2}push${C_RESET}          [project]  Push all .env files (local + Vercel if detected)
  ${C_2}push-local${C_RESET}    [project]  Push only local .env files
  ${C_2}push-vercel${C_RESET}   [project]  Push only Vercel env vars
  ${C_2}pull${C_RESET}          [project]  Decrypt and restore .env files from the vault
  ${C_2}diff${C_RESET}          [project]  Compare local .env files with the vault
  ${C_2}list${C_RESET}                     List all projects in the vault
  ${C_2}clean${C_RESET}                    Remove a project from the vault
  ${C_2}rotate${C_RESET}                   Generate new age key and re-encrypt vault
  ${C_2}config${C_RESET}                   View and edit settings
  ${C_2}init${C_RESET}                     Set up the vault (first-time setup)
  ${C_2}help${C_RESET}                     Show this help

${C_BOLD}WORKFLOW${C_RESET}
  ${C_DIM}1.${C_RESET} Run ${C_2}ev init${C_RESET} to create your encrypted vault
  ${C_DIM}2.${C_RESET} Save the age key displayed during init in your password manager
  ${C_DIM}3.${C_RESET} Use ${C_2}ev push${C_RESET} to encrypt and back up .env files
  ${C_DIM}4.${C_RESET} Use ${C_2}ev pull${C_RESET} to restore them on any machine
  ${C_DIM}5.${C_RESET} Use ${C_2}ev vercel${C_RESET} to import env vars from Vercel

${C_BOLD}INTERACTIVE MODE${C_RESET}
  Inside a git repo: shows project-specific actions first
  Outside a repo:    shows global actions (list, config, rotate)

${C_BOLD}CONFIG${C_RESET}  ~/.envoyrc
  ENVOY_VAULT    Path to vault directory     (default: ~/.env-vault)
  ENVOY_KEY      Path to age private key     (default: ~/.age/key.txt)
  ENVOY_PROJECTS Path to projects directory  (default: ~/projects)
  ENVOY_REPO     GitHub repo for the vault   (set during init)
EOF
}
