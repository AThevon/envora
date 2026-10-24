#!/usr/bin/env bash
# tests/run.sh - envora test suite, plain bash, fully sandboxed.
#
#   bash tests/run.sh            run everything with the current bash
#   /bin/bash tests/run.sh       run everything with macOS bash 3.2
#   bash tests/run.sh rotate     run the tests whose name contains "rotate"
#
# Every test gets its own HOME, a local bare git repo as the vault remote,
# dummy secrets and stub vercel / wrangler / gh executables first on PATH.
# Nothing touches the network or your real ~/.envorarc, ~/.env-vault, ~/.age.

# Test functions are called through "declare -F"; ls -l is used to read modes.
# shellcheck disable=SC2329,SC2012,SC2016,SC2088
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
EV="$ROOT/ev.sh"
TEST_BASH="${TEST_BASH:-$BASH}"
FILTER="${1:-}"
ORIG_PATH="$PATH"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/envora-tests.XXXXXX")"
BASE="$(cd "$BASE" && pwd -P)"
PASS=0
FAIL=0
FAILED=""

for tool in age age-keygen git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

# --- helpers -----------------------------------------------------------------

fail() {
  printf '    FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "${3:-values differ}: expected [$2], got [$1]"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-missing text}: [$2] not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-unexpected text}: [$2] found in: $1" ;;
  esac
}

assert_file() { [[ -f "$1" ]] || fail "file missing: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "file should not exist: $1"; }

# Run ev without a terminal. Output in $OUT, exit code in $RC.
run_ev() {
  RC=0
  OUT="$("$TEST_BASH" "$EV" "$@" 2>&1 </dev/null)" || RC=$?
}

# Run ev, fail the test unless it exits with $1.
expect_rc() {
  local want="$1"
  shift
  run_ev "$@"
  [[ "$RC" == "$want" ]] || fail "ev $* exited $RC (expected $want). Output:
$OUT"
}

commits() { git -C "$ENVORA_VAULT" rev-list --count HEAD 2>/dev/null || echo 0; }
remote_commits() { git --git-dir="$T/remote.git" rev-list --count HEAD 2>/dev/null || echo 0; }

# Machine-specific environment (HOME, vault, key, projects).
use_machine() {
  local m="$1"
  export HOME="$T/$m/home"
  export ENVORA_VAULT="$HOME/.env-vault"
  export ENVORA_KEY="$HOME/.age/key.txt"
  export ENVORA_PROJECTS="$HOME/projects"
  export XDG_STATE_HOME="$HOME/.local/state"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  mkdir -p "$HOME"
  if [[ ! -f "$GIT_CONFIG_GLOBAL" ]]; then
    git config --global user.name "test $m"
    git config --global user.email "test@example.com"
    git config --global init.defaultBranch main
    git config --global advice.detachedHead false
  fi
}

# A machine with a key and a vault cloned from the shared bare remote.
new_machine() {
  use_machine "$1"
  mkdir -p "$HOME/.age" "$ENVORA_PROJECTS"
  if [[ -n "${2:-}" ]]; then
    cp "$2" "$ENVORA_KEY"
  else
    age-keygen -o "$ENVORA_KEY" 2>/dev/null
  fi
  chmod 600 "$ENVORA_KEY"
  git clone -q "$T/remote.git" "$ENVORA_VAULT" 2>/dev/null
}

# mkproject NAME [origin-url] -> creates $ENVORA_PROJECTS/NAME as a git repo
mkproject() {
  local name="$1" url="${2-git@github.com:me/$1.git}" dir="$ENVORA_PROJECTS/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  [[ -n "$url" ]] && git -C "$dir" remote add origin "$url"
  printf '.env*\n.dev.vars*\n!.env.example\n' >"$dir/.gitignore"
  printf 'A=example\n' >"$dir/.env.example"
  git -C "$dir" add .gitignore .env.example
  git -C "$dir" commit -q -m init
  printf '%s' "$dir"
}

install_stubs() {
  mkdir -p "$T/bin" "$T/stub"
  export STUB="$T/stub"
  cat >"$T/bin/vercel" <<'STUB'
#!/bin/bash
# stub vercel: never touches the network
echo "vercel $* (cwd=$PWD)" >>"$STUB/vercel.log"
case "$1 ${2:-}" in
  "env pull")
    file="$3" env="development"
    shift 3
    while [[ $# -gt 0 ]]; do
      case "$1" in --environment) env="$2"; shift ;; esac
      shift
    done
    [[ -f "$STUB/vercel.fail" ]] && { echo "Error: not authorized" >&2; exit 1; }
    [[ -f "$STUB/vercel.$env.env" ]] || { echo "no such env" >&2; exit 1; }
    cp "$STUB/vercel.$env.env" "$file"
    ;;
  "target list")
    [[ -f "$STUB/vercel.targets.json" ]] || exit 1
    cat "$STUB/vercel.targets.json"
    ;;
  "env ls")
    cat "$STUB/vercel.ls.$3.json"
    ;;
  "env add"|"env update")
    value="$(cat)"
    # vercel 58: without --non-interactive, "env add NAME preview" asks
    # "Git branch?", reads the empty stdin and exits 0 having added nothing.
    case " $* " in
      *" --non-interactive "*) ;;
      *) [[ "$4" == preview ]] && exit 0 ;;
    esac
    echo "$2 $4 $3=$value" >>"$STUB/vercel.stdin"
    ;;
  *) echo "stub vercel: unhandled $*" >&2; exit 1 ;;
esac
STUB
  cat >"$T/bin/wrangler" <<'STUB'
#!/bin/bash
echo "wrangler $* (cwd=$PWD)" >>"$STUB/wrangler.log"
env=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--env" ]]; then j=$((i + 1)); env="${!j}"; fi
done
case "$1 ${2:-} ${3:-}" in
  "secret list "*)
    if [[ -f "$STUB/wrangler.listfail" ]]; then
      # what wrangler 4.132 says for a Worker never deployed
      echo '✘ [ERROR] A request to the Cloudflare API failed.' >&2
      echo '  This Worker does not exist on your account. [code: 10007]' >&2
      echo '  Worker "api" not found.' >&2
      exit 1
    fi
    f="$STUB/wrangler.list${env:+.$env}.json"
    [[ -f "$f" ]] && cat "$f" || echo "[]"
    ;;
  "secret bulk "*)
    n="$(cat "$STUB/wrangler.bulkcount" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" >"$STUB/wrangler.bulkcount"
    cat >"$STUB/wrangler.stdin"
    cp "$STUB/wrangler.stdin" "$STUB/wrangler.stdin.$n"
    if [[ -f "$STUB/wrangler.bulkfail.$n" ]]; then
      echo "✘ A request to the Cloudflare API failed" >&2
      exit 1
    fi
    echo "Successfully uploaded secrets"
    ;;
  "pages secret list")
    echo "The \"production\" environment of your Pages project \"site\" has access to the following secrets:"
    echo "  - OLD_SECRET: Value Encrypted"
    ;;
  "pages secret bulk")
    cat >"$STUB/wrangler.stdin"
    ;;
  *) echo "stub wrangler: unhandled $*" >&2; exit 1 ;;
esac
STUB
  cat >"$T/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >>"$STUB/gh.log"
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "repo create") git init -q --bare -b main "$STUB/gh-$3.git" ;;
  "repo view") echo "me/$3" ;;
  "repo clone") git clone -q "$STUB/gh-${3#me/}.git" "$4" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$T/bin/vercel" "$T/bin/wrangler" "$T/bin/gh"
}

setup() {
  T="$BASE/$1"
  mkdir -p "$T/tmp"
  export TMPDIR="$T/tmp"
  local v
  for v in $(env | sed -n 's/^\(ENVORA_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
  unset XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE
  export GIT_CONFIG_NOSYSTEM=1 NO_COLOR=1 GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  install_stubs
  export PATH="$T/bin:$ORIG_PATH"
  export GIT_CONFIG_GLOBAL="$T/no-global-gitconfig"
  git init -q --bare -b main "$T/remote.git"
  new_machine A
}

run_test() {
  local name="$1"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  printf '  %-58s' "$name"
  local log="$BASE/$name.log" rc=0
  ( set -e; setup "$name"; "t_$name" ) >"$log" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    # No plaintext temp dir may survive a run.
    if [[ -n "$(find "$BASE/$name/tmp" -name 'envora.*' 2>/dev/null)" ]]; then
      echo "FAIL"
      echo "    FAIL: an envora temp dir was left behind" >&2
      FAIL=$((FAIL + 1)); FAILED="$FAILED $name"
      return 0
    fi
    echo "ok"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    sed 's/^/    | /' "$log" | tail -n 25
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $name"
  fi
}

# --- tests -------------------------------------------------------------------

t_save_restore_round_trip() {
  local p
  p="$(mkproject app)"
  printf 'DB_URL=postgres://x\nTOKEN="a b"\n' >"$p/.env"
  printf 'LOCAL=1\n' >"$p/.env.local"
  cd "$p"
  expect_rc 0 save
  assert_contains "$OUT" "2 files saved to the vault (app)"
  assert_contains "$OUT" "pushed to GitHub"
  assert_file "$ENVORA_VAULT/app/.env.age"
  assert_file "$ENVORA_VAULT/app/.env.local.age"
  assert_eq "$(head -n 1 "$ENVORA_VAULT/app/.origin")" "git@github.com:me/app.git"
  assert_eq "$(cat "$ENVORA_VAULT/.gitattributes")" "*.age binary"
  assert_eq "$(cat "$ENVORA_VAULT/.recipient")" "$(age-keygen -y "$ENVORA_KEY")"
  assert_eq "$(remote_commits)" "1" "pushed to the remote"
  rm "$p/.env" "$p/.env.local"
  expect_rc 0 restore
  assert_eq "$(cat "$p/.env")" "$(printf 'DB_URL=postgres://x\nTOKEN="a b"')"
  assert_eq "$(cat "$p/.env.local")" "LOCAL=1"
  local perm
  perm="$(ls -l "$p/.env" | cut -c 1-10)"
  assert_eq "$perm" "-rw-------" "restored files are 600"
  expect_rc 0 restore
  assert_contains "$OUT" "already up to date"
}

t_noop_save_makes_no_commit() {
  local p before
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  before="$(commits)"
  expect_rc 0 save
  assert_contains "$OUT" "nothing changed"
  assert_eq "$(commits)" "$before" "no new commit"
  printf 'A=2\n' >"$p/.env"
  expect_rc 0 save
  assert_eq "$(commits)" "$((before + 1))"
  assert_eq "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "save: app (.env)"
}

t_monorepo_nested_files() {
  local p
  p="$(mkproject mono)"
  mkdir -p "$p/apps/web" "$p/apps/api/src" "$p/node_modules/pkg" "$p/a/b/c/d"
  printf 'ROOT=1\n' >"$p/.env"
  printf 'WEB=1\n' >"$p/apps/web/.env.local"
  printf 'API=1\n' >"$p/apps/api/.dev.vars"
  printf 'NO=1\n' >"$p/node_modules/pkg/.env"
  printf 'DEEP=1\n' >"$p/a/b/c/d/.env"
  cd "$p/apps/web"
  # too deep for the scan: saved files are saved, but exit 1 (do not delete)
  expect_rc 1 save
  assert_contains "$OUT" "NOT saved: a/b/c/d/.env"
  assert_file "$ENVORA_VAULT/mono/apps/web/.env.local.age"
  assert_file "$ENVORA_VAULT/mono/apps/api/.dev.vars.age"
  assert_no_file "$ENVORA_VAULT/mono/node_modules"
  assert_no_file "$ENVORA_VAULT/mono/a"
  assert_contains "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "apps/web/.env.local"
  rm -rf "$p/apps/web/.env.local" "$p/apps/api" "$p/a"
  expect_rc 0 restore
  assert_eq "$(cat "$p/apps/api/.dev.vars")" "API=1"
  assert_eq "$(cat "$p/apps/web/.env.local")" "WEB=1"
}

t_tracked_files_skipped() {
  local p
  p="$(mkproject app)"
  printf 'COMMITTED=1\n' >"$p/.env.test"
  git -C "$p" add -f .env.test
  git -C "$p" commit -q -m "track env"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  assert_contains "$OUT" "tracked by git"
  assert_no_file "$ENVORA_VAULT/app/.env.test.age"
  assert_file "$ENVORA_VAULT/app/.env.age"
  # a vault file that git now tracks in the project is never overwritten
  printf 'OLD=1\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/app/.env.test.age"
  expect_rc 0 restore --yes
  assert_eq "$(cat "$p/.env.test")" "COMMITTED=1"
  assert_contains "$OUT" "tracked by git here"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -q -m tracked
  expect_rc 0 forget app .env --yes
  expect_rc 0 restore --yes
  assert_contains "$OUT" "nothing restored: 1 file of the vault tracked by git here"
  assert_not_contains "$OUT" "0 files identical"
  # paths are literal for git: [x]/.env is not x/.env
  mkdir -p "$p/x" "$p/[x]"
  printf 'X=tracked\n' >"$p/x/.env"
  git -C "$p" add -f x/.env && git -C "$p" commit -q -m x
  printf 'X=bracket\n' >"$p/[x]/.env"
  expect_rc 0 save
  assert_file "$ENVORA_VAULT/app/[x]/.env.age"
  rm "$p/[x]/.env"
  expect_rc 0 restore
  assert_eq "$(cat "$p/[x]/.env")" "X=bracket"
}

t_file_patterns() {
  local p
  p="$(mkproject app)"
  printf 'export X=1\n' >"$p/.envrc"
  printf 'S=1\n' >"$p/.dev.vars"
  printf 'S=2\n' >"$p/.dev.vars.staging"
  printf 'E=1\n' >"$p/.env.sample"
  printf 'E=1\n' >"$p/.env.local.template"
  printf 'E=1\n' >"$p/.env.production"
  printf 'E=1\n' >"$p/real.env"
  ln -s .env.production "$p/.env.link"
  cd "$p"
  expect_rc 0 save
  assert_no_file "$ENVORA_VAULT/app/.envrc.age"
  assert_no_file "$ENVORA_VAULT/app/.env.example.age"
  assert_no_file "$ENVORA_VAULT/app/.env.sample.age"
  assert_no_file "$ENVORA_VAULT/app/.env.local.template.age"
  assert_no_file "$ENVORA_VAULT/app/real.env.age"
  assert_file "$ENVORA_VAULT/app/.dev.vars.age"
  assert_file "$ENVORA_VAULT/app/.dev.vars.staging.age"
  assert_file "$ENVORA_VAULT/app/.env.production.age"
  assert_file "$ENVORA_VAULT/app/.env.link.age"
}

t_worktree_identity() {
  local p wt
  p="$(mkproject app "")"
  wt="$T/A/home/elsewhere/app-feature"
  mkdir -p "$(dirname "$wt")"
  git -C "$p" worktree add -q "$wt" -b feature 2>/dev/null
  printf 'WT=1\n' >"$wt/.env"
  cd "$wt"
  expect_rc 0 save
  assert_file "$ENVORA_VAULT/app/.env.age"
  assert_no_file "$ENVORA_VAULT/app-feature"
  cd "$p"
  expect_rc 0 restore
  assert_eq "$(cat "$p/.env")" "WT=1"
}

t_origin_name_and_mismatch() {
  local p q
  p="$(mkproject folder-name "https://github.com/me/real-repo.git/")"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  assert_file "$ENVORA_VAULT/real-repo/.env.age"
  q="$(mkproject other "git@github.com:someone-else/real-repo.git")"
  printf 'B=1\n' >"$q/.env"
  cd "$q"
  expect_rc 1 save
  assert_contains "$OUT" "belongs to another repository"
  assert_contains "$OUT" "--as"
  expect_rc 0 save --as other-real-repo
  assert_file "$ENVORA_VAULT/other-real-repo/.env.age"
  # same repo through another URL form is accepted
  git -C "$p" remote set-url origin "git@GitHub.com:me/real-repo"
  cd "$p"
  printf 'A=2\n' >"$p/.env"
  expect_rc 0 save
}

t_name_validation() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 1 save --as ../escape
  assert_contains "$OUT" "invalid project name"
  expect_rc 1 save --as .hidden
  expect_rc 1 save --as -rf
  assert_no_file "$ENVORA_VAULT/-rf"
  expect_rc 1 save --as 'a b'
  expect_rc 1 restore ..
  expect_rc 1 forget ..
  assert_no_file "$T/A/home/escape.age"
  cd "$T"
  expect_rc 1 restore nope
  assert_contains "$OUT" "no local folder for 'nope'"
}

