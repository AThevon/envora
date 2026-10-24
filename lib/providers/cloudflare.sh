#!/usr/bin/env bash
# lib/providers/cloudflare.sh - vault → Cloudflare (Workers and Pages secrets)
#
# Facts this module relies on (checked against wrangler 4.132.0):
#   wrangler secret list --format json [--env e]   [{"name":..,"type":"secret_text"}]
#   wrangler secret bulk [--env e]                 JSON {"k":"v"} on stdin, 100 max, deploys
#   wrangler pages secret list --project-name N [--env production|preview]
#       text: '  - NAME: Value Encrypted'
#   wrangler pages secret bulk --project-name N [--env production|preview]
# Cloudflare secrets are write-only: values cannot be read back or imported.

CF_CONFIGS="wrangler.jsonc wrangler.json wrangler.toml"
CF_BATCH=100

cloudflare_dirs() {
  # shellcheck disable=SC2086
  find_marked_dirs $CF_CONFIGS
}

cf_config_file() {
  local c
  for c in $CF_CONFIGS; do
    [[ -f "$1/$c" ]] && { printf '%s/%s' "$1" "$c"; return 0; }
  done
  return 1
}

cf_is_pages() {
  grep -q 'pages_build_output_dir' "$1" 2>/dev/null
}

# Top-level "name" of a wrangler config.
cf_name() {
  local f="$1"
  case "$f" in
    *.toml)
      awk '/^[ \t]*\[/ {exit} /^[ \t]*name[ \t]*=/ {
        sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }' "$f"
      ;;
    *)
      grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | head -n 1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
      ;;
  esac
}

