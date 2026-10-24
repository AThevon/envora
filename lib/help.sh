#!/usr/bin/env bash
# lib/help.sh - help texts (every command shows where data goes)

help_diagram() {
  local a="$C_ACC" d="$C_DIM" r="$C_RST" b="$C_BOLD"
  cat <<EOF
  ${b}PROJECT${r}                 ${b}VAULT${r}                     ${b}GITHUB${r}
  ${d}your .env files${r}         ${d}encrypted copies (git)${r}    ${d}private repo${r}
     │   ${a}save    →${r}            │   ${a}sync    ↔${r}             │
     │   ${a}← restore${r}            │                         │
     │   ${a}status  ↔${r}            │                         │
                              │   ${a}export  →${r}   ${b}PLATFORMS${r}
                              │   ${a}← import${r}    ${d}Vercel, Cloudflare${r}
EOF
}

help_overview() {
  local a="$C_ACC" d="$C_DIM" r="$C_RST" b="$C_BOLD"
  cat <<EOF
${b}envora${r} ${d}v$VERSION · encrypted vault for your untracked .env files${r}

$(help_diagram)

${b}PROJECT ↔ VAULT${r}
  ${a}ev save${r}      [-C dir] [--as name]   project → vault    encrypt this project's env files, commit, push
  ${a}ev restore${r}   [name] [--force]       vault → project    write the saved files back (asks before overwriting)
  ${a}ev status${r}    [name] [--values]      project ↔ vault    what differs, key names only (--values: real diff)

${b}VAULT${r}
  ${a}ev list${r}                             vault              every project in the vault
  ${a}ev forget${r}    <name> [file]          vault              remove a project (or one file) from the vault

${b}VAULT ↔ GITHUB${r}
  ${a}ev sync${r}                             vault ↔ GitHub     pull, merge, push; reports what moved

${b}VAULT ↔ PLATFORMS${r}
  ${a}ev import vercel${r}   [--env e]        Vercel → vault     snapshot Vercel env vars into the vault
  ${a}ev export cloudflare${r} [--env e]      vault → Cloudflare upload secrets to the Worker / Pages project
  ${a}ev export vercel${r}   [--env e]        vault → Vercel     add / update Vercel env vars

${b}MAINTENANCE${r}
  ${a}ev${r}                                  interactive menu with a live preview of every action
  ${a}ev doctor${r}                           check the setup, with a fix for each problem
  ${a}ev rotate${r}    [--pq]                 new key, re-encrypt everything
  ${a}ev init${r}                             first-time or new-machine setup
  ${a}ev config${r}    [get|set ...]          settings (~/.envorarc)
  ${a}ev help${r}      <command>              details for one command

${b}GLOBAL FLAGS${r} ${d}(anywhere on the line)${r}
  -y, --yes      no prompts, safe defaults (backups before overwriting)
  -q, --quiet    only errors and warnings, one line each, on stderr
  -C <dir>       act on the project in <dir>
  --no-sync      do not talk to GitHub (local vault only)
  -h, --help     help · -v, --version

${b}EXIT CODES${r}
  0 done (for save: every env file of the folder is in the vault AND on GitHub)
  3 saved and committed in the local vault but NOT pushed to GitHub
  1 error, or some env files are not in the vault: nothing is guaranteed
EOF
}

show_help() {
  local topic="${1:-}" sub="${2:-}"
  local a="$C_ACC" d="$C_DIM" r="$C_RST" b="$C_BOLD"
  case "$topic" in
    ""|help) help_overview ;;
    save|push|push-local)
      cat <<EOF
${b}ev save${r} [name] [-C dir] [--as name]        ${a}project → vault${r}

Encrypts the env files of the project into the vault, commits and pushes to GitHub.
  · finds .env, .env.*, .dev.vars, .dev.vars.* up to 4 levels deep (monorepos)
  · skips *.example *.sample *.template *.dist *.defaults .envrc and files tracked by git
  · only re-encrypts files whose content changed: a no-op save creates no commit
  · files in the vault but missing here are kept (ev forget NAME FILE removes them)
  · two machines: a file you did not edit while another machine saved a newer
    version is left alone (ev restore brings the newer one); a file edited on both
    sides is asked about (with --yes: yours is saved, the other version stays in
    git history and a warning names its commit)