t_restore_by_name_never_substring() {
  local p q
  p="$(mkproject app)"
  q="$(mkproject app-admin)"
  printf 'APP=1\n' >"$p/.env"
  printf 'ADMIN=1\n' >"$q/.env"
  cd "$p" && expect_rc 0 save
  cd "$q" && expect_rc 0 save
  rm "$p/.env" "$q/.env"
  cd "$q"
  expect_rc 0 restore app
  assert_eq "$(cat "$p/.env")" "APP=1"
  assert_no_file "$q/.env"
}

t_two_machines_no_stale_restore() {
  local key="$T/A/home/.age/key.txt" p
  p="$(mkproject app)"
  printf 'V=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  new_machine B "$key"
  local pb
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore)
  assert_eq "$(cat "$pb/.env")" "V=1"
  use_machine A
  printf 'V=2\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  use_machine B
  cd "$pb"
  expect_rc 0 restore --yes
  assert_eq "$(cat "$pb/.env")" "V=2" "B restored the latest version"
}

t_two_machines_merge_different_files() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore)
  # B works offline and saves another file
  printf 'B=1\n' >"$pb/.env.local"
  (cd "$pb" && expect_rc 3 save --no-sync)
  # meanwhile A changes .env and pushes
  use_machine A
  printf 'A=2\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  use_machine B
  expect_rc 0 sync
  assert_contains "$OUT" "in sync"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
  use_machine A
  (cd "$p" && expect_rc 0 restore)
  assert_eq "$(cat "$p/.env.local")" "B=1" "A got B's file"
  assert_eq "$(cat "$p/.env")" "A=2"
}

t_two_machines_same_file_newest_wins() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore)
  # B saves offline first (older), A saves later (newer)
  printf 'A=1\nFROM_B=1\n' >"$pb/.env"
  (cd "$pb" && GIT_COMMITTER_DATE="2026-01-01T10:00:00" GIT_AUTHOR_DATE="2026-01-01T10:00:00" expect_rc 3 save --no-sync)
  use_machine A
  printf 'A=1\nFROM_A=1\n' >"$p/.env"
  (cd "$p" && GIT_COMMITTER_DATE="2026-01-01T11:00:00" GIT_AUTHOR_DATE="2026-01-01T11:00:00" expect_rc 0 save)
  use_machine B
  expect_rc 0 sync
  assert_contains "$OUT" "conflict on app/.env.age"
  assert_contains "$OUT" "kept the other machine's version"
  assert_contains "$OUT" "FROM_B"
  assert_contains "$OUT" "stays in git history"
  local gd
  gd="$(git -C "$ENVORA_VAULT" rev-parse --absolute-git-dir)"
  assert_no_file "$gd/rebase-merge"
  assert_no_file "$gd/MERGE_HEAD"
  (cd "$pb" && expect_rc 0 restore --yes)
  assert_contains "$(cat "$pb/.env")" "FROM_A"
}

t_stale_copy_never_overwrites_newer_vault() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'TOKEN=old\n' >"$p/.env.local"
  (cd "$p" && expect_rc 0 save --yes -q)
  new_machine B "$key"
  pb="$(mkproject app)"
  cd "$pb"
  expect_rc 0 restore --yes -q
  printf 'TOKEN=new-rotated\n' >"$pb/.env.local"
  expect_rc 0 save --yes -q
  # A never touched its copy: it is stale, not newer
  use_machine A
  cd "$p"
  expect_rc 0 status
  assert_contains "$OUT" "newer in the vault"
  expect_rc 0 save -C . --yes
  assert_contains "$OUT" "left the vault version in place"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.local.age")" "TOKEN=new-rotated"
  # restore updates the stale copy without asking (backup kept)
  expect_rc 0 restore
  assert_eq "$(cat "$p/.env.local")" "TOKEN=new-rotated"
  # both edited: --yes keeps this copy but says loudly what it replaced
  printf 'TOKEN=from-A\n' >"$p/.env.local"
  use_machine B
  printf 'TOKEN=from-B\n' >"$pb/.env.local"
  (cd "$pb" && expect_rc 0 save --yes -q)
  use_machine A
  expect_rc 0 status
  assert_contains "$OUT" "changed here AND in the vault"
  expect_rc 0 save --yes -q
  assert_contains "$OUT" "ev: warning: .env.local: the vault had a newer version from another machine (commit "
  assert_contains "$OUT" "the other version stays in git history"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.local.age")" "TOKEN=from-A"
}

t_restore_and_save_check_origin() {
  local p fork plain bare
  p="$(mkproject app "git@github.com:me/app.git")"
  printf 'MY_SECRET=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  # a homonym clone of someone else's repo: nothing is written into it
  fork="$T/A/home/elsewhere/app"
  mkdir -p "$fork"
  git -C "$fork" init -q
  git -C "$fork" remote add origin "https://github.com/stranger/app.git"
  expect_rc 1 restore -C "$fork" --yes --quiet
  assert_contains "$OUT" "ev: error: the vault entry 'app' belongs to another repository"
  assert_no_file "$fork/.env"
  # a folder without git, or a repo without remote, cannot overwrite the entry
  plain="$T/A/home/Downloads/app"
  mkdir -p "$plain"
  printf 'MY_SECRET=other\n' >"$plain/.env"
  expect_rc 1 save -C "$plain" --yes
  assert_contains "$OUT" "has no git origin"
  bare="$T/A/home/tmp2/app"
  mkdir -p "$bare"
  git -C "$bare" init -q
  printf 'MY_SECRET=other\n' >"$bare/.env"
  expect_rc 1 save -C "$bare" --yes
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "MY_SECRET=1"
  # --as only names the entry: it does not skip the origin check
  expect_rc 1 restore -C "$fork" --as app --yes
  assert_contains "$OUT" "ev restore -C ~/elsewhere/app --as app --force"
  assert_no_file "$fork/.env"
  # another repo cannot overwrite an entry by typing its name
  local web
  web="$(mkproject web "git@github.com:me/web.git")"
  printf 'WEB=1\n' >"$web/.env"
  expect_rc 1 save -C "$web" --as app --yes
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "MY_SECRET=1"
  # --force says "this is that project"
  expect_rc 0 restore -C "$fork" --as app --force --yes
  assert_file "$fork/.env"
  # a repo moved to an organization: save --force records the new origin,
  # then everything works without --force
  git -C "$p" remote set-url origin "git@github.com:acme/app.git"
  printf 'MY_SECRET=2\n' >"$p/.env"
  cd "$p"
  expect_rc 1 export cloudflare --dry-run
  assert_contains "$OUT" "--as app --force"
  expect_rc 0 save --as app --force --yes
  assert_eq "$(cat "$ENVORA_VAULT/app/.origin")" "git@github.com:acme/app.git"
  expect_rc 0 status -q
  assert_not_contains "$OUT" "another repository"
}

t_legacy_name_and_folder_guard() {
  local p
  p="$(mkproject victor "git@github.com:me/victordenay.git")"
  printf 'K=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  assert_file "$ENVORA_VAULT/victordenay/.env.age"
  printf 'K=2\n' >"$p/.env"
  cd "$T"
  # the old wipe hook names the folder: same vault entry as inside the project
  expect_rc 0 push-local victor
  assert_no_file "$ENVORA_VAULT/victor"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/victordenay/.env.age")" "K=2"
  # an entry saved by envora 0.x under the folder name is still found
  local q
  q="$(mkproject old-folder "git@github.com:me/new-name.git")"
  mkdir -p "$ENVORA_VAULT/old-folder"
  printf 'OLD=1\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/old-folder/.env.age"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -q -m "v0 entry"
  cd "$q"
  expect_rc 0 restore
  assert_eq "$(cat "$q/.env")" "OLD=1"
  # never a folder of projects, never home
  mkdir -p "$T/A/home/work"
  mv "$p" "$T/A/home/work/victor"
  expect_rc 1 save -C "$T/A/home/work/" --yes
  assert_contains "$OUT" "looks like a folder of projects"
  expect_rc 1 save -C "$ENVORA_PROJECTS" --yes
  assert_contains "$OUT" "is the projects root (ENVORA_PROJECTS), not a project"
  expect_rc 1 save -C "$HOME" --yes
  assert_no_file "$ENVORA_VAULT/work"
  assert_no_file "$ENVORA_VAULT/home"
}

t_push_failure_exit_3() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  # remote becomes unreachable
  mv "$T/remote.git" "$T/remote.gone"
  printf 'A=2\n' >"$p/.env"
  expect_rc 3 save
  assert_contains "$OUT" "PUSH FAILED"
  assert_contains "$OUT" "cannot reach GitHub"
  mv "$T/remote.gone" "$T/remote.git"
  expect_rc 0 sync
  assert_eq "$(remote_commits)" "$(commits)"
  # a rejected push (hook) is also exit 3
  printf '#!/bin/sh\nexit 1\n' >"$T/remote.git/hooks/pre-receive"
  chmod +x "$T/remote.git/hooks/pre-receive"
  printf 'A=3\n' >"$p/.env"
  expect_rc 3 save
  assert_contains "$OUT" "NOT pushed"
}

t_vault_never_commits_unmanaged_files() {
  local p pub head
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  printf '*.plain\n' >"$ENVORA_VAULT/.gitignore"
  git -C "$ENVORA_VAULT" add .gitignore && git -C "$ENVORA_VAULT" commit -q -m ignore
  printf 'STRIPE=sk_live_plain\n' >"$ENVORA_VAULT/backup.plain"
  printf 'notes\n' >"$ENVORA_VAULT/README.md"
  pub="$(age-keygen -y "$ENVORA_KEY")"
  # an interrupted save left a re-encrypted file uncommitted
  printf 'A=2\n' | age -r "$pub" -o "$ENVORA_VAULT/app/.env.age"
  expect_rc 0 sync
  assert_eq "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "envora: record changes left uncommitted"
  git --git-dir="$T/remote.git" show HEAD:backup.plain >/dev/null 2>&1 && fail "an ignored plaintext file reached the remote"
  git --git-dir="$T/remote.git" show HEAD:README.md >/dev/null 2>&1 && fail "an unmanaged file was committed"
  assert_eq "$(git --git-dir="$T/remote.git" show HEAD:app/.env.age | age -d -i "$ENVORA_KEY")" "A=2"
  # an uncommitted file the key cannot decrypt is refused, loudly
  head="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  printf 'X=1\n' | age -r "$(age-keygen 2>/dev/null | age-keygen -y)" -o "$ENVORA_VAULT/app/.env.age"
  expect_rc 1 status
  assert_contains "$OUT" "your key cannot decrypt"
  assert_eq "$(git -C "$ENVORA_VAULT" rev-parse HEAD)" "$head" "nothing committed"
}

t_sync_labels_offline_and_no_sync() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  mv "$T/remote.git" "$T/remote.gone"
  printf 'A=2\n' >"$p/.env"
  expect_rc 3 save
  assert_contains "$OUT" "! 1 file saved to the vault"
  expect_rc 0 status
  assert_contains "$OUT" "offline · ↑ 1 to push (not on GitHub yet)"
  mv "$T/remote.gone" "$T/remote.git"
  expect_rc 0 sync
  # --no-sync never claims to be in sync
  new_machine B "$T/A/home/.age/key.txt"
  use_machine A
  printf 'A=3\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  use_machine B
  local pb
  pb="$(mkproject app)"
  cd "$pb"
  expect_rc 0 status --no-sync
  assert_contains "$OUT" "not checked with GitHub (--no-sync)"
  assert_not_contains "$OUT" "synced with GitHub"
}

