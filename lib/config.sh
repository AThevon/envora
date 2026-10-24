#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/config.sh - settings: defaults < ~/.envorarc < ENVORA_* environment
#
# The rc file is parsed as KEY=VALUE lines, never sourced. Only known keys are
# read. "ev config set" writes back only what the file already had plus the
# setting being changed (never values that came from the environment or from
# the defaults), each value single-quoted.

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

# A command setting: a leading ~ in its first word is expanded (it is never
# run through a shell, so nothing else would expand it).
expand_cmd() {
  local v="$1" first rest=""
  first="${v%% *}"
  [[ "$v" == *" "* ]] && rest=" ${v#* }"
  printf '%s%s' "$(expand_path "$first")" "$rest"
}

# Read a value the way a shell would read a word: '...' literal, "..." with
# \" \\ \$ \` escapes, backslash escapes outside quotes, pieces glued
# together, a " # comment" after the value ignored. Nothing is ever executed.
# Returns 1 for what it does not understand ($'...', open quote).
config_unquote() {
  local v="$1" res="" c nxt i=0 n state=none
  case "$v" in \$\'*) return 1 ;; esac
  n=${#v}
  while [[ $i -lt $n ]]; do
    c="${v:$i:1}"
    case "$state" in
      none)
        if [[ "$c" == " " || "$c" == $'\t' ]]; then
          # Outside quotes, blanks before a # start a comment (as in a shell);
          # trailing blanks are dropped; other blanks are kept as written.
          local rest="${v:$i}"
          rest="${rest#"${rest%%[![:space:]]*}"}"
          if [[ -z "$rest" || "$rest" == \#* ]]; then
            break
          fi
          res="$res$c"
        elif [[ "$c" == "'" ]]; then
          state=single
        elif [[ "$c" == '"' ]]; then
          state=double
        elif [[ "$c" == "\\" ]]; then
          i=$((i + 1))
          res="$res${v:$i:1}"
        else
          res="$res$c"
        fi
        ;;
      single)
        if [[ "$c" == "'" ]]; then state=none; else res="$res$c"; fi
        ;;
      double)
        if [[ "$c" == '"' ]]; then
          state=none
        elif [[ "$c" == "\\" ]]; then
          nxt="${v:$((i + 1)):1}"
          case "$nxt" in
            '"'|"\\"|'$'|'`') res="$res$nxt"; i=$((i + 1)) ;;
            *) res="$res$c" ;;
          esac
        else
          res="$res$c"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  [[ "$state" == none ]] || return 1
  printf '%s' "$res"
}

# 'value' with ' written as '\''
config_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

config_rc_label() {
  tildify "$(config_rc_path)"
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
    eval "_RC_HAS_$k=''"
    eval "_RC_$k=''"
  done

  local rc line key val n=0
  rc="$(config_rc_path)"
  if [[ -f "$rc" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      line="${line#export }"
      [[ "$line" == *=* ]] || continue
      # KEY = value is read like KEY=value
      key="${line%%=*}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if ! config_is_known "$key"; then
        case "$key" in
          ENVORA_*) warn "$(config_rc_label) line $n: unknown setting $key: ignored (known: $CONFIG_KEYS)" ;;
        esac
        continue
      fi
      if ! val="$(config_unquote "$val")"; then
        warn "$(config_rc_label): cannot read $key (unsupported quoting): ignored. Set it again: ev config set $key <value>"
        continue
      fi
      # What the file says, kept apart: "ev config set" writes only this back.
      printf -v "_RC_$key" '%s' "$val"
      eval "_RC_HAS_$key=1"
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

# Mark a setting to be written by the next save_config, with its current value.
config_mark() {
  local k="$1" v
  config_is_known "$k" || return 1
  eval "v=\${$k:-}"
  printf -v "_RC_$k" '%s' "$v"
  eval "_RC_HAS_$k=1"
}

save_config() {
  local rc k v has tmp
  rc="$(config_rc_path)"
  tmp="$(mktemp "$rc.envora-XXXXXX")" || return 1
  {
    printf '# envora settings (edit with: ev config)\n'
    for k in $CONFIG_KEYS; do
      eval "has=\${_RC_HAS_$k:-}"
      [[ -n "$has" ]] || continue
      eval "v=\${_RC_$k:-}"
      [[ -z "$v" ]] && continue
      printf '%s=%s\n' "$k" "$(config_quote "$v")"
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
  if [[ "$val" == *[[:cntrl:]]* ]]; then
    err "values cannot contain a newline, a tab or other control characters"
    return 1
  fi
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
    ENVORA_VERCEL_CMD|ENVORA_WRANGLER_CMD)
      case "$val" in
        *\"*|*\'*|*\\*)
          err "$var: quotes and backslashes are not supported (words are split on spaces)"
          say "  put the command in a small script and point the setting at it"
          return 1
          ;;
      esac
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
    ENVORA_VERCEL_CMD|ENVORA_WRANGLER_CMD) val="$(expand_cmd "$val")" ;;
  esac
  config_validate "$var" "$val" || return 1
  printf -v "$var" '%s' "$val"
  config_mark "$var"
  save_config || { err "cannot write $(config_rc_path)"; return 1; }
  ok "$var = $val  ${C_DIM}(saved in $(tildify "$(config_rc_path)"))${C_RST}"
  if [[ -n "$(eval "printf '%s' \"\${_ENV_SET_$var:-}\"")" ]]; then
    warn "$var is also set in your environment: that value wins while it is set"
  fi
  case "$var" in
    ENVORA_VERCEL_CMD|ENVORA_WRANGLER_CMD)
      local first="${val%% *}"
      if [[ -n "$first" ]] && ! has "$first"; then
        warn "$first is not an executable command here (not on PATH): check the setting"
      fi
      ;;
    ENVORA_REPO)
      local url=""
      vault_exists && url="$(vgit remote get-url origin 2>/dev/null || true)"
      if [[ -n "$url" ]]; then
        warn "ENVORA_REPO is only used by ev init: this vault syncs with $(sanitize_origin "$url")"
        say "  to move the vault to another repo: git -C $(tildify "$ENVORA_VAULT") remote set-url origin <url>"
      fi
      ;;
  esac
}

config_describe() {
  case "$1" in
    ENVORA_VAULT) echo "Vault: the local git repo holding the encrypted copies" ;;
    ENVORA_KEY) echo "Key: your age private key (keep a copy in a password manager)" ;;
    ENVORA_PROJECTS) echo "Projects: where 'ev restore NAME' looks for NAME" ;;
    ENVORA_REPO) echo "GitHub repo used by ev init to clone or create the vault (the vault then syncs with its own git remote)" ;;
    ENVORA_VERCEL_CMD) echo "Command used for Vercel (default: vercel, else npx); words split on spaces, no quotes" ;;
    ENVORA_WRANGLER_CMD) echo "Command used for Cloudflare (default: wrangler, else npx); words split on spaces, no quotes" ;;
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
      [[ -n "${2:-}" ]] || { err "usage: ev config get <setting>  (vault, key, projects, repo, vercel-cmd, wrangler-cmd)"; return 1; }
      var="$(config_var_name "$2")" || { err "unknown setting: $2 (vault, key, projects, repo, vercel-cmd, wrangler-cmd)"; return 1; }
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
