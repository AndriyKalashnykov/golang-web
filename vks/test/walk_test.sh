#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # fixtures are text in single quotes; `A && ok || bad` only prints
# Tests for walk.sh (run by `make scripts-test`). Offline: extraction of the three guides, and
# `run` against a small guide of harmless blocks in a scratch HOME. `remote` and `container`
# are tested only up to their dry run: a real one needs another machine or a container engine.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WALK=$HERE/walk.sh
VKS=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
TAB=$(printf '\t')

checks=0
ok()   { echo "PASS  $1"; checks=$((checks + 1)); }
bad()  { echo "FAIL  $1: $2"; fails=$((fails + 1)); checks=$((checks + 1)); }
# has <label> <text> <fixed string>
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "did not want '$3' in: $2"; else ok "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- extraction of the real guides: the counts the gate's floors were set from ---------------
# The counts come from the gate's own table, so a guide added there is extracted here too and
# the two lists cannot drift.
BLOCKS_TABLE="$VKS/../.github/scripts/check-vks-docs.blocks"
n_guides=0
while read -r g want; do
  case "$g" in ''|'#'*) continue ;; esac
  n_guides=$((n_guides + 1)); d="$T/real-$(printf '%s' "$g" | tr '/' '_')"
  bash "$WALK" extract "$VKS/$g" "$d" || bad "extract $g" "exit $?"
  eq "extract $g: $want blocks" "$(grep -c . "$d/manifest.tsv")" "$want"
  eq "extract $g: one file per block" "$(find "$d" -name '[0-9][0-9][0-9].sh' | grep -c .)" "$want"
  eq "extract $g: as many fences as blocks" "$(grep -c '^```sh$' "$VKS/$g")" "$want"
done < "$BLOCKS_TABLE"
if [ "$n_guides" -ge 10 ]; then ok "the table lists $n_guides guides"; else bad "the table of guides" "only $n_guides line(s) read from $BLOCKS_TABLE"; fi
eq "README: alternatives marked" "$(awk -F'\t' '$2 == "alt"' "$T/real-README.md/manifest.tsv" | grep -c .)" 3
eq "ARGOCD-manual: one 'this terminal' block, until the end of step 8" "$(awk -F'\t' '$3 ~ /^T/ { print $3 "/" $6 }' "$T/real-ARGOCD-manual.md/manifest.tsv")" 'T8/NEW_CLUSTER="my-new-cluster"'
eq "README block 1 is written verbatim" "$(awk -v n="$(grep -c '' "$T/real-README.md/001.sh")" '!s && /^```sh$/ { s = NR; next } s && NR <= s + n' "$VKS/README.md" | cksum)" "$(cksum < "$T/real-README.md/001.sh")"

# --- a small guide of harmless blocks ---------------------------------------------------------
cat > "$T/guide.md" <<'GUIDE'
# Fixture

## 1. First

```sh
echo "hello from $(basename "$HOME")"
pwd
```

**Expect:** `hello from home`, then
the directory. **If not:** read on.

```sh
echo "about to fail"
false
```

**Expect:** `about to fail`.

### Stdin

```sh
if read -r LINE; then echo "read a line: $LINE"; else echo "stdin is empty"; fi
```

**Expect:** `stdin is empty`.

<details>
<summary>Alternative</summary>

```sh
echo "the alternative ran"
```

**Expect:** `the alternative ran`.

</details>

## 2. Second

Put your choice into this terminal.

```sh
CHOICE="blue"
```

```sh
echo "choice=${CHOICE:-unset} token=${FIXTURE_TOKEN:-unset}"
[ -f "$HOME/.fixture.env" ] && . "$HOME/.fixture.env" && echo "env file loaded"
```

**Expect:** `choice=blue`.

```sh
sleep 30
echo "slept"
```
GUIDE
mkdir -p "$T/home" "$T/work" "$T/out"
printf "export FIXTURE_TOKEN='not-a-real-secret'\n" > "$T/.fixture.env"

bash "$WALK" extract "$T/guide.md" "$T/out"
m=$T/out/manifest.tsv
eq "fixture: 7 blocks" "$(grep -c . "$m")" 7
eq "fixture: row 1" "$(sed -n 1p "$m")" "001${TAB}main${TAB}-${TAB}6${TAB}1. First${TAB}echo \"hello from \$(basename \"\$HOME\")\"${TAB}\`hello from home\`, then the directory."
eq "fixture: heading path" "$(awk -F'\t' '$1 == "003" { print $5 }' "$m")" "1. First > Stdin"
eq "fixture: block 4 is an alternative" "$(awk -F'\t' '$1 == "004" { print $2 }' "$m")" alt
eq "fixture: block 5 is a this-terminal block" "$(awk -F'\t' '$1 == "005" { print $3 "/" $7 }' "$m")" "T/-"
eq "fixture: block 7 has no Expect" "$(awk -F'\t' '$1 == "007" { print $7 }' "$m")" "-"
eq "--list of an extracted directory" "$(bash "$WALK" --list "$T/out")" "$(cat "$m")"
eq "--list of a guide" "$(bash "$WALK" --list "$T/guide.md")" "$(cat "$m")"

