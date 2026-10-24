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
     │   status  ↔            │
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
| `ev save [name] [-C dir] [--as name]` | project → vault | Encrypts the project's env files, commits, pushes to GitHub. Only changed files are re-encrypted, so a no-op save creates no commit. |
| `ev restore [name] [-C dir] [--force]` | vault → project | Writes the saved files back. Identical files are skipped; a file that differs is shown (key names only) and you are asked. With `--yes`, `--force` or no terminal, the local file is backed up (encrypted) first. |
| `ev status [name] [--values]` | project ↔ vault | Per file: in sync, changed (keys added / removed / changed), only in project, only in vault. Plus the vault ↔ GitHub state. `--values` prints a real diff. |

### VAULT ↔ GITHUB

| Command | Direction | What it does |
|---|---|---|
| `ev sync` | vault ↔ GitHub | Fetches, integrates the other machines' saves, pushes yours, reports what moved. Every command already does this; use it after working offline. |
| `ev list` | vault | Every project: number of files, last save, whether it exists under `~/projects`, platform snapshots. |
| `ev forget <name> [file]` | vault | Removes a project or one file from the vault (asks first). Old versions stay in git history. |

### VAULT ↔ PLATFORMS

| Command | Direction | What it does |
|---|---|---|
| `ev import vercel [--env e]` | Vercel → vault | Snapshots the Vercel env vars into `vault/<project>/@vercel/<env>.env`. Never touches your project files. |
| `ev export cloudflare [--env e] [--file f] [--dry-run]` | vault → Cloudflare | Uploads a saved `.dev.vars` / `.env` as Worker or Pages secrets, after showing the plan. |
| `ev export vercel [--env e] [--file f] [--dry-run]` | vault → Vercel | Adds / updates Vercel env vars from a saved `.env.production` (etc.), after showing the plan. |

### Maintenance

| Command | What it does |
|---|---|
| `ev` | Interactive menu (context-aware: project actions inside a repo, global ones outside). |
| `ev doctor` | Checks tools, key, vault, GitHub sync and the current project, with a fix for each problem. |
| `ev rotate [--pq]` | New key, every file re-encrypted and verified, old key kept as `<key>.bak-<date>`. |
| `ev init` | First-time or new-machine setup. |
| `ev config [get\|set ...]` | Settings in `~/.envorarc`. |
| `ev help [command]` | Help for one command, with the direction diagram. |

Global flags work anywhere on the line: `-y/--yes` (no prompts, safe defaults), `-q/--quiet` (errors and warnings only, one line each, on stderr), `-C <dir>`, `--no-sync` (local vault only), `-h/--help`, `-v/--version`.

The 0.x names still work for one version and print a hint: `push`, `push-local` → `save`, `pull` → `restore`, `diff` → `status`, `clean` → `forget`, `push-vercel`, `vercel` → `import vercel`.

## The interactive menu

Run `ev` inside a project:

```
 victordenay  3 files saved · 1 changed
 ✓ synced with GitHub · ? help
 › ↑  Save               project → vault      encrypt this project's env files
   ↓  Restore            vault → project      write the saved env files back here
   ≈  Compare            project ↔ vault      see what differs (key names only)
   ☁  Send to Cloudflare vault → Cloudflare   upload secrets to the Worker
   ──────────────────────────────────────────────
   ☰  Browse vault       all projects saved in the vault
   ⇅  Sync with GitHub   vault ↔ GitHub
   ...
```

The preview next to each action is a live plan for this project: which files would be written, replaced or skipped and why, which keys differ, where things go. Vercel items appear when the project is linked (or has a snapshot), the Cloudflare item when a `wrangler.toml` / `wrangler.json(c)` exists. Press `?` for the keys.

