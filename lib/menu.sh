#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/menu.sh - interactive menu: one action per line, live plan in the preview
#
# Actions run as a child "ev <command>" process, so each one has its own
# cleanup and exit code; then the menu comes back.

FZF_COLORS="fg:#c5cbd3,fg+:#e6e9ed,bg+:#1f2328,hl:#6fcf7c,hl+:#6fcf7c,pointer:#6fcf7c,prompt:#6fcf7c,header:#808894,border:#3a3f46,label:#6fcf7c,info:#808894,separator:#3a3f46,scrollbar:#3a3f46,preview-border:#3a3f46,preview-label:#808894"

# Run "ev ARGS..." as a child process. Never exits the menu.
menu_run() {
  local rc=0
  printf '\n' >&2
  "$ENVORA_BASH" "$ENVORA_SELF" "$@" || rc=$?
  case "$rc" in
    0) ;;
    3) warn "saved locally, not on GitHub yet: run Sync with GitHub when you are online" ;;
    *) warn "the action did not complete (exit $rc)" ;;
  esac
  printf '\n' >&2
  return 0
}

menu_fzf() {
  # menu_fzf LABEL HEADER < items  ->  chosen id
  local label="$1" header="$2" choice
  choice="$(ENVORA_COLOR=1 fzf --ansi --no-sort --no-input --layout=reverse \
    --height=85% --min-height=22 --border=rounded --border-label=" $label " \
    --delimiter=$'\t' --with-nth=2 --header="$header" --header-first \
    --pointer='›' --color="$FZF_COLORS" \
    --preview='"$ENVORA_BASH" "$ENVORA_SELF" _preview {1}' \
    --preview-window='right,50%,wrap,border-left,<160(down,60%,wrap,border-top)' \
    --bind='?:preview("$ENVORA_BASH" "$ENVORA_SELF" _preview keys)' \
    --bind='j:down,k:up,q:abort')" || return 1
  printf '%s' "${choice%%$'\t'*}"
}

menu_header_project() {
  local plan="$TMP_ROOT/plan.save" n_vault same changed new missing parts=()
  n_vault="$(vault_project_files "$PROJECT_NAME" | grep -c . || true)"
  same="$(plan_count "$plan" same)"
  changed="$(plan_count "$plan" changed)"
  new="$(plan_count "$plan" new)"
  missing="$(plan_count "$plan" vaultonly)"
  local state
  if [[ "$n_vault" -eq 0 ]]; then
    state="not saved yet"
    [[ "$new" -gt 0 ]] && state="not saved yet · $(plural "$new" env file) here"
  else
    parts[${#parts[@]}]="$(plural "$n_vault" file) saved"
    if [[ $((changed + new)) -eq 0 && "$missing" -eq 0 ]]; then
      parts[${#parts[@]}]="in sync"
    else
      [[ $((changed + new)) -gt 0 ]] && parts[${#parts[@]}]="$((changed + new)) changed"
      [[ "$missing" -gt 0 ]] && parts[${#parts[@]}]="$missing missing here"
    fi
    state="$(join_by ' · ' "${parts[@]}")"
  fi
  printf '%s%s%s  %s\n%s%s%s' "$C_BOLD" "$PROJECT_NAME" "$C_RST" "$state" "$C_DIM" "$(vault_sync_label) · ? help" "$C_RST"
}

menu_items_project() {
  local t=$'\t' a="$C_ACC" d="$C_DIM" r="$C_RST"
  printf '%s\n' \
    "save${t}${a}↑${r}  Save               ${a}project → vault${r}      ${d}encrypt this project's env files${r}" \
    "restore${t}${a}↓${r}  Restore            ${a}vault → project${r}      ${d}write the saved env files back here${r}" \
    "compare${t}${a}≈${r}  Compare            ${a}project ↔ vault${r}      ${d}see what differs (key names only)${r}"
  if vercel_relevant; then
    printf '%s\n' \
      "import-vercel${t}${a}▲${r}  Import Vercel      ${a}Vercel → vault${r}       ${d}snapshot Vercel env vars${r}" \
      "export-vercel${t}${a}▲${r}  Send to Vercel     ${a}vault → Vercel${r}       ${d}add / update Vercel env vars${r}"
  fi
  if cloudflare_relevant; then
    printf '%s\n' \
      "export-cloudflare${t}${a}☁${r}  Send to Cloudflare ${a}vault → Cloudflare${r}   ${d}upload secrets to the Worker${r}"
  fi
  menu_items_global
}

menu_items_global() {
  local t=$'\t' a="$C_ACC" d="$C_DIM" r="$C_RST"
  printf '%s\n' \
    "sep${t}${d}──────────────────────────────────────────────${r}" \
    "browse${t}${d}☰${r}  Browse vault       ${d}all projects saved in the vault${r}" \
    "sync${t}${d}⇅${r}  Sync with GitHub   ${a}vault ↔ GitHub${r}" \
    "doctor${t}${d}✚${r}  Doctor             ${d}check the setup, with fixes${r}" \
    "config${t}${d}⚙${r}  Settings           ${d}paths and repo${r}" \
    "rotate${t}${d}⟳${r}  Rotate key         ${d}new key, re-encrypt everything${r}"
}

cmd_menu() {
  ui_logo
  vault_pull >/dev/null 2>&1 || true
  export ENVORA_NO_SYNC_PREVIEW=1
  local choice in_project=0
  if detect_current_project 2>/dev/null; then
    in_project=1
    export ENVORA_MENU_DIR="$PROJECT_DIR"
    export ENVORA_MENU_AS="${ARG_AS:-}"
  fi
  while true; do
    if [[ $in_project == 1 ]]; then
      save_plan 2>/dev/null || true
      choice="$(menu_items_project | menu_fzf "envora · project" "$(menu_header_project)")" || return 0
    else
      choice="$(menu_items_global | sed 1d | menu_fzf "envora" "${C_BOLD}envora${C_RST} ${C_DIM}v$VERSION · not in a project · $(vault_sync_label) · ? help${C_RST}")" || return 0
    fi
    local cargs=()
    if [[ $in_project == 1 ]]; then
      cargs=(-C "$PROJECT_DIR")
      [[ -n "${ARG_AS:-}" ]] && cargs=(-C "$PROJECT_DIR" --as "$ARG_AS")
    fi
    case "$choice" in
      save) menu_run save ${cargs[@]+"${cargs[@]}"} ;;
      restore) menu_run restore ${cargs[@]+"${cargs[@]}"} ;;
      compare) menu_run status ${cargs[@]+"${cargs[@]}"} ;;
      import-vercel) menu_run import vercel -C "$PROJECT_DIR" ;;
      export-vercel) menu_run export vercel -C "$PROJECT_DIR" ;;
      export-cloudflare) menu_run export cloudflare -C "$PROJECT_DIR" ;;
      browse) menu_browse ;;
      sync) menu_run sync ;;
      doctor) menu_run doctor ;;
      config) menu_run config ;;
      rotate) menu_run rotate ;;
      *) ;;
    esac
  done
}