printf '```sh\necho open\n' > "$T/open.md"
out=$(bash "$WALK" extract "$T/open.md" "$T/open" 2>&1); rc=$?
has "unclosed fence is an error" "$rc $out" "a fenced block is not closed"

# --- run: refuses without --yes-run -----------------------------------------------------------
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --home "$T/home" 2>&1); rc=$?
has "no --yes-run: says so" "$out" "DRY RUN — nothing runs without --yes-run"
has "no --yes-run: lists the selection" "$out" "6 block(s) selected."
[ ! -e "$T/out/results" ] && [ "$rc" -eq 0 ] && ok "no --yes-run: nothing ran" || bad "no --yes-run: nothing ran" "rc=$rc, results exist?"

# --- run: option parsing ----------------------------------------------------------------------
for args in "--bogus" "--shell fish" "--from x" "--only 1;2" "--timeout" "--to"; do
  # shellcheck disable=SC2086  # the options are split on purpose
  out=$(bash "$WALK" run "$T/out" $args 2>&1); rc=$?
  eq "option error: $args" "$rc" 2
done
out=$(bash "$WALK" run "$T/nowhere" --yes-run 2>&1); rc=$?
has "no manifest" "$rc $out" "2 walk.sh: no manifest in"
out=$(bash "$WALK" 2>&1); rc=$?
has "no subcommand prints the usage" "$rc $out" "walk.sh extract"

# --- run: the walk itself ---------------------------------------------------------------------
out=$(cd "$T/work" && umask 022 && FIXTURE_TOKEN=leaked-from-the-caller bash "$WALK" run "$T/out" --yes-run --home "$T/home" --to 6 --env-file "$T/.fixture.env" 2>&1); rc=$?
r=$T/out/results
eq "run: exit status 0 although a block failed" "$rc" 0
has "run: block 1 output" "$(cat "$r/001.out")" "hello from home"
has "run: --workdir defaults to the current directory" "$(cat "$r/001.out")" "$T/work"
eq "run: block 1 exit status" "$(cat "$r/001.rc")" 0
eq "run: the failing block's exit status is recorded" "$(cat "$r/002.rc")" 1
has "run: it went on after the failing block" "$(cat "$r/003.out")" "stdin is empty"
[ ! -e "$r/004.out" ] && ok "run: the alternative is skipped by default" || bad "run: the alternative is skipped by default" "004.out exists"
has "run: a this-terminal block reaches later blocks" "$(cat "$r/006.out")" "choice=blue"
has "run: a fresh shell does not inherit the walk's variables" "$(cat "$r/006.out")" "token=unset"
eq "run: the results directory is for this user only" "$(find "$r" -maxdepth 0 -perm 700 | grep -c .)" 1
eq "run: no result file is readable by others" "$(find "$r" -type f \( -perm -g+r -o -perm -o+r \) | grep -c .)" 0
has "run: --env-file was installed in HOME" "$(cat "$r/006.out")" "env file loaded"
eq "run: --env-file mode" "$(find "$T/home/.fixture.env" -perm 600 | grep -c .)" 1
hasnt "run: --env-file values are not printed" "$out$(cat "$r"/*.out)" "not-a-real-secret"
has "run: table shows exit status, output and Expect" "$out" "[002] main exit=1   1. First"
has "run: table, first output line" "$out" "      output: about to fail"
has "run: table, Expect text" "$out" '      expect: `about to fail`.'
has "run: says how to judge" "$out" "Judge each block by its Expect text, not by its exit status."
eq "run: summary.tsv row" "$(sed -n 3p "$r/summary.tsv")" "002${TAB}main${TAB}1${TAB}1. First${TAB}about to fail${TAB}\`about to fail\`."

printf "export FIXTURE_TOKEN='changed'\n" > "$T/.fixture.env"
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --only 6 --env-file "$T/.fixture.env" 2>&1)
has "run: an existing env file is kept" "$out" "exists and is kept"
has "run: an existing env file is not overwritten" "$(cat "$T/home/.fixture.env")" "not-a-real-secret"

rm -rf "$r"
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --to 6 --stop-on-fail 2>&1)
has "--stop-on-fail: stops" "$out" "Stopped at block 002 (--stop-on-fail)."
[ ! -e "$r/003.out" ] && ok "--stop-on-fail: later blocks did not run" || bad "--stop-on-fail: later blocks did not run" "003.out exists"