Outside a project, the menu lets you browse the vault and **clone + restore** a project that is not on this machine yet (envora remembers each project's origin URL).

## What gets saved

- `.env`, `.env.*`, `.dev.vars`, `.dev.vars.*`, up to 4 levels deep (monorepos), skipping `node_modules`, `vendor`, `dist`, `build`, `.next`, `.nuxt`, `.output`, `.turbo`, `.vercel`, `.wrangler`, `.venv`, `venv`, `target`, `coverage`.
- Never: `*.example`, `*.sample`, `*.template`, `*.dist`, `*.defaults`, `.envrc`.
- Files tracked by git are skipped (git already has them) and reported. `ev doctor` also warns about env files that are not ignored by git.
- Symlinks to regular files are followed.
- Stored as `vault/<project>/<path>.age`. The project name is the git origin repo name (so worktrees and renamed folders map to the same entry), else the main worktree folder name, or `--as name`. Each entry remembers its origin URL: saving another repo under the same name is refused.

## Shell integration

envora is safe to call from scripts. The contract:

| Call | Exit codes |
|---|---|
| `ev restore -C <dir> --yes --quiet` | `0` restored, or nothing to restore (prints nothing). Non-zero only on real errors. |
| `ev save -C <dir> --yes --quiet` | `0` saved (or nothing to save) **and** pushed to GitHub. `3` saved and committed locally but **not** pushed (offline, rejected): you decide. `1` failure: nothing is guaranteed. |

In quiet mode, errors and warnings still go to stderr, one line each.

```zsh
# clone a repo into ~/projects and bring its env files back
clone() {
  local name="${1##*/}"
  git clone "git@github.com:<you>/${1#*/}.git" "$HOME/projects/$name" || return
  ev restore -C "$HOME/projects/$name" --yes --quiet
}

# delete a project folder only once its env files are safe on GitHub
wipe() {
  local dir="$HOME/projects/$1"
  ev save -C "$dir" --yes --quiet
  case $? in
    0) rm -rf "$dir" ;;
    3) echo "wipe: saved locally but not on GitHub yet (ev sync), $dir kept"; return 3 ;;
    *) echo "wipe: save failed, $dir kept"; return 1 ;;
  esac
}
```

## Providers

Both platforms treat secrets as **write-only**: you can set them, list their names, but not read their values back. So the vault is the source of truth, and the platforms are targets.

### Vercel

- `ev import vercel` runs `vercel env pull` for development, preview, production and your custom environments, and stores each one as a snapshot in the vault. `VERCEL_OIDC_TOKEN` (short-lived) is dropped.
- Vercel **Secret** (sensitive) variables come back as `[SENSITIVE]`. envora keeps the value from the previous snapshot when it has one, and tells you how many values remain unknown. Put the real values in your project files and `ev save` them.
- `ev export vercel` compares names with `vercel env ls <env> --format json`, then runs `vercel env add` (new) or `vercel env update` (existing) with the value on **stdin**, never on the command line. Readable values that are already identical are skipped. Nothing is ever deleted.
- envora uses `vercel` from your PATH, else `npx -y vercel@58.4.0` (`ENVORA_VERCEL_CMD` overrides). If the project is not linked, it offers `vercel link`.

### Cloudflare

- `ev export cloudflare` takes the saved `.dev.vars.<env>` / `.dev.vars` (else `.env.<env>` / `.env`) from the vault, warns if your local file differs from the vault copy, compares names with `wrangler secret list`, shows the plan (add / update / only on Cloudflare, never deleted), asks (secrets deploy immediately), then pipes a JSON object to `wrangler secret bulk`. The values never touch the disk or the command line.
- Pages projects (`pages_build_output_dir` in the config) use `wrangler pages secret bulk --project-name <name>` (environments: production, preview).
- In a monorepo, wrangler runs in the folder that holds the wrangler config.
- Cloudflare secrets cannot be imported: there is no way to read them back.
- envora uses `wrangler` from your PATH, else `npx -y wrangler@4.132.0` (`ENVORA_WRANGLER_CMD` overrides).

## New machine

```bash
ev init
```

1. **Key**: choose "I already have an envora key" and paste it from your password manager (it is validated, then saved with mode 600). Only choose "Generate a new key" the very first time.
2. **Vault**: pick your vault repo (or type `user/name`), it is cloned to `~/.env-vault`.
3. If the vault was encrypted for another key, init explains it and stops: nothing is mixed.

Then `ev restore` in each project, or browse the vault from `ev` and clone + restore.

Scripted: `printf '%s\n' "$KEY" | ev init --import-key --repo user/env-vault`.

## Security

Be clear about what this protects:

- **Use a private repo.** File contents are encrypted with age before they leave your machine, but the vault still shows metadata: project names, file names, origin URLs, sizes and dates of every save.
- **One key unlocks everything.** Keep it in a password manager. Without it nobody, including you, can decrypt the vault.
- **History keeps old ciphertexts.** `ev rotate` re-encrypts the current files with a new key, but every past version stays in git history, encrypted with the old key. If your key leaked, rotating it is not enough: **rotate the secrets themselves at their providers**.
- `ev rotate --pq` creates a post-quantum hybrid key (ML-KEM-768 + X25519, needs age >= 1.3).
- Plaintext only lives in private temp directories (mode 700) that are removed on exit, including on Ctrl-C. Restored files are written atomically with mode 600. Backups made before overwriting a file are encrypted (`~/.local/state/envora/backups/<project>/`, last 10 kept).
- Restore only writes env file names, and never outside the project folder, even if the vault contains something else.
- `~/.envorarc` is parsed, never executed.

## Configuration

`~/.envorarc`, edited with `ev config` (or `ev config set <setting> <value>`). Any `ENVORA_*` environment variable overrides the file.

| Setting | Default | Meaning |
|---|---|---|
| `ENVORA_VAULT` | `~/.env-vault` | the local vault repo |
| `ENVORA_KEY` | `~/.age/key.txt` | your age key |
| `ENVORA_PROJECTS` | `~/projects` | where `ev restore NAME` looks for `NAME` |
| `ENVORA_REPO` | set by `ev init` | the vault's GitHub repo (`user/name`) |
| `ENVORA_VERCEL_CMD` | `vercel` or pinned `npx` | command used for Vercel |
| `ENVORA_WRANGLER_CMD` | `wrangler` or pinned `npx` | command used for Cloudflare |

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
