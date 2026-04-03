<p align="center">
  <img src="assets/logo.svg" alt="envoy" width="540" />
</p>

<h1 align="center">envoy</h1>

<p align="center">
  <strong>Encrypted .env vault manager</strong><br>
  Back up, restore, and sync your .env files across machines with age encryption and git.
</p>

<p align="center">
  <a href="https://github.com/AThevon/envoy/releases"><img src="https://img.shields.io/github/v/release/AThevon/envoy?style=flat-square&color=10B981" alt="Release" /></a>
  <a href="https://github.com/AThevon/envoy/blob/main/LICENSE"><img src="https://img.shields.io/github/license/AThevon/envoy?style=flat-square&color=10B981" alt="License" /></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/nix-flake-10B981?style=flat-square&logo=nixos&logoColor=white" alt="Nix Flake" /></a>
</p>

---

## Why

Your `.env` files contain secrets that can't go in git. But they need to exist on every machine you work from. Envoy solves this by keeping them in a **private git repo, encrypted with [age](https://github.com/FiloSottile/age)**. Even if the repo is compromised, your secrets stay safe.

## How it works

```
your-project/.env  -->  ev push  -->  vault/your-project/.env.age  -->  GitHub (private)
                                                                          |
another-machine    <--  ev pull  <--  vault/your-project/.env.age  <------'
```

- **Push** encrypts your `.env` files and stores them in a git-backed vault
- **Pull** decrypts them back into your project
- One age key, stored in your password manager, unlocks everything
- Works across macOS, Linux, and WSL

## Install

### Nix (recommended)

```nix
# flake.nix
envoy = {
  url = "github:AThevon/envoy";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
# packages
envoy.packages.${system}.default
```

### Manual

Requires: `age`, `fzf`, `gum`, `gh`, `jq`, `git`

```bash
git clone https://github.com/AThevon/envoy.git
cd envoy
chmod +x ev.sh
./ev.sh
```

## Quick start

```bash
# First time: sets up key + vault repo
ev init

# Save your .env files
cd ~/projects/my-app
ev push

# Restore on another machine
cd ~/projects/my-app
ev pull

# Pull from Vercel
ev vercel

# Interactive mode
ev
```

## Commands

| Command | Description |
|---------|-------------|
| `ev` | Interactive mode (context-aware) |
| `ev push [project]` | Push all .env files (local + Vercel if detected) |
| `ev push-local [project]` | Push only local .env files |
| `ev push-vercel [project]` | Push only Vercel env vars |
| `ev pull [project]` | Decrypt and restore .env files from the vault |
| `ev diff [project]` | Compare local .env files with the vault |
| `ev list` | List all projects in the vault |
| `ev clean` | Remove a project from the vault |
| `ev rotate` | Generate new age key and re-encrypt vault |
| `ev config` | View and edit settings |
| `ev init` | First-time setup |
| `ev help` | Show detailed help |

## Interactive mode

Run `ev` without arguments for an interactive menu:

- **Inside a git repo**: shows project-specific actions (push, pull, diff, vercel) plus global actions
- **Outside a repo**: shows global actions (list, clean, config, rotate)

## Configuration

Stored in `~/.envoyrc`:

```bash
ENVOY_VAULT="$HOME/.env-vault"       # Path to vault directory
ENVOY_KEY="$HOME/.age/key.txt"       # Path to age private key
ENVOY_PROJECTS="$HOME/projects"      # Path to projects directory
ENVOY_REPO="user/env-vault"          # GitHub repo for the vault
```

Edit with `ev config`.

## Security

- Secrets are encrypted with [age](https://github.com/FiloSottile/age) before leaving your machine
- The vault repo can be public or private - encrypted files are unreadable without the key
- One key to manage: store it in your password manager (Bitwarden, 1Password, etc.)
- `ev rotate` regenerates the key and re-encrypts everything if compromised

## Providers

Envoy can pull environment variables directly from cloud platforms:

- **Vercel** - `ev vercel` pulls development, preview, and production env vars

More providers welcome via PR.

## License

MIT
