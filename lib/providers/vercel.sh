#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/providers/vercel.sh - Vercel → vault (import) and vault → Vercel (export)
#
# Facts this module relies on (checked against vercel 58.4.0):
#   vercel env pull FILE --environment E --yes   writes KEY="value" lines; Secret
#       (sensitive) variables come back as KEY="[SENSITIVE]"
#   vercel env ls E --format json                {"envs":[{"key","value","type","target":[..],"gitBranch"}]}
#   vercel target list --format json             {"targets":[{"slug",...}]}
#   vercel env add NAME E --yes / vercel env update NAME E --yes   value on stdin

VERCEL_STD_ENVS="development preview production"

# Dirs (absolute) linked to a Vercel project: they hold .vercel/project.json
vercel_dirs() {
  local d prune_expr=()
  for d in $PRUNE_DIRS; do
    [[ "$d" == ".vercel" ]] && continue
    [[ ${#prune_expr[@]} -gt 0 ]] && prune_expr[${#prune_expr[@]}]="-o"
    prune_expr[${#prune_expr[@]}]="-name"
    prune_expr[${#prune_expr[@]}]="$d"
  done
  find "$PROJECT_DIR" -maxdepth "$SCAN_DEPTH" \
    \( -type d -name .vercel -print -prune \) -o \
    \( -type d \( "${prune_expr[@]}" \) -prune \) 2>/dev/null |
    while IFS= read -r d; do
      [[ -f "$d/project.json" ]] && dirname "$d"
    done | LC_ALL=C sort -u
}

# Vault path (relative to the project entry) of a snapshot.
vercel_snapshot_rel() {
  local reldir="$1" env="$2"
  if [[ "$reldir" == "." ]]; then printf '@vercel/%s.env' "$env"; else printf '@vercel/%s/%s.env' "$reldir" "$env"; fi
}

vercel_not_linked() {
  err "this project is not linked to Vercel (no .vercel/project.json)"
  if is_interactive && confirm "Run 'vercel link' in $PROJECT_DIR now?"; then
    provider_cmd vercel || return 1
    (cd "$PROJECT_DIR" && "${PCMD[@]}" link) || { err "vercel link failed"; return 1; }
    [[ -f "$PROJECT_DIR/.vercel/project.json" ]] && return 0
    err "still not linked"
    return 1
  fi
  say "  link it first: cd $PROJECT_DIR && vercel link"
  return 1
}

# Keep Secret values from the previous snapshot, drop VERCEL_OIDC_TOKEN.
# vercel_merge_previous PREV_PLAINTEXT_FILE NEW_FILE > merged
VERCEL_MERGE_AWK='
function keyof(line) {
  if (match(line, /^[A-Za-z_][A-Za-z0-9_.-]*=/)) return substr(line, 1, RLENGTH - 1)
  return ""
}
FILENAME == ARGV[1] {
  k = keyof($0)
  if (k != "" && index($0, k "=\"[SENSITIVE]\"") != 1) prev[k] = $0
  next
}
{
  k = keyof($0)
  if (k == "VERCEL_OIDC_TOKEN") next
  if (k != "" && $0 == k "=\"[SENSITIVE]\"" && (k in prev)) { print prev[k]; next }
  print
}
'

vercel_import() {
  parse_provider_args "import vercel" "$@" || return 1
  [[ -z "$P_FILE" ]] || { err "--file is not used by import"; return 1; }
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient write || return 1
  resolve_project "" || return 1
  check_origin "$PROJECT_NAME" || return 1

  local dirs pdir reldir
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    vercel_not_linked || return 1
    dirs="$(vercel_dirs)"
  fi
  pdir="$(pick_dir Vercel "$dirs")" || return 1
  reldir="$(rel_of_dir "$pdir")"
  provider_cmd vercel || return 1

  local envs="$P_ENV"
  if [[ -z "$envs" ]]; then
    envs="$VERCEL_STD_ENVS"
    local custom
    custom="$( (cd "$pdir" && "${PCMD[@]}" target list --format json) 2>/dev/null | jq -r '.targets[]?.slug // empty' 2>/dev/null || true)"
    local s
    for s in $custom; do
      case " $envs " in *" $s "*) ;; *) envs="$envs $s" ;; esac
    done
  fi

  local base="$ENVORA_VAULT/$PROJECT_NAME" env tmp merged snap rel n unknown total_unknown=0
  local changed=() failed=0 same=0
  for env in $envs; do
    tmp="$TMP_ROOT/vercel.$env.env"
    merged="$TMP_ROOT/vercel.$env.merged"
    rm -f "$tmp" "$merged"
    if ! (cd "$pdir" && "${PCMD[@]}" env pull "$tmp" --environment "$env" --yes) >"$TMP_ROOT/vercel.out" 2>&1 || [[ ! -f "$tmp" ]]; then
      err "vercel env pull failed for $env:"
      show_tool_output "$TMP_ROOT/vercel.out"
      failed=$((failed + 1))
      continue
    fi
    rel="$(vercel_snapshot_rel "$reldir" "$env")"
    snap="$base/$rel.age"
    if [[ -f "$snap" ]]; then
      awk "$VERCEL_MERGE_AWK" <(decrypt_stream "$snap" 2>/dev/null || true) "$tmp" >"$merged"
    else
      awk "$VERCEL_MERGE_AWK" /dev/null "$tmp" >"$merged"
    fi
    rm -f "$tmp"
    n="$(dotenv_keys <"$merged" | grep -c . || true)"
    unknown="$(grep -c '^[A-Za-z_][A-Za-z0-9_.-]*="\[SENSITIVE\]"$' "$merged" || true)"
    total_unknown=$((total_unknown + unknown))
    if [[ -f "$snap" ]] && same_plaintext "$snap" "$merged"; then
      same=$((same + 1))
      step "$env  ${C_DIM}$(plural "$n" variable), unchanged${C_RST}"
    elif encrypt_file "$merged" "$snap"; then
      changed[${#changed[@]}]="$env"
      step "$env  ${C_DIM}$(plural "$n" variable) → vault/$PROJECT_NAME/$rel${C_RST}"
    else
      failed=$((failed + 1))
    fi
    rm -f "$merged"
  done

  if [[ ${#changed[@]} -gt 0 ]]; then
    vault_gitattributes
    vault_commit "import vercel: $PROJECT_NAME ($(join_by ', ' "${changed[@]}"))" "$PROJECT_NAME" .recipient .gitattributes || true
  fi
  local push_rc=0
  vault_push || push_rc=$?

  if [[ $total_unknown -gt 0 ]]; then
    warn "$(plural "$total_unknown" secret) are write-only on Vercel, value unknown (kept as [SENSITIVE]; put the real values in your project files and ev save)"
  fi
  if [[ ${#changed[@]} -gt 0 ]]; then
    ok "Vercel → vault: $(plural ${#changed[@]} environment) updated ($(join_by ', ' "${changed[@]}"))$(push_suffix "$push_rc")"
  elif [[ $failed -eq 0 ]]; then
    ok "Vercel → vault: nothing changed since the last snapshot"
  fi
  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return "$push_rc"
}

# --- export: vault -> Vercel -------------------------------------------------

vercel_env_of_file() {
  case "${1##*/}" in
    .env.production) echo production ;;
    .env.preview) echo preview ;;
    .env.development) echo development ;;
    *) return 1 ;;
  esac
}

vercel_export() {
  parse_provider_args "export vercel" "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient read || return 1
  resolve_project "" || return 1

  local dirs pdir reldir
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    vercel_not_linked || return 1
    dirs="$(vercel_dirs)"
  fi
  pdir="$(pick_dir Vercel "$dirs")" || return 1
  reldir="$(rel_of_dir "$pdir")"
  local base="$ENVORA_VAULT/$PROJECT_NAME" file="$P_FILE" env="$P_ENV"

  if [[ -z "$file" && -n "$env" ]]; then
    file="$(in_dir "$reldir" ".env.$env")"
  elif [[ -n "$file" && -z "$env" ]]; then
    env="$(vercel_env_of_file "$file")" || { err "which Vercel environment for $file? add --env <production|preview|development|custom>"; return 1; }
  elif [[ -z "$file" ]]; then
    local cands=() e f
    for e in production preview development; do
      f="$(in_dir "$reldir" ".env.$e")"
      [[ -f "$base/$f.age" ]] && cands[${#cands[@]}]="$f"
    done
    if [[ ${#cands[@]} -eq 0 ]]; then
      err "no .env.production / .env.preview / .env.development saved for this project"
      say "  pick a file and an environment: ev export vercel --file <file> --env <env>"
      return 1
    fi
    if [[ ${#cands[@]} -eq 1 ]]; then
      file="${cands[0]}"
    elif is_interactive; then
      file="$(choose "Which file goes to Vercel?" "${cands[@]}")" || return 1
    else
      err "several files could go to Vercel ($(join_by ', ' "${cands[@]}")): choose with --file / --env"
      return 1
    fi
    env="$(vercel_env_of_file "$file")"
  fi
  if [[ ! -f "$base/$file.age" ]]; then
    err "$file is not in the vault for $PROJECT_NAME (save it first: ev save)"
    return 1
  fi
  warn_if_local_differs "$file" || { say "cancelled"; return 1; }

  local recs keys
  recs="$(decrypt_stream "$base/$file.age" | dotenv_json v)" || { err "cannot decrypt $file"; return 1; }
  keys="$(printf '%s\n' "$recs" | jq -r '.k' | LC_ALL=C sort -u)"
  if [[ -z "$keys" ]]; then
    warn "$file has no variables: nothing to send"
    return 0
  fi

  provider_cmd vercel || return 1
  step "reading the variables of Vercel ($env)"
  if ! (cd "$pdir" && "${PCMD[@]}" env ls "$env" --format json) >"$TMP_ROOT/vls.json" 2>"$TMP_ROOT/vls.err"; then
    err "vercel env ls failed:"
    show_tool_output "$TMP_ROOT/vls.err"
    return 1
  fi
  local remote_filter='
    .envs[]? | select((.gitBranch // "") == "")
    | select(
        ($std | index($e) | not)
        or ((.target // []) | (if type == "array" then . else [.] end) | index($e) != null)
      )'
  local remote plain_same
  remote="$(jq -r --arg e "$env" --argjson std '["production","preview","development"]' "$remote_filter | .key" "$TMP_ROOT/vls.json" 2>/dev/null | LC_ALL=C sort -u)" || {
    err "unexpected output from vercel env ls"
    return 1
  }
  # Plain (readable) variables whose value is already the same can be skipped.
  plain_same="$({
    jq -c --arg e "$env" --argjson std '["production","preview","development"]' "$remote_filter | select(.type == \"plain\" and .value != null) | {s: \"r\", k: .key, v: .value}" "$TMP_ROOT/vls.json" 2>/dev/null
    printf '%s\n' "$recs"
  } | jq -rs '(map(select(.s=="r")) | map({(.k): .v}) | add // {}) as $R
             | (map(select(.s=="v")) | map({(.k): .v}) | add // {}) as $V
             | $V | keys[] as $k | select(($R | has($k)) and $R[$k] == $V[$k]) | $k' 2>/dev/null || true)"

  local k add=() upd=() same=() only=()
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if printf '%s\n' "$plain_same" | grep -Fxq -- "$k"; then
      same[${#same[@]}]="$k"
    elif printf '%s\n' "$remote" | grep -Fxq -- "$k"; then
      upd[${#upd[@]}]="$k"
    else
      add[${#add[@]}]="$k"
    fi
  done <<EOF
$keys
EOF
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    printf '%s\n' "$keys" | grep -Fxq -- "$k" || only[${#only[@]}]="$k"
  done <<EOF
$remote
EOF

  say "${C_BOLD}vault → Vercel${C_RST}  ${C_DIM}vault/$PROJECT_NAME/$file → Vercel $env ($(rel_of_dir "$pdir"))${C_RST}"
  [[ ${#add[@]} -gt 0 ]] && say "  ${C_ACC}+ add${C_RST}     $(join_by ' ' "${add[@]}")"
  [[ ${#upd[@]} -gt 0 ]] && say "  ${C_WARN}~ update${C_RST}  $(join_by ' ' "${upd[@]}")"
  [[ ${#same[@]} -gt 0 ]] && say "  ${C_DIM}= same     $(join_by ' ' "${same[@]}")${C_RST}"
  [[ ${#only[@]} -gt 0 ]] && say "  ${C_DIM}· only on Vercel, kept: $(join_by ' ' "${only[@]}")${C_RST}"

  local todo=$(( ${#add[@]} + ${#upd[@]} ))
  if [[ $todo -eq 0 ]]; then
    ok "Vercel ($env) already has these values"
    return 0
  fi
  if [[ $P_DRY == 1 ]]; then
    say "${C_DIM}dry run: nothing sent${C_RST}"
    return 0
  fi
  if ! confirm "Send $(plural "$todo" variable) to Vercel ($env)?"; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to change Vercel without confirmation: add --yes"
    return 1
  fi

  local failed=0 done_n=0 action
  for k in ${add[@]+"${add[@]}"} ${upd[@]+"${upd[@]}"}; do
    action=add
    printf '%s\n' "${upd[@]+"${upd[@]}"}" | grep -Fxq -- "$k" && action=update
    if printf '%s\n' "$recs" | jq -sj --arg k "$k" 'map(select(.k == $k)) | last | .v' |
      (cd "$pdir" && "${PCMD[@]}" env "$action" "$k" "$env" --yes) >"$TMP_ROOT/vadd.out" 2>&1; then
      done_n=$((done_n + 1))
      step "$k  ${C_DIM}${action}d${C_RST}"
    else
      err "vercel env $action $k failed:"
      show_tool_output "$TMP_ROOT/vadd.out" 3
      failed=$((failed + 1))
    fi
  done
  if [[ $done_n -gt 0 ]]; then
    ok "vault → Vercel ($env): $(plural "$done_n" variable) sent"
  fi
  [[ $failed -eq 0 ]] || return 1
  return 0
}

# --- menu integration --------------------------------------------------------

vercel_relevant() {
  [[ -n "$(vercel_dirs)" || -n "$(vault_snapshot_files "$PROJECT_NAME" | grep '^@vercel/' || true)" ]]
}
