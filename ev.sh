#!/usr/bin/env bash
# =============================================================================
# envora - keep the untracked .env files of all your projects in an encrypted
# git vault, and send them to Vercel / Cloudflare.
#
#   PROJECT  ── save → ──  VAULT  ── sync ↔ ──  GitHub
#            ── ← restore ─        ── export → / ← import ──  PLATFORMS
# =============================================================================

VERSION="1.0.0"
ENVORA_CMDLINE="ev $*"

set -euo pipefail

# Resolve the real script location through symlinks (BSD readlink has no -f).
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
ENVORA_SELF="$SCRIPT_DIR/$(basename "$_src")"
unset _src _dir
LIB_DIR="${ENVORA_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=lib/ui.sh
. "$LIB_DIR/ui.sh"
# shellcheck source=lib/util.sh
. "$LIB_DIR/util.sh"
# shellcheck source=lib/config.sh
. "$LIB_DIR/config.sh"
# shellcheck source=lib/crypto.sh
. "$LIB_DIR/crypto.sh"
# shellcheck source=lib/project.sh
. "$LIB_DIR/project.sh"
# shellcheck source=lib/vault.sh
. "$LIB_DIR/vault.sh"
# shellcheck source=lib/commands.sh
. "$LIB_DIR/commands.sh"
# shellcheck source=lib/rotate.sh
. "$LIB_DIR/rotate.sh"
# shellcheck source=lib/doctor.sh
. "$LIB_DIR/doctor.sh"
# shellcheck source=lib/init.sh
. "$LIB_DIR/init.sh"
# shellcheck source=lib/providers/common.sh
. "$LIB_DIR/providers/common.sh"
# shellcheck source=lib/providers/vercel.sh
. "$LIB_DIR/providers/vercel.sh"
# shellcheck source=lib/providers/cloudflare.sh
. "$LIB_DIR/providers/cloudflare.sh"
# shellcheck source=lib/help.sh
. "$LIB_DIR/help.sh"
# shellcheck source=lib/menu.sh
. "$LIB_DIR/menu.sh"

# --- global flags (accepted anywhere) ----------------------------------------
ASSUME_YES=0
QUIET=0
NO_SYNC="${ENVORA_NO_SYNC:-0}"
ARG_C=""
ARG_AS=""
ARG_FORCE=0
ARG_VALUES=0
WANT_HELP=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -q|--quiet) QUIET=1 ;;
    --no-sync) NO_SYNC=1 ;;
    -C)
      if [[ $# -lt 2 ]]; then
        printf 'ev: error: -C needs a directory\n' >&2
        exit 1
      fi
      ARG_C="$2"
      shift
      ;;
    -C?*) ARG_C="${1#-C}" ;;
    -h|--help) WANT_HELP=1 ;;
    -v|--version)
      printf 'ev %s\n' "$VERSION"
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do ARGS[${#ARGS[@]}]="$1"; shift; done
      break
      ;;
    *) ARGS[${#ARGS[@]}]="$1" ;;
  esac
  shift
done

ui_init_colors
ev_setup_tmp
load_config
export ENVORA_BASH="$BASH" ENVORA_SELF

set -- ${ARGS[@]+"${ARGS[@]}"}
CMD="${1:-}"
[[ $# -gt 0 ]] && shift

# --- deprecated names (kept for one version) ---------------------------------
deprecated() {
  printf 'ev: "%s" is deprecated, use "%s"%s\n' "$1" "$2" "${3:-}" >&2
}

case "$CMD" in
  push)
    deprecated push save " (Vercel snapshots: ev import vercel)"
    CMD=save
    ;;
  push-local) deprecated push-local save; CMD=save ;;
  pull) deprecated pull restore; CMD=restore ;;
  diff) deprecated diff status; CMD=status ;;
  clean) deprecated clean forget; CMD=forget ;;
  push-vercel|vercel)
    deprecated "$CMD" "import vercel"
    CMD=import
    set -- vercel "$@"
    ;;
esac

if [[ $WANT_HELP == 1 ]]; then
  show_help "${CMD:-}" "${1:-}"
  exit 0
fi

# --- internal entry points (fzf previews) ------------------------------------
case "$CMD" in
  _preview)
    NO_SYNC=1
    QUIET=0
    menu_preview "$@" || true
    exit 0
    ;;
esac

# --- setup gate: init first when needed, then the original command ------------
needs_setup() {
  case "$CMD" in
    help|config|init|doctor) return 1 ;;
  esac
  vault_exists && key_exists && return 1
  return 0
}

if needs_setup; then
  if is_interactive; then
    ui_logo
    say "envora is not set up on this machine yet. Let's do it first."
    say ""
    run_init || exit 1
    say ""
    [[ -z "$CMD" ]] || say "now running: ev $CMD $*"
  else
    if ! vault_exists; then
      err "envora is not set up: no vault at $ENVORA_VAULT (run 'ev init')"
    else
      err "envora is not set up: no key at $ENVORA_KEY (run 'ev init')"
    fi
    exit 1
  fi
fi

case "$CMD" in
  "")
    if is_interactive && has fzf && fzf_recent; then
      cmd_menu
    else
      if is_interactive && has fzf; then
        warn "the menu needs fzf $FZF_MIN or newer (you have $(fzf_version)): upgrade fzf; here is the help"
      fi
      show_help ""
    fi
    ;;
  save) cmd_save "$@" ;;
  restore) cmd_restore "$@" ;;
  status) cmd_status "$@" ;;
  list) cmd_list "$@" ;;
  import) cmd_import "$@" ;;
  export) cmd_export "$@" ;;
  sync) cmd_sync "$@" ;;
  forget) cmd_forget "$@" ;;
  rotate) cmd_rotate "$@" ;;
  doctor) cmd_doctor "$@" ;;
  init) run_init "$@" ;;
  config) cmd_config "$@" ;;
  help) show_help "${1:-}" "${2:-}" ;;
  *)
    err "unknown command: $CMD"
    say "  run 'ev help' to see the commands"
    exit 1
    ;;
esac
exit 0