menu_browse() {
  local t=$'\t' name choice n
  while true; do
    choice="$(
      vault_projects | while IFS= read -r name; do
        n="$(vault_project_files "$name" | grep -c . || true)"
        if [[ -d "$ENVORA_PROJECTS/$name" ]]; then
          printf '%s%s%s  %-28s %s%s · on this machine%s\n' "p:$name" "$t" "$C_ACC◈$C_RST" "$name" "$C_DIM" "$(plural "$n" file)" "$C_RST"
        else
          printf '%s%s%s  %-28s %s%s · not on this machine%s\n' "p:$name" "$t" "$C_DIM◇$C_RST" "$name" "$C_DIM" "$(plural "$n" file)" "$C_RST"
        fi
      done | menu_fzf "vault" "${C_BOLD}vault${C_RST} ${C_DIM}$ENVORA_VAULT · esc back${C_RST}"
    )" || return 0
    name="${choice#p:}"
    valid_name "$name" || continue
    menu_vault_project "$name"
  done
}

menu_vault_project() {
  local name="$1" t=$'\t' a="$C_ACC" d="$C_DIM" r="$C_RST" dir="$ENVORA_PROJECTS/$1" choice origin=""
  [[ -f "$ENVORA_VAULT/$name/.origin" ]] && origin="$(head -n 1 "$ENVORA_VAULT/$name/.origin")"
  export ENVORA_MENU_PROJECT="$name"
  local items
  if [[ -d "$dir" ]]; then
    items="v-restore${t}${a}↓${r}  Restore            ${a}vault → $(tildify "$dir")${r}"$'\n'"v-compare${t}${a}≈${r}  Compare            ${a}project ↔ vault${r}"
  elif [[ -n "$origin" ]]; then
    items="v-clone${t}${a}↓${r}  Clone + restore    ${a}GitHub + vault → $(tildify "$dir")${r}"
  else
    items="v-none${t}${d}·  no local folder and no known origin: clone it yourself into $dir${r}"
  fi
  items="$items"$'\n'"v-forget${t}${d}✕${r}  Forget             ${d}remove $name from the vault${r}"
  choice="$(printf '%s\n' "$items" | menu_fzf "$name" "${C_BOLD}$name${C_RST} ${C_DIM}esc back${C_RST}")" || return 0
  case "$choice" in
    v-restore) menu_run restore "$name" ;;
    v-compare) menu_run status "$name" ;;
    v-clone)
      if confirm "git clone $origin $dir, then restore its env files?"; then
        if git clone "$origin" "$dir"; then
          menu_run restore -C "$dir" --as "$name"
        else
          warn "git clone failed"
        fi
      fi
      ;;
    v-forget) menu_run forget "$name" ;;
  esac
}

