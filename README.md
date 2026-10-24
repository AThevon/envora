<p align="center">
  <img src="assets/logo.svg" alt="envora" width="540" />
</p>

<h1 align="center">envora</h1>

<p align="center">
  <strong>An encrypted vault for the untracked .env files of all your projects</strong><br>
  Save them, restore them on any machine, send them to Vercel or Cloudflare. age encryption, git storage, one key.
</p>

<p align="center">
  <a href="https://github.com/AThevon/envora/releases"><img src="https://img.shields.io/github/v/release/AThevon/envora?style=flat-square&color=6fcf7c" alt="Release" /></a>
  <a href="https://github.com/AThevon/envora/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/AThevon/envora/ci.yml?style=flat-square&color=6fcf7c&label=ci" alt="CI" /></a>
  <a href="https://github.com/AThevon/envora/blob/main/LICENSE"><img src="https://img.shields.io/github/license/AThevon/envora?style=flat-square&color=6fcf7c" alt="License" /></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/nix-flake-6fcf7c?style=flat-square&logo=nixos&logoColor=white" alt="Nix Flake" /></a>
</p>

---

## Three places, and arrows between them

```
  PROJECT                 VAULT                     GITHUB
  your .env files         encrypted copies (git)    private repo
     │   save    →            │   sync    ↔             │
     │   ← restore            │                         │
     │   status  ↔            │                         │
                              │   export  →   PLATFORMS
                              │   ← import    Vercel, Cloudflare
```

