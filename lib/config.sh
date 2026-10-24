#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/config.sh - settings: defaults < ~/.envorarc < ENVORA_* environment
#
# The rc file is parsed as KEY=VALUE lines, never sourced. Only known keys are
# read. Values are written back escaped with printf %q.

CONFIG_KEYS="ENVORA_VAULT ENVORA_KEY ENVORA_PROJECTS ENVORA_REPO ENVORA_VERCEL_CMD ENVORA_WRANGLER_CMD"

config_rc_path() {
  printf '%s' "${ENVORA_RC:-$HOME/.envorarc}"
}

# Expand a leading ~ or $HOME / ${HOME}.
expand_path() {
  local v="$1"
  case "$v" in
    "~") v="$HOME" ;;
    \~/*) v="$HOME/${v#\~/}" ;;
    '$HOME') v="$HOME" ;;
    '$HOME/'*) v="$HOME/${v#\$HOME/}" ;;
    '${HOME}') v="$HOME" ;;
    '${HOME}/'*) v="$HOME/${v#\$\{HOME\}/}" ;;
  esac
  printf '%s' "$v"
}

# Undo the quoting forms we accept: "..." '...' and backslash escapes (%q).
config_unquote() {
  local v="$1"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"; return 0 ;;
    \$\'*) return 1 ;;
  esac
  local res="" c i n=${#v}
  i=0
  while [[ $i -lt $n ]]; do
    c="${v:$i:1}"
    if [[ "$c" == "\\" && $((i + 1)) -lt $n ]]; then
      i=$((i + 1))
      c="${v:$i:1}"
    fi
    res="$res$c"
    i=$((i + 1))
  done
  printf '%s' "$res"
}

config_is_known() {
  local k
  for k in $CONFIG_KEYS; do
    [[ "$k" == "$1" ]] && return 0
  done
  return 1
}

load_config() {
  # Remember what the environment set: it wins over the rc file.
  local k
  for k in $CONFIG_KEYS; do
    eval "_ENV_SET_$k=\${$k+x}"
  done

  local rc line key val
  rc="$(config_rc_path)"
  if [[ -f "$rc" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      line="${line#export }"
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      config_is_known "$key" || continue
      val="$(config_unquote "$val")" || continue
      if [[ -z "$(eval "printf '%s' \"\${_ENV_SET_$key}\"")" ]]; then
        printf -v "$key" '%s' "$val"
      fi
    done <"$rc"
  fi

  ENVORA_VAULT="$(expand_path "${ENVORA_VAULT:-$HOME/.env-vault}")"
  ENVORA_KEY="$(expand_path "${ENVORA_KEY:-$HOME/.age/key.txt}")"
  ENVORA_PROJECTS="$(expand_path "${ENVORA_PROJECTS:-$HOME/projects}")"
  ENVORA_REPO="${ENVORA_REPO:-}"
  ENVORA_VERCEL_CMD="${ENVORA_VERCEL_CMD:-}"
  ENVORA_WRANGLER_CMD="${ENVORA_WRANGLER_CMD:-}"
  ENVORA_STATE="$(expand_path "${XDG_STATE_HOME:-$HOME/.local/state}")/envora"
}

save_config() {
  local rc k v tmp
  rc="$(config_rc_path)"
  tmp="$(mktemp "$rc.envora-XXXXXX")" || return 1
  {
    printf '# envora settings (edit with: ev config)\n'
    for k in ENVORA_VAULT ENVORA_KEY ENVORA_PROJECTS ENVORA_REPO ENVORA_VERCEL_CMD ENVORA_WRANGLER_CMD; do
      eval "v=\${$k:-}"
      [[ -z "$v" ]] && continue
      printf '%s=%q\n' "$k" "$v"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$rc"
}

# Map short names (vault, key...) to variable names.
config_var_name() {
  case "$1" in
    vault|ENVORA_VAULT) echo ENVORA_VAULT ;;
    key|ENVORA_KEY) echo ENVORA_KEY ;;
    projects|ENVORA_PROJECTS) echo ENVORA_PROJECTS ;;
    repo|ENVORA_REPO) echo ENVORA_REPO ;;
    vercel-cmd|ENVORA_VERCEL_CMD) echo ENVORA_VERCEL_CMD ;;
    wrangler-cmd|ENVORA_WRANGLER_CMD) echo ENVORA_WRANGLER_CMD ;;
    *) return 1 ;;
  esac
}

config_validate() {
  local var="$1" val="$2"
  case "$val" in
    *$'\n'*) err "values cannot contain a newline"; return 1 ;;
  esac
  case "$var" in
    ENVORA_VAULT|ENVORA_KEY|ENVORA_PROJECTS)
      [[ -n "$val" ]] || { err "$var cannot be empty"; return 1; }
      case "$val" in
        /*) ;;
        *) err "$var must be an absolute path (or start with ~)"; return 1 ;;
      esac
      ;;
    ENVORA_REPO)
      local re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
      if [[ -n "$val" && ! "$val" =~ $re && "$val" != *:* && "$val" != /* ]]; then
        err "ENVORA_REPO must look like user/name (or a git URL)"
        return 1
      fi
      ;;
  esac
  return 0
}

config_set() {
  local var val
  var="$(config_var_name "$1")" || { err "unknown setting: $1 (vault, key, projects, repo, vercel-cmd, wrangler-cmd)"; return 1; }
  val="$2"
  case "$var" in
    ENVORA_VAULT|ENVORA_KEY|ENVORA_PROJECTS) val="$(expand_path "$val")" ;;
  esac
  config_validate "$var" "$val" || return 1
  printf -v "$var" '%s' "$val"
  save_config || { err "cannot write $(config_rc_path)"; return 1; }
  ok "$var = $val"
}

config_describe() {
  case "$1" in
    ENVORA_VAULT) echo "Vault: the local git repo holding the encrypted copies" ;;
    ENVORA_KEY) echo "Key: your age private key (keep a copy in a password manager)" ;;
    ENVORA_PROJECTS) echo "Projects: where 'ev restore NAME' looks for NAME" ;;
    ENVORA_REPO) echo "GitHub repo of the vault (user/name)" ;;
    ENVORA_VERCEL_CMD) echo "Command used for Vercel (default: vercel, else npx)" ;;
    ENVORA_WRANGLER_CMD) echo "Command used for Cloudflare (default: wrangler, else npx)" ;;
  esac
}

config_print() {
  local k v
  out "${C_BOLD}settings${C_RST} ${C_DIM}$(config_rc_path)${C_RST}"
  for k in $CONFIG_KEYS; do
    eval "v=\${$k:-}"
    out "  $(printf '%-20s' "$k") ${v:-${C_DIM}(not set)${C_RST}}"
    out "  $(printf '%-20s' '') ${C_DIM}$(config_describe "$k")${C_RST}"
  done
}

cmd_config() {
  local sub="${1:-}"
  case "$sub" in
    "")
      if is_interactive && has fzf; then
        config_menu
      else
        config_print
      fi
      ;;
    get)
      local var
      var="$(config_var_name "${2:-}")" || { err "unknown setting: ${2:-}"; return 1; }
      eval "out \"\${$var:-}\""
      ;;
    set)
      [[ $# -ge 3 ]] || { err "usage: ev config set <setting> <value>"; return 1; }
      config_set "$2" "$3"
      ;;
    *)
      err "usage: ev config [get <setting> | set <setting> <value>]"
      return 1
      ;;
  esac
}

config_menu() {
  local choice var cur new
  while true; do
    choice="$(
      for var in ENVORA_VAULT ENVORA_KEY ENVORA_PROJECTS ENVORA_REPO ENVORA_VERCEL_CMD ENVORA_WRANGLER_CMD; do
        eval "cur=\${$var:-}"
        printf '%s\t%-18s %s\n' "$var" "${var#ENVORA_}" "${cur:-(not set)}"
      done | fzf --ansi --height=~40% --layout=reverse --border=rounded \
        --border-label=" settings " --delimiter=$'\t' --with-nth=2 \
        --no-input --header="enter edit · esc back" \
        --color="$FZF_COLORS" \
        --preview='"$ENVORA_BASH" "$ENVORA_SELF" _preview config {1}' \
        --preview-window='right,50%,wrap'
    )" || return 0
    var="${choice%%$'\t'*}"
    eval "cur=\${$var:-}"
    new="$(ask "$var:" "$cur")" || continue
    [[ "$new" == "$cur" ]] && continue
    config_set "$var" "$new" || true
  done
}

config_preview() {
  local var="$1" v
  eval "v=\${$var:-}"
  out "${C_BOLD}${var}${C_RST}"
  out ""
  out "$(config_describe "$var")"
  out ""
  out "current: ${v:-(not set)}"
  out ""
  out "${C_DIM}stored in $(config_rc_path)${C_RST}"
  out "${C_DIM}an ENVORA_* environment variable overrides the file${C_RST}"
}
