#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for awk/jq, on purpose
# lib/providers/cloudflare.sh - vault → Cloudflare (Workers and Pages secrets)
#
# Facts this module relies on (checked against wrangler 4.132.0):
#   wrangler secret list --format json [--env e]   [{"name":..,"type":"secret_text"}]
#   wrangler secret bulk [--env e]                 JSON {"k":"v"} on stdin, 100 max, deploys
#   wrangler pages secret list [--env production|preview]
#       text: '  - NAME: Value Encrypted'
#   wrangler pages secret bulk [--env production|preview] --project-name P
#   wrangler looks for its config in the current folder AND its parents
#   (wrangler.json, then wrangler.jsonc, then wrangler.toml): in a monorepo a
#   wrangler.json at the root would win over apps/api/wrangler.toml. So envora
#   always names the config (--config) for Workers and the project
#   (--project-name, Pages ignores --config), and runs in that folder.
#   Without --env: the top-level (deployed) Worker, or Pages production.
# Cloudflare secrets are write-only: values cannot be read back or imported.

CF_CONFIGS="wrangler.json wrangler.jsonc wrangler.toml"
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

# JSONC -> JSON: comments and trailing commas removed (strings left intact).
CF_JSONC_AWK='
{ buf = buf $0 "\n" }
END {
  n = length(buf); out = ""; i = 1; ins = 0
  while (i <= n) {
    c = substr(buf, i, 1); d = substr(buf, i + 1, 1)
    if (ins) {
      out = out c
      if (c == "\\") { out = out d; i += 2; continue }
      if (c == "\"") ins = 0
      i++; continue
    }
    if (c == "\"") { ins = 1; out = out c; i++; continue }
    if (c == "/" && d == "/") { while (i <= n && substr(buf, i, 1) != "\n") i++; continue }
    if (c == "/" && d == "*") {
      i += 2
      while (i <= n && !(substr(buf, i, 1) == "*" && substr(buf, i + 1, 1) == "/")) i++
      i += 2; continue
    }
    out = out c; i++
  }
  n = length(out); res = ""; ins = 0
  for (i = 1; i <= n; i++) {
    c = substr(out, i, 1)
    if (ins) {
      res = res c
      if (c == "\\") { i++; res = res substr(out, i, 1); continue }
      if (c == "\"") ins = 0
      continue
    }
    if (c == "\"") { ins = 1; res = res c; continue }
    if (c == ",") {
      j = i + 1
      while (j <= n && substr(out, j, 1) ~ /[ \t\r\n]/) j++
      e = substr(out, j, 1)
      if (e == "}" || e == "]") continue
    }
    res = res c
  }
  printf "%s", res
}'

cf_json_config() {
  LC_ALL=C awk "$CF_JSONC_AWK" "$1" | jq -c . 2>/dev/null
}

# Top-level keys of a wrangler.toml, before the first [table].
cf_toml_top() {
  # cf_toml_top FILE KEY -> value (quotes removed) ; exit 1 when absent
  awk -v k="$2" '
    /^[ \t]*\[/ { exit }
    {
      line = $0
      if (match(line, "^[ \t]*" k "[ \t]*=")) {
        v = substr(line, RLENGTH + 1)
        sub(/^[ \t]+/, "", v)
        q = substr(v, 1, 1)
        if (q == "\"" || q == "\047") {
          v = substr(v, 2); p = index(v, q); if (p > 0) v = substr(v, 1, p - 1)
        } else {
          sub(/[ \t]*#.*$/, "", v); sub(/[ \t]+$/, "", v)
        }
        print v; found = 1; exit
      }
    }
    END { exit found ? 0 : 1 }' "$1"
}

# cf_read_config DIR -> sets CF_CFG, CF_PAGES (0|1), CF_NAME. Returns 1 when
# the config cannot be read.
CF_CFG="" CF_PAGES=0 CF_NAME=""
cf_read_config() {
  local json
  CF_CFG="$(cf_config_file "$1")" || return 1
  CF_PAGES=0
  CF_NAME=""
  case "$CF_CFG" in
    *.toml)
      CF_NAME="$(cf_toml_top "$CF_CFG" name || true)"
      cf_toml_top "$CF_CFG" pages_build_output_dir >/dev/null && CF_PAGES=1
      ;;
    *)
      json="$(cf_json_config "$CF_CFG")" || return 1
      [[ -n "$json" ]] || return 1
      CF_NAME="$(printf '%s' "$json" | jq -r '.name // empty | strings')"
      [[ "$(printf '%s' "$json" | jq -r 'has("pages_build_output_dir")')" == true ]] && CF_PAGES=1
      ;;
  esac
  return 0
}