# Source file in the vault for an environment (first existing).
cf_source_file() {
  local reldir="$1" env="$2" c cands
  if [[ -n "$env" ]]; then
    cands=".dev.vars.$env .dev.vars .env.$env .env"
  else
    cands=".dev.vars .env"
  fi
  for c in $cands; do
    c="$(in_dir "$reldir" "$c")"
    if [[ -f "$ENVORA_VAULT/$PROJECT_NAME/$c.age" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

cloudflare_export() {
  parse_provider_args "export cloudflare" "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient read || return 1
  resolve_project "" || return 1

  local dirs cfdir reldir cfg pages=0 name
  dirs="$(cloudflare_dirs)"
  if [[ -z "$dirs" ]]; then
    err "no wrangler.toml / wrangler.json / wrangler.jsonc in this project"
    return 1
  fi
  cfdir="$(pick_dir Cloudflare "$dirs")" || return 1
  reldir="$(rel_of_dir "$cfdir")"
  cfg="$(cf_config_file "$cfdir")"
  cf_is_pages "$cfg" && pages=1
  name="$(cf_name "$cfg" || true)"
  if [[ $pages == 1 ]]; then
    [[ -n "$name" ]] || { err "no project name in $cfg"; return 1; }
    case "$P_ENV" in
      ""|production|preview) ;;
      *) err "Cloudflare Pages only has the production and preview environments"; return 1 ;;
    esac
  fi

  local file="$P_FILE"
  if [[ -z "$file" ]]; then
    if ! file="$(cf_source_file "$reldir" "$P_ENV")"; then
      err "no .dev.vars${P_ENV:+.$P_ENV} or .env${P_ENV:+.$P_ENV} saved in the vault for $(in_dir "$reldir" "")"
      say "  save your local file first (ev save), or choose one with --file"
      return 1
    fi
  elif [[ ! -f "$ENVORA_VAULT/$PROJECT_NAME/$file.age" ]]; then
    err "$file is not in the vault for $PROJECT_NAME (save it first: ev save)"
    return 1
  fi
  warn_if_local_differs "$file" || { say "cancelled"; return 1; }

  local recs keys count
  recs="$(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$file.age" | dotenv_json v)" || { err "cannot decrypt $file"; return 1; }
  keys="$(printf '%s\n' "$recs" | jq -r '.k' | LC_ALL=C sort -u)"
  count="$(printf '%s\n' "$keys" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    warn "$file has no variables: nothing to send"
    return 0
  fi

  provider_cmd wrangler || return 1
  local env_args=() target_label
  [[ -n "$P_ENV" ]] && env_args=(--env "$P_ENV")
  if [[ $pages == 1 ]]; then
    target_label="Pages project $name${P_ENV:+ ($P_ENV)}"
  else
    target_label="Worker ${name:-(from $(basename "$cfg"))}${P_ENV:+ (env $P_ENV)}"
  fi

  step "reading the secret names of the $target_label"
  local remote=""
  if [[ $pages == 1 ]]; then
    if ! (cd "$cfdir" && "${PCMD[@]}" pages secret list --project-name "$name" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfl.out" 2>"$TMP_ROOT/cfl.err"; then
      err "wrangler pages secret list failed:"
      show_tool_output "$TMP_ROOT/cfl.err"
      return 1
    fi
    remote="$(sed -n 's/^[[:space:]]*- \([^:]*\):.*/\1/p' "$TMP_ROOT/cfl.out" | LC_ALL=C sort -u)"
  else
    if ! (cd "$cfdir" && "${PCMD[@]}" secret list --format json ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfl.out" 2>"$TMP_ROOT/cfl.err"; then
      err "wrangler secret list failed:"
      show_tool_output "$TMP_ROOT/cfl.err"
      return 1
    fi
    remote="$(jq -r '.[]?.name // empty' "$TMP_ROOT/cfl.out" 2>/dev/null | LC_ALL=C sort -u)" || {
      err "unexpected output from wrangler secret list"
      return 1
    }
  fi

  local k add=() upd=() only=()
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if printf '%s\n' "$remote" | grep -Fxq -- "$k"; then upd[${#upd[@]}]="$k"; else add[${#add[@]}]="$k"; fi
  done <<EOF
$keys
EOF
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    printf '%s\n' "$keys" | grep -Fxq -- "$k" || only[${#only[@]}]="$k"
  done <<EOF
$remote
EOF

  say "${C_BOLD}vault → Cloudflare${C_RST}  ${C_DIM}vault/$PROJECT_NAME/$file → $target_label${C_RST}"
  [[ ${#add[@]} -gt 0 ]] && say "  ${C_ACC}+ add${C_RST}     $(join_by ' ' "${add[@]}")"
  [[ ${#upd[@]} -gt 0 ]] && say "  ${C_WARN}~ update${C_RST}  $(join_by ' ' "${upd[@]}")  ${C_DIM}(values are write-only, so every key is sent)${C_RST}"
  [[ ${#only[@]} -gt 0 ]] && say "  ${C_DIM}· only on Cloudflare, kept: $(join_by ' ' "${only[@]}")${C_RST}"

  if [[ $P_DRY == 1 ]]; then
    say "${C_DIM}dry run: nothing sent${C_RST}"
    return 0
  fi
  if ! confirm "Upload $(plural "$count" secret) to the $target_label? This deploys immediately."; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to deploy secrets without confirmation: add --yes"
    return 1
  fi

  local json i=0 batch_rc=0
  json="$(printf '%s\n' "$recs" | jq -sc 'map({(.k): .v}) | add // {}')" || { err "cannot build the secrets payload"; return 1; }
  while [[ $i -lt $count ]]; do
    if [[ $pages == 1 ]]; then
      printf '%s' "$json" | jq -c --argjson i "$i" --argjson n "$CF_BATCH" 'to_entries | .[$i:$i+$n] | from_entries' |
        (cd "$cfdir" && "${PCMD[@]}" pages secret bulk --project-name "$name" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfb.out" 2>&1 || batch_rc=$?
    else
      printf '%s' "$json" | jq -c --argjson i "$i" --argjson n "$CF_BATCH" 'to_entries | .[$i:$i+$n] | from_entries' |
        (cd "$cfdir" && "${PCMD[@]}" secret bulk ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfb.out" 2>&1 || batch_rc=$?
    fi
    if [[ $batch_rc -ne 0 ]]; then
      err "wrangler secret bulk failed:"
      show_tool_output "$TMP_ROOT/cfb.out"
      return 1
    fi
    i=$((i + CF_BATCH))
  done
  json=""
  recs=""
  [[ "${QUIET:-0}" == 1 ]] || show_tool_output "$TMP_ROOT/cfb.out" 3
  ok "vault → Cloudflare: $(plural "$count" secret) uploaded to the $target_label"
  return 0
}

cloudflare_relevant() {
  [[ -n "$(cloudflare_dirs)" ]]
}