t_restore_backup_no_silent_overwrite() {
  local p
  p="$(mkproject app)"
  printf 'A=1\nB=2\n' >"$p/.env"
  printf 'SAME=1\n' >"$p/.env.local"
  cd "$p"
  expect_rc 0 save
  printf 'A=changed\nC=3\n' >"$p/.env"
  expect_rc 0 restore --yes
  assert_eq "$(cat "$p/.env")" "$(printf 'A=1\nB=2')"
  assert_contains "$OUT" "backed up"
  local bk
  bk="$(find "$HOME/.local/state/envora/backups/app" -name '.env.age')"
  [[ -n "$bk" ]] || fail "no backup"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$bk")" "$(printf 'A=changed\nC=3')"
  # identical file untouched
  assert_not_contains "$OUT" ".env.local  vault"
  # keep only 10 backups
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'X=%s\n' "$i" >"$p/.env"
    run_ev restore --yes
  done
  assert_eq "$(find "$HOME/.local/state/envora/backups/app" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "10"
  assert_no_file "$p/.env.envora-tmp"
  [[ -z "$(find "$p" -name '*.envora-*')" ]] || fail "temp file left in the project"
}

t_forged_entries_not_restored() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  printf 'evil\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/app/package.json.age"
  mkdir -p "$ENVORA_VAULT/app/sub"
  printf 'evil\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/app/sub/run.sh.age"
  rm "$p/.env"
  expect_rc 1 restore
  assert_contains "$OUT" "refusing to restore 'package.json'"
  assert_no_file "$p/package.json"
  assert_no_file "$p/sub/run.sh"
  assert_file "$p/.env"
}

t_restore_through_symlinked_dir_refused() {
  local p
  p="$(mkproject app)"
  mkdir -p "$p/apps/web"
  printf 'W=1\n' >"$p/apps/web/.env"
  cd "$p"
  expect_rc 0 save
  rm -rf "$p/apps"
  mkdir -p "$T/outside"
  ln -s "$T/outside" "$p/apps"
  expect_rc 1 restore
  assert_contains "$OUT" "outside"
  assert_no_file "$T/outside/web/.env"
}

t_rotate_success() {
  local p old_pub
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  mkdir -p "$p/apps/x"
  printf 'X=1\n' >"$p/apps/x/.dev.vars"
  cd "$p"
  expect_rc 0 save
  old_pub="$(age-keygen -y "$ENVORA_KEY")"
  expect_rc 0 rotate --yes
  assert_contains "$OUT" "2 files re-encrypted and verified"
  assert_contains "$OUT" "old ciphertexts remain in git history"
  assert_contains "$OUT" "AGE-SECRET-KEY-"
  [[ "$(age-keygen -y "$ENVORA_KEY")" != "$old_pub" ]] || fail "key not changed"
  ls "$ENVORA_KEY".bak-* >/dev/null 2>&1 || fail "old key backup missing"
  assert_no_file "$ENVORA_KEY.new"
  assert_eq "$(cat "$ENVORA_VAULT/.recipient")" "$(age-keygen -y "$ENVORA_KEY")"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/apps/x/.dev.vars.age")" "X=1"
  assert_eq "$(remote_commits)" "$(commits)"
  rm "$p/.env"
  expect_rc 0 restore
  assert_eq "$(cat "$p/.env")" "A=1"
}

t_rotate_failure_keeps_key() {
  local p old_key
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  old_key="$(cat "$ENVORA_KEY")"
  # a file encrypted for someone else cannot be re-encrypted
  printf 'x\n' | age -r "$(age-keygen 2>/dev/null | age-keygen -y)" -o "$ENVORA_VAULT/app/.env.bad.age"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -q -m bad
  expect_rc 1 rotate --yes
  assert_contains "$OUT" "rotation aborted"
  assert_eq "$(cat "$ENVORA_KEY")" "$old_key" "key unchanged"
  assert_no_file "$ENVORA_KEY.new"
  [[ -z "$(find "$ENVORA_VAULT" -name '*.envora-*')" ]] || fail "temp files left in the vault"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "A=1"
  ls "$ENVORA_KEY".bak-* >/dev/null 2>&1 && fail "no backup expected on failure"
  # without --yes and without a terminal: refused
  rm "$ENVORA_VAULT/app/.env.bad.age"
  expect_rc 1 rotate
  assert_contains "$OUT" "add --yes"
}

# A mv wrapper first on PATH: fails or slows down on demand.
install_mv_wrapper() {
  mkdir -p "$T/mvbin"
  cat >"$T/mvbin/mv" <<'STUB'
#!/bin/bash
for last in "$@"; do :; done
if [[ -n "${ENVORA_TEST_MV_FAIL:-}" && "$last" == *"$ENVORA_TEST_MV_FAIL" ]]; then
  echo "mv: rename: Operation not permitted" >&2
  exit 1
fi
[[ -n "${ENVORA_TEST_MV_SLOW:-}" ]] && sleep "$ENVORA_TEST_MV_SLOW"
for real in /bin/mv /usr/bin/mv; do [[ -x "$real" ]] && exec "$real" "$@"; done
exit 127
STUB
  chmod +x "$T/mvbin/mv"
  export PATH="$T/mvbin:$PATH"
}

# rotate_saved_vault: two projects with 4 files, all saved.
rotate_saved_vault() {
  local p q
  p="$(mkproject a)"
  q="$(mkproject b)"
  printf 'A=1\n' >"$p/.env"
  printf 'A2=1\n' >"$p/.env.local"
  printf 'B=1\n' >"$q/.env"
  printf 'B2=1\n' >"$q/.env.local"
  (cd "$p" && expect_rc 0 save)
  (cd "$q" && expect_rc 0 save)
}

all_decrypt_with_key() {
  local f
  while IFS= read -r f; do
    age -d -i "$ENVORA_KEY" "$f" >/dev/null 2>&1 || fail "$f does not decrypt with the current key"
  done < <(find "$ENVORA_VAULT" -name '*.age' ! -path '*/.git/*')
}

t_rotate_failed_switch_rolls_back() {
  rotate_saved_vault
  install_mv_wrapper
  local old_key
  old_key="$(cat "$ENVORA_KEY")"
  # the key cannot be installed: nothing changes
  ENVORA_TEST_MV_FAIL="/key.txt" expect_rc 1 rotate --yes
  assert_contains "$OUT" "cannot install the new key"
  assert_eq "$(cat "$ENVORA_KEY")" "$old_key"
  all_decrypt_with_key
  assert_no_file "$ENVORA_KEY.new"
  rm -f "$ENVORA_KEY".bak-*
  # a file cannot be moved halfway: rolled back, old key back in place
  ENVORA_TEST_MV_FAIL="b/.env.age" expect_rc 1 rotate --yes
  assert_contains "$OUT" "rolled back"
  assert_eq "$(cat "$ENVORA_KEY")" "$old_key"
  all_decrypt_with_key
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
  assert_eq "$(cat "$ENVORA_VAULT/.recipient")" "$(age-keygen -y "$ENVORA_KEY")"
  [[ -z "$(find "$ENVORA_VAULT" -name '*.envora-*')" ]] || fail "temp files left in the vault"
}

t_rotate_signal_during_switch_loses_nothing() {
  rotate_saved_vault
  install_mv_wrapper
  ENVORA_TEST_MV_SLOW=0.3 "$TEST_BASH" "$EV" rotate --yes --no-sync </dev/null >"$T/rot.out" 2>&1 &
  local pid=$! n=0
  while ! ls "$ENVORA_KEY".bak-* >/dev/null 2>&1; do
    sleep 0.05
    n=$((n + 1))
    [[ $n -lt 400 ]] || fail "rotation never reached the switch"
  done
  kill -TERM "$pid" 2>/dev/null || true
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" || true
  # every file opens with the key in place, whatever happened
  all_decrypt_with_key
  assert_eq "$(cat "$ENVORA_VAULT/.recipient")" "$(age-keygen -y "$ENVORA_KEY")"
  expect_rc 0 sync
  all_decrypt_with_key
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
}

t_rotate_reencrypts_saves_made_meanwhile() {
  local key="$T/A/home/.age/key.txt" p pb pw
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  new_machine B "$key"
  pb="$(mkproject app)"
  pw="$(mkproject web)"
  (cd "$pb" && expect_rc 0 restore)
  printf 'A=from-B\n' >"$pb/.env"
  printf 'W=1\n' >"$pw/.env"
  use_machine A
  # B saves with the old key while A pushes its rotation
  cat >"$ENVORA_VAULT/.git/hooks/pre-push" <<HOOK
#!/bin/bash
[ -f "$T/hook.done" ] && exit 0
touch "$T/hook.done"
for d in "$pb" "$pw"; do
  env HOME="$T/B/home" ENVORA_VAULT="$T/B/home/.env-vault" ENVORA_KEY="$T/B/home/.age/key.txt" \
    ENVORA_PROJECTS="$T/B/home/projects" XDG_STATE_HOME="$T/B/home/.local/state" \
    GIT_CONFIG_GLOBAL="$T/B/home/.gitconfig" GIT_AUTHOR_DATE="2030-01-01T10:00:00" \
    GIT_COMMITTER_DATE="2030-01-01T10:00:00" \
    "$TEST_BASH" "$EV" save -C "\$d" --yes -q </dev/null >>"$T/hook.log" 2>&1
done
exit 0
HOOK
  chmod +x "$ENVORA_VAULT/.git/hooks/pre-push"
  cd "$p"
  expect_rc 0 rotate --yes
  assert_file "$T/hook.done"
  assert_contains "$OUT" "re-encrypted for your current key 2 files saved with the previous key"
  all_decrypt_with_key
  rm "$ENVORA_VAULT/.git/hooks/pre-push"
  local f
  for f in app/.env.age web/.env.age; do
    git --git-dir="$T/remote.git" show "HEAD:$f" | age -d -i "$ENVORA_KEY" >/dev/null 2>&1 ||
      fail "$f on GitHub is not readable with the new key"
  done
  assert_eq "$(remote_commits)" "$(commits)"
}

t_rotate_pq() {
  age-keygen -pq -o "$T/pqtest" >/dev/null 2>&1 || { echo "age without -pq: skipped"; return 0; }
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  expect_rc 0 rotate --pq --yes
  assert_contains "$(cat "$ENVORA_VAULT/.recipient")" "age1pq1"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "A=1"
}

t_init_import_existing_key() {
  local p key
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  key="$(cat "$ENVORA_KEY")"
  # new machine: nothing set up
  use_machine C
  cd "$HOME"
  expect_rc 1 restore -C "$T/A/home/projects/app"
  assert_contains "$OUT" "not set up"
  RC=0
  OUT="$(printf '%s\n' "$key" | "$TEST_BASH" "$EV" init --import-key --repo "$T/remote.git" 2>&1)" || RC=$?
  [[ $RC == 0 ]] || fail "init failed: $OUT"
  assert_contains "$OUT" "key saved"
  assert_eq "$(age-keygen -y "$ENVORA_KEY")" "$(age-keygen -y "$T/A/home/.age/key.txt")"
  assert_eq "$(ls -l "$ENVORA_KEY" | cut -c 1-10)" "-rw-------"
  assert_file "$ENVORA_VAULT/app/.env.age"
  assert_file "$HOME/.envorarc"
  local pc
  pc="$(mkproject app)"
  cd "$pc"
  expect_rc 0 restore
  assert_eq "$(cat "$pc/.env")" "A=1"
  # the whole key file pasted on one line (what a single-line prompt does)
  use_machine G
  RC=0
  OUT="$(tr '\n' ' ' <"$T/A/home/.age/key.txt" | "$TEST_BASH" "$EV" init --import-key --repo "$T/remote.git" 2>&1)" || RC=$?
  [[ $RC == 0 ]] || fail "init with a pasted key file failed: $OUT"
  assert_eq "$(age-keygen -y "$ENVORA_KEY")" "$(age-keygen -y "$T/A/home/.age/key.txt")"
  # a machine with the wrong key replaces it, the old one is kept as .bak
  use_machine H
  mkdir -p "$HOME/.age"
  age-keygen -o "$ENVORA_KEY" 2>/dev/null
  expect_rc 1 init --repo "$T/remote.git"
  assert_contains "$OUT" "ev init --import-key"
  RC=0
  OUT="$(printf '%s\n' "$key" | "$TEST_BASH" "$EV" init --import-key 2>&1)" || RC=$?
  [[ $RC == 0 ]] || fail "replacing the key failed: $OUT"
  assert_contains "$OUT" "previous key is kept"
  ls "$ENVORA_KEY".bak-* >/dev/null 2>&1 || fail "the replaced key was not kept"
  assert_eq "$(age-keygen -y "$ENVORA_KEY")" "$(age-keygen -y "$T/A/home/.age/key.txt")"
  # a key that is not the vault's is refused: nothing changes on disk
  local before n_bak
  before="$(cat "$ENVORA_KEY")"
  n_bak="$(ls "$ENVORA_KEY".bak-* | wc -l)"
  RC=0
  OUT="$(age-keygen 2>/dev/null | "$TEST_BASH" "$EV" init --import-key 2>&1)" || RC=$?
  assert_eq "$RC" "1"
  assert_contains "$OUT" "this key is not your vault's key"
  assert_contains "$OUT" "nothing changed: your current key stays in place"
  assert_eq "$(cat "$ENVORA_KEY")" "$before"
  assert_eq "$(ls "$ENVORA_KEY".bak-* | wc -l)" "$n_bak"
  # rotated on machine A: H imports the new key before its vault pulled it
  use_machine A
  (cd "$p" && expect_rc 0 rotate --yes -q)
  use_machine H
  RC=0
  OUT="$(cat "$T/A/home/.age/key.txt" | "$TEST_BASH" "$EV" init --import-key 2>&1)" || RC=$?
  [[ $RC == 0 ]] || fail "importing the rotated key failed: $OUT"
  assert_eq "$(age-keygen -y "$ENVORA_KEY")" "$(age-keygen -y "$T/A/home/.age/key.txt")"
  # a key replaced by mistake: the message points at the .bak that matches
  use_machine A
  mv "$ENVORA_KEY" "$ENVORA_KEY.bak-20200101-000000"
  age-keygen -o "$ENVORA_KEY" 2>/dev/null
  cd "$p"
  expect_rc 1 status -q
  assert_contains "$OUT" "different key than yours (rotated elsewhere? run: ev init --import-key)"
  expect_rc 1 status
  assert_contains "$OUT" "your previous key ~/.age/key.txt.bak-20200101-000000 matches this vault"
  # garbage key refused
  use_machine D
  RC=0
  OUT="$(printf 'not a key\n' | "$TEST_BASH" "$EV" init --import-key --repo "$T/remote.git" 2>&1)" || RC=$?
  assert_eq "$RC" "1"
  assert_contains "$OUT" "no AGE-SECRET-KEY"
  assert_no_file "$ENVORA_KEY"
}