cf_kind() {
  if [[ "$CF_PAGES" == 1 ]]; then printf 'Pages project'; else printf 'Worker'; fi
}

# Source file in the vault for an environment (first existing):
#   no --env    .dev.vars, else .env      -> the deployed top-level Worker
#   --env e     .dev.vars.e, else .env.e  -> environment e
# (--file picks any other saved file.)
cf_source_file() {
  local reldir="$1" env="$2" c cands
  if [[ -n "$env" ]]; then
    cands=".dev.vars.$env .env.$env"
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
  vault_unlock # read-only from here: prompts must not hold the vault
  resolve_project "" || return 1
  check_origin "$PROJECT_NAME" "export cloudflare" || return 1

  local dirs cfdir reldir
  dirs="$(cloudflare_dirs)"
  if [[ -z "$dirs" ]]; then
    err "no wrangler.toml / wrangler.json / wrangler.jsonc in this project"
    return 1
  fi
  cfdir="$(pick_dir Cloudflare "$dirs")" || return 1
  reldir="$(rel_of_dir "$cfdir")"
  if ! cf_read_config "$cfdir"; then
    err "cannot read $(in_dir "$reldir" "$(basename "${CF_CFG:-wrangler.json}")") (invalid JSON?)"
    return 1
  fi
  local pages="$CF_PAGES" name="$CF_NAME" cfg="$CF_CFG"
  if [[ $pages == 1 ]]; then
    [[ -n "$name" ]] || { err "no \"name\" in $cfg: wrangler needs it for the Pages project"; return 1; }
    case "$P_ENV" in
      ""|production|preview) ;;
      *) err "Cloudflare Pages only has the production and preview environments"; return 1 ;;
    esac
  fi

  local file="$P_FILE"
  if [[ -z "$file" ]]; then
    if ! file="$(cf_source_file "$reldir" "$P_ENV")"; then
      if [[ -n "$P_ENV" ]]; then
        err "no $(in_dir "$reldir" ".dev.vars.$P_ENV") or $(in_dir "$reldir" ".env.$P_ENV") saved in the vault"
        if cf_source_file "$reldir" "" >/dev/null; then
          say "  to send $(cf_source_file "$reldir" "") to $P_ENV instead: ev export cloudflare --env $P_ENV --file $(cf_source_file "$reldir" "")"
        else
          say "  save your local file first (ev save), or choose one with --file"
        fi
      else
        err "no $(in_dir "$reldir" .dev.vars) or $(in_dir "$reldir" .env) saved in the vault for $PROJECT_NAME"
        say "  save your local file first (ev save), or choose one with --file"
      fi
      return 1
    fi
  elif [[ ! -f "$ENVORA_VAULT/$PROJECT_NAME/$file.age" ]]; then
    err "$file is not in the vault for $PROJECT_NAME (save it first: ev save)"
    return 1
  fi
  warn_if_local_differs "$file" || { say "cancelled"; return 1; }

  local recs keys count
  recs="$(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$file.age" | dotenv_json v)" || { err "cannot decrypt $file"; return 1; }
  split_var_names "$(printf '%s\n' "$recs" | jq -r '.k' | LC_ALL=C sort -u)"
  keys="$VALID_KEYS"
  count="$(printf '%s\n' "$keys" | grep -c . || true)"
  if [[ ${#BAD_KEYS[@]} -gt 0 ]]; then
    recs="$(printf '%s\n' "$recs" | jq -c 'select(.k | test("^[A-Za-z_][A-Za-z0-9_]*$"))')"
  fi
  if [[ "$count" -eq 0 ]]; then
    warn "$file has no variables: nothing to send"
    return 0
  fi

  provider_cmd wrangler || return 1
  local env_args=() target_args=() target_label
  [[ -n "$P_ENV" ]] && env_args=(--env "$P_ENV")
  if [[ $pages == 1 ]]; then
    target_args=(--project-name "$name")
    target_label="Pages project $name (${P_ENV:-production})"
  else
    target_args=(--config "$cfg")
    if [[ -n "$P_ENV" ]]; then
      target_label="Worker ${name:-(from $(basename "$cfg"))}, environment $P_ENV"
    else
      target_label="Worker ${name:-(from $(basename "$cfg"))} (deployed, top-level)"
    fi
  fi

  step "reading the secret names of the $target_label"
  local remote=""
  if [[ $pages == 1 ]]; then
    if ! (cd "$cfdir" && "${PCMD[@]}" pages secret list "${target_args[@]}" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfl.out" 2>"$TMP_ROOT/cfl.err"; then
      err "wrangler pages secret list failed:"
      show_tool_output "$TMP_ROOT/cfl.err"
      return 1
    fi
    remote="$(sed -n 's/^[[:space:]]*- \([^:]*\):.*/\1/p' "$TMP_ROOT/cfl.out" | LC_ALL=C sort -u)"
  else
    if ! (cd "$cfdir" && "${PCMD[@]}" secret list --format json "${target_args[@]}" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfl.out" 2>"$TMP_ROOT/cfl.err"; then
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
  done <<<"$keys"
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    printf '%s\n' "$keys" | grep -Fxq -- "$k" || only[${#only[@]}]="$k"
  done <<<"$remote"

  plan_line "${C_BOLD}vault → Cloudflare${C_RST}  ${C_DIM}vault/$PROJECT_NAME/$file → $target_label$([[ "$reldir" != "." ]] && printf ' (%s)' "$reldir")${C_RST}"
  [[ ${#add[@]} -gt 0 ]] && plan_line "  ${C_ACC}+ add${C_RST}      $(join_by ' ' "${add[@]}")"
  [[ ${#upd[@]} -gt 0 ]] && plan_line "  ${C_WARN}~ update${C_RST}   $(join_by ' ' "${upd[@]}")  ${C_DIM}(values are write-only, so every key is sent)${C_RST}"
  [[ ${#only[@]} -gt 0 ]] && plan_line "  ${C_DIM}· kept     $(join_by ' ' "${only[@]}")  (only on Cloudflare, never deleted)${C_RST}"
  [[ ${#BAD_KEYS[@]} -gt 0 ]] && plan_line "  ${C_WARN}! skipped${C_RST}  $(join_by ' ' "${BAD_KEYS[@]}")  ${C_DIM}(not a valid variable name)${C_RST}"
  if [[ $pages == 0 && -z "$P_ENV" ]]; then
    plan_line "  ${C_DIM}target: the deployed Worker (no --env). Another environment: --env <name>, which sends .dev.vars.<name>${C_RST}"
  fi

  if [[ $P_DRY == 1 ]]; then
    plan_line "${C_DIM}dry run: nothing sent${C_RST}"
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
        (cd "$cfdir" && "${PCMD[@]}" pages secret bulk "${target_args[@]}" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfb.out" 2>&1 || batch_rc=$?
    else
      printf '%s' "$json" | jq -c --argjson i "$i" --argjson n "$CF_BATCH" 'to_entries | .[$i:$i+$n] | from_entries' |
        (cd "$cfdir" && "${PCMD[@]}" secret bulk "${target_args[@]}" ${env_args[@]+"${env_args[@]}"}) >"$TMP_ROOT/cfb.out" 2>&1 || batch_rc=$?
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

# "Worker", "Pages project" or "Worker / Pages" for the menu label.
cloudflare_kinds() {
  local d w=0 p=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    cf_read_config "$d" || continue
    if [[ "$CF_PAGES" == 1 ]]; then p=1; else w=1; fi
  done <<<"$(cloudflare_dirs)"
  if [[ $w == 1 && $p == 1 ]]; then
    printf 'Worker / Pages'
  elif [[ $p == 1 ]]; then
    printf 'Pages project'
  else
    printf 'Worker'
  fi
}