- **PROJECT**: the `.env` files in your working copy. Git ignores them, so they exist nowhere else.
- **VAULT**: `~/.env-vault`, a git repo holding an [age](https://github.com/FiloSottile/age)-encrypted copy of each file, synced with a private GitHub repo.
- **PLATFORMS**: Vercel and Cloudflare, where your apps read their variables.

Every command name says which way data moves, and the help, the menu and the previews show the arrow.

## Install

### Nix (recommended)

```nix
# flake.nix inputs
envora = {
  url = "github:AThevon/envora";
  inputs.nixpkgs.follows = "nixpkgs";
};

# packages
envora.packages.${system}.default
```

The package pulls in everything it needs (age, git, jq, fzf, gum, gh).

### Manual

Requires `bash` (3.2 is fine), `age`, `git`, `jq`, and for the interactive menu `fzf` (>= 0.59) and `gum`. `gh` is optional (used by `ev init`). `vercel` and `wrangler` are optional: without them envora runs a pinned version through `npx`.

```bash
git clone https://github.com/AThevon/envora.git ~/.local/share/envora
ln -s ~/.local/share/envora/ev.sh ~/.local/bin/ev   # symlinks are resolved
```

## Quick start

```bash
ev init                      # import your key (or create one), clone (or create) the vault repo
cd ~/projects/my-app
ev save                      # project → vault
ev status                    # project ↔ vault: what differs, key names only
ev restore                   # vault → project (asks before overwriting anything)
ev                           # interactive menu with a live preview of every action
```

## Commands

### PROJECT ↔ VAULT

| Command | Direction | What it does |
|---|---|---|
| `ev save [name] [--as name]` | project → vault | Encrypts the project's env files, commits, pushes to GitHub. Only changed files are re-encrypted, so a no-op save creates no commit. |
| `ev restore [name] [--force]` | vault → project | Writes the saved files back. Identical files are skipped; a file that differs is shown (key names only) and you are asked. With `--yes`, `--force` or no terminal, the local file is backed up (encrypted) first. `--force` only skips the questions: it never makes another repository's entry land here. |
| `ev status [name] [--values]` | project ↔ vault | Per file: in sync, changed (keys added / removed / changed), newer in the vault, changed on both sides, only in project, only in vault. Vercel snapshots compared with your `.env.<env>`. Plus the vault ↔ GitHub state. `--values` prints a real diff and the snapshot contents. |

### VAULT

| Command | Direction | What it does |
|---|---|---|
| `ev list` | vault | Every project: number of files, last save, where it lives on this machine (found by its git origin, not by the folder name), platform snapshots. |
| `ev forget <name> [file]` | vault | Removes a project or one file from the vault (asks first; without a name, a picker). Old versions stay in git history. |

### VAULT ↔ GITHUB

| Command | Direction | What it does |
|---|---|---|
| `ev sync` | vault ↔ GitHub | Fetches, integrates the other machines' saves, pushes yours, reports what moved. Every command already does this; use it after working offline. Exit 0 in sync, 3 commits waiting (offline, refused), 1 error. |

### VAULT ↔ PLATFORMS

| Command | Direction | What it does |
|---|---|---|
| `ev import vercel [--env e]` | Vercel → vault | Snapshots the Vercel env vars into `vault/<project>/@vercel/<env>.env`. Never touches your project files. |
| `ev export cloudflare [--env e] [--file f] [--dry-run]` | vault → Cloudflare | Uploads a saved `.dev.vars` / `.env` (or `.dev.vars.<env>`) as Worker or Pages secrets, after showing the plan. |
| `ev export vercel [--env e] [--file f] [--dry-run] [--update-shared]` | vault → Vercel | Adds / updates Vercel env vars from a saved `.env.production` (etc.), after showing the plan. |

### Maintenance

| Command | What it does |
|---|---|
| `ev` | Interactive menu (context-aware: project actions inside a repo, global ones outside). |
| `ev doctor` | Checks tools, key, vault, GitHub sync and the current project, with a fix for each problem. |
| `ev rotate [--pq]` | New key, every file re-encrypted and verified, old key kept as `<key>.bak-<date>`. |
| `ev init [--import-key]` | First-time or new-machine setup; `--import-key` also replaces a key (after a rotation elsewhere). |
| `ev config [get\|set ...]` | Settings in `~/.envorarc`. |
| `ev help [command]` | Help for one command, with the direction diagram. |

Global flags work anywhere on the line: `-y/--yes` (no prompts, safe defaults), `-q/--quiet` (errors and warnings only, one line each, on stderr), `-C <dir>` (act on the project in that folder), `--no-sync` (local vault only), `-h/--help`, `-v/--version`. A command refuses options it does not use (`ev status --force`, `ev import vercel --dry-run`) instead of ignoring them.

The 0.x names still work for one version and print a hint: `push`, `push-local` → `save`, `pull` → `restore`, `diff` → `status`, `clean` → `forget`, `push-vercel`, `vercel` → `import vercel`.

## The interactive menu

Run `ev` inside a project:

```
 victordenay  3 files saved · 1 to save
 vault: ✓ synced with GitHub · ? keys
 › ↑  Save                project → vault     encrypt this project's env files    │ ↑ Save  (ev save)   project → vault
   ↓  Restore             vault → project     write the saved env files back here │   ~ .env  changed here → replaces the vault copy
   ≈  Compare             project ↔ vault     see what differs (key names only)   │       adds STRIPE_KEY to the vault · updates DB_URL
   ☁  Send to Cloudflare  vault → Cloudflare  upload Worker secrets               │   = apps/web/.env.local  identical, skipped
   ──────────────────────────────── whole vault                                   │
   ≡  Browse vault        vault               every saved project, clone + restore│ then: commit in the vault and push to GitHub
   ⇅  Sync with GitHub    vault ↔ GitHub      bring in other machines' saves, push│
   ...
```

The preview next to each action is a live plan for this project: which files would be written, replaced or skipped and why, what happens to each key (added, dropped, updated: names only, never values), where things go, and which env files a save would not reach. Its title names the matching command (`ev status`, `ev export cloudflare`...), so what you do in the menu works the same on the command line. Vercel items appear when the project is linked (or has a snapshot), the Cloudflare item when a `wrangler.toml` / `wrangler.json(c)` exists. Press `?` for the keys and the symbols. After an action, its report stays on screen until you press a key, then the menu comes back on the same item.

If the sync with GitHub had something to say when the menu opens (offline, a conflict resolved between two machines), it is shown first. In a monorepo, Send to Vercel / Cloudflare use the config around the folder you started `ev` from, like the CLI.

Outside a project, the menu lets you browse the vault and **clone + restore** a project that is not on this machine yet (envora remembers each project's origin URL). A project is "on this machine" when a folder under `~/projects` has its git origin, whatever the folder is called.

## What gets saved

- `.env`, `.env.*`, `.dev.vars`, `.dev.vars.*`, up to 4 levels deep (monorepos), skipping `node_modules`, `vendor`, `dist`, `build`, `.next`, `.nuxt`, `.output`, `.turbo`, `.vercel`, `.wrangler`, `.venv`, `venv`, `target`, `coverage`.
- Never: `*.example`, `*.sample`, `*.template`, `*.dist`, `*.defaults`, `.envrc`.
- Files tracked by git are skipped (git already has them) and reported. `ev doctor` also warns about env files that are not ignored by git.
- Symlinks to regular files are followed.
- Env files the scan does not reach (deeper than 4 levels, or inside `build/` or `dist/`), or whose path holds a newline or a tab, are listed by `ev save` (which then exits 1: the folder is not safe to delete), `ev status`, `ev doctor`, the Save preview and the menu header. Move them, delete them, or list them in a `.envoraignore` at the project root (one pattern per line, e.g. `build/` or `*/fixtures/*`): listed files are neither saved nor reported. Dependency folders (`node_modules`, `vendor`) never count.
- Stored as `vault/<project>/<path>.age`. The project name is the git origin repo name (so worktrees and renamed folders map to the same entry), else the main worktree folder name, or `--as name`. `ev save victor` (a folder under `~/projects`) still uses the folder's git identity. Each entry remembers its origin URL (any `user:token@` part is removed first): saving, restoring or exporting from another repo with the same name, or from a folder without a git origin, is refused, also with `--as` (which only names the entry). When it really is that project, for example after the repo was renamed or moved to an organization, name the entry and confirm: `ev save --as <entry> --force` (it also records the new origin), `ev restore --as <entry> --force`. `--force` alone never does it. GitHub, GitLab and Bitbucket origins are compared without case.

## Two machines

Every command pulls the vault before reading it and pushes after writing, so a restore is never stale. On top of that, envora remembers which vault version each machine last saved or restored, per file:

- you did not touch a file while another machine saved a newer version: `ev save` leaves the newer version alone, `ev restore` brings it here without asking (your copy is backed up anyway);
- you edited a file that another machine also saved meanwhile: `ev save` shows which keys differ and asks; with `--yes` (scripts) it saves yours and prints a warning naming the other machine's commit, which stays in git history;
- a folder that never saved or restored a file (a new worktree, a copy made by hand, files from envora 0.x) cannot tell which side is newer: a copy identical to an older vault version is left alone like an unedited one, anything else that differs is treated as edited on both sides (asked, or a loud warning with `--yes`);
- two machines saving different files at the same time merge cleanly; the same file saved on both sides while offline is resolved newest-wins at sync, with the differing key names printed;
- two different repositories with the same name saved on two machines are never merged into one entry: `ev sync` stops and tells you how to save one of them under another name;
- after `ev rotate`, files another machine saved with the old key are re-encrypted for the new one at the next sync.

## Shell integration

envora is safe to call from scripts. The contract:

| Call | Exit codes |
|---|---|
| `ev restore -C <dir> --yes --quiet` | `0` restored, or nothing to restore (prints nothing). Non-zero only on real errors. |
| `ev save -C <dir> --yes --quiet` | `0` every env file of the folder is in the vault (or there is none) **and** the vault is pushed to GitHub. `3` saved and committed locally but **not** pushed (offline, rejected): you decide. `1` failure, or env files envora does not reach: nothing is guaranteed, do not delete. |

In quiet mode, errors and warnings still go to stderr, one line each (a restore that replaces a file you had edited says so, with the backup location). A restore into a clone of someone else's repository that has the same name as one of yours is refused (exit 1): the secrets of your project never land in it. `-C` refuses `/`, your home, `~/projects` itself and folders that contain several repositories, so a wrong argument cannot save (or let you delete) a whole tree.

```zsh
# clone a repo into ~/projects and bring its env files back
#   clone app            -> git@github.com:<you>/app.git
#   clone some-org/app   -> git@github.com:some-org/app.git
clone() {
  [[ -n $1 ]] || { echo "usage: clone <repo> | <owner>/<repo>"; return 1; }
  local repo="${1%.git}" name
  [[ $repo == */* ]] || repo="<you>/$repo"
  name="${repo##*/}"
  git clone "git@github.com:$repo.git" "$HOME/projects/$name" || return
  ev restore -C "$HOME/projects/$name" --yes --quiet
}

# delete a project folder only once its env files are safe on GitHub
# (-e: in a git worktree, .git is a file)
wipe() {
  [[ -n $1 && $1 != */* && $1 != .* && -e $HOME/projects/$1/.git ]] ||
    { echo "usage: wipe <project>   (a git repo under ~/projects)"; return 1; }
  local dir="$HOME/projects/$1"
  ev save -C "$dir" --yes --quiet
  case $? in
    0) rm -rf -- "$dir" ;;
    3) echo "wipe: saved locally but not on GitHub yet (ev sync), $dir kept"; return 3 ;;
    *) echo "wipe: not everything is in the vault, $dir kept (see above)"; return 1 ;;
  esac
}
```

Do not hide stderr (`2>/dev/null`): the one-line warnings are what tell you why a folder was kept.

## Providers

Both platforms treat secrets as **write-only**: you can set them, list their names, but not read their values back. So the vault is the source of truth, and the platforms are targets.

### Vercel

- `ev import vercel` runs `vercel env pull` for development, preview, production and your custom environments, and stores each one as a snapshot in the vault. `VERCEL_OIDC_TOKEN` (short-lived) is dropped.
- Vercel **Secret** (sensitive) variables come back as `[SENSITIVE]`. envora keeps the value from the previous snapshot when it has one (and says how many values were carried over, since they may have changed on Vercel), and tells you how many values remain unknown. Put the real values in your project files and `ev save` them.
- Snapshots are never written into your project. `ev status` lists them and compares them with your `.env.<env>`; `ev status --values` shows their contents.
- `ev export vercel` compares names with `vercel env ls <env> --format json`, then runs `vercel env add` (new) or `vercel env update` (existing) with the value on **stdin**, never on the command line. Readable values that are already identical are skipped. Nothing is ever deleted.
- One Vercel variable often serves several environments (production, preview, development, custom ones): updating it for one changes them all. Such variables are shown apart and only updated if you confirm (or pass `--update-shared`). Keys that also have branch-specific values, empty values (the CLI cannot receive them), values over 60 KB and names that are not variable names are listed and left alone.
- Values are sent as written: `API=$BASE/api` reaches Vercel literally (Next.js expands `$BASE` locally, Vercel does not). The plan points such values out.
- Every `vercel` call runs with `--non-interactive`, so a prompt can never swallow a value silently.
- Projects linked with `vercel link` (`.vercel/project.json`) or `vercel link --repo` (`.vercel/repo.json`) are recognised. envora uses `vercel` from your PATH, else `npx -y vercel@58.4.0` (`ENVORA_VERCEL_CMD` overrides). If the project is not linked, it offers `vercel link`.

### Cloudflare

- `ev export cloudflare` without `--env` takes the saved `.dev.vars` (else `.env`) and sends it to the **deployed, top-level Worker** (Pages: production); the plan and the prompt say so. With `--env e` it takes the saved `.dev.vars.<e>` (else `.env.<e>`) for environment `e`. When only per-environment files are saved, envora lists them (and asks which one in the menu). `--file` picks any other saved file; a `.dev.vars.<e>` file goes to environment `e` unless you pass `--env=` (the deployed Worker). It warns if your local file differs from the vault copy, compares names with `wrangler secret list`, shows the plan (add / update / only on Cloudflare, never deleted), asks (secrets deploy immediately), then pipes a JSON object to `wrangler secret bulk`. The values never touch the disk or the command line.
- Values are read with the same rules as wrangler (the `dotenv` package, `KEY=value` and `KEY: value`, no `$VAR` expansion): what you send is what `wrangler dev` reads locally.
- Pages projects (`pages_build_output_dir` in the config) use `wrangler pages secret bulk --project-name=<name>` (environments: production, preview). `wrangler.jsonc` comments and trailing commas are handled.
- A Worker that was never deployed gets created by `wrangler secret bulk` with its first secrets: the plan says so.
- More than 100 secrets are sent in batches of 100, and each batch deploys. If a later batch fails, envora says how many secrets are already live.
- In a monorepo, envora uses the wrangler config around the current folder (or `-C <dir>`), runs wrangler in that folder and names the config explicitly (`--config`): on its own, wrangler would pick a `wrangler.json` from a parent folder.
- Cloudflare secrets cannot be imported: there is no way to read them back.
- envora uses `wrangler` from your PATH, else `npx -y wrangler@4.132.0` (`ENVORA_WRANGLER_CMD` overrides).

## New machine

```bash
ev init
```

1. **Key**: choose "I already have an envora key" and paste it from your password manager (it is validated, then saved with mode 600). Only choose "Generate a new key" the very first time.
2. **Vault**: pick your vault repo (or type `user/name`), it is cloned to `~/.env-vault`.
3. If the vault was encrypted for another key, init explains it and offers to paste the right one: nothing is mixed.

Then `ev restore` in each project, or browse the vault from `ev` and clone + restore.

Scripted: `printf '%s\n' "$KEY" | ev init --import-key --repo user/env-vault`.

After `ev rotate` on one machine, the others stop with "encrypted for a different key". Run `ev init --import-key` there and paste the new key: the previous key is kept as `<key>.bak-<date>`, and envora still uses it to read old versions.

## Upgrading from 0.x

- Commands were renamed after the direction they move data (`push-local` → `save`, `pull` → `restore`...). The old names still work for one version and print the new one.
- Projects are now named after their git origin. An entry that 0.x saved under the folder name is still found as long as no entry exists under the new name.
- 0.x stored Vercel snapshots as `.env.development` / `.env.preview` / `.env.production` at the root of the entry, where `ev restore` now writes them into the project (Next.js would load them). `ev doctor` and `ev restore` point them out: run `ev import vercel` (snapshots now live under `@vercel/`, never restored), then `ev forget <project> .env.production` (and the others).

## Security

Be clear about what this protects:

- **Use a private repo.** File contents are encrypted with age before they leave your machine, but the vault still shows metadata: project names, file names, origin URLs, sizes and dates of every save.
- **One key unlocks everything.** Keep it in a password manager. Without it nobody, including you, can decrypt the vault.
- **History keeps old ciphertexts.** `ev rotate` re-encrypts the current files with a new key, but every past version stays in git history, encrypted with the old key. If your key leaked, rotating it is not enough: **rotate the secrets themselves at their providers**.
- `ev rotate` installs the new key before moving any file and cannot be interrupted during the switch; a failure rolls back. Files are always readable with the key in place or with the old one it keeps.
- `ev rotate --pq` creates a post-quantum hybrid key (ML-KEM-768 + X25519, needs age >= 1.3).
- Plaintext only lives in private temp directories (mode 700) that are removed on exit, including on Ctrl-C. Restored files are written atomically with mode 600 (through a temp file named like the target, so your `.env*` ignore rules cover it). Backups made before overwriting a file are encrypted (`~/.local/state/envora/backups/<project>/`, last 10 kept; read one with `age -d -i ~/.age/key.txt <file>.age`).
- envora only ever commits its own files in the vault (`*.age`, `.recipient`, `.gitattributes`, `<project>/.origin`), and never an encrypted file that your key cannot decrypt. Anything else in the vault folder stays uncommitted.
- Restore only writes env file names, never inside `.git` or dependency folders, and never outside the project folder, even if the vault contains something else. A file that is a link you made to somewhere outside the project is only written through on an explicit yes in a terminal.
- `~/.envorarc` is parsed, never executed.

## Configuration

`~/.envorarc`, edited with `ev config` (or `ev config set <setting> <value>`). Lines are `KEY=value` (spaces around `=` are fine); an unknown `ENVORA_` key is reported. Any `ENVORA_*` environment variable overrides the file, and is never written to it: `ev config set` only writes what the file already had plus the setting you change.

| Setting | Default | Meaning |
|---|---|---|
| `ENVORA_VAULT` | `~/.env-vault` | the local vault repo |
| `ENVORA_KEY` | `~/.age/key.txt` | your age key |
| `ENVORA_PROJECTS` | `~/projects` | where `ev restore NAME` looks for `NAME` |
| `ENVORA_REPO` | set by `ev init` | the GitHub repo `ev init` clones or creates (`user/name`); afterwards the vault syncs with its own git remote |
| `ENVORA_VERCEL_CMD` | `vercel` or pinned `npx` | command used for Vercel (words split on spaces, no quotes, a leading `~` is expanded: use a small script for anything else) |
| `ENVORA_WRANGLER_CMD` | `wrangler` or pinned `npx` | command used for Cloudflare (same rule) |

## Development

```bash
bash tests/run.sh            # full suite, sandboxed (own HOME, local bare remote, stub vercel/wrangler/gh)
/bin/bash tests/run.sh       # same on macOS bash 3.2
bash tests/run.sh rotate     # only tests whose name contains "rotate"
shellcheck -x -a ev.sh tests/run.sh
```

Code map: `ev.sh` (flags, dispatch), `lib/commands.sh` (save, restore, status, list, forget, sync), `lib/vault.sh` (git sync and conflict handling), `lib/project.sh` (identity, file scan), `lib/crypto.sh`, `lib/rotate.sh`, `lib/init.sh`, `lib/doctor.sh`, `lib/menu.sh`, `lib/providers/{common,vercel,cloudflare}.sh`.

## License

MIT