t_init_generate_and_create_with_gh() {
  use_machine E
  expect_rc 0 init --generate-key --create my-vault
  assert_contains "$OUT" "AGE-SECRET-KEY-"
  assert_file "$ENVORA_KEY"
  assert_contains "$(cat "$STUB/gh.log")" "repo create my-vault --private"
  assert_contains "$(cat "$STUB/gh.log")" "repo view my-vault --json nameWithOwner -q .nameWithOwner"
  assert_contains "$(cat "$HOME/.envorarc")" "ENVORA_REPO='me/my-vault'"
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  assert_eq "$(git --git-dir="$STUB/gh-my-vault.git" rev-list --count HEAD)" "1"
}

t_init_recipient_mismatch_stops() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save)
  use_machine F
  expect_rc 1 init --generate-key --repo "$T/remote.git"
  assert_contains "$OUT" "encrypted for a different key"
}

t_recipient_mismatch_refusal() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  mv "$ENVORA_KEY" "$ENVORA_KEY.orig"
  age-keygen -o "$ENVORA_KEY" 2>/dev/null
  printf 'A=2\n' >"$p/.env"
  expect_rc 1 save
  assert_contains "$OUT" "encrypted for a different key"
  expect_rc 1 restore
  assert_contains "$OUT" "encrypted for a different key"
  # older vault without .recipient: still refused because files do not decrypt
  git -C "$ENVORA_VAULT" rm -q .recipient
  git -C "$ENVORA_VAULT" commit -q -m "drop recipient"
  expect_rc 1 save
  assert_contains "$OUT" "cannot decrypt the files already in the vault"
}

t_import_vercel_stub() {
  local p
  p="$(mkproject web)"
  mkdir -p "$p/.vercel"
  printf '{"projectId":"prj_1","orgId":"team_1"}\n' >"$p/.vercel/project.json"
  printf 'LOCAL=keep\n' >"$p/.env.production"
  cat >"$STUB/vercel.production.env" <<'EOF'
# Created by Vercel CLI
API_KEY="[SENSITIVE]"
PUBLIC_URL="https://example.com"
VERCEL_OIDC_TOKEN="eyJ.short.lived"
EOF
  printf '# Created by Vercel CLI\nDEV="1"\n' >"$STUB/vercel.development.env"
  printf '# Created by Vercel CLI\nPREV="1"\n' >"$STUB/vercel.preview.env"
  printf '{"targets":[{"slug":"production"},{"slug":"preview"},{"slug":"development"},{"slug":"staging"}]}\n' >"$STUB/vercel.targets.json"
  printf '# Created by Vercel CLI\nST="1"\n' >"$STUB/vercel.staging.env"
  cd "$p"
  expect_rc 0 import vercel
  assert_contains "$OUT" "1 secret is write-only on Vercel, value unknown"
  assert_contains "$OUT" "ev status --values"
  local snap="$ENVORA_VAULT/web/@vercel/production.env.age"
  assert_file "$snap"
  assert_file "$ENVORA_VAULT/web/@vercel/staging.env.age"
  local plain
  plain="$(age -d -i "$ENVORA_KEY" "$snap")"
  assert_not_contains "$plain" "VERCEL_OIDC_TOKEN"
  assert_contains "$plain" 'PUBLIC_URL="https://example.com"'
  assert_eq "$(cat "$p/.env.production")" "LOCAL=keep" "project files untouched"
  assert_no_file "$ENVORA_VAULT/web/.env.production.age"
  # the entry is claimed by this repository, as a save would
  assert_eq "$(cat "$ENVORA_VAULT/web/.origin")" "git@github.com:me/web.git"
  # options import does not use are refused, never ignored
  expect_rc 1 import vercel --dry-run
  assert_contains "$OUT" "--dry-run is not used by import vercel"
  expect_rc 1 import vercel --update-shared
  expect_rc 1 import vercel --env=--debug
  assert_contains "$OUT" "invalid environment name"
  # a Secret (write-only) exists on Vercel: never reported as missing there
  printf 'API_KEY=local\nPUBLIC_URL="https://example.com"\n' >"$p/.env.production"
  expect_rc 0 status
  assert_contains "$OUT" "1 write-only (value unknown)"
  assert_not_contains "$OUT" "only in .env.production (API_KEY"
  assert_not_contains "$OUT" "changed (API_KEY"
  printf 'LOCAL=keep\n' >"$p/.env.production"
  # previous snapshot knows the secret value: it survives
  printf '# Created by Vercel CLI\nAPI_KEY="real-secret"\nPUBLIC_URL="https://example.com"\n' |
    age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$snap"
  git -C "$ENVORA_VAULT" commit -q -am "known secret"
  expect_rc 0 import vercel --env production
  plain="$(age -d -i "$ENVORA_KEY" "$snap")"
  assert_contains "$plain" 'API_KEY="real-secret"'
  assert_not_contains "$OUT" "write-only"
  assert_contains "$OUT" "1 value carried over from the previous snapshot"
  # snapshots can be read back
  expect_rc 0 status
  assert_contains "$OUT" "@vercel/production.env"
  assert_contains "$OUT" "only in Vercel"
  expect_rc 0 status --values
  assert_contains "$OUT" 'PUBLIC_URL="https://example.com"'

  assert_not_contains "$(cat "$STUB/vercel.log")" "--value"
  # vercel errors are shown, not hidden
  touch "$STUB/vercel.fail"
  expect_rc 1 import vercel --env production
  assert_contains "$OUT" "not authorized"
}

t_legacy_vercel_copies_flagged() {
  local p
  p="$(mkproject web)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  printf '# Created by Vercel CLI\nDB="prod"\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/web/.env.production.age"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -q -m "v0 vercel copy"
  expect_rc 0 restore --yes -q
  assert_contains "$OUT" "ev: warning: .env.production is a Vercel snapshot saved by envora 0.x"
  run_ev doctor
  assert_contains "$OUT" "ev forget web .env.production"
}

t_import_vercel_not_linked() {
  local p
  p="$(mkproject web)"
  cd "$p"
  expect_rc 1 import vercel
  assert_contains "$OUT" "not linked to Vercel"
}

t_export_cloudflare_stub() {
  local p
  p="$(mkproject worker)"
  mkdir -p "$p/apps/edge"
  printf 'name = "edge-worker"\nmain = "src/index.ts"\n\n[vars]\nname = "nope"\n' >"$p/apps/edge/wrangler.toml"
  printf 'API_TOKEN="tok en"\nMULTI="line1\\nline2"\nNEW_ONE=1\n' >"$p/apps/edge/.dev.vars"
  printf 'STAGE_ONLY=1\n' >"$p/apps/edge/.dev.vars.staging"
  printf '[{"name":"API_TOKEN","type":"secret_text"},{"name":"REMOTE_ONLY","type":"secret_text"}]\n' >"$STUB/wrangler.list.json"
  cd "$p"
  expect_rc 0 save
  # dry run: plan only
  expect_rc 0 export cloudflare --dry-run
  assert_contains "$OUT" "+ add      MULTI NEW_ONE"
  assert_contains "$OUT" "~ update   API_TOKEN"
  assert_contains "$OUT" "kept     REMOTE_ONLY  (only on Cloudflare"
  assert_contains "$OUT" "Worker edge-worker (deployed, top-level)"
  assert_no_file "$STUB/wrangler.stdin"
  # no confirmation, no terminal: refused
  expect_rc 1 export cloudflare
  assert_contains "$OUT" "add --yes"
  expect_rc 0 export cloudflare --yes
  assert_file "$STUB/wrangler.stdin"
  assert_eq "$(jq -r '.API_TOKEN' "$STUB/wrangler.stdin")" "tok en"
  assert_eq "$(jq -r '.MULTI' "$STUB/wrangler.stdin")" "$(printf 'line1\nline2')"
  assert_eq "$(jq -r 'keys | join(",")' "$STUB/wrangler.stdin")" "API_TOKEN,MULTI,NEW_ONE"
  assert_contains "$(cat "$STUB/wrangler.log")" "secret list --format json --config $p/apps/edge/wrangler.toml (cwd=$p/apps/edge)"
  assert_contains "$(cat "$STUB/wrangler.log")" "secret bulk --config $p/apps/edge/wrangler.toml (cwd=$p/apps/edge)"
  assert_not_contains "$(cat "$STUB/wrangler.log")" "tok en"
  # --env picks .dev.vars.<env> and passes --env
  expect_rc 0 export cloudflare --env staging --yes
  assert_eq "$(jq -c . "$STUB/wrangler.stdin")" '{"STAGE_ONLY":"1"}'
  assert_contains "$(tail -n 1 "$STUB/wrangler.log")" "secret bulk --config $p/apps/edge/wrangler.toml --env staging"
  # local file differs from the vault: warned
  printf 'API_TOKEN=newer\n' >"$p/apps/edge/.dev.vars"
  expect_rc 0 export cloudflare --dry-run
  assert_contains "$OUT" "your local apps/edge/.dev.vars has changes the vault does not have"
  # a dotenv key that looks like an option never reaches the wrangler argv
  # or the payload; KEY: value lines are read like dotenv does
  printf -- '--scope=evil\nGOOD=1\nCOLON: yes\n' >"$p/apps/edge/.dev.vars"
  expect_rc 0 save
  expect_rc 0 export cloudflare --yes
  assert_contains "$OUT" "! skipped  --scope"
  assert_eq "$(jq -cS . "$STUB/wrangler.stdin")" '{"COLON":"yes","GOOD":"1"}'
}

t_export_cloudflare_pages() {
  local p
  p="$(mkproject site)"
  printf '{\n  // comment\n  "name": "site",\n  "pages_build_output_dir": "./dist"\n}\n' >"$p/wrangler.jsonc"
  printf 'S=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save
  expect_rc 1 export cloudflare --env staging --yes
  assert_contains "$OUT" "only has the production and preview"
  expect_rc 0 export cloudflare --yes
  assert_contains "$OUT" "kept     OLD_SECRET"
  assert_contains "$OUT" "Pages project site (production)"
  assert_contains "$(tail -n 1 "$STUB/wrangler.log")" "pages secret bulk --project-name=site (cwd=$p)"
  assert_eq "$(jq -c . "$STUB/wrangler.stdin")" '{"S":"1"}'
  # the name wrangler will use: comments, nested names and trailing commas ignored
  printf '{\n  "$schema": "https://x/schema.json", // "name": "old-site",\n  /* "name": "older" */\n  "name": "real-site",\n  "vars": {"name": "nope",},\n  "pages_build_output_dir": "./dist",\n}\n' >"$p/wrangler.jsonc"
  expect_rc 0 export cloudflare --dry-run
  assert_contains "$OUT" "Pages project real-site"
  # a Worker whose config only mentions pages_build_output_dir in a comment
  rm "$p/wrangler.jsonc"
  printf '# migrated from Pages: removed pages_build_output_dir\nname = "edge-worker" # the worker\n' >"$p/wrangler.toml"
  expect_rc 0 export cloudflare --dry-run -q
  assert_contains "$OUT" "Worker edge-worker"
  assert_contains "$OUT" "dry run: nothing sent"
}

t_export_cloudflare_safety() {
  local p other
  p="$(mkproject cfw)"
  printf 'name = "cfw"\n' >"$p/wrangler.toml"
  printf 'API_TOKEN=tok\n' >"$p/.dev.vars"
  cd "$p"
  expect_rc 0 save
  # another repo with the same name never receives these secrets
  other="$T/A/home/work/cfw"
  mkdir -p "$other"
  git -C "$other" init -q
  git -C "$other" remote add origin git@github.com:acme/cfw.git
  printf 'name = "acme-worker"\n' >"$other/wrangler.toml"
  cd "$other"
  expect_rc 1 export cloudflare --yes
  assert_contains "$OUT" "belongs to another repository"
  assert_no_file "$STUB/wrangler.stdin"
  # --env never falls back to the local development file
  cd "$p"
  expect_rc 1 export cloudflare --env production --yes
  assert_contains "$OUT" "no .dev.vars.production or .env.production saved"
  assert_contains "$OUT" "--file .dev.vars"
  assert_no_file "$STUB/wrangler.stdin"
  expect_rc 0 export cloudflare --env production --file .dev.vars --yes
  assert_eq "$(jq -c . "$STUB/wrangler.stdin")" '{"API_TOKEN":"tok"}'
  # quotes in a command setting are refused, not passed literally
  ENVORA_WRANGLER_CMD="wrangler --profile 'my prof'" expect_rc 1 export cloudflare --dry-run
  assert_contains "$OUT" "quotes and backslashes are not supported"
  # monorepo: the config of the current folder is picked
  local m
  m="$(mkproject mono)"
  mkdir -p "$m/apps/edge/src" "$m/apps/api"
  printf 'name = "edge"\n' >"$m/apps/edge/wrangler.toml"
  printf 'name = "api"\n' >"$m/apps/api/wrangler.toml"
  printf 'E=1\n' >"$m/apps/edge/.dev.vars"
  cd "$m"
  expect_rc 0 save
  expect_rc 1 export cloudflare --dry-run
  assert_contains "$OUT" "several Cloudflare configs"
  cd "$m/apps/edge/src"
  expect_rc 0 export cloudflare --dry-run
  assert_contains "$OUT" "Worker edge"
  # a wrangler.json at the root (wrangler would find it from apps/edge): the
  # config of the folder is passed explicitly, the root one is never used
  printf '{"name":"root-worker"}\n' >"$m/wrangler.json"
  expect_rc 0 export cloudflare --yes
  assert_contains "$(tail -n 1 "$STUB/wrangler.log")" "secret bulk --config $m/apps/edge/wrangler.toml (cwd=$m/apps/edge)"
  # -C <subdir> (what the menu passes) picks the same config
  cd "$T"
  expect_rc 0 export cloudflare -C "$m/apps/edge/src" --dry-run
  assert_contains "$OUT" "Worker edge"
  # without --env, the plan says the target is the deployed Worker
  assert_contains "$OUT" "the deployed Worker (no --env)"
}