# --- previews ----------------------------------------------------------------

preview_title() {
  out "${C_BOLD}$1${C_RST}   ${C_ACC}$2${C_RST}"
  out "${C_DIM}$3${C_RST}"
  out ""
}

preview_need_vault() {
  if ! vault_exists || ! key_exists; then
    out "envora is not set up yet: run ev init"
    return 1
  fi
  require_key 2>/dev/null || { out "the key at $ENVORA_KEY cannot be read"; return 1; }
  check_recipient read >/dev/null 2>&1 || { out "your key does not match this vault (run ev doctor)"; return 1; }
}

preview_project() {
  [[ -n "${ENVORA_MENU_DIR:-}" ]] || return 1
  ARG_C="$ENVORA_MENU_DIR"
  ARG_AS="${ENVORA_MENU_AS:-}"
  detect_current_project 2>/dev/null
}

menu_preview() {
  local item="${1:-}"
  case "$item" in
    keys) preview_keys; return 0 ;;
    sep) return 0 ;;
    config)
      if [[ -n "${2:-}" ]]; then config_preview "$2"; else config_print; fi
      return 0
      ;;
  esac
  preview_need_vault || return 0
  case "$item" in
    save) preview_project && preview_save ;;
    restore) preview_project && preview_restore ;;
    compare) preview_project && { save_plan; status_report; } ;;
    import-vercel) preview_project && preview_import_vercel ;;
    export-vercel) preview_project && preview_export_vercel ;;
    export-cloudflare) preview_project && preview_export_cloudflare ;;
    browse) preview_browse ;;
    sync) preview_sync ;;
    doctor) cmd_doctor || true ;;
    rotate) preview_rotate ;;
    p:*) preview_vault_entry "${item#p:}" ;;
    v-restore|v-clone|v-compare) preview_vault_restore "${ENVORA_MENU_PROJECT:-}" "$item" ;;
    v-forget) preview_forget "${ENVORA_MENU_PROJECT:-}" ;;
  esac
}

preview_keys() {
  out "${C_BOLD}keys${C_RST}"
  out ""
  out "  ↑ ↓  or  j k     move"
  out "  enter            run the selected action"
  out "  ?                this help (move to close it)"
  out "  shift ↑ ↓        scroll this preview"
  out "  esc  or  q       back / quit"
  out ""
  out "${C_BOLD}where things go${C_RST}"
  out ""
  help_diagram
}

preview_save() {
  preview_title "↑ Save" "project → vault" "encrypt the env files of $PROJECT_NAME into the vault, then push to GitHub"
  save_plan
  local plan="$TMP_ROOT/plan.save" st rel any=0
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      new) out "  ${C_ACC}+${C_RST} $rel  ${C_DIM}new → will be encrypted into the vault${C_RST}"; any=1 ;;
      changed)
        out "  ${C_WARN}~${C_RST} $rel  ${C_DIM}changed → the vault copy will be replaced${C_RST}"
        out "      ${C_DIM}$(key_diff_line "$rel")${C_RST}"
        any=1
        ;;
    esac
  done <"$plan"
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      same) out "  ${C_DIM}= $rel  identical, skipped${C_RST}" ;;
      tracked) out "  ${C_DIM}· $rel  tracked by git, skipped${C_RST}" ;;
      vaultonly) out "  ${C_DIM}· $rel  only in the vault, kept${C_RST}" ;;
    esac
  done <"$plan"
  out ""
  if [[ $any == 1 ]]; then
    out "then: commit in the vault and push to GitHub"
    out "${C_DIM}vault: $(tildify "$ENVORA_VAULT/$PROJECT_NAME")${C_RST}"
  elif [[ ! -s "$plan" ]]; then
    out "no env files found in this project (.env, .env.*, .dev.vars...)"
  else
    out "${C_ACC}nothing to save: the vault is up to date${C_RST}"
  fi
}