Project name: --as, else the git origin repo name, else the main worktree folder.
The vault entry remembers its origin URL: a different repo with the same name, or a
folder without a git origin, is refused (--as NAME says it really is that project).

${b}exit codes${r} (for scripts, e.g. before deleting a folder)
  0 every env file of the folder is in the vault AND pushed to GitHub (or nothing to save)
  3 saved and committed locally but NOT pushed (offline / rejected): decide yourself
  1 failure, or env files envora does not reach (deeper than 4 levels, inside build/,
    dist/, vendor/) or not saved: nothing is guaranteed, do not delete anything

${d}example: ev save -C ~/projects/app --yes --quiet${r}
EOF
      ;;
    restore|pull)
      cat <<EOF
${b}ev restore${r} [name] [-C dir] [--force]        ${a}vault → project${r}

Writes the saved env files back into the project.
  · identical files are skipped
  · a newer version saved by another machine replaces a copy you did not edit
  · a local file you edited is shown (key names only) and you are asked
  · with --yes, --force or without a terminal: the local file is backed up first
    (encrypted, ~/.local/state/envora/backups/<project>/, last 10 kept), then replaced
  · each file is written atomically with mode 600
  · only env file names are restored, never outside the project folder
  · refused when the vault entry belongs to another repository (--as NAME to force)

NAME outside the project: uses \$ENVORA_PROJECTS/NAME ($ENVORA_PROJECTS).
Exit 0 also when there is nothing to restore.
Read a backup: age -d -i $(tildify "$ENVORA_KEY") <backup>.age (made before a rotation:
use the <key>.bak-<date> kept by ev rotate).

${d}example (after a clone): ev restore -C ~/projects/app --yes --quiet${r}
EOF
      ;;
    status|diff)
      cat <<EOF
${b}ev status${r} [name] [--values]        ${a}project ↔ vault${r}

For each file: in sync, changed (which keys were added, removed or changed: names only),
only in project (not saved yet), only in vault (missing here), tracked by git (skipped).
Files edited here AND saved by another machine are flagged, so are newer vault versions.
Vercel snapshots (ev import vercel) are listed and compared with .env.<env>.
Then the vault ↔ GitHub state: synced, N to push, N to pull, offline.
--values prints a real diff of the changed files and the snapshot contents
(values visible on screen).
EOF
      ;;
    list)
      cat <<EOF
${b}ev list${r}        ${a}vault${r}

Every project in the vault: number of files, last save date, whether the project
folder exists under \$ENVORA_PROJECTS, and platform snapshots.
EOF
      ;;
    sync)
      cat <<EOF
${b}ev sync${r}        ${a}vault ↔ GitHub${r}

Fetches GitHub, integrates other machines' saves, pushes yours.
Every command already does this; use it after working offline.
If two machines changed the same file, the most recent save wins; the other version
stays in git history and the differing keys are listed.
EOF
      ;;
    import|vercel|push-vercel)
      cat <<EOF
${b}ev import vercel${r} [--env e] [-C dir]        ${a}Vercel → vault${r}

Snapshots the Vercel env vars of the linked project into the vault, under
vault/<project>/@vercel/<env>.env. Your project files are never touched.
  · environments: development, preview, production and custom ones (or --env e)
  · VERCEL_OIDC_TOKEN is dropped (short-lived)
  · Secret (sensitive) variables are write-only on Vercel: their value comes back as
    [SENSITIVE]; envora keeps the value from the previous snapshot when it has one
    (it may be stale) and tells you how many stay unknown
  · snapshots are never restored into the project: ev status --values shows them
Uses 'vercel' from PATH, else npx vercel@$VERCEL_PINNED (override: ENVORA_VERCEL_CMD).
EOF
      ;;
    export)
      case "$sub" in
        vercel)
          cat <<EOF
${b}ev export vercel${r} [--env e] [--file f] [--dry-run] [-C dir]        ${a}vault → Vercel${r}

