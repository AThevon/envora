#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $vars are for fzf/awk/jq, on purpose
# lib/menu.sh - interactive menu: one action per line, live plan in the preview
#
# Actions run as a child "ev <command>" process, so each one has its own
# cleanup and exit code; then the menu comes back.

FZF_MIN="0.59"

fzf_version() {
  fzf --version 2>/dev/null | awk '{print $1; exit}'
}

# True when fzf is recent enough for the menu (--no-input, load:pos...).
fzf_recent() {
  local v maj min
  v="$(fzf_version)"
  maj="${v%%.*}"
  min="${v#*.}"
  min="${min%%.*}"
  case "$maj$min" in ''|*[!0-9]*) return 1 ;; esac
  [[ $maj -gt 0 || $min -ge 59 ]]
}

FZF_COLORS="fg:#c5cbd3,fg+:#e6e9ed,bg+:#1f2328,hl:#6fcf7c,hl+:#6fcf7c,pointer:#6fcf7c,prompt:#6fcf7c,header:#808894,border:#3a3f46,label:#6fcf7c,info:#808894,separator:#3a3f46,scrollbar:#3a3f46,preview-border:#3a3f46,preview-label:#808894"

# Run "ev ARGS..." as a child process, then wait for a key so its report
# stays on screen. Never exits the menu; returns 1 when you press q.
menu_run() {
  local rc=0 key=""
  printf '\n' >&2
  "$ENVORA_BASH" "$ENVORA_SELF" "$@" || rc=$?
  case "$rc" in
    0) ;;
    3) warn "saved on this machine, not on GitHub yet: use Sync with GitHub when you are online" ;;
    *) warn "the action did not complete (exit $rc): see the messages above" ;;
  esac
  printf '\n%spress any key to go back to the menu · q to quit%s' "$C_DIM" "$C_RST" >&2
  IFS= read -rsn1 key </dev/tty 2>/dev/null || true
  printf '\n' >&2
  [[ "$key" == q || "$key" == Q ]] && return 1
  return 0
}

# menu_fzf LABEL HEADER [POS] [SEP] < items  ->  chosen id
# The cursor starts on line POS (the last action), the preview sits on the
# right when it has room (at least 52 columns), else below, kept small so
# every menu line stays visible. SEP is the line of the separator (if any):
# moving with the arrows or j / k jumps over it.
MENU_FZF_RC=0
menu_fzf() {
  local label="$1" header="$2" pos="${3:-1}" sep="${4:-0}" choice
  local down='down' up='up'
  MENU_FZF_RC=0
  case "$pos" in ''|*[!0-9]*) pos=1 ;; esac
  case "$sep" in ''|*[!0-9]*) sep=0 ;; esac
  if [[ $sep -gt 1 ]]; then
    # {n} is the 0-based index of the current line
    down="transform:[ {n} -eq $((sep - 2)) ] && echo down+down || echo down"
    up="transform:[ {n} -eq $sep ] && echo up+up || echo up"
  fi
  choice="$(ENVORA_COLOR=1 fzf --ansi --no-sort --no-input --layout=reverse \
    --height=85% --min-height=24 --border=rounded --border-label=" $label " \
    --delimiter=$'\t' --with-nth=2 --header="$header" --header-first \
    --pointer='›' --color="$FZF_COLORS" \
    --preview='"$ENVORA_BASH" "$ENVORA_SELF" _preview {1}' \
    --preview-window='right,40%,wrap,border-left,<44(down,40%,wrap,border-top)' \
    --bind="load:pos($pos)" \
    --bind='?:preview("$ENVORA_BASH" "$ENVORA_SELF" _preview keys)' \
    --bind="down:$down" --bind="j:$down" --bind="up:$up" --bind="k:$up" \
    --bind='q:abort')" || MENU_FZF_RC=$?
  [[ $MENU_FZF_RC == 0 ]] || return 1
  printf '%s' "${choice%%$'\t'*}"
}

# fzf exit codes: 1 no match, 130 esc / q. Anything else is an error.
menu_fzf_failed() {
  case "$MENU_FZF_RC" in
    0|1|130) return 1 ;;
  esac
  err "fzf failed (exit $MENU_FZF_RC): try 'ev doctor', or use the commands directly (ev help)"
  return 0
}