preview_restore() {
  preview_title "↓ Restore" "vault → project" "write the saved env files of $PROJECT_NAME back into $(tildify "$PROJECT_DIR")"
  restore_plan
  local plan="$TMP_ROOT/plan.restore" st rel any=0
  if [[ ! -s "$plan" ]]; then
    out "nothing saved in the vault for $PROJECT_NAME yet"
    out ""
    out "${C_DIM}use Save first${C_RST}"
    return 0
  fi
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      new) out "  ${C_ACC}+${C_RST} $rel  ${C_DIM}missing here → will be created${C_RST}"; any=1 ;;
      differs)
        out "  ${C_WARN}~${C_RST} $rel  ${C_DIM}differs → you will be asked; a backup is kept${C_RST}"
        out "      ${C_DIM}$(key_diff_line "$rel")${C_RST}"
        any=1
        ;;
      invalid) out "  ${C_ERR}✗${C_RST} $rel  ${C_DIM}refused (not an env file name / unsafe path)${C_RST}" ;;
    esac
  done <"$plan"
  while IFS=$'\t' read -r st rel; do
    [[ "$st" == same ]] && out "  ${C_DIM}= $rel  identical, skipped${C_RST}"
  done <"$plan"
  out ""
  if [[ $any == 0 ]]; then
    out "${C_ACC}nothing to restore: your files match the vault${C_RST}"
  else
    out "${C_DIM}files are written with mode 600, atomically${C_RST}"
  fi
}

preview_import_vercel() {
  preview_title "▲ Import Vercel" "Vercel → vault" "snapshot the Vercel env vars into the vault (your files are not touched)"
  local dirs d rel snaps
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    out "not linked to Vercel yet (no .vercel/project.json)"
    out "${C_DIM}running it will offer 'vercel link'${C_RST}"
  else
    while IFS= read -r d; do
      out "  linked: $(rel_of_dir "$d")"
    done <<EOF
$dirs
EOF
  fi
  out ""
  out "environments: development, preview, production (+ custom ones)"
  snaps="$(vault_snapshot_files "$PROJECT_NAME" | grep '^@vercel/' || true)"
  if [[ -n "$snaps" ]]; then
    out ""
    out "current snapshots in the vault:"
    while IFS= read -r rel; do
      out "  ▲ $rel  ${C_DIM}$(vgit log -1 --format=%cr -- "$PROJECT_NAME/$rel.age" 2>/dev/null)${C_RST}"
    done <<EOF
$snaps
EOF
  fi
  out ""
  out "${C_DIM}Secret variables are write-only on Vercel: their value comes back as"
  out "[SENSITIVE]. envora keeps the value of the previous snapshot when it has one.${C_RST}"
}

preview_export_vercel() {
  preview_title "▲ Send to Vercel" "vault → Vercel" "add / update Vercel env vars from a file saved in the vault"
  local dirs pdir reldir e f any=0
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    out "not linked to Vercel yet (no .vercel/project.json)"
    return 0
  fi
  pdir="$(printf '%s\n' "$dirs" | head -n 1)"
  reldir="$(rel_of_dir "$pdir")"
  for e in production preview development; do
    f="$(in_dir "$reldir" ".env.$e")"
    if [[ -f "$ENVORA_VAULT/$PROJECT_NAME/$f.age" ]]; then
      out "  vault/$f  ${C_ACC}→${C_RST} Vercel $e  ${C_DIM}($(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$f.age" 2>/dev/null | dotenv_keys | grep -c . || true) vars)${C_RST}"
      any=1
    fi
  done
  [[ $any == 0 ]] && out "no .env.production / .env.preview / .env.development saved (use --file / --env from the CLI)"
  out ""
  out "${C_DIM}running it reads 'vercel env ls', shows add / update / kept, and asks before"
  out "sending. Values go through stdin. Nothing is ever deleted on Vercel.${C_RST}"
}

preview_export_cloudflare() {
  preview_title "☁ Send to Cloudflare" "vault → Cloudflare" "upload a saved file as Worker / Pages secrets"
  local dirs d cfg reldir name kind file keys
  dirs="$(cloudflare_dirs)"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    cfg="$(cf_config_file "$d")"
    reldir="$(rel_of_dir "$d")"
    name="$(cf_name "$cfg" || true)"
    if cf_is_pages "$cfg"; then kind="Pages project"; else kind="Worker"; fi
    out "  $kind ${C_BOLD}${name:-?}${C_RST}  ${C_DIM}$(in_dir "$reldir" "$(basename "$cfg")")${C_RST}"
    if file="$(cf_source_file "$reldir" "")"; then
      keys="$(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$file.age" 2>/dev/null | dotenv_keys | tr '\n' ' ')"
      out "    source: vault/$file"
      out "    ${C_DIM}secrets: $keys${C_RST}"
      if [[ -f "$PROJECT_DIR/$file" ]] && ! same_plaintext "$ENVORA_VAULT/$PROJECT_NAME/$file.age" "$PROJECT_DIR/$file"; then
        out "    ${C_WARN}! your local $file differs from the vault: save first?${C_RST}"
      fi
    else
      out "    ${C_WARN}no .dev.vars or .env saved in the vault for it: save first${C_RST}"
    fi
  done <<EOF