Sends a saved file from the vault to Vercel.
  · default mapping: .env.production → production, .env.preview → preview,
    .env.development → development (otherwise --file and --env)
  · plan by names against 'vercel env ls': add (new), update (existing), kept (only on Vercel)
  · values go through stdin, never on the command line; nothing is deleted
  · a variable that also serves other environments is skipped unless you confirm
    (or --update-shared): updating it changes them all
  · skipped too: keys with branch-specific values, empty values, values over 60 KB
  · asks before applying (--yes to skip, --dry-run to only show the plan)
EOF
          ;;
        *)
          cat <<EOF
${b}ev export cloudflare${r} [--env e] [--file f] [--dry-run] [-C dir]        ${a}vault → Cloudflare${r}

Uploads a saved file from the vault as Worker (or Pages) secrets.
  · source: .dev.vars, else .env; with --env e: .dev.vars.<e>, else .env.<e>
    (never your local .dev.vars unless you pass --file)
  · warns when your local file differs from the vault copy (save first?)
  · plan by names against 'wrangler secret list': add, update, only on Cloudflare (kept)
  · secrets are piped as JSON to 'wrangler secret bulk' (never written to disk);
    Pages projects use 'wrangler pages secret bulk' (production / preview)
  · this deploys immediately: asks first (--yes to skip, --dry-run for the plan only)
  · monorepos: runs wrangler in the folder holding wrangler.toml / wrangler.json(c);
    the one around the current folder is picked, else -C <dir>
Uses 'wrangler' from PATH, else npx wrangler@$WRANGLER_PINNED (override: ENVORA_WRANGLER_CMD).

See also: ev export vercel
EOF
          ;;
      esac
      ;;
    forget|clean)
      cat <<EOF
${b}ev forget${r} [name] [file]        ${a}vault${r}

Removes a project, or one of its files, from the vault (asks first; --yes in scripts).
Without a name, in a terminal: pick the project. Old versions remain in git history.
Paths are relative to the project: ev forget app apps/web/.env.local
EOF
      ;;
    rotate)
      cat <<EOF
${b}ev rotate${r} [--pq]        ${a}vault${r}

Creates a new key, re-encrypts every file of the vault with it, verifies each one,
keeps the old key as <key>.bak-<date>, commits and pushes, then shows the new key once.
The switch cannot be interrupted halfway (Ctrl-C waits for it); if it fails, it rolls
back. Run it again to finish an interrupted rotation or to re-encrypt files another
machine saved with the old key. Other machines: ev init --import-key.
--pq creates a post-quantum hybrid key (age >= 1.3).

Old ciphertexts remain in git history: if your key leaked, also rotate the secrets
themselves at their providers.
EOF
      ;;
    doctor)
      cat <<EOF
${b}ev doctor${r}

Checks tools, key, vault, GitHub sync and the current project (env files not ignored by
git could be committed by mistake). Each problem comes with a fix.
EOF
      ;;
    init)
      cat <<EOF
${b}ev init${r} [--import-key | --generate-key] [--repo user/name | --create name]

First-time or new-machine setup.
  1. key: import your existing envora key (from your password manager) or generate one
  2. vault: clone your existing vault repo, or create a new private one with gh
If the vault was encrypted for another key, init explains it and offers to paste the
right one. --import-key also replaces an existing key (after a rotation on another
machine): the previous one is kept as <key>.bak-<date>.
Without a terminal, --import-key reads the key from stdin.
EOF
      ;;
    config)
      cat <<EOF
${b}ev config${r} [get <setting> | set <setting> <value>]

Settings live in ~/.envorarc; ENVORA_* environment variables override them.
  vault         ENVORA_VAULT      $ENVORA_VAULT
  key           ENVORA_KEY        $ENVORA_KEY
  projects      ENVORA_PROJECTS   $ENVORA_PROJECTS
  repo          ENVORA_REPO       ${ENVORA_REPO:-(not set)}
  vercel-cmd    ENVORA_VERCEL_CMD
  wrangler-cmd  ENVORA_WRANGLER_CMD
EOF
      ;;
    *)
      err "no help for '$topic'"
      help_overview
      return 1
      ;;
  esac
}