# Line number of item ID in a list of "id<TAB>label" lines.
menu_pos_of() {
  awk -F '\t' -v id="$1" '$1 == id { print NR; exit }'
}

menu_header_project() {
  local plan="$TMP_ROOT/plan.save" n_vault changed new missing stale conflict parts=()
  n_vault="$(vault_project_files "$PROJECT_NAME" | grep -c . || true)"
  changed="$(plan_count "$plan" changed)"
  new="$(plan_count "$plan" new)"
  missing="$(plan_count "$plan" vaultonly)"
  stale="$(plan_count "$plan" stale)"
  conflict="$(plan_count "$plan" conflict)"
  local state
  if [[ "$n_vault" -eq 0 ]]; then
    state="not saved yet"
    [[ "$new" -gt 0 ]] && state="not saved yet · $(plural "$new" "env file") here"
  else
    parts[${#parts[@]}]="$(plural "$n_vault" file) saved"
    if [[ $((changed + new + missing + stale + conflict)) -eq 0 ]]; then
      parts[${#parts[@]}]="in sync"
    else
      [[ $((changed + new)) -gt 0 ]] && parts[${#parts[@]}]="$((changed + new)) to save"
      [[ "$stale" -gt 0 ]] && parts[${#parts[@]}]="$stale newer in the vault"
      [[ "$conflict" -gt 0 ]] && parts[${#parts[@]}]="$conflict changed on both sides"
      [[ "$missing" -gt 0 ]] && parts[${#parts[@]}]="$missing missing here"
    fi
    state="$(join_by ' · ' "${parts[@]}")"
  fi
  printf '%s%s%s  %s\n%s%s%s' "$C_BOLD" "$PROJECT_NAME" "$C_RST" "$state" "$C_DIM" "vault: $(vault_sync_label) · ? keys" "$C_RST"
}

# pad TEXT WIDTH: TEXT followed by spaces up to WIDTH characters. printf
# pads bytes, and an arrow is 3 bytes: UTF-8 continuation bytes are not
# counted (whatever the locale).
pad() {
  local n
  n="$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c)"
  n=$((n + 0))
  printf '%s%*s' "$1" $(($2 > n ? $2 - n : 1)) ''
}

# menu_line ID ICON LABEL DIRECTION DESCRIPTION [dim]
# One menu line, in columns: icon, verb (20), where data goes (20), what for.
menu_line() {
  local id="$1" icon="$2" label="$3" dir="$4" desc="$5" ic="$C_ACC"
  [[ "${6:-}" == dim ]] && ic="$C_DIM"
  printf '%s\t%s%s%s  %s%s%s%s%s%s%s\n' "$id" "$ic" "$icon" "$C_RST" "$(pad "$label" 20)" \
    "$C_ACC" "$(pad "$dir" 20)" "$C_RST" "$C_DIM" "$desc" "$C_RST"
}

menu_items_project() {
  menu_line save "↑" "Save" "project → vault" "encrypt env files"
  menu_line restore "↓" "Restore" "vault → project" "write them back here"
  menu_line compare "≈" "Compare" "project ↔ vault" "key names only"
  if vercel_relevant; then
    menu_line import-vercel "▲" "Import Vercel" "Vercel → vault" "snapshot Vercel vars"
    menu_line export-vercel "▲" "Send to Vercel" "vault → Vercel" "add / update vars"
  fi
  if cloudflare_relevant; then
    menu_line export-cloudflare "☁" "Send to Cloudflare" "vault → Cloudflare" "$(cloudflare_kinds) secrets"
  fi
  menu_items_global
}

menu_items_global() {
  printf 'sep\t%s%s%s\n' "$C_DIM" "──────────────────────────────── whole vault" "$C_RST"
  menu_line browse "≡" "Browse vault" "vault" "every saved project" dim
  menu_line sync "⇅" "Sync with GitHub" "vault ↔ GitHub" "pull + push now" dim
  menu_line doctor "✚" "Doctor" "" "check the setup" dim
  menu_line config "⚙" "Settings" "" "paths and repo" dim
  menu_line rotate "⟳" "Rotate key" "vault" "new key, re-encrypt" dim
}

# The folder the menu acts on: -C, else the current folder (in a monorepo,
# Send to Vercel / Cloudflare pick the config around it, like the CLI).
menu_dir() {
  if [[ -n "${ARG_C:-}" ]]; then abs_dir "$ARG_C"; else pwd -P; fi
}

cmd_menu() {
  ui_logo
  # Show what the sync did (a conflict resolved, offline...) before the menu.
  vault_pull >/dev/null 2>"$TMP_ROOT/menu.pull" || true
  vault_unlock
  if [[ -s "$TMP_ROOT/menu.pull" ]]; then
    cat "$TMP_ROOT/menu.pull" >&2
    printf '\n%spress any key to open the menu%s' "$C_DIM" "$C_RST" >&2
    local key=""
    IFS= read -rsn1 key </dev/tty 2>/dev/null || true
    printf '\n' >&2
  fi
  local_index_build
  export ENVORA_LOCAL_INDEX="$LOCAL_INDEX"
  local choice in_project=0 mdir
  mdir="$(menu_dir)"
  if detect_current_project 2>/dev/null; then
    in_project=1
    export ENVORA_MENU_DIR="$mdir"
    export ENVORA_MENU_AS="${ARG_AS:-}"
  fi
  local items pos=1 rc=0 sep
  while true; do
    if [[ $in_project == 1 ]]; then
      save_plan 2>/dev/null || true
      items="$(menu_items_project)"
      sep="$(printf '%s\n' "$items" | menu_pos_of sep)"
      choice="$(printf '%s\n' "$items" | menu_fzf "envora · project" "$(menu_header_project)" "$pos" "$sep")" || {
        menu_fzf_failed && return 1
        return 0
      }
    else
      items="$(menu_items_global | sed 1d)"
      choice="$(printf '%s\n' "$items" | menu_fzf "envora" "${C_BOLD}envora${C_RST} ${C_DIM}v$VERSION · not in a project${C_RST}"$'\n'"${C_DIM}vault: $(vault_sync_label) · ? keys${C_RST}" "$pos")" || {
        menu_fzf_failed && return 1
        return 0
      }
    fi
    pos="$(printf '%s\n' "$items" | menu_pos_of "$choice")"
    local cargs=()
    if [[ $in_project == 1 ]]; then
      cargs=(-C "$mdir")
      [[ -n "${ARG_AS:-}" ]] && cargs=(-C "$mdir" --as "$ARG_AS")
    fi
    rc=0
    case "$choice" in
      save) menu_run save ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      restore) menu_run restore ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      compare) menu_run status ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      import-vercel) menu_run import vercel ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      export-vercel) menu_run export vercel ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      export-cloudflare) menu_run export cloudflare ${cargs[@]+"${cargs[@]}"} || rc=$? ;;
      browse) menu_browse ;;
      sync) menu_run sync || rc=$? ;;
      doctor) menu_run doctor || rc=$? ;;
      config) "$ENVORA_BASH" "$ENVORA_SELF" config || true ;;
      rotate) menu_run rotate || rc=$? ;;
      *) ;;
    esac
    [[ $rc == 0 ]] || return 0
    # The vault may have moved (save, sync, clone): refresh the state.
    SYNC_STATE=""
    local_index_build
  done
}

