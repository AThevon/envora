#!/usr/bin/env bash

# =============================================================================
# envoy - Encrypted .env vault manager
# =============================================================================
# Manages .env files across projects with age encryption and git-backed storage.
# All UI messages go to stderr, only paths/data go to stdout.
# =============================================================================

VERSION="0.1.0"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${ENVOY_LIB:-$SCRIPT_DIR/lib}"
ENVOY_BIN="${BASH_SOURCE[0]}"

# Load libs
for lib in ui config vault crypto provider menu; do
  source "$LIB_DIR/${lib}.sh"
done

# =============================================================================
# CLI options
# =============================================================================

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
  echo "ev $VERSION" >&2
  exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
  show_help
  exit 0
fi

# =============================================================================
# Internal commands (called by fzf preview, skip init check)
# =============================================================================

case "${1:-}" in
  _hub-preview)  load_config; shift; hub_preview "$@"; exit 0 ;;
  _list-preview) load_config; shift; list_preview "$@"; exit 0 ;;
esac

# =============================================================================
# Init check
# =============================================================================

load_config

if ! vault_exists; then
  ui_header
  msg "Vault not found. Let's set it up."
  echo ""
  run_init
  exit 0
fi

# =============================================================================
# Command dispatch
# =============================================================================

case "${1:-}" in
  init)         run_init ;;
  push)         cmd_push "${2:-}" ;;
  push-local)   cmd_push_local "${2:-}" ;;
  push-vercel)  cmd_push_vercel "${2:-}" ;;
  pull)         cmd_pull "${2:-}" ;;
  diff)         cmd_diff "${2:-}" ;;
  list)         cmd_list ;;
  rotate)       cmd_rotate ;;
  config)       cmd_config ;;
  clean)        cmd_clean ;;
  "")           cmd_interactive ;;
  *)
    ui_error "Unknown command: $1"
    msg "Run 'ev help' for usage"
    exit 1
    ;;
esac