rm -rf "$r"
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --from 3 --to 4 --with-alt 2>&1)
eq "--from/--to/--with-alt: exactly blocks 3 and 4" "$(cd "$r" && echo [0-9]*.out)" "003.out 004.out"
has "--with-alt: the alternative ran" "$(cat "$r/004.out")" "the alternative ran"

rm -rf "$r"
out=$(cd / && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --only 1,4 --workdir "$T/work" 2>&1)
eq "--only: exactly the named blocks, an alternative included" "$(cd "$r" && echo [0-9]*.out)" "001.out 004.out"
has "--workdir" "$(cat "$r/001.out")" "$T/work"

out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --only 99 2>&1); rc=$?
has "nothing selected is an error" "$rc $out" "1 walk: ran 0 block(s)"

if command -v zsh >/dev/null 2>&1; then
  rm -rf "$r"
  out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --only 1,5,6 --shell zsh 2>&1)
  has "--shell zsh" "$(cat "$r/001.out" "$r/006.out")" "choice=blue"
else
  echo "SKIP  --shell zsh (zsh is not installed)"
fi

rm -rf "$r"
start=$(date +%s)
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home" --only 7 --timeout 2 2>&1)
took=$(( $(date +%s) - start ))
eq "--timeout: exit status 124" "$(cat "$r/007.rc")" 124
has "--timeout: the output says why" "$(cat "$r/007.out")" "stopped after 2s (--timeout)"
[ "$took" -lt 20 ] && ok "--timeout: stopped early (${took}s)" || bad "--timeout: stopped early" "took ${took}s"
hasnt "--timeout: the rest of the block did not run" "$(cat "$r/007.out")" "slept"

# --- remote and container: only the dry run can be tested here -------------------------------
out=$(cd "$T/work" && bash "$WALK" remote nobody@host.invalid "$T/out" --to 2 2>&1); rc=$?
has "remote without --yes-run: dry run" "$rc $out" "0 DRY RUN — would copy $T/out to nobody@host.invalid:walk-out"
out=$(cd "$T/work" && CONTAINER_ENGINE=docker bash "$WALK" container ubuntu:24.04 "$T/out" --to 2 2>&1); rc=$?
has "container without --yes-run: dry run" "$rc $out" "0 DRY RUN — would start ubuntu:24.04"
out=$(CONTAINER_ENGINE=nerdctl bash "$WALK" container ubuntu:24.04 "$T/out" --yes-run 2>&1); rc=$?
has "container: unknown engine" "$rc $out" "CONTAINER_ENGINE must be podman or docker"

# --- the scrubbed environment, and --pass-env ----------------------------------------------------
rm -rf "$r"
mkdir -p "$T/home2"
out=$(cd "$T/work" && FIXTURE_TOKEN=leaked-from-the-caller bash "$WALK" run "$T/out" --yes-run --home "$T/home2" --only 6 2>&1)
has "scrubbed: the caller's exported variable does not reach a block" "$(cat "$r/006.out")" "token=unset"
out=$(cd "$T/work" && FIXTURE_TOKEN=leaked-from-the-caller bash "$WALK" run "$T/out" --yes-run --home "$T/home2" --only 6 --pass-env FIXTURE_TOKEN 2>&1)
has "--pass-env: the named variable does" "$(cat "$r/006.out")" "token=leaked-from-the-caller"
out=$(bash "$WALK" run "$T/out" --pass-env '1BAD' 2>&1); rc=$?
has "--pass-env: not a variable name" "$rc $out" "2 walk.sh: --pass-env needs a variable NAME"

# --- "this terminal": only a block the walk RAN is carried --------------------------------------
rm -rf "$r"
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home2" --only 6 2>&1)
has "carry: a this-terminal block that did not run leaves nothing" "$(cat "$r/006.out")" "choice=unset"
out=$(cd "$T/work" && bash "$WALK" run "$T/out" --yes-run --home "$T/home2" --only 5,6 2>&1)
has "carry: one that ran is carried" "$(cat "$r/006.out")" "choice=blue"

# --- extract: "this terminal until the end of step N", wrapped; a four-backtick fence -----------
printf '# G\n\n## 3. Step\n\nPut it into **this terminal**. Keep using this terminal until the\nend of step 4.\n\n```sh\nA="1"\n```\n\n````text\n```sh\nnot a block\n```\n````\n\n```sh\necho "$A"\n```\n' > "$T/until.md"
bash "$WALK" extract "$T/until.md" "$T/until" || bad "extract until.md" "exit $?"
eq "extract: T4 from a wrapped sentence; a 4-backtick fence does not swallow the rest" "$(cut -f1,3 "$T/until/manifest.tsv" | tr '\t\n' ' ;')" "001 T4;002 -;"

