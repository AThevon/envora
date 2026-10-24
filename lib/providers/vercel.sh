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
#     - stdin is read once: an empty value counts as "no value" (it prompts),
#       and only the first chunk (about 64 KB) is read
#     - update changes the whole variable: every environment it targets
#   .vercel/project.json (vercel link) or .vercel/repo.json at the repo root
#     (vercel link --repo: {"projects":[{"name","directory"}]})
#   --non-interactive on every call: a piped stdin is not enough for the CLI
#     to skip its prompts (env add NAME preview asks "Git branch?", reads the
#     empty stdin and exits 0 without adding anything)
#   env ls --format json has no customEnvironmentIds: a variable that also
#     serves a custom environment is found by listing that environment too

VERCEL_STD_ENVS="development preview production"
VERCEL_STDIN_MAX=60000

# Dirs (absolute) linked to a Vercel project: they hold .vercel/project.json,
# or are listed by the repo link .vercel/repo.json of the project root.
vercel_dirs() {
  local d prune_expr=()
  for d in $PRUNE_DIRS; do
    [[ "$d" == ".vercel" ]] && continue
    [[ ${#prune_expr[@]} -gt 0 ]] && prune_expr[${#prune_expr[@]}]="-o"
    prune_expr[${#prune_expr[@]}]="-name"
    prune_expr[${#prune_expr[@]}]="$d"
  done
  {
    find "$PROJECT_DIR" -maxdepth "$SCAN_DEPTH" \
      \( -type d -name .vercel -print -prune \) -o \
      \( -type d \( "${prune_expr[@]}" \) -prune \) 2>/dev/null |
      while IFS= read -r d; do
        [[ -f "$d/project.json" ]] && dirname "$d"
      done
    if [[ -f "$PROJECT_DIR/.vercel/repo.json" ]]; then
      jq -r '.projects[]?.directory // empty' "$PROJECT_DIR/.vercel/repo.json" 2>/dev/null |
        while IFS= read -r d; do
          case "$d" in
            .|"") printf '%s\n' "$PROJECT_DIR" ;;
            /*|*..*) ;;
            *) [[ -d "$PROJECT_DIR/${d#./}" ]] && printf '%s\n' "$PROJECT_DIR/${d#./}" ;;
          esac
        done
    fi
  } | LC_ALL=C sort -u
}

# Vault path (relative to the project entry) of a snapshot.
vercel_snapshot_rel() {
  local reldir="$1" env="$2"
  if [[ "$reldir" == "." ]]; then printf '@vercel/%s.env' "$env"; else printf '@vercel/%s/%s.env' "$reldir" "$env"; fi
}

vercel_not_linked() {
  err "this project is not linked to Vercel (no .vercel/project.json or .vercel/repo.json)"
  if is_interactive && confirm "Run 'vercel link' in $(tildify "$PROJECT_DIR") now?"; then
    provider_cmd vercel || return 1
    (cd "$PROJECT_DIR" && "${PCMD[@]}" link) || { err "vercel link failed"; return 1; }
    [[ -n "$(vercel_dirs)" ]] && return 0
    err "still not linked"
    return 1
  fi
  say "  link it first: cd $(tildify "$PROJECT_DIR") && vercel link"
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
  parse_provider_args "import vercel" "--env" "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  resolve_project "" || return 1

  # Linking may ask questions: done before taking the vault.
  local dirs pdir reldir
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    vercel_not_linked || return 1
    dirs="$(vercel_dirs)"
  fi
  pdir="$(pick_dir Vercel "$dirs")" || return 1
  reldir="$(rel_of_dir "$pdir")"
  provider_cmd vercel || return 1

  vault_pull || return 1
  check_recipient write || return 1
  check_origin "$PROJECT_NAME" "import vercel" || return 1

  local envs="$P_ENV"
  if [[ -z "$envs" ]]; then
    envs="$VERCEL_STD_ENVS"
    local custom
    custom="$( (cd "$pdir" && "${PCMD[@]}" target list --format json --non-interactive) 2>/dev/null | jq -r '.targets[]?.slug // empty' 2>/dev/null || true)"
    local s
    for s in $custom; do
      case " $envs " in *" $s "*) ;; *) envs="$envs $s" ;; esac
    done
  fi

  local base="$ENVORA_VAULT/$PROJECT_NAME" env tmp merged snap rel n unknown sens total_unknown=0 total_carried=0
  local changed=() failed=0 same=0
  for env in $envs; do
    tmp="$TMP_ROOT/vercel.$env.env"
    merged="$TMP_ROOT/vercel.$env.merged"
    rm -f "$tmp" "$merged"
    if ! (cd "$pdir" && "${PCMD[@]}" env pull "$tmp" --environment "$env" --yes --non-interactive) >"$TMP_ROOT/vercel.out" 2>&1 || [[ ! -f "$tmp" ]]; then
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
    sens="$(grep -v '^VERCEL_OIDC_TOKEN=' "$tmp" | grep -c '^[A-Za-z_][A-Za-z0-9_.-]*="\[SENSITIVE\]"$' || true)"
    rm -f "$tmp"
    n="$(dotenv_keys <"$merged" | grep -c . || true)"
    unknown="$(grep -c '^[A-Za-z_][A-Za-z0-9_.-]*="\[SENSITIVE\]"$' "$merged" || true)"
    total_unknown=$((total_unknown + unknown))
    total_carried=$((total_carried + sens - unknown))
    if [[ -f "$snap" ]] && same_plaintext "$snap" "$merged"; then
      same=$((same + 1))
      step "$env  ${C_DIM}$(plural "$n" variable), unchanged${C_RST}"
    elif vault_inflight_add "$PROJECT_NAME/$rel.age" && encrypt_file "$merged" "$snap"; then
      changed[${#changed[@]}]="$env"
      step "$env  ${C_DIM}$(plural "$n" variable) → vault/$PROJECT_NAME/$rel${C_RST}"
    else
      failed=$((failed + 1))
    fi
    rm -f "$merged"
  done

  if [[ ${#changed[@]} -gt 0 ]]; then
    # The entry is claimed by this repository, as ev save would.
    vault_inflight_add "$PROJECT_NAME/.origin"
    save_origin_file
    vault_gitattributes
    local commit_rc=0
    vault_commit "import vercel: $PROJECT_NAME ($(join_by ', ' "${changed[@]}"))" "$PROJECT_NAME" .recipient .gitattributes || commit_rc=$?
    [[ $commit_rc == 2 ]] && return 1
    vault_inflight_done
    record_project_dir
  fi
  local push_rc=0
  vault_push || push_rc=$?

  if [[ $total_carried -gt 0 ]]; then
    warn "$(plural "$total_carried" value) carried over from the previous snapshot: Secret on Vercel, so it may have changed there since"
  fi
  if [[ $total_unknown -gt 0 ]]; then
    if [[ $total_unknown -eq 1 ]]; then
      warn "1 secret is write-only on Vercel, value unknown (kept as [SENSITIVE])"
    else
      warn "$total_unknown secrets are write-only on Vercel, values unknown (kept as [SENSITIVE])"
    fi
    say "  snapshots are never restored into the project: read them with ev status --values;"
    say "  keep the real values in your project files (ev save), the vault is the source of truth"
  fi
  if [[ ${#changed[@]} -gt 0 ]]; then
    result "$push_rc" "Vercel → vault: $(plural ${#changed[@]} environment) updated ($(join_by ', ' "${changed[@]}"))$(push_suffix "$push_rc")"
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

# Per key on Vercel for environment E: "key<TAB>other targets<TAB>branch"
#   other targets: the environments the general variable ALSO targets (an
#     update changes them too); branch: "branch" when the key also has
#     branch-specific values for E.
VERCEL_KEYS_JQ='
  [ .envs[]?
    | { key,
        branch: ((.gitBranch // "") != ""),
        c: (.createdAt // ""),
        t: ((.target // []) | if type == "array" then . else [.] end) }
    | select(($std | index($e) | not) or (.t | index($e) != null)) ]
  | group_by(.key)[]
  | . as $g
  | ([$g[] | select(.branch | not)] | .[0]) as $main
  | [ $g[0].key,
      (if $main then ($main.t - [$e] | join(", ")) else "" end),
      (if ([$g[] | select(.branch)] | length) > 0 then "branch" else "" end),
      (if $main then "general" else "" end),
      (if $main then ($main.c | tostring) else "" end) ]
  | @tsv'

vercel_export() {
  parse_provider_args "export vercel" "--env --file --dry-run --update-shared" "$@" || return 1
  vault_ready || return 1
  require_key || return 1
  vault_pull || return 1
  check_recipient read || return 1
  vault_unlock # read-only from here: prompts must not hold the vault
  resolve_project "" || return 1
  check_origin "$PROJECT_NAME" "export vercel" || return 1

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
      err "no .env.production / .env.preview / .env.development saved for $(dir_label "$reldir")"
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
  split_var_names "$(printf '%s\n' "$recs" | jq -r '.k' | LC_ALL=C sort -u)"
  keys="$VALID_KEYS"
  if [[ -z "$keys" ]]; then
    warn "$file has no variables: nothing to send"
    return 0
  fi

  provider_cmd vercel || return 1
  step "reading the variables of Vercel ($env)"
  if ! (cd "$pdir" && "${PCMD[@]}" env ls "$env" --format json --non-interactive) >"$TMP_ROOT/vls.json" 2>"$TMP_ROOT/vls.err"; then
    err "vercel env ls failed:"
    show_tool_output "$TMP_ROOT/vls.err"
    return 1
  fi
  local info
  info="$(jq -r --arg e "$env" --argjson std '["production","preview","development"]' "$VERCEL_KEYS_JQ" "$TMP_ROOT/vls.json" 2>/dev/null)" || {
    err "unexpected output from vercel env ls"
    return 1
  }
  # Custom environments: "env ls" does not say which variables also serve
  # them, so each one is listed; the same variable shows up with the same
  # creation time. Lines: "key<TAB>createdAt<TAB>slug".
  local custom slug
  : >"$TMP_ROOT/vcustom.tsv"
  custom="$( (cd "$pdir" && "${PCMD[@]}" target list --format json --non-interactive) 2>/dev/null | jq -r '.targets[]?.slug // empty' 2>/dev/null || true)"
  for slug in $custom; do
    case " $VERCEL_STD_ENVS $env " in *" $slug "*) continue ;; esac
    (cd "$pdir" && "${PCMD[@]}" env ls "$slug" --format json --non-interactive) 2>/dev/null |
      jq -r --arg s "$slug" '.envs[]? | select((.gitBranch // "") == "") | [.key, (.createdAt // "" | tostring), $s] | @tsv' 2>/dev/null >>"$TMP_ROOT/vcustom.tsv" || true
  done
  local remote_filter='
    .envs[]? | select((.gitBranch // "") == "")
    | select(
        ($std | index($e) | not)
        or ((.target // []) | (if type == "array" then . else [.] end) | index($e) != null)
      )'
  # Plain (readable) variables whose value is already the same can be skipped.
  local plain_same
  plain_same="$({
    jq -c --arg e "$env" --argjson std '["production","preview","development"]' "$remote_filter | select(.type == \"plain\" and .value != null) | {s: \"r\", k: .key, v: .value}" "$TMP_ROOT/vls.json" 2>/dev/null
    printf '%s\n' "$recs"
  } | jq -rs '(map(select(.s=="r")) | map({(.k): .v}) | add // {}) as $R
             | (map(select(.s=="v")) | map({(.k): .v}) | add // {}) as $V
             | $V | keys[] as $k | select(($R | has($k)) and $R[$k] == $V[$k]) | $k' 2>/dev/null || true)"

  local k line others branch general created cust val len
  local add=() upd=() same=() only=() shared=() shared_info=() branchy=() empty=() big=() expands=()
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    line="$(printf '%s\n' "$info" | awk -F '\t' -v k="$k" '$1 == k' | head -n 1)"
    others="$(printf '%s' "$line" | cut -f2)"
    branch="$(printf '%s' "$line" | cut -f3)"
    general="$(printf '%s' "$line" | cut -f4)"
    created="$(printf '%s' "$line" | cut -f5)"
    if [[ "$general" == general && -s "$TMP_ROOT/vcustom.tsv" ]]; then
      cust="$(awk -F '\t' -v k="$k" -v c="$created" '$1 == k && $2 == c { print $3 }' "$TMP_ROOT/vcustom.tsv" | LC_ALL=C sort -u | tr '\n' ' ')"
      cust="${cust% }"
      if [[ -n "$cust" ]]; then
        others="${others:+$others, }${cust// /, }"
      fi
    fi
    val="$(printf '%s\n' "$recs" | jq -sj --arg k "$k" 'map(select(.k == $k)) | last | .v')"
    # Bytes, not characters: the Vercel CLI reads one 64 KiB chunk of stdin.
    len="$(printf '%s' "$val" | LC_ALL=C wc -c | tr -d ' ')"
    case "$val" in
      *'$'[A-Za-z_]*|*'${'*) expands[${#expands[@]}]="$k" ;;
    esac
    if printf '%s\n' "$plain_same" | grep -Fxq -- "$k"; then
      same[${#same[@]}]="$k"
    elif [[ $len -eq 0 ]]; then
      empty[${#empty[@]}]="$k"
    elif [[ $len -gt $VERCEL_STDIN_MAX ]]; then
      big[${#big[@]}]="$k"
    elif [[ "$general" == general ]]; then
      if [[ "$branch" == branch ]]; then
        branchy[${#branchy[@]}]="$k"
      elif [[ -n "$others" ]]; then
        shared[${#shared[@]}]="$k"
        shared_info[${#shared_info[@]}]="$k (also $others)"
      else
        upd[${#upd[@]}]="$k"
      fi
    else
      add[${#add[@]}]="$k"
    fi
  done <<<"$keys"
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$(printf '%s' "$k" | cut -f4)" == general ]] || continue
    k="$(printf '%s' "$k" | cut -f1)"
    printf '%s\n' "$keys" | grep -Fxq -- "$k" || only[${#only[@]}]="$k"
  done <<<"$info"

  plan_line "${C_BOLD}vault → Vercel${C_RST}  ${C_DIM}vault/$PROJECT_NAME/$file → Vercel $env ($(dir_label "$reldir"))${C_RST}"
  [[ ${#add[@]} -gt 0 ]] && plan_line "  ${C_ACC}+ add${C_RST}      $(join_by ' ' "${add[@]}")"
  [[ ${#upd[@]} -gt 0 ]] && plan_line "  ${C_WARN}~ update${C_RST}   $(join_by ' ' "${upd[@]}")"
  [[ ${#same[@]} -gt 0 ]] && plan_line "  ${C_DIM}= same     $(join_by ' ' "${same[@]}")${C_RST}"
  # Shared variables are only updated on an explicit yes (asked after the plan).
  local send_shared=0
  if [[ ${#shared[@]} -gt 0 ]]; then
    plan_line "  ${C_WARN}! shared${C_RST}   $(join_by ', ' "${shared_info[@]}")"
    plan_line "             ${C_DIM}one variable on Vercel serves several environments: updating it changes them all${C_RST}"
    if [[ $P_SHARED == 1 ]]; then
      send_shared=1
      plan_line "             ${C_DIM}updated anyway (--update-shared)${C_RST}"
    elif [[ $P_DRY != 1 ]] && is_interactive; then
      plan_line "             ${C_DIM}you will be asked whether to update them${C_RST}"
    else
      plan_line "             ${C_DIM}skipped: add --update-shared to update them anyway${C_RST}"
    fi
  fi
  [[ ${#branchy[@]} -gt 0 ]] && plan_line "  ${C_WARN}! skipped${C_RST}  $(join_by ' ' "${branchy[@]}")  ${C_DIM}(also has branch-specific values: change it in the Vercel dashboard)${C_RST}"
  [[ ${#BAD_KEYS[@]} -gt 0 ]] && plan_line "  ${C_WARN}! skipped${C_RST}  $(join_by ' ' "${BAD_KEYS[@]}")  ${C_DIM}(not a valid variable name)${C_RST}"
  [[ ${#empty[@]} -gt 0 ]] && plan_line "  ${C_DIM}· skipped  $(join_by ' ' "${empty[@]}")  (empty value: the Vercel CLI cannot receive it, set it by hand)${C_RST}"
  [[ ${#big[@]} -gt 0 ]] && plan_line "  ${C_DIM}· skipped  $(join_by ' ' "${big[@]}")  (value over 60 KB: the Vercel CLI would cut it, set it by hand)${C_RST}"
  [[ ${#only[@]} -gt 0 ]] && plan_line "  ${C_DIM}· kept     $(join_by ' ' "${only[@]}")  (only on Vercel, never deleted)${C_RST}"
  [[ ${#expands[@]} -gt 0 ]] && plan_line "  ${C_WARN}! note${C_RST}     $(join_by ' ' "${expands[@]}")  ${C_DIM}(the value contains \$NAME: sent as written, Vercel does not expand it; Next.js does locally)${C_RST}"

  if [[ ${#shared[@]} -gt 0 && $send_shared == 0 && $P_DRY != 1 ]] && is_interactive; then
    if confirm "Also update the shared variables ($(join_by ', ' "${shared[@]}"))? Their other environments change too." no; then
      send_shared=1
    fi
  fi
  [[ $send_shared == 1 ]] && upd=(${upd[@]+"${upd[@]}"} "${shared[@]}")

  local todo=$(( ${#add[@]} + ${#upd[@]} ))
  if [[ $todo -eq 0 ]]; then
    if [[ ${#shared[@]} -eq 0 && ${#branchy[@]} -eq 0 && ${#empty[@]} -eq 0 && ${#big[@]} -eq 0 ]]; then
      ok "Vercel ($env) already has these values"
    else
      plan_line "nothing to send automatically"
    fi
    return 0
  fi
  if [[ $P_DRY == 1 ]]; then
    plan_line "${C_DIM}dry run: nothing sent${C_RST}"
    return 0
  fi
  if ! confirm "Send $(plural "$todo" variable) to Vercel ($env)?"; then
    if is_interactive; then say "cancelled"; return 0; fi
    err "refusing to change Vercel without confirmation: add --yes"
    return 1
  fi

  local failed=0 done_n=0 action label
  for k in ${add[@]+"${add[@]}"} ${upd[@]+"${upd[@]}"}; do
    action=add label=added
    if printf '%s\n' "${upd[@]+"${upd[@]}"}" | grep -Fxq -- "$k"; then action=update label=updated; fi
    if printf '%s\n' "$recs" | jq -sj --arg k "$k" 'map(select(.k == $k)) | last | .v' |
      (cd "$pdir" && "${PCMD[@]}" env "$action" "$k" "$env" --yes --non-interactive) >"$TMP_ROOT/vadd.out" 2>&1; then
      done_n=$((done_n + 1))
      step "$k  ${C_DIM}$label${C_RST}"
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