$dirs
EOF
  out ""
  out "${C_DIM}running it compares names with 'wrangler secret list', shows the plan and asks:"
  out "secrets deploy immediately. Values are piped, never written to disk."
  out "Nothing is deleted on Cloudflare. Other environments: ev export cloudflare --env e${C_RST}"
}

preview_browse() {
  preview_title "☰ Browse vault" "vault" "every project saved in the vault"
  local name n
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    n="$(vault_project_files "$name" | grep -c . || true)"
    out "  $(printf '%-26s' "$name") ${C_DIM}$(plural "$n" file)$([[ -d "$ENVORA_PROJECTS/$name" ]] || printf ' · not on this machine')${C_RST}"
  done <<EOF
$(vault_projects)
EOF
}

preview_sync() {
  preview_title "⇅ Sync with GitHub" "vault ↔ GitHub" "pull the other machines' saves, push yours"
  if vault_has_remote; then
    out "  remote: $(vgit remote get-url origin)"
    out "  state:  $(vault_sync_label) ${C_DIM}(as of the last fetch)${C_RST}"
  else
    out "  the vault has no remote: nothing leaves this machine"
  fi
  out ""
  out "${C_DIM}every command already syncs; use this after working offline.${C_RST}"
}

preview_rotate() {
  local n
  n="$(find "$ENVORA_VAULT" -type f -name '*.age' ! -path '*/.git/*' | grep -c . || true)"
  preview_title "⟳ Rotate key" "vault" "create a new key and re-encrypt the $(plural "$n" file) of the vault"
  out "  1. new key generated next to the current one"
  out "  2. every file re-encrypted and verified"
  out "  3. old key kept as $(basename "$ENVORA_KEY").bak-<date>"
  out "  4. commit, push, the new key is shown once"
  out ""
  out "${C_WARN}old ciphertexts remain in git history: if your key leaked,"
  out "also rotate the secrets themselves at their providers.${C_RST}"
}

preview_vault_entry() {
  local name="$1" origin="" rel
  valid_name "$name" || return 0
  [[ -f "$ENVORA_VAULT/$name/.origin" ]] && origin="$(head -n 1 "$ENVORA_VAULT/$name/.origin")"
  out "${C_BOLD}$name${C_RST}"
  out "${C_DIM}${origin:-origin unknown} · last save $(vgit log -1 --format=%cr -- "$name" 2>/dev/null)${C_RST}"
  out ""
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && out "  $rel"
  done <<EOF
$(vault_project_files "$name")
EOF
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && out "  ${C_DIM}▲ $rel${C_RST}"
  done <<EOF
$(vault_snapshot_files "$name")
EOF
  out ""
  if [[ -d "$ENVORA_PROJECTS/$name" ]]; then
    out "${C_DIM}local folder: $ENVORA_PROJECTS/$name${C_RST}"
  else
    out "${C_DIM}not on this machine ($ENVORA_PROJECTS/$name)${C_RST}"
  fi
}

preview_vault_restore() {
  local name="$1" item="$2"
  valid_name "$name" || return 0
  if [[ "$item" == v-clone ]]; then
    out "${C_BOLD}Clone + restore${C_RST}"
    out ""
    out "  1. git clone $(head -n 1 "$ENVORA_VAULT/$name/.origin" 2>/dev/null) $ENVORA_PROJECTS/$name"
    out "  2. restore its env files from the vault:"
    vault_project_files "$name" | sed 's/^/       /'
    return 0
  fi
  ARG_C="$ENVORA_PROJECTS/$name"
  ARG_AS="$name"
  set_project_dir "$ARG_C" 2>/dev/null || return 0
  PROJECT_NAME="$name"
  if [[ "$item" == v-compare ]]; then
    save_plan
    status_report
  else
    preview_restore
  fi
}

preview_forget() {
  local name="$1"
  valid_name "$name" || return 0
  out "${C_BOLD}✕ Forget $name${C_RST}"
  out ""
  out "removes these files from the vault (asks first):"
  vault_project_files "$name" | sed 's/^/  /'
  out ""
  out "${C_DIM}old versions stay in git history; your project folder is not touched${C_RST}"
}