# --- --timeout: what the block started is gone when the walk goes on, even if it ignores TERM ----
mkdir -p "$T/stub"
cat > "$T/stubborn.md" <<'GUIDE'
# Stubborn

```sh
( trap '' TERM; echo "$BASHPID" > "$HOME/stubborn.pid"; while :; do sleep 1; done ) &
wait
```
GUIDE
bash "$WALK" extract "$T/stubborn.md" "$T/stub/out"
start=$(date +%s)
out=$(cd "$T/work" && bash "$WALK" run "$T/stub/out" --yes-run --home "$T/home2" --timeout 2 2>&1)
took=$(( $(date +%s) - start ))
spid=$(cat "$T/home2/stubborn.pid" 2>/dev/null || true)
eq "--timeout: exit status 124 for a block whose child ignores TERM" "$(cat "$T/stub/out/results/001.rc")" 124
if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
  bad "--timeout: the TERM-ignoring child is gone when the walk returns" "pid $spid is still alive after ${took}s"
  kill -KILL "$spid" 2>/dev/null          # a process this test started, by its own pid
else
  ok "--timeout: the TERM-ignoring child is gone when the walk returns (${took}s, pid ${spid:-none})"
fi
[ -n "$spid" ] || bad "--timeout: the stubborn block ran" "no pid file"

# --- container, against a stand-in engine: what is created is removed; what was there is not ----
# The stand-in logs every call. FAKE_EXISTS: a container of that name is already there.
# FAKE_MODE=int: Ctrl-C arrives while the blocks run. FAKE_MODE=setupfail: the setup step fails.
mkdir -p "$T/fake"
cat > "$T/fake/podman" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "container inspect") [ -n "${FAKE_EXISTS:-}" ]; exit $? ;;
esac
case "$1" in
  cp) case "$3" in */results-container) mkdir -p "$3" ;; esac ;;
  exec)
    case "$*" in
      *"walk.sh run"*) if [ "${FAKE_MODE:-}" = int ]; then kill -INT "$PPID"; sleep 1; fi ;;
      *"apt-get"*)     [ "${FAKE_MODE:-}" != setupfail ] || exit 1 ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$T/fake/podman"
ct() { # <label> [env assignments…] -- <walk options…>  -> sets $out, $rc, $log
  local envs=()
  while [ "$1" != -- ]; do envs=("${envs[@]}" "$1"); shift; done; shift
  : > "$T/engine.log"
  out=$(cd "$T/work" && env PATH="$T/fake:$PATH" CONTAINER_ENGINE=podman FAKE_LOG="$T/engine.log" "${envs[@]}" \
        bash "$WALK" container img:1 "$T/out" --yes-run --only 1 "$@" 2>&1); rc=$?
  log=$(cat "$T/engine.log")
}
ct X=1 -- --name w1
has "container: a container it created is removed at the end" "$log" "rm -f w1"
has "container: says so" "$out" "walk: container 'w1' removed."
ct FAKE_EXISTS=1 -- --name w1
has "container: an existing container of that name is refused, with the reason" "$rc $out" "2 walk.sh: a container named 'w1' already exists and this walk did not create it"
hasnt "container: … and is not removed" "$log" "rm -f"
hasnt "container: … and nothing runs in it" "$log" "exec"
ct FAKE_EXISTS=1 -- --name w1 --reuse
has "container --reuse: walks in the existing container" "$log" "walk.sh run"
hasnt "container --reuse: never removes it" "$log" "rm -f"
hasnt "container --reuse: does not create one" "$log" "run -d"
ct X=1 -- --name w1 --reuse
has "container --reuse: nothing to reuse" "$rc $out" "2 walk.sh: --reuse: no container named 'w1' exists"
ct FAKE_MODE=int -- --name w1
eq "container: Ctrl-C ends the walk with 130" "$rc" 130
has "container: Ctrl-C still removes the container it created" "$log" "rm -f w1"
ct FAKE_MODE=int -- --name w1 --keep
hasnt "container: Ctrl-C with --keep leaves it" "$log" "rm -f"
has "container: … and says how to remove it" "$out" "remove it with: podman rm -f w1"
ct FAKE_MODE=setupfail -- --name w1
has "container: a failed setup removes the container it created" "$rc $log" "rm -f w1"
has "container: … and says what failed" "$out" "container setup failed"

if [ "$fails" -eq 0 ]; then echo "walk.sh tests: all $checks checks passed"; else echo "walk.sh tests: $fails of $checks FAILED"; exit 1; fi