t_export_vercel_stub() {
  local p
  p="$(mkproject web)"
  mkdir -p "$p/.vercel"
  printf '{}\n' >"$p/.vercel/project.json"
  printf 'EXISTING=new-value\nFRESH="with space"\nSAME=plain\n' >"$p/.env.production"
  cat >"$STUB/vercel.ls.production.json" <<'EOF'
{"envs":[
 {"key":"EXISTING","type":"sensitive","target":["production"],"gitBranch":null},
 {"key":"SAME","value":"plain","type":"plain","target":["production","preview"]},
 {"key":"ONLY_REMOTE","type":"encrypted","target":["production"]},
 {"key":"FRESH","type":"encrypted","target":["preview"]},
 {"key":"BRANCHY","type":"encrypted","target":["production"],"gitBranch":"feat"}
]}
EOF
  cd "$p"
  expect_rc 0 save
  expect_rc 0 export vercel --dry-run
  assert_contains "$OUT" "+ add      FRESH"
  assert_contains "$OUT" "~ update   EXISTING"
  assert_contains "$OUT" "= same     SAME"
  assert_contains "$OUT" "kept     ONLY_REMOTE  (only on Vercel"
  assert_no_file "$STUB/vercel.stdin"
  expect_rc 0 export vercel --yes
  assert_contains "$OUT" "FRESH  added"
  assert_contains "$OUT" "EXISTING  updated"
  assert_contains "$(cat "$STUB/vercel.stdin")" "add production FRESH=with space"
  assert_contains "$(cat "$STUB/vercel.stdin")" "update production EXISTING=new-value"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "SAME"
  assert_not_contains "$(cat "$STUB/vercel.log")" "new-value"
  assert_contains "$(cat "$STUB/vercel.log")" "env add FRESH production --yes --non-interactive"
  assert_contains "$(cat "$STUB/vercel.log")" "env ls production --format json --non-interactive"
  # preview: a new key is really added (vercel would prompt for a branch)
  printf 'NEWK=secret-value\nURL=$BASE/api\n--scope=evil-team\n' >"$p/.env.preview"
  printf '{"envs":[]}\n' >"$STUB/vercel.ls.preview.json"
  expect_rc 0 save
  expect_rc 0 export vercel --env preview --yes
  assert_contains "$(cat "$STUB/vercel.stdin")" "add preview NEWK=secret-value"
  assert_contains "$OUT" "! skipped  --scope"
  assert_contains "$OUT" "URL  (the value contains \$NAME"
  assert_not_contains "$(cat "$STUB/vercel.log")" "--scope"
  # explicit file needs an env when it cannot be guessed
  printf 'X=1\n' >"$p/.env.custom"
  expect_rc 0 save
  expect_rc 1 export vercel --file .env.custom --yes
  assert_contains "$OUT" "which Vercel environment"
}

t_export_vercel_shared_branch_empty() {
  local p
  p="$(mkproject web)"
  mkdir -p "$p/.vercel"
  printf '{}\n' >"$p/.vercel/project.json"
  printf 'DATABASE_URL=postgres://localhost/dev\nPREV_BRANCHY=x\nEMPTY=\nOWN=1\n' >"$p/.env.development"
  cat >"$STUB/vercel.ls.development.json" <<'EOF'
{"envs":[
 {"key":"DATABASE_URL","type":"encrypted","target":["production","preview","development"]},
 {"key":"PREV_BRANCHY","type":"encrypted","target":["development"]},
 {"key":"PREV_BRANCHY","type":"encrypted","target":["development"],"gitBranch":"feat"},
 {"key":"OWN","type":"encrypted","target":["development"]}
]}
EOF
  cd "$p"
  expect_rc 0 save
  expect_rc 0 export vercel --env development --yes
  assert_contains "$OUT" "! shared   DATABASE_URL (also production, preview)"
  assert_contains "$OUT" "updating it changes them all
             skipped: add --update-shared to update them anyway"
  assert_contains "$OUT" "PREV_BRANCHY  (also has branch-specific values"
  assert_contains "$OUT" "EMPTY  (empty value"
  assert_contains "$(cat "$STUB/vercel.stdin")" "update development OWN=1"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "DATABASE_URL"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "EMPTY"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "PREV_BRANCHY"
  expect_rc 0 export vercel --env development --update-shared --yes
  assert_contains "$(cat "$STUB/vercel.stdin")" "update development DATABASE_URL=postgres://localhost/dev"
  # a variable that also serves a custom environment (env ls has no
  # customEnvironmentIds): found by listing that environment, so it is shared
  printf '{"targets":[{"slug":"production"},{"slug":"staging"}]}\n' >"$STUB/vercel.targets.json"
  cat >"$STUB/vercel.ls.development.json" <<'EOF'
{"envs":[{"key":"OWN","type":"encrypted","target":["development"],"createdAt":111}]}
EOF
  cat >"$STUB/vercel.ls.staging.json" <<'EOF'
{"envs":[{"key":"OWN","type":"encrypted","target":[],"createdAt":111}]}
EOF
  rm -f "$STUB/vercel.stdin"
  expect_rc 0 export vercel --env development --yes
  assert_contains "$OUT" "! shared   OWN (also staging)"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "OWN"
  # repo link (vercel link --repo) counts as linked
  local m
  m="$(mkproject mono)"
  mkdir -p "$m/.vercel" "$m/apps/site"
  printf '{"remoteName":"origin","projects":[{"id":"p1","name":"site","directory":"apps/site"}]}\n' >"$m/.vercel/repo.json"
  printf 'S=1\n' >"$m/apps/site/.env.production"
  printf '{"envs":[]}\n' >"$STUB/vercel.ls.production.json"
  cd "$m"
  expect_rc 0 save
  expect_rc 0 export vercel --dry-run
  assert_contains "$OUT" "Vercel production (apps/site)"
}

t_deprecated_aliases() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 push-local
  assert_contains "$OUT" '"push-local" is deprecated, use "save"'
  assert_file "$ENVORA_VAULT/app/.env.age"
  rm "$p/.env"
  expect_rc 0 pull
  assert_contains "$OUT" '"pull" is deprecated, use "restore"'
  assert_file "$p/.env"
  expect_rc 0 diff
  assert_contains "$OUT" "in sync"
  expect_rc 0 push
  assert_contains "$OUT" "ev import vercel"
  cd "$T"
  expect_rc 0 push-local app
  expect_rc 0 pull app
  expect_rc 1 vercel
  assert_contains "$OUT" '"vercel" is deprecated, use "import vercel"'
  expect_rc 0 clean app --yes
  assert_no_file "$ENVORA_VAULT/app"
  assert_eq "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "forget: app"
}

t_hooks_contract() {
  local p
  p="$(mkproject app)"
  cd "$T"
  # nothing in the vault yet: restore after clone is a silent success
  expect_rc 0 restore -C "$p" --yes --quiet
  assert_eq "$OUT" ""
  # nothing to save: success, silent
  expect_rc 0 save -C "$p" --yes --quiet
  assert_eq "$OUT" ""
  printf 'A=1\n' >"$p/.env"
  expect_rc 0 save -C "$p" --yes --quiet
  assert_eq "$OUT" ""
  assert_eq "$(remote_commits)" "$(commits)"
  # restore into a fresh clone, quiet
  rm "$p/.env"
  expect_rc 0 restore -C "$p" --yes --quiet
  assert_eq "$OUT" ""
  assert_file "$p/.env"
  # offline: 3, with a one-line warning on stderr
  mv "$T/remote.git" "$T/remote.gone"
  printf 'A=2\n' >"$p/.env"
  expect_rc 3 save -C "$p" --yes --quiet
  assert_contains "$OUT" "ev: warning:"
  assert_contains "$OUT" "ev: error: PUSH FAILED"
  # unpushed commits from before also give 3 even if nothing new to save
  expect_rc 3 save -C "$p" --yes --quiet
  mv "$T/remote.gone" "$T/remote.git"
  expect_rc 0 save -C "$p" --yes --quiet
  assert_eq "$(remote_commits)" "$(commits)"
  # real failure: 1
  expect_rc 1 save -C "$T/does-not-exist" --yes --quiet
  chmod 000 "$ENVORA_KEY"
  if [[ ! -r "$ENVORA_KEY" ]]; then
    printf 'A=3\n' >"$p/.env"
    expect_rc 1 save -C "$p" --yes --quiet
  fi
  chmod 600 "$ENVORA_KEY"
}

t_parallel_saves_are_serialized() {
  local p q
  p="$(mkproject app1)"
  q="$(mkproject app2)"
  printf 'A=1\n' >"$p/.env"
  printf 'B=1\n' >"$q/.env"
  "$TEST_BASH" "$EV" save -C "$p" --yes --quiet </dev/null >"$T/out1" 2>&1 &
  local pid1=$!
  "$TEST_BASH" "$EV" save -C "$q" --yes --quiet </dev/null >"$T/out2" 2>&1 &
  local pid2=$!
  local rc1=0 rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?
  assert_eq "$rc1:$rc2" "0:0" "both saves succeed: $(cat "$T/out1" "$T/out2")"
  assert_file "$ENVORA_VAULT/app1/.env.age"
  assert_file "$ENVORA_VAULT/app2/.env.age"
  assert_eq "$(remote_commits)" "$(commits)"
  assert_no_file "$(git -C "$ENVORA_VAULT" rev-parse --absolute-git-dir)/envora.lock"
}

t_status_report() {
  local p
  p="$(mkproject app)"
  printf 'A=1\nB=2\n' >"$p/.env"
  printf 'X=1\n' >"$p/.env.old"
  cd "$p"
  expect_rc 0 save
  printf 'A=1\nB=changed\nC=new\n' >"$p/.env"
  printf 'N=1\n' >"$p/.env.local"
  rm "$p/.env.old"
  expect_rc 0 status
  assert_contains "$OUT" "1 key only in project (C)"
  assert_contains "$OUT" "1 value changed (B)"
  assert_not_contains "$OUT" "changed\n"
  assert_contains "$OUT" "only in project (not saved yet)"
  assert_contains "$OUT" "only in vault (missing here)"
  assert_contains "$OUT" "synced with GitHub"
  assert_not_contains "$OUT" "B=changed"
  expect_rc 0 status --values
  assert_contains "$OUT" "+B=changed"
  expect_rc 0 save
  assert_contains "$OUT" "kept in the vault, missing here: .env.old"
}

t_list_and_forget() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  printf 'B=1\n' >"$p/.env.local"
  (cd "$p" && expect_rc 0 save)
  expect_rc 0 list
  assert_contains "$OUT" "app"
  assert_contains "$OUT" "2 files"
  assert_contains "$OUT" "on this machine: ~/projects/app"
  expect_rc 1 forget app .env.local
  assert_contains "$OUT" "add --yes"
  expect_rc 0 forget app .env.local --yes
  assert_no_file "$ENVORA_VAULT/app/.env.local.age"
  assert_eq "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "forget: app (.env.local)"
  expect_rc 0 forget app --yes
  assert_no_file "$ENVORA_VAULT/app"
  assert_eq "$(git -C "$ENVORA_VAULT" log -1 --format=%s)" "forget: app"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
  assert_eq "$(remote_commits)" "$(commits)"
}

t_config_rc_parsing() {
  local p
  # values with spaces, quotes, tilde; unknown keys and code are ignored
  cat >"$HOME/.envorarc" <<'EOF'
ENVORA_PROJECTS="~/my projects"
ENVORA_REPO=me/vault
EVIL=$(touch /tmp/should-not-exist)
ENVORA_KEY=$(touch "$HOME/pwned")
EOF
  unset ENVORA_PROJECTS
  expect_rc 0 config get projects
  assert_eq "$OUT" "$HOME/my projects"
  assert_no_file "$HOME/pwned"
  expect_rc 0 config get repo
  assert_eq "$OUT" "me/vault"
  # environment overrides the file
  ENVORA_REPO=other/repo expect_rc 0 config get repo
  assert_eq "$OUT" "other/repo"
  # set writes escaped values and reads them back
  expect_rc 0 config set projects "~/dir with \$dollar and 'quote'"
  expect_rc 0 config get projects
  assert_eq "$OUT" "$HOME/dir with \$dollar and 'quote'"
  expect_rc 1 config set vault relative/path
  expect_rc 1 config set nope x
  # non-ASCII survives the round trip; control characters are refused
  unset ENVORA_VAULT ENVORA_KEY
  LC_ALL=C expect_rc 0 config set vault "~/Coffre é"
  expect_rc 0 config get vault
  assert_eq "$OUT" "$HOME/Coffre é"
  expect_rc 1 config set vault "$(printf '/a\tb')"
  assert_contains "$OUT" "control characters"
  # values from the environment or the defaults are never written to the file
  ENVORA_KEY=/tmp/temporary-key expect_rc 0 config set repo me/other
  assert_not_contains "$(cat "$HOME/.envorarc")" "temporary-key"
  ENVORA_REPO=env/wins expect_rc 0 config set repo me/third
  assert_contains "$OUT" "also set in your environment"
  # an unreadable line is reported, not silently replaced by the default
  printf "ENVORA_PROJECTS=\$'/x\\ty'\n" >>"$HOME/.envorarc"
  expect_rc 0 config get projects
  assert_contains "$OUT" "cannot read ENVORA_PROJECTS"
  # a comment after the value is not part of it
  printf 'ENVORA_VERCEL_CMD="vercel --scope x" # my team\nENVORA_REPO=me/v   # vault repo\n' >"$HOME/.envorarc"
  expect_rc 0 config get vercel-cmd
  assert_eq "$OUT" "vercel --scope x"
  expect_rc 0 config get repo
  assert_eq "$OUT" "me/v"
  expect_rc 1 config get
  assert_contains "$OUT" "usage: ev config get <setting>"
}

