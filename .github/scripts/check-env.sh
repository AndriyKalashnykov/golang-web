#!/usr/bin/env bash
# Verify .env.example documents every setting the code reads (run by `make check-env`).
#
# Settings are derived from the code, not listed by hand:
#   - Makefile: every `NAME ?=` (also indented, or after `export`/`override`) and `export NAME`;
#   - Go (non-test *.go): every getenv / os.Getenv / os.LookupEnv("NAME") key.
# Fails when a setting is not documented as a commented `# NAME ?= value` line, when a documented
# name is no longer read, when a Go-read name is missing from the Makefile's APP_ENV_VARS (so
# .env could not reach the app), when .env.example is missing, or when .env is not gitignored.
# Also warns when .env has a line that is not `NAME ?= value` (a plain `=` would override the shell).
# Not detected: a getenv call split across lines, a key held in a constant (`getenv(key, ...)`),
# syscall.Getenv, an aliased os import, third-party env readers, and Go files not yet `git add`ed.
# Run from the repository root. Needs bash 3.2+, sed, grep, sort, comm.
set -euo pipefail

name='[A-Z][A-Z0-9_]*'
fail=0
err() { echo "ERROR: $*"; fail=1; }

[ -f .env.example ] || { echo "ERROR: .env.example is missing. It documents every setting; restore it from git."; exit 1; }

if git rev-parse --git-dir >/dev/null 2>&1; then
  git check-ignore -q .env || err ".env is not gitignored. Add '.env' to .gitignore: it may hold REGISTRY_TOKEN."
else
  grep -qxE '/?\.env' .gitignore 2>/dev/null || err ".env is not listed in .gitignore. Add a '.env' line: it may hold REGISTRY_TOKEN."
fi

makefile_names=$( {
  sed -nE "s/^[[:space:]]*((export|override)[[:space:]]+)*(${name})[[:space:]]*\\?=.*/\\3/p" Makefile
  sed -nE "s/^[[:space:]]*export[[:space:]]+(${name})[[:space:]]*$/\\1/p" Makefile
} | sort -u )
# Tracked Go files only (not agent worktrees or other untracked copies); outside git, skip
# hidden directories, vendor and testdata.
if git rev-parse --git-dir >/dev/null 2>&1; then
  go_files=$(git ls-files -- '*.go' | grep -v '_test\.go$' || true)
else
  go_files=$(find . -name '*.go' ! -name '*_test.go' ! -path './.*' ! -path './vendor/*' ! -path '*/testdata/*' | sort)
fi
go_names=""
if [ -n "$go_files" ]; then
  # shellcheck disable=SC2086  # the list is whitespace-free paths
  go_names=$( (grep -hoE "(^|[^A-Za-z0-9_.])(os\\.Getenv|os\\.LookupEnv|getenv)\\(\"${name}\"" $go_files || true) \
    | sed -E 's/.*\("([^"]+)"/\1/' | sort -u)
fi
code=$(printf '%s\n%s\n' "$makefile_names" "$go_names" | sed '/^$/d' | sort -u)
[ -n "$code" ] || { echo "ERROR: found no settings in the Makefile or Go code; this check's patterns need fixing."; exit 1; }

documented=$(sed -nE "s/^#[[:space:]]*(${name})[[:space:]]*\\?=.*/\\1/p" .env.example | sort -u)
missing=$(comm -23 <(echo "$code") <(echo "$documented"))
stale=$(comm -13 <(echo "$code") <(echo "$documented"))
[ -z "$missing" ] || err "not documented in .env.example (add a commented '# NAME ?= default' line): $(tr '\n' ' ' <<<"$missing")"
[ -z "$stale" ] || err "documented in .env.example but no longer read anywhere (remove the line): $(tr '\n' ' ' <<<"$stale")"

app_line=$(sed -nE 's/^APP_ENV_VARS[[:space:]]*:?=[[:space:]]*//p' Makefile)
case "$app_line" in *\\) die_line=1 ;; *) die_line=0 ;; esac
[ "$die_line" -eq 0 ] || err "APP_ENV_VARS in the Makefile continues on the next line; keep it on one line so this check can read it."
app_vars=" PORT ${app_line} "
unreachable=""
for v in $go_names; do
  grep -qF " $v " <<<"$app_vars" || unreachable="$unreachable $v"
done
[ -z "$unreachable" ] || err "read by the Go code but not in the Makefile's APP_ENV_VARS, so .env cannot reach it:$unreachable"

if [ -f .env ]; then
  bad=$(grep -nvE "^[[:space:]]*(#.*)?$|^[[:space:]]*((export|override)[[:space:]]+)*${name}[[:space:]]*\\?=" .env | cut -d: -f1 | tr '\n' ' ' || true)
  [ -z "$bad" ] || echo "WARNING: .env line(s) ${bad}are not 'NAME ?= value'; a plain '=' overrides your shell."
fi

[ "$fail" -eq 0 ] || exit 1
echo ".env.example documents all $(echo "$code" | wc -l | tr -d ' ') settings."