menu_items_vault() {
  local name n dir
  vault_projects | while IFS= read -r name; do
    n="$(vault_project_files "$name" | grep -c . || true)"
    dir="$(local_dir_of "$name")"
    if [[ -n "$dir" ]]; then
      printf 'p:%s\t%s◆%s  %-28s %s%s · %s%s\n' "$name" "$C_ACC" "$C_RST" "$name" "$C_DIM" "$(plural "$n" file)" "$(tildify "$dir")" "$C_RST"
    else
      printf 'p:%s\t%s◇%s  %-28s %s%s · not on this machine%s\n' "$name" "$C_DIM" "$C_RST" "$name" "$C_DIM" "$(plural "$n" file)" "$C_RST"
    fi
  done
}

menu_browse() {
  local name choice
  local items pos=1
  while true; do
    items="$(menu_items_vault)"
    if [[ -z "$items" ]]; then
      say "the vault is empty: use Save inside a project first"
      return 0
    fi
    choice="$(printf '%s\n' "$items" | menu_fzf "vault" "${C_BOLD}vault${C_RST} ${C_DIM}$(tildify "$ENVORA_VAULT") · enter: actions · esc back${C_RST}" "$pos")" || return 0
    pos="$(printf '%s\n' "$items" | menu_pos_of "$choice")"
    name="${choice#p:}"
    valid_name "$name" || continue
    menu_vault_project "$name"
    local_index_build
  done
}