t_dotenv_parser() {
  # shellcheck source=lib/ui.sh
  . "$ROOT/lib/ui.sh"
  # shellcheck source=lib/util.sh
  . "$ROOT/lib/util.sh"
  local got
  # same results as the dotenv package used by wrangler and Next.js
  got="$({ printf '\357\273\277'; printf '%s\n' \
    'FIRST=bom' \
    '# comment' \
    'export A=1' \
    'B = two  # inline comment' \
    'HASH=abc#def' \
    "C='single # not comment'" \
    'D="dq \"esc\" \n done"' \
    'TAB="x\ty"' \
    'E="multi' \
    'line"' \
    'F=' \
    'not a var' \
    'G.H-I=dots' \
    'BROKEN="unterminated' \
    'TOKEN=after-broken' \
    'COLON: yes' \
    'URL:http://not-a-var' \
    'LAST="ok" # c'; } | dotenv_json x | jq -c '{(.k): .v}' | jq -Sc -s add)"
  assert_eq "$got" '{"A":"1","B":"two","BROKEN":"\"unterminated","C":"single # not comment","COLON":"yes","D":"dq \\\"esc\\\" \n done","E":"multi\nline","F":"","FIRST":"bom","G.H-I":"dots","HASH":"abc","LAST":"ok","TAB":"x\\ty","TOKEN":"after-broken"}'
}

t_menu_previews_and_items() {
  local p out item
  p="$(mkproject app)"
  mkdir -p "$p/.vercel" "$p/worker"
  printf '{}\n' >"$p/.vercel/project.json"
  printf 'name = "w"\n' >"$p/worker/wrangler.toml"
  printf 'A=1\n' >"$p/.env"
  printf 'S=1\n' >"$p/worker/.dev.vars"
  (cd "$p" && expect_rc 0 save)
  printf 'A=2\nB=1\n' >"$p/.env"
  for item in save restore compare import-vercel export-vercel export-cloudflare browse sync doctor rotate keys config sep p:app; do
    out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview "$item" 2>&1 </dev/null)" || fail "_preview $item failed: $out"
    assert_not_contains "$out" "unbound variable" "_preview $item"
    assert_not_contains "$out" "command not found" "_preview $item"
  done
  out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview save 2>&1)"
  assert_contains "$out" "changed here → replaces the vault copy"
  assert_contains "$out" "adds B to the vault · updates A"
  out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview restore 2>&1)"
  assert_contains "$out" "removes B from your file · sets A to the vault value"
  out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview export-cloudflare 2>&1)"
  assert_contains "$out" "Worker w"
  out="$(ENVORA_MENU_PROJECT=app ENVORA_MENU_PROJECT_DIR="$p" "$TEST_BASH" "$EV" _preview v-restore 2>&1)"
  assert_contains "$out" "differs"
  out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview export-vercel 2>&1)"
  assert_contains "$out" "linked folder: project root"
  out="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview sep 2>&1)"
  assert_contains "$out" "whole vault"
  out="$(ENVORA_MENU_PROJECT=app "$TEST_BASH" "$EV" _preview v-forget 2>&1)"
  assert_contains "$out" "worker/.dev.vars"
  # menu building blocks, under the same bash
  out="$(cd "$p" && "$TEST_BASH" -c '
    set -euo pipefail
    for f in ui util config crypto project vault commands help menu providers/common providers/vercel providers/cloudflare; do
      . "$1/lib/$f.sh"
    done
    ui_init_colors; ev_setup_tmp; load_config; ARG_C=""; ARG_AS=""
    detect_current_project
    require_key
    save_plan
    menu_items_project
    menu_header_project
    echo
    menu_items_vault
  ' _ "$ROOT" 2>&1)" || fail "menu blocks failed: $out"
  assert_contains "$out" "Import Vercel"
  assert_contains "$out" "Send to Cloudflare"
  assert_contains "$out" "1 to save"
  assert_contains "$out" "Worker secrets"
  assert_contains "$out" "Rotate key"
  assert_contains "$out" "p:app"
  assert_contains "$out" "~/projects/app"
  assert_contains "$out" "─── whole vault"
}

t_symlink_install() {
  local p
  mkdir -p "$T/bin2"
  ln -s "$EV" "$T/bin2/ev"
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  RC=0
  OUT="$("$TEST_BASH" "$T/bin2/ev" save 2>&1 </dev/null)" || RC=$?
  assert_eq "$RC" "0" "$OUT"
  RC=0
  OUT="$("$TEST_BASH" "$T/bin2/ev" --version 2>&1)" || RC=$?
  assert_eq "$OUT" "ev 1.0.0"
}

t_help_and_doctor() {
  expect_rc 0 help
  assert_contains "$OUT" "project → vault"
  assert_contains "$OUT" "EXIT CODES"
  expect_rc 0 help save
  assert_contains "$OUT" "3 saved and committed locally but NOT pushed"
  expect_rc 0 save --help
  assert_contains "$OUT" "ev save"
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  printf 'NOT_IGNORED=1\n' >"$p/.dev.vars.local"
  printf '.env*\n' >"$p/.gitignore"
  cd "$p"
  run_ev doctor
  assert_contains "$OUT" "✓ key readable"
  assert_contains "$OUT" ".dev.vars.local is not ignored by git"
  assert_eq "$RC" "1"
  expect_rc 0 save
  printf '.env*\n.dev.vars*\n' >"$p/.gitignore"
  run_ev doctor
  assert_contains "$OUT" "open with your key"
  # a file only an old key opens, and one no key opens
  cp "$ENVORA_KEY" "$ENVORA_KEY.bak-20260101-000000"
  printf 'O=1\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/app/.env.old.age"
  age-keygen -o "$T/newkey" 2>/dev/null
  cp "$T/newkey" "$ENVORA_KEY"
  printf '%s\n' "$(age-keygen -y "$ENVORA_KEY")" >"$ENVORA_VAULT/.recipient"
  printf 'L=1\n' | age -r "$(age-keygen 2>/dev/null | age-keygen -y)" -o "$ENVORA_VAULT/app/.env.lost.age"
  run_ev doctor
  assert_contains "$OUT" "still encrypted for an old key"
  assert_contains "$OUT" "ev rotate"
  assert_contains "$OUT" "open with none of your keys: app/.env.lost"
  # an fzf too old for the menu is reported
  mkdir -p "$T/oldfzf"
  printf '#!/bin/sh\necho "0.44.1 (debian)"\n' >"$T/oldfzf/fzf"
  chmod +x "$T/oldfzf/fzf"
  PATH="$T/oldfzf:$PATH" run_ev doctor
  assert_contains "$OUT" "fzf 0.44.1 is too old for the menu"
}

# --- round 2: sync, identity, safety -----------------------------------------

t_sync_lost_conflict_is_not_stale() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  # B saves offline (older), A saves later (newer): A wins the sync conflict
  printf 'A=1\nB_ONLY=b\n' >"$pb/.env"
  (cd "$pb" && GIT_COMMITTER_DATE="2026-01-01T10:00:00" GIT_AUTHOR_DATE="2026-01-01T10:00:00" expect_rc 3 save --no-sync -q -y)
  use_machine A
  printf 'A=1\nA_ONLY=a\n' >"$p/.env"
  (cd "$p" && GIT_COMMITTER_DATE="2026-01-01T11:00:00" GIT_AUTHOR_DATE="2026-01-01T11:00:00" expect_rc 0 save -q -y)
  use_machine B
  # B's copy was edited here: never "unchanged here, newer in the vault"
  expect_rc 0 status -C "$pb"
  assert_contains "$OUT" "kept the other machine's version"
  assert_contains "$OUT" "changed here AND in the vault"
  assert_not_contains "$OUT" "unchanged since"
  # restore asks / backs up instead of updating it silently as "stale"
  expect_rc 0 restore -C "$pb" -q -y
  assert_contains "$OUT" "differed from the vault: replaced by the vault version (backup: "
  printf 'A=1\nB_ONLY=b\n' >"$pb/.env"
  # the wipe hook: exit 0 means the folder's contents ARE the vault's version
  expect_rc 0 save -C "$pb" --yes --quiet
  assert_eq "$(age -d -i "$key" "$ENVORA_VAULT/app/.env.age")" "$(printf 'A=1\nB_ONLY=b')"
  assert_eq "$(remote_commits)" "$(commits)"
}

t_sync_push_race_never_claims_saved() {
  local key="$T/A/home/.age/key.txt" p pb x
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  # A's newer commit reaches GitHub between B's fetch and B's push
  use_machine A
  printf 'A=1\nFROM_A=yes\n' >"$p/.env"
  (cd "$p" && GIT_COMMITTER_DATE="2026-01-01T11:00:00" expect_rc 3 save -q -y --no-sync)
  x="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  git -C "$ENVORA_VAULT" push -q origin HEAD:refs/heads/side
  cat >"$T/remote.git/hooks/pre-receive" <<HOOK
#!/bin/sh
if [ ! -f "$T/raced" ]; then
  touch "$T/raced"
  unset GIT_QUARANTINE_PATH
  git update-ref refs/heads/main $x
  echo "someone pushed first" >&2
  exit 1
fi
exit 0
HOOK
  chmod +x "$T/remote.git/hooks/pre-receive"
  use_machine B
  printf 'A=1\nFROM_B=yes\n' >"$pb/.env"
  GIT_COMMITTER_DATE="2026-01-01T10:00:00" expect_rc 1 save -C "$pb" --yes
  assert_contains "$OUT" "another machine saved a different version at the same moment"
  assert_not_contains "$OUT" "saved to the vault (app) · pushed"
  # saving again keeps this folder's version (it was edited here)
  expect_rc 0 save -C "$pb" --yes --quiet
  assert_eq "$(age -d -i "$key" "$ENVORA_VAULT/app/.env.age")" "$(printf 'A=1\nFROM_B=yes')"
}

t_sync_rotate_race_keeps_other_save() {
  local key="$T/A/home/.age/key.txt" p pb x
  p="$(mkproject app)"
  printf 'TOKEN=v1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  printf 'TOKEN=v2-from-B\n' >"$pb/.env"
  (cd "$pb" && GIT_COMMITTER_DATE="2026-01-01T10:00:00" expect_rc 3 save -q -y --no-sync)
  x="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  git -C "$ENVORA_VAULT" push -q origin HEAD:refs/heads/side
  cat >"$T/remote.git/hooks/pre-receive" <<HOOK
#!/bin/sh
if [ ! -f "$T/raced" ]; then
  touch "$T/raced"
  unset GIT_QUARANTINE_PATH
  git update-ref refs/heads/main $x
  exit 1
fi
exit 0
HOOK
  chmod +x "$T/remote.git/hooks/pre-receive"
  # A rotates (a newer commit that changes no value): B's edit must survive
  use_machine A
  expect_rc 0 rotate --yes
  assert_not_contains "$OUT" "conflict on"
  git clone -q "$T/remote.git" "$T/check"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$T/check/app/.env.age")" "TOKEN=v2-from-B"
}

t_two_folders_one_project_never_revert() {
  local p wt
  p="$(mkproject app)"
  printf 'TOKEN=old\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  wt="$ENVORA_PROJECTS/app-wt"
  git -C "$p" worktree add -q "$wt" -b wt 2>/dev/null
  expect_rc 0 restore -C "$wt" -q -y
  printf 'TOKEN=new-rotated\n' >"$wt/.env"
  expect_rc 0 save -C "$wt" -q -y
  # the main copy was never edited: it is behind, not newer
  expect_rc 0 status -C "$p"
  assert_contains "$OUT" "newer in the vault"
  expect_rc 0 save -C "$p" --yes --quiet
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "TOKEN=new-rotated"
}

t_sync_interrupt_never_leaves_a_merge() {
  local key="$T/A/home/.age/key.txt" p pb real pid gd rc=0
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  printf 'A=1\nB=1\n' >"$pb/.env"
  (cd "$pb" && expect_rc 3 save -q -y --no-sync)
  use_machine A
  printf 'A=1\nAA=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  use_machine B
  # a slow decryption keeps the conflict resolution running
  real="$(command -v age)"
  mkdir -p "$T/slow"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -d ] && [ -f "%s/slow/on" ] && sleep 2; done\nexec "%s" "$@"\n' "$T" "$real" >"$T/slow/age"
  chmod +x "$T/slow/age"
  touch "$T/slow/on"
  # job control: the job gets its own process group and keeps SIGINT (a
  # non-interactive shell starts background jobs with SIGINT ignored)
  set -m
  PATH="$T/slow:$PATH" "$TEST_BASH" "$EV" sync </dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -INT -- "-$pid"
  wait "$pid" || rc=$?
  set +m
  rm -f "$T/slow/on"
  assert_eq "$rc" "130"
  gd="$(git -C "$ENVORA_VAULT" rev-parse --absolute-git-dir)"
  assert_no_file "$gd/MERGE_HEAD"
  assert_no_file "$gd/rebase-merge"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
}

t_forget_while_another_machine_saves() {
  local key="$T/A/home/.age/key.txt" p pb x
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  printf 'A=2\n' >"$pb/.env"
  (cd "$pb" && expect_rc 3 save -q -y --no-sync)
  x="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  git -C "$ENVORA_VAULT" push -q origin HEAD:refs/heads/side
  cat >"$T/remote.git/hooks/pre-receive" <<HOOK
#!/bin/sh
if [ ! -f "$T/raced" ]; then
  touch "$T/raced"
  unset GIT_QUARANTINE_PATH
  git update-ref refs/heads/main $x
  exit 1
fi
exit 0
HOOK
  chmod +x "$T/remote.git/hooks/pre-receive"
  use_machine A
  expect_rc 1 forget app --yes
  assert_contains "$OUT" "another machine saved app while it was being removed"
  assert_not_contains "$OUT" "removed app"
  assert_file "$ENVORA_VAULT/app/.env.age"
  assert_eq "$(cat "$ENVORA_VAULT/app/.origin")" "git@github.com:me/app.git"
}

t_unicode_and_quote_paths_sync() {
  local key="$T/A/home/.age/key.txt" p pb d
  p="$(mkproject app)"
  mkdir -p "$p/café" "$p/q\"uote"
  printf 'X=1\n' >"$p/café/.env"
  printf 'Q=1\n' >"$p/q\"uote/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -q -y)
  printf 'X=B\n' >"$pb/café/.env"
  printf 'Q=B\n' >"$pb/q\"uote/.env"
  (cd "$pb" && GIT_COMMITTER_DATE="2026-01-01T10:00:00" expect_rc 3 save -q -y --no-sync)
  use_machine A
  printf 'X=A\n' >"$p/café/.env"
  printf 'Q=A\n' >"$p/q\"uote/.env"
  (cd "$p" && GIT_COMMITTER_DATE="2026-01-01T11:00:00" expect_rc 0 save -q -y)
  use_machine B
  expect_rc 0 sync
  assert_contains "$OUT" "conflict on app/café/.env.age"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
  (cd "$pb" && expect_rc 0 save -q -y)
  # a stray file the key cannot decrypt is never committed, whatever its path
  d="$ENVORA_VAULT/app/café"
  printf 'EVIL=1\n' | age -r "$(age-keygen 2>/dev/null | age-keygen -y)" -o "$d/.env.local.age"
  expect_rc 1 status -C "$pb"
  assert_contains "$OUT" "your key cannot decrypt"
  assert_not_contains "$(git -C "$ENVORA_VAULT" log --stat -1)" ".env.local.age"
}

t_origin_credentials_never_stored() {
  local p
  p="$(mkproject tok "https://x-access-token:ghp_SECRET123@github.com/me/tok.git")"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  expect_rc 0 save -y
  assert_eq "$(git --git-dir="$T/remote.git" show HEAD:tok/.origin)" "https://github.com/me/tok.git"
  assert_not_contains "$OUT" "ghp_SECRET123"
  # an entry written by an older version is cleaned on the next save
  printf 'https://u:ghp_OLD@github.com/me/tok.git\n' >"$ENVORA_VAULT/tok/.origin"
  git -C "$ENVORA_VAULT" commit -qam "old origin"
  printf 'A=2\n' >"$p/.env"
  expect_rc 0 save -y
  assert_eq "$(cat "$ENVORA_VAULT/tok/.origin")" "https://github.com/me/tok.git"
  # GitHub ignores case in owner/repo: same project
  git -C "$p" remote set-url origin "https://github.com/Me/Tok.git"
  expect_rc 0 status -q
  assert_not_contains "$OUT" "another repository"
}

t_init_wrong_key_on_vault_without_recipient() {
  local p
  p="$(mkproject old)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  git -C "$ENVORA_VAULT" rm -q .recipient
  git -C "$ENVORA_VAULT" commit -qm "a 0.x vault has no .recipient"
  git -C "$ENVORA_VAULT" push -q
  use_machine C
  expect_rc 1 init --generate-key --repo "$T/remote.git"
  assert_contains "$OUT" "your key cannot decrypt the files already in the vault"
  assert_not_contains "$OUT" "envora is ready"
  mkdir -p "$ENVORA_PROJECTS"
  expect_rc 1 restore -C "$p" -y -q
  assert_contains "$OUT" "your key cannot decrypt"
  assert_not_contains "$OUT" "no identity matched"
}

t_envoraignore_and_dependency_dirs() {
  local p
  p="$(mkproject php)"
  mkdir -p "$p/vendor/vlucas/phpdotenv/tests/fixtures/env" "$p/build" "$p/fixtures"
  printf 'FOO=bar\n' >"$p/vendor/vlucas/phpdotenv/tests/fixtures/env/.env"
  printf 'A=1\n' >"$p/.env"
  cd "$p"
  # a dependency's fixture never blocks the wipe hook
  expect_rc 0 save -y -q
  # a copy in build/ does, with a way out
  printf 'COPY=1\n' >"$p/build/.env"
  expect_rc 1 save -y -q
  assert_contains "$OUT" "NOT saved: build/.env"
  assert_contains "$OUT" ".envoraignore"
  printf '# copies made by the build\nbuild/\nfixtures/*\n' >"$p/.envoraignore"
  printf 'F=1\n' >"$p/fixtures/.env.test"
  expect_rc 0 save -y
  assert_contains "$OUT" "skipped (.envoraignore): fixtures/.env.test"
  assert_no_file "$ENVORA_VAULT/php/fixtures/.env.test.age"
}

t_list_and_browse_follow_the_origin() {
  local p q out
  # folder foo holds repo bar; folder qux holds repo foo
  p="$(mkproject foo "git@github.com:me/bar.git")"
  printf 'B=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  q="$(mkproject qux "git@github.com:me/foo.git")"
  printf 'F=1\n' >"$q/.env"
  (cd "$q" && expect_rc 0 save -q -y)
  rm -rf "$XDG_STATE_HOME/envora/dirs"
  expect_rc 0 list
  assert_contains "$OUT" "bar"
  assert_contains "$(printf '%s\n' "$OUT" | grep '^  bar')" "on this machine: ~/projects/foo"
  assert_contains "$(printf '%s\n' "$OUT" | grep '^  foo')" "on this machine: ~/projects/qux"
  # ev list | head never prints a broken pipe error
  out="$("$TEST_BASH" "$EV" list 2>&1 </dev/null | head -n 1)"
  out="$( ("$TEST_BASH" "$EV" list | head -n 1 >/dev/null) 2>&1 </dev/null)"
  assert_not_contains "$out" "Broken pipe"
  # restore NAME finds the folder by its origin when ~/projects/NAME is missing
  rm "$p/.env"
  mv "$p" "$ENVORA_PROJECTS/renamed"
  cd "$T"
  expect_rc 0 restore bar -y
  assert_contains "$OUT" "'bar' lives in ~/projects/renamed"
  assert_eq "$(cat "$ENVORA_PROJECTS/renamed/.env")" "B=1"
  # forget counts the Vercel snapshots it removes
  mkdir -p "$ENVORA_VAULT/bar/@vercel"
  printf 'S=1\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/bar/@vercel/production.env.age"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -qm snap
  expect_rc 0 forget bar --yes
  assert_contains "$OUT" "removed bar (1 file + 1 Vercel snapshot)"
}

t_killed_runs_leave_no_plaintext() {
  local p d pid
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  # a temp dir of a run killed with SIGKILL (fzf does that to previews)
  sh -c 'exit 0' &
  pid=$!
  wait "$pid"
  d="$TMPDIR/envora.KILLED"
  mkdir -p "$d"
  printf '%s\n' "$pid" >"$d/.pid"
  printf 'A=1\n' >"$d/snap.plain"
  expect_rc 0 help
  assert_no_file "$d"
  # the save / restore previews never write a decrypted copy to disk
  printf 'A=2\n' >"$p/.env"
  ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview save >/dev/null 2>&1 </dev/null
  assert_eq "$(grep -rl 'A=1' "$TMPDIR" 2>/dev/null | grep -v '\.age$' || true)" ""
}

t_copy_without_base_never_reverts_vault() {
  local key="$T/A/home/.age/key.txt" p wt pb
  p="$(mkproject app)"
  printf 'X=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  # a worktree gets a copy of .env (the copy-env way), then the main folder moves on
  wt="$ENVORA_PROJECTS/app-wt"
  git -C "$p" worktree add -q "$wt" -b feat 2>/dev/null
  cp "$p/.env" "$wt/.env"
  printf 'X=2\nSTRIPE_KEY=new\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  expect_rc 0 save -C "$wt" -y
  assert_contains "$OUT" "this copy is an older version of the vault's"
  assert_contains "$(age -d -i "$key" "$ENVORA_VAULT/app/.env.age")" "STRIPE_KEY=new"
  expect_rc 0 status -C "$wt"
  assert_contains "$OUT" "newer in the vault"
  # a file made by hand on another machine (or by envora 0.x): never replaces silently
  new_machine B "$key"
  pb="$(mkproject app)"
  printf 'X=hand\n' >"$pb/.env"
  expect_rc 0 status -C "$pb"
  assert_contains "$OUT" "this folder never saved or restored it"
  expect_rc 0 save -C "$pb" -y -q
  assert_contains "$OUT" "ev: warning: .env: this folder never saved or restored it, and the vault holds another version (commit "
  assert_contains "$OUT" "the other version stays in git history"
}

t_sync_homonym_repos_never_merge() {
  local key="$T/A/home/.age/key.txt" pa pb head
  printf 'C=1\n' >"$(mkproject common)/.env"
  expect_rc 0 save -C "$ENVORA_PROJECTS/common" -y -q
  pa="$(mkproject app "git@github.com:work/app.git")"
  mkdir -p "$pa/apps/web"
  printf 'WORK_DB=1\n' >"$pa/.env"
  printf 'WORK_API_KEY=work-secret\n' >"$pa/apps/web/.env.local"
  (cd "$pa" && expect_rc 3 save -y -q --no-sync)
  new_machine B "$key"
  pb="$(mkproject app "git@github.com:me/app.git")"
  printf 'PERSONAL=1\n' >"$pb/.env"
  (cd "$pb" && expect_rc 0 save -y -q)
  use_machine A
  head="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  expect_rc 1 sync
  assert_contains "$OUT" "the vault entry 'app' was saved from two different repositories"
  assert_contains "$OUT" "ev save --as <other-name>"
  assert_not_contains "$OUT" "conflict on app/.env.age"
  assert_eq "$(git -C "$ENVORA_VAULT" rev-parse HEAD)" "$head" "nothing merged"
  assert_no_file "$(git -C "$ENVORA_VAULT" rev-parse --absolute-git-dir)/MERGE_HEAD"
  git --git-dir="$T/remote.git" show HEAD:app/apps/web/.env.local.age >/dev/null 2>&1 && fail "the work file reached the other entry"
  assert_eq "$(git --git-dir="$T/remote.git" show HEAD:app/.origin)" "git@github.com:me/app.git"
  expect_rc 1 restore -C "$pa" --yes --quiet
}

t_sync_reencrypts_files_saved_with_the_old_key() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'X=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -y -q)
  # A rotates offline; B saves meanwhile with the old key
  use_machine A
  git -C "$ENVORA_VAULT" remote set-url origin "$T/nowhere.git"
  (cd "$p" && expect_rc 3 rotate -y)
  use_machine B
  printf 'X=2\n' >"$pb/.env"
  (cd "$pb" && expect_rc 0 save -y -q)
  use_machine A
  git -C "$ENVORA_VAULT" remote set-url origin "$T/remote.git"
  expect_rc 0 sync
  assert_contains "$OUT" "re-encrypted for your current key 1 file saved with the previous key: app/.env.age"
  # a machine with only the new key reads it
  assert_eq "$(git --git-dir="$T/remote.git" show HEAD:app/.env.age | age -d -i "$ENVORA_KEY")" "X=2"
  rm "$p/.env"
  (cd "$p" && expect_rc 0 restore -y -q)
  assert_eq "$(cat "$p/.env")" "X=2"
}

t_sync_merge_failure_is_never_silent() {
  local key="$T/A/home/.age/key.txt" p pb
  p="$(mkproject app)"
  printf 'X=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  new_machine B "$key"
  pb="$(mkproject app)"
  (cd "$pb" && expect_rc 0 restore -y -q)
  # B commits a README in the vault and saves X=2
  printf 'notes\n' >"$ENVORA_VAULT/README.md"
  git -C "$ENVORA_VAULT" add README.md && git -C "$ENVORA_VAULT" commit -q -m readme
  printf 'X=2\n' >"$pb/.env"
  (cd "$pb" && expect_rc 0 save -y -q)
  # A has an untracked README (left uncommitted) and a commit of its own
  use_machine A
  printf 'mine\n' >"$ENVORA_VAULT/README.md"
  printf 'L=1\n' >"$p/.env.local"
  (cd "$p" && expect_rc 3 save -y -q --no-sync)
  expect_rc 1 restore -C "$p" -y
  assert_contains "$OUT" "block the sync: README.md"
  assert_contains "$OUT" "NOT up to date with GitHub"
  assert_not_contains "$OUT" "already up to date"
  assert_eq "$(cat "$p/.env")" "X=1"
  # unrelated histories: a vault made with git init, then given a remote
  new_machine C "$key"
  rm -rf "$ENVORA_VAULT"
  git init -q "$ENVORA_VAULT"
  git -C "$ENVORA_VAULT" remote add origin "$T/remote.git"
  local pc
  pc="$(mkproject app)"
  printf 'X=from-c\n' >"$pc/.env"
  (cd "$pc" && expect_rc 3 save -y -q --no-sync)
  expect_rc 1 sync
  assert_contains "$OUT" "unrelated histories"
  assert_not_contains "$OUT" "back online"
}

t_sync_forget_and_save_keep_the_origin() {
  local key="$T/A/home/.age/key.txt" p
  p="$(mkproject api)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  new_machine B "$key"
  expect_rc 0 forget api -y
  use_machine A
  printf 'A=2\n' >"$p/.env"
  (cd "$p" && expect_rc 3 save -y -q --no-sync)
  expect_rc 0 sync
  assert_contains "$OUT" "deleted on another machine, changed here"
  assert_eq "$(cat "$ENVORA_VAULT/api/.origin")" "git@github.com:me/api.git"
  assert_eq "$(git --git-dir="$T/remote.git" show HEAD:api/.origin)" "git@github.com:me/api.git"
}

t_interrupted_save_is_never_published() {
  local p real pid rc=0 head
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  printf 'B=1\n' >"$p/.env.local"
  (cd "$p" && expect_rc 0 save -y -q)
  head="$(git -C "$ENVORA_VAULT" rev-parse HEAD)"
  printf 'A=2\n' >"$p/.env"
  printf 'B=2\n' >"$p/.env.local"
  # a slow encryption: the save is stopped after its first file
  real="$(command -v age)"
  mkdir -p "$T/slow"
  printf '#!/bin/sh\n"%s" "$@" || exit $?\nfor a in "$@"; do [ "$a" = -r ] && [ -f "%s/slow/on" ] && sleep 3; done\nexit 0\n' "$real" "$T" >"$T/slow/age"
  chmod +x "$T/slow/age"
  touch "$T/slow/on"
  set -m
  PATH="$T/slow:$PATH" "$TEST_BASH" "$EV" save -C "$p" -y -q </dev/null >/dev/null 2>&1 &
  pid=$!
  local n=0
  while [[ -z "$(git -C "$ENVORA_VAULT" status --porcelain)" && $n -lt 100 ]]; do sleep 0.1; n=$((n + 1)); done
  kill -TERM -- "-$pid"
  wait "$pid" || rc=$?
  set +m
  rm -f "$T/slow/on"
  assert_eq "$rc" "143"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" "" "the half save was put back"
  # killed without a trap (SIGKILL): the next command, even a read, puts it back
  printf 'A=3\n' | age -r "$(age-keygen -y "$ENVORA_KEY")" -o "$ENVORA_VAULT/app/.env.age"
  printf 'app/.env.age\n' >"$(git -C "$ENVORA_VAULT" rev-parse --absolute-git-dir)/envora-inflight"
  expect_rc 0 list -q
  assert_contains "$OUT" "an interrupted save left 1 file half written"
  assert_eq "$(git -C "$ENVORA_VAULT" rev-parse HEAD)" "$head" "nothing committed"
  assert_eq "$(git -C "$ENVORA_VAULT" status --porcelain)" ""
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/.env.age")" "A=1"
}