# Where "Clone + restore" puts a project: ENVORA_PROJECTS/<name>.
clone_target() {
  printf '%s/%s' "$ENVORA_PROJECTS" "$1"
}

menu_vault_project() {
  local name="$1" dir choice origin target items
  origin="$(entry_origin "$name")"
  dir="$(local_dir_of "$name")"
  target="$(clone_target "$name")"
  export ENVORA_MENU_PROJECT="$name" ENVORA_MENU_PROJECT_DIR="$dir"
  if [[ -n "$dir" ]]; then
    items="$(menu_line v-restore "↓" "Restore" "vault → project" "into $(tildify "$dir")")"$'\n'"$(menu_line v-compare "≈" "Compare" "project ↔ vault" "key names only")"
  elif [[ -n "$origin" && ! -e "$target" ]]; then
    items="$(menu_line v-clone "↓" "Clone + restore" "GitHub + vault" "into $(tildify "$target")")"
  elif [[ -n "$origin" ]]; then
    items="v-none"$'\t'"${C_DIM}·  $(tildify "$target") exists but is another project: clone $name elsewhere, then ev restore -C <dir>${C_RST}"
  else
    items="v-none"$'\t'"${C_DIM}·  no local folder and no known origin: clone it yourself, then ev restore -C <dir> --as $name${C_RST}"
  fi
  items="$items"$'\n'"$(menu_line v-forget "✕" "Forget" "vault" "remove $name from the vault" dim)"
  choice="$(printf '%s\n' "$items" | menu_fzf "$name" "${C_BOLD}$name${C_RST} ${C_DIM}esc back${C_RST}")" || return 0
  case "$choice" in
    v-restore) menu_run restore -C "$dir" --as "$name" || true ;;
    v-compare) menu_run status -C "$dir" --as "$name" || true ;;
    v-clone)
      if confirm "git clone $origin $(tildify "$target"), then restore its env files?"; then
        if git clone "$origin" "$target"; then
          menu_run restore -C "$target" --as "$name" || true
        else
          warn "git clone failed"
        fi
      fi
      ;;
    v-forget) menu_run forget "$name" || true ;;
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
    sep)
      out "${C_BOLD}whole vault${C_RST}"
      out ""
      out "${C_DIM}the actions below this line work on the whole vault (every project), not only on this one${C_RST}"
      return 0
      ;;
    config)
      if [[ -n "${2:-}" ]]; then config_preview "$2"; else config_print; fi
      return 0
      ;;
  esac
  preview_need_vault || return 0
  case "$item" in
    save) preview_project && preview_save ;;
    restore) preview_project && preview_restore ;;
    compare)
      preview_project && {
        preview_title "≈ Compare" "project ↔ vault" "what differs between your files and the vault (key names only)"
        save_plan
        status_report
      }
      ;;
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
  out "  ↑ ↓  or  j k     move (the preview shows what would happen)"
  out "  enter            run the selected action"
  out "  ?                this help (move to close it)"
  out "  shift ↑ ↓        scroll this preview"
  out "  esc  or  q       back / quit"
  out ""
  out "${C_BOLD}reading the previews${C_RST}"
  out ""
  out "  ${C_ACC}+${C_RST} new   ${C_WARN}~${C_RST} changed   ${C_WARN}↓${C_RST} newer in the vault   ${C_ERR}!${C_RST} changed on both sides"
  out "  = identical, skipped   · not handled (tracked by git, only on one side)"
  out "  values are never shown, only key names"
  out ""
  out "${C_BOLD}where things go${C_RST}"
  out ""
  out "  ${C_BOLD}PROJECT${C_RST}    ${C_DIM}your .env files (git ignores them)${C_RST}"
  out "    ${C_ACC}↑ save${C_RST}     project → vault"
  out "    ${C_ACC}↓ restore${C_RST}  vault → project"
  out "  ${C_BOLD}VAULT${C_RST}      ${C_DIM}encrypted copies, a git repo${C_RST}"
  out "    ${C_ACC}⇅ sync${C_RST}     vault ↔ GitHub (private repo)"
  out "    ${C_ACC}→ send${C_RST}     vault → Vercel / Cloudflare  ${C_DIM}(ev export)${C_RST}"
  out "    ${C_ACC}← import${C_RST}   Vercel → vault (snapshots)  ${C_DIM}(ev import)${C_RST}"
}

# What applying the project file to the vault (save) or the vault file to the
# project (restore) does to the keys, names only.
# key_effect REL save|restore -> "adds A · drops B from the vault copy · updates C"
key_effect() {
  local rel="$1" dir="$2" diff line adds=() drops=() chg=() parts=()
  diff="$({
    dotenv_json a <"$PROJECT_DIR/$rel"
    decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$rel.age" 2>/dev/null | dotenv_json b
  } | dotenv_diff_stream 2>/dev/null)" || { printf 'could not compare the keys'; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "a "*) if [[ $dir == save ]]; then adds[${#adds[@]}]="${line#a }"; else drops[${#drops[@]}]="${line#a }"; fi ;;
      "b "*) if [[ $dir == save ]]; then drops[${#drops[@]}]="${line#b }"; else adds[${#adds[@]}]="${line#b }"; fi ;;
      "~ "*) chg[${#chg[@]}]="${line#\~ }" ;;
    esac
  done <<<"$diff"
  if [[ $dir == save ]]; then
    [[ ${#adds[@]} -gt 0 ]] && parts[${#parts[@]}]="adds $(short_list 4 "${adds[@]}") to the vault"
    [[ ${#drops[@]} -gt 0 ]] && parts[${#parts[@]}]="drops $(short_list 4 "${drops[@]}") from the vault copy"
    [[ ${#chg[@]} -gt 0 ]] && parts[${#parts[@]}]="updates $(short_list 4 "${chg[@]}")"
  else
    [[ ${#adds[@]} -gt 0 ]] && parts[${#parts[@]}]="adds $(short_list 4 "${adds[@]}") here"
    [[ ${#drops[@]} -gt 0 ]] && parts[${#parts[@]}]="removes $(short_list 4 "${drops[@]}") from your file"
    [[ ${#chg[@]} -gt 0 ]] && parts[${#parts[@]}]="sets $(short_list 4 "${chg[@]}") to the vault value"
  fi
  if [[ ${#parts[@]} -eq 0 ]]; then
    printf 'same keys and values, only the formatting differs'
  else
    join_by ' · ' "${parts[@]}"
  fi
}

# Origin check for previews: one line instead of a refusal.
preview_origin_ok() {
  if ! check_origin "$PROJECT_NAME" >/dev/null 2>&1; then
    out "${C_ERR}✗ the vault entry '$PROJECT_NAME' belongs to another repository${C_RST}"
    out "${C_DIM}  ($(entry_origin "$PROJECT_NAME")): run it to see how to proceed${C_RST}"
    out ""
    return 1
  fi
  return 0
}

preview_save() {
  preview_title "↑ Save" "project → vault" "encrypt the env files of $PROJECT_NAME into the vault, then push to GitHub"
  preview_origin_ok || return 0
  save_plan
  local plan="$TMP_ROOT/plan.save" st rel any=0
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      new) out "  ${C_ACC}+${C_RST} $rel  ${C_DIM}new → encrypted into the vault${C_RST}"; any=1 ;;
      changed)
        out "  ${C_WARN}~${C_RST} $rel  ${C_DIM}changed here → replaces the vault copy${C_RST}"
        out "      ${C_DIM}$(key_effect "$rel" save)${C_RST}"
        any=1
        ;;
      conflict)
        out "  ${C_ERR}!${C_RST} $rel  ${C_DIM}changed here AND in the vault ($(vault_file_commit "$rel")) → you will be asked${C_RST}"
        out "      ${C_DIM}$(key_effect "$rel" save)${C_RST}"
        any=1
        ;;
    esac
  done <"$plan"
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      same) out "  ${C_DIM}= $rel  identical, skipped${C_RST}" ;;
      stale) out "  ${C_WARN}↓${C_RST} $rel  ${C_DIM}newer in the vault, unchanged here since your last save/restore → skipped (use Restore)${C_RST}" ;;
      tracked) out "  ${C_DIM}· $rel  tracked by git, skipped${C_RST}" ;;
      vaultonly) out "  ${C_DIM}· $rel  only in the vault, kept there${C_RST}" ;;
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
  preview_origin_ok || return 0
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
        out "      ${C_DIM}$(key_effect "$rel" restore)${C_RST}"
        any=1
        ;;
      stale)
        out "  ${C_WARN}↓${C_RST} $rel  ${C_DIM}newer in the vault ($(vault_file_commit "$rel")) → updated; a backup is kept${C_RST}"
        out "      ${C_DIM}$(key_effect "$rel" restore)${C_RST}"
        any=1
        ;;
      invalid) out "  ${C_ERR}✗${C_RST} $rel  ${C_DIM}refused (not an env file name / unsafe path)${C_RST}" ;;
    esac
  done <"$plan"
  while IFS=$'\t' read -r st rel; do
    case "$st" in
      same) out "  ${C_DIM}= $rel  identical, skipped${C_RST}" ;;
      tracked) out "  ${C_DIM}· $rel  tracked by git here, skipped${C_RST}" ;;
    esac
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
      out "  linked: $(dir_label "$(rel_of_dir "$d")") → vault/$PROJECT_NAME/$(vercel_snapshot_rel "$(rel_of_dir "$d")" "<env>")"
    done <<<"$dirs"
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
  out "${C_DIM}Snapshots are never written into your project: read them with ev status --values."
  out "Secret variables are write-only on Vercel: their value comes back as"
  out "[SENSITIVE]. envora keeps the value of the previous snapshot when it has one.${C_RST}"
}

# The config folder an export would use (same choice as the command), or
# nothing when it would have to ask.
preview_pick() {
  pick_dir "$1" "$2" 2>/dev/null </dev/null || true
}

preview_export_vercel() {
  preview_title "▲ Send to Vercel" "vault → Vercel" "add / update Vercel env vars from a file saved in the vault"
  preview_origin_ok || return 0
  local dirs pdir reldir e f any=0
  dirs="$(vercel_dirs)"
  if [[ -z "$dirs" ]]; then
    out "not linked to Vercel yet (no .vercel/project.json)"
    out "${C_DIM}running it will offer 'vercel link'${C_RST}"
    return 0
  fi
  pdir="$(preview_pick Vercel "$dirs")"
  if [[ -z "$pdir" ]]; then
    out "several folders are linked to Vercel; running it asks which one:"
    while IFS= read -r pdir; do out "  $(dir_label "$(rel_of_dir "$pdir")")"; done <<<"$dirs"
    return 0
  fi
  reldir="$(rel_of_dir "$pdir")"
  out "  linked folder: $(dir_label "$reldir")"
  for e in production preview development; do
    f="$(in_dir "$reldir" ".env.$e")"
    if [[ -f "$ENVORA_VAULT/$PROJECT_NAME/$f.age" ]]; then
      out "  vault/$PROJECT_NAME/$f  ${C_ACC}→${C_RST} Vercel $e  ${C_DIM}($(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$f.age" 2>/dev/null | dotenv_keys | grep -c . || true) vars)${C_RST}"
      any=1
    fi
  done
  [[ $any == 0 ]] && out "no $(in_dir "$reldir" .env.production) / .env.preview / .env.development saved (use --file / --env from the CLI)"
  out ""
  out "${C_DIM}running it reads 'vercel env ls', shows add / update / kept, and asks before"
  out "sending. Values go through stdin. Nothing is ever deleted on Vercel."
  out "A variable shared with other environments is only updated if you say so.${C_RST}"
}

preview_export_cloudflare() {
  preview_title "☁ Send to Cloudflare" "vault → Cloudflare" "upload a saved file as Worker / Pages secrets"
  preview_origin_ok || return 0
  local dirs d reldir file keys target
  dirs="$(cloudflare_dirs)"
  d="$(preview_pick Cloudflare "$dirs")"
  if [[ -z "$d" ]]; then
    out "several wrangler configs in this project; running it asks which one:"
  else
    dirs="$d"
  fi
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    reldir="$(rel_of_dir "$d")"
    if ! cf_read_config "$d"; then
      out "  ${C_ERR}✗${C_RST} $(in_dir "$reldir" "$(basename "${CF_CFG:-wrangler.json}")")  ${C_DIM}cannot be read (invalid JSON?)${C_RST}"
      continue
    fi
    target="Worker ${CF_NAME:-?} (deployed, top-level)"
    [[ "$CF_PAGES" == 1 ]] && target="Pages project ${CF_NAME:-?} (production)"
    out "  $(cf_kind) ${C_BOLD}${CF_NAME:-?}${C_RST}  ${C_DIM}$(in_dir "$reldir" "$(basename "$CF_CFG")")${C_RST}"
    local saved e f
    saved="$(cf_saved_envs "$reldir" "$CF_PAGES")"
    if file="$(cf_source_file "$reldir" "")"; then
      keys="$(decrypt_stream "$ENVORA_VAULT/$PROJECT_NAME/$file.age" 2>/dev/null | dotenv_keys | tr '\n' ' ')"
      out "    vault/$PROJECT_NAME/$file ${C_ACC}→${C_RST} $target"
      out "    ${C_DIM}secrets: $keys${C_RST}"
      case "$(local_vs_vault "$file")" in
        edited) out "    ${C_WARN}! your local $file has changes the vault does not have: save first?${C_RST}" ;;
        stale) out "    ${C_DIM}the vault has a newer $file than your local file: the vault version is sent${C_RST}" ;;
      esac
    elif [[ -z "$saved" ]]; then
      out "    ${C_WARN}no $(in_dir "$reldir" .dev.vars) or $(in_dir "$reldir" .env) saved in the vault: save first${C_RST}"
    else
      out "    ${C_DIM}no $(in_dir "$reldir" .dev.vars) for the deployed $(cf_kind): running it asks which environment${C_RST}"
    fi
    while IFS=$'\t' read -r e f; do
      [[ -n "$e" ]] && out "    vault/$PROJECT_NAME/$f ${C_ACC}→${C_RST} environment $e  ${C_DIM}(ev export cloudflare --env $e)${C_RST}"
    done <<<"$saved"
  done <<<"$dirs"
  out ""
  out "${C_DIM}running it compares names with 'wrangler secret list', shows the plan and asks:"
  out "secrets deploy immediately. Values are piped, never written to disk."
  out "Nothing is deleted on Cloudflare."
  out "Without --env: .dev.vars goes to the deployed Worker (Pages: production)."
  out "With --env e: .dev.vars.<e> goes to environment e.${C_RST}"
}

preview_browse() {
  preview_title "≡ Browse vault" "vault" "every project saved in the vault"
  local name n dir
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    n="$(vault_project_files "$name" | grep -c . || true)"
    dir="$(local_dir_of "$name")"
    if [[ -n "$dir" ]]; then dir="$(tildify "$dir")"; else dir="not on this machine"; fi
    out "  $(printf '%-26s' "$name") ${C_DIM}$(plural "$n" file) · $dir${C_RST}"
  done <<EOF
$(vault_projects)
EOF
}

preview_sync() {
  preview_title "⇅ Sync with GitHub" "vault ↔ GitHub" "pull the other machines' saves, push yours"
  if vault_has_remote; then
    out "  remote: $(sanitize_origin "$(vgit remote get-url origin)")"
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
  local name="$1" origin rel dir
  valid_name "$name" || return 0
  origin="$(entry_origin "$name")"
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
  dir="$(local_dir_of "$name")"
  if [[ -n "$dir" ]]; then
    out "${C_DIM}on this machine: $(tildify "$dir")${C_RST}"
  else
    out "${C_DIM}not on this machine (looked for its git origin under $(tildify "$ENVORA_PROJECTS"))${C_RST}"
  fi
}

preview_vault_restore() {
  local name="$1" item="$2" dir="${ENVORA_MENU_PROJECT_DIR:-}"
  valid_name "$name" || return 0
  if [[ "$item" == v-clone ]]; then
    out "${C_BOLD}Clone + restore${C_RST}"
    out ""
    out "  1. git clone $(entry_origin "$name") $(tildify "$(clone_target "$name")")"
    out "  2. restore its env files from the vault:"
    vault_project_files "$name" | sed 's/^/       /'
    return 0
  fi
  [[ -n "$dir" ]] || return 0
  ARG_C="$dir"
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
  local name="$1" snaps
  valid_name "$name" || return 0
  out "${C_BOLD}✕ Forget $name${C_RST}"
  out ""
  out "removes these files from the vault (asks first):"
  vault_project_files "$name" | sed 's/^/  /'
  snaps="$(vault_snapshot_files "$name")"
  if [[ -n "$snaps" ]]; then
    out "and its Vercel snapshots:"
    printf '%s\n' "$snaps" | sed 's/^/  ▲ /'
  fi
  out ""
  out "${C_DIM}old versions stay in git history; your project folder is not touched${C_RST}"
}