t_vault_files_deleted_by_hand_are_put_back() {
  local p q
  p="$(mkproject app)"
  q="$(mkproject other)"
  printf 'A=1\n' >"$p/.env"
  printf 'O=1\n' >"$q/.env"
  (cd "$p" && expect_rc 0 save -y -q)
  rm -rf "$ENVORA_VAULT/app"
  cd "$q"
  expect_rc 0 save -y
  assert_contains "$OUT" "app/.env.age, app/.origin deleted from the vault folder: put back"
  assert_file "$ENVORA_VAULT/app/.env.age"
  git --git-dir="$T/remote.git" show HEAD:app/.env.age >/dev/null 2>&1 || fail "the deletion reached GitHub"
}

t_push_retries_and_key_only_commits() {
  local key="$T/A/home/.age/key.txt" i pids="" rc out
  new_machine B "$key"
  for i in 1 2 3; do
    use_machine A
    printf 'A%s=1\n' "$i" >"$(mkproject "a$i")/.env"
    use_machine B
    printf 'B%s=1\n' "$i" >"$(mkproject "b$i")/.env"
  done
  for i in 1 2 3; do
    (use_machine A; "$TEST_BASH" "$EV" save -C "$ENVORA_PROJECTS/a$i" -y -q </dev/null >"$T/oa$i" 2>&1; echo $? >"$T/rca$i") &
    pids="$pids $!"
    (use_machine B; "$TEST_BASH" "$EV" save -C "$ENVORA_PROJECTS/b$i" -y -q </dev/null >"$T/ob$i" 2>&1; echo $? >"$T/rcb$i") &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i" || true; done
  for i in 1 2 3; do
    for rc in a b; do
      out="$(cat "$T/rc$rc$i"):$(cat "$T/o$rc$i")"
      assert_eq "${out%%:*}" "0" "parallel save $rc$i: $out"
    done
  done
  # a new vault, a folder without env files, GitHub unreachable: nothing of
  # the folder waits, so no "PUSH FAILED" and exit 0
  setup push_retries_fresh
  local p
  p="$(mkproject empty)"
  git -C "$ENVORA_VAULT" remote set-url origin "$T/nowhere.git"
  expect_rc 0 save -C "$p" -y -q
  assert_not_contains "$OUT" "PUSH FAILED"
}

t_odd_paths_are_never_dropped_silently() {
  local p p2
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  mkdir -p "$p/nl"$'\n'"x"
  printf 'N=1\n' >"$p/nl"$'\n'"x/.env"
  printf 'W=1\n' >"$p/.env.weird"$'\n'"name"
  expect_rc 1 save -C "$p" --yes --quiet
  assert_contains "$OUT" "NOT saved: \$'nl\\nx/.env' (a newline or tab in its path"
  assert_contains "$OUT" "NOT saved: \$'.env.weird\\nname'"
  assert_contains "$OUT" "2 env files of this folder NOT in the vault"
  assert_eq "$(cd "$ENVORA_VAULT/app" && find . -name '*.age' | sort | tr '\n' ' ')" "./.env.age "
  expect_rc 0 status -C "$p"
  assert_contains "$OUT" "a newline or tab in its path"
  rm -rf "$p/nl"$'\n'"x" "$p/.env.weird"$'\n'"name"
  # a backslash in a folder name: conflicts are decided like any other path
  mkdir -p "$p/sub\\nx"
  printf 'S=1\n' >"$p/sub\\nx/.env"
  expect_rc 0 save -C "$p" --yes -q
  p2="$T/A/home/elsewhere/app"
  mkdir -p "$p2"
  git -C "$p2" init -q
  git -C "$p2" remote add origin "git@github.com:me/app.git"
  expect_rc 0 restore -C "$p2" --yes -q
  printf 'S=2\n' >"$p2/sub\\nx/.env"
  expect_rc 0 save -C "$p2" --yes -q
  printf 'S=3\n' >"$p/sub\\nx/.env"
  expect_rc 0 save -C "$p" --yes
  assert_contains "$OUT" "replaced the vault's other version"
  assert_not_contains "$OUT" "while you were answering"
  assert_eq "$(age -d -i "$ENVORA_KEY" "$ENVORA_VAULT/app/sub\\nx/.env.age")" "S=3"
}

t_restore_never_writes_outside_or_into_git() {
  local p pub
  p="$(mkproject app)"
  printf 'A=vault\n' >"$p/.env.local"
  (cd "$p" && expect_rc 0 save -q -y)
  mkdir -p "$T/outside"
  printf 'IMPORTANT=1\n' >"$T/outside/file"
  rm "$p/.env.local"
  ln -s "$T/outside/file" "$p/.env.local"
  expect_rc 1 restore -C "$p" --yes -q
  assert_contains "$OUT" "is a link to $T/outside/file, outside the project"
  assert_eq "$(cat "$T/outside/file")" "IMPORTANT=1"
  # forged vault names inside .git or a dependency folder are refused
  pub="$(age-keygen -y "$ENVORA_KEY")"
  mkdir -p "$ENVORA_VAULT/app/.git/hooks" "$ENVORA_VAULT/app/sub/.git" "$ENVORA_VAULT/app/node_modules/x"
  printf 'X=1\n' | age -r "$pub" -o "$ENVORA_VAULT/app/.git/hooks/.env.age"
  printf 'X=1\n' | age -r "$pub" -o "$ENVORA_VAULT/app/sub/.git/.env.age"
  printf 'X=1\n' | age -r "$pub" -o "$ENVORA_VAULT/app/node_modules/x/.env.age"
  git -C "$ENVORA_VAULT" add -A && git -C "$ENVORA_VAULT" commit -q -m forged
  rm "$p/.env.local"
  expect_rc 1 restore -C "$p" --yes -q
  assert_contains "$OUT" "refusing to restore '.git/hooks/.env'"
  assert_contains "$OUT" "refusing to restore 'sub/.git/.env'"
  assert_contains "$OUT" "refusing to restore 'node_modules/x/.env'"
  assert_no_file "$p/.git/hooks/.env"
  assert_no_file "$p/sub"
  assert_no_file "$p/node_modules"
  assert_eq "$(cat "$p/.env.local")" "A=vault"
}

t_vault_remote_credentials_never_shown() {
  local p
  p="$(mkproject app)"
  printf 'A=1\n' >"$p/.env"
  (cd "$p" && expect_rc 0 save -q -y)
  git -C "$ENVORA_VAULT" remote set-url origin "https://me:ghp_SECRETTOKEN123@127.0.0.1:9/me/env-vault.git"
  run_ev doctor --no-sync
  assert_not_contains "$OUT" "ghp_SECRETTOKEN123"
  assert_contains "$OUT" "remote: https://127.0.0.1:9/me/env-vault.git"
  OUT="$("$TEST_BASH" "$EV" _preview sync 2>&1)"
  assert_not_contains "$OUT" "ghp_SECRETTOKEN123"
}

t_config_rc_spaces_and_unknown_keys() {
  cat >"$HOME/.envorarc" <<'EOF'
 ENVORA_WRANGLER_CMD = wrangler
ENVORA_VAULTT=/somewhere
EOF
  expect_rc 0 config get wrangler-cmd
  assert_contains "$OUT" "line 2: unknown setting ENVORA_VAULTT"
  assert_contains "$OUT" "wrangler"
  assert_eq "$("$TEST_BASH" "$EV" config get wrangler-cmd 2>/dev/null)" "wrangler"
}

t_export_cloudflare_environments_and_batches() {
  local p i keys=""
  p="$(mkproject cfenv)"
  printf 'name = "api"\n\n[env.production]\n\n[env.staging]\n' >"$p/wrangler.toml"
  printf 'K=prod\n' >"$p/.dev.vars.production"
  printf 'K=staging\n' >"$p/.dev.vars.staging"
  cd "$p"
  expect_rc 0 save -q -y
  # only per-environment files: the CLI says which ones, the preview lists them
  expect_rc 1 export cloudflare --yes
  assert_contains "$OUT" ".dev.vars.production → ev export cloudflare --env production"
  assert_contains "$OUT" ".dev.vars.staging → ev export cloudflare --env staging"
  OUT="$(ENVORA_MENU_DIR="$p" "$TEST_BASH" "$EV" _preview export-cloudflare 2>&1)"
  assert_contains "$OUT" "vault/cfenv/.dev.vars.staging → environment staging"
  assert_not_contains "$OUT" "save first"
  # --file names the environment, like for Vercel; --env= keeps the deployed Worker
  expect_rc 0 export cloudflare --file .dev.vars.staging --dry-run
  assert_contains "$OUT" "Worker api, environment staging"
  assert_contains "$OUT" "environment staging: from the file name"
  expect_rc 0 export cloudflare --file .dev.vars.staging --yes
  assert_contains "$(tail -n 1 "$STUB/wrangler.log")" "secret bulk --config $p/wrangler.toml --env staging"
  assert_eq "$(jq -c . "$STUB/wrangler.stdin")" '{"K":"staging"}'
  expect_rc 0 export cloudflare --file .dev.vars.staging --env= --dry-run
  assert_contains "$OUT" "(deployed, top-level)"
  assert_contains "$OUT" "add --env <name> (the same file is sent)"
  # options export cloudflare does not use are refused
  expect_rc 1 export cloudflare --update-shared --dry-run
  # a Worker never deployed: wrangler secret bulk creates it
  touch "$STUB/wrangler.listfail"
  expect_rc 0 export cloudflare --env production --yes
  assert_contains "$OUT" "not deployed yet: wrangler creates it"
  rm "$STUB/wrangler.listfail"
  # more than 100 secrets: a failed later batch says what is already live
  for i in $(seq 1 150); do keys="${keys}K$i=v$i"$'\n'; done
  printf '%s' "$keys" >"$p/.dev.vars.big"
  expect_rc 0 save -q -y
  rm -f "$STUB/wrangler.bulkcount"
  touch "$STUB/wrangler.bulkfail.2"
  expect_rc 1 export cloudflare --env big --yes
  assert_contains "$OUT" "2 batches"
  assert_contains "$OUT" "100 of 150 secrets were already uploaded and deployed by the earlier batches"
  assert_eq "$(jq 'length' "$STUB/wrangler.stdin.1")" "100"
  # an option-like Pages project name is refused before wrangler runs
  local s
  s="$(mkproject pagesite)"
  printf 'name = "--help"\npages_build_output_dir = "./dist"\n' >"$s/wrangler.toml"
  printf 'P=1\n' >"$s/.env"
  cd "$s"
  expect_rc 0 save -q -y
  expect_rc 1 export cloudflare --dry-run
  assert_contains "$OUT" "invalid Pages project name"
}

t_export_cloudflare_newer_vault_is_not_save_first() {
  local p p2
  p="$(mkproject cfw)"
  printf 'name = "cfw"\n' >"$p/wrangler.toml"
  printf 'CF=1\n' >"$p/.dev.vars"
  expect_rc 0 save -C "$p" -q -y
  p2="$T/A/home/elsewhere/cfw"
  mkdir -p "$p2"
  git -C "$p2" init -q
  git -C "$p2" remote add origin "git@github.com:me/cfw.git"
  cp "$p/wrangler.toml" "$p2/"
  expect_rc 0 restore -C "$p2" -q -y
  printf 'CF=2\n' >"$p2/.dev.vars"
  expect_rc 0 save -C "$p2" -q -y
  cd "$p"
  expect_rc 0 export cloudflare --dry-run
  assert_contains "$OUT" "the vault has a newer .dev.vars than your local file"
  assert_not_contains "$OUT" "Save first"
}

t_provider_settings_and_sizes() {
  local p big
  expect_rc 1 config set vercel-cmd 'npx -y "vercel@58.4.0"'
  assert_contains "$OUT" "quotes and backslashes are not supported"
  expect_rc 0 config set vercel-cmd '~/bin/vercel --debug'
  assert_contains "$OUT" "not an executable command here"
  expect_rc 0 config get vercel-cmd
  assert_eq "$OUT" "$HOME/bin/vercel --debug"
  expect_rc 0 config set vercel-cmd vercel
  # REPO is only used by init: the setting says where the vault really syncs
  expect_rc 0 config set repo me/other-vault
  assert_contains "$OUT" "ENVORA_REPO is only used by ev init: this vault syncs with $T/remote.git"
  # the stdin limit counts bytes: 40000 two-byte characters are skipped
  p="$(mkproject web)"
  mkdir -p "$p/.vercel"
  printf '{}\n' >"$p/.vercel/project.json"
  big="$(head -c 40000 /dev/zero | tr '\0' x | sed 's/x/é/g')"
  printf 'BIGU=%s\nSMALL=1\n' "$big" >"$p/.env.preview"
  printf '{"envs":[]}\n' >"$STUB/vercel.ls.preview.json"
  cd "$p"
  expect_rc 0 save -q -y
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 expect_rc 0 export vercel --env preview --yes
  assert_contains "$OUT" "BIGU  (value over 60 KB"
  assert_not_contains "$(cat "$STUB/vercel.stdin")" "BIGU"
  assert_contains "$(cat "$STUB/vercel.stdin")" "add preview SMALL=1"
}

# --- run ---------------------------------------------------------------------

echo "envora tests · $("$TEST_BASH" -c 'echo "bash $BASH_VERSION"') · $(age --version)"
TESTS="$(declare -F | awk '{print $3}' | sed -n 's/^t_//p')"
for t in $TESTS; do
  run_test "$t"
done
echo ""
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "failed:$FAILED"
  echo "logs: $BASE"
  exit 1
fi
rm -rf "$BASE"
exit 0
