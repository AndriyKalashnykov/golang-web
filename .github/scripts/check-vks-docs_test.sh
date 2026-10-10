#!/usr/bin/env bash
# shellcheck disable=SC2016  # the fixtures are shell and markdown text in single quotes, on purpose
# Tests for check-vks-docs.sh (run by `make scripts-test`). Each case builds a small vks/ tree
# with one correct guide, plants one defect (or none), runs the gate on it and compares the
# result with the expected pass or with the gate's reason line. A planted defect must produce
# exactly ONE error, so a case cannot pass because some other check happened to fire.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/check-vks-docs.sh
ROOT=$(cd "$HERE/../.." && pwd)
WALK=$ROOT/vks/test/walk.sh
fails=0

# A correct guide. It holds, on purpose, every shape a check must NOT flag: `#` inside a
# heredoc, inside quotes and in ${#x}; a prompting command that is last, or inside an `if`;
# `read` fed by a pipe; a login with --password-stdin; an optional ${VAR:-default}; a
# "this terminal" variable used by a later block; single-quoted $text; an alternative.
fixture() {
  D=$(mktemp -d)
  mkdir -p "$D/vks/img" "$D/vks/sub"
  : > "$D/vks/img/a.png"
  : > "$D/allow"
  printf '# Other\n\n## Second part — the `tools`\n\ntext\n\n## Twice\n\n## Twice\n' > "$D/vks/OTHER.md"
  printf '# Internal\n\n```sh\nif then # not checked\n```\n[x](nowhere.md)\n' > "$D/vks/HANDOFF.md"
  cat > "$D/vks/GUIDE.md" <<'GUIDE'
# Guide

See [the other file](OTHER.md), [its tools](OTHER.md#second-part--the-tools), the
[second Twice](OTHER.md#twice-1), [below](#2-use-it) and [a site](https://example.test/x#y).
![a picture](img/a.png) and `[not a link](nowhere.md)`.

## 1. Set up

```sh
( umask 077; set -C; cat > ~/.fx.env <<'EOF'
export APP_HOST="app.example.test"     # a comment in a heredoc is data
export APP_TOKEN=''
. "$HOME/.fx.functions"
EOF
)
cat >| ~/.fx.functions <<'EOF'
# fx_cfg: writes a curl config to $CFG
fx_cfg() {
  local u="$1"
  CFG="$(mktemp)"; printf 'user = "%s"\n' "$u" > "$CFG"
}
tool_install() {
  local t="$1"
  sudo install -m 0755 "$t" /usr/local/bin/tool
}
EOF
cat > ~/.fx2.env <<'EOF'
export EXTRA="1"
. "$HOME/.fx.env"
EOF
```

**Expect:** no output.

## 2. Use it

```sh
source ~/.fx.env
fx_cfg admin
curl -s -K "$CFG" "https://${APP_HOST}/x#frag" -o /dev/null -w 'http=%{http_code} # not a comment\n'
echo "count ${#APP_HOST} $# and a # in quotes" '$NOT_A_VARIABLE'
printf '%s' "$APP_TOKEN" | podman login --username u --password-stdin "$APP_HOST"
if [ -n "${OPTIONAL:-}" ]; then
  sudo true
  echo "inside the same if: read before the prompt"
fi
```

**Expect:** `http=200`.
**If not:** check `APP_HOST`.

Put your choice into this terminal:

```sh
CHOICE="one"
```

**Expect:** no output.

```sh
source ~/.fx2.env
echo "$CHOICE $EXTRA $APP_HOST"
printf 'a b\n' | while IFS=" " read -r first second; do echo "$first $second"; done
for f in a b; do echo "$f"; done
tool_install /tmp/tool
```

**Expect:** `one 1 app.example.test`.

<details>
<summary>Alternative</summary>

```sh
D="$(. /etc/os-release && echo "$ID")"
sudo true
```

**Expect:** no output.

</details>
GUIDE
}

# block <text>: appends one more `sh` block, followed by an Expect, to the guide.
block() { printf '\n```sh\n%s\n```\n\n**Expect:** something.\n' "$1" >> "$D/vks/GUIDE.md"; }

# run <label> <pass | text of the expected reason line> [extra env assignments for the gate]
run() {
  local label=$1 want=$2 out rc n; shift 2
  out=$(cd "$D" && env VKS_DOCS_ALLOW="$D/allow" VKS_DOCS_WALK="$WALK" VKS_DOCS_MIN_BLOCKS=1 VKS_DOCS_MIN_FILES=1 "$@" bash "$SCRIPT" 2>&1); rc=$?
  n=$(grep -c '^ERROR ' <<<"$out")
  if [ "$want" = pass ]; then
    if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ] && grep -q '^check-vks-docs: checked [1-9][0-9]* block(s) in [1-9][0-9]* file(s); 0 error(s)' <<<"$out"; then echo "PASS  $label"
    else echo "FAIL  $label: rc=$rc: $out"; fails=$((fails + 1)); fi
  elif [ "$rc" -ne 0 ] && [ "$n" -eq 1 ] && grep '^ERROR ' <<<"$out" | grep -qF -- "$want"; then echo "PASS  $label (fails: $want)"
  else echo "FAIL  $label: rc=$rc, $n error(s), want exactly one containing '$want': $out"; fails=$((fails + 1)); fi
  rm -rf "$D"
}

fixture;                                               run "correct guide"                         pass

# 1 syntax
fixture; block 'if true; then';                        run "bash syntax error"                     "[syntax] vks/GUIDE.md:83: the block does not parse in bash"
if command -v zsh >/dev/null 2>&1; then
  fixture; block 'end';                                run "parses in bash, not in zsh"            "the block does not parse in zsh"
else
  echo "SKIP  parses in bash, not in zsh (zsh is not installed)"
fi

# 2 comment
fixture; block 'ls -l # list the files';               run "comment after a command"               "[comment] vks/GUIDE.md:83: a comment on a command line"
fixture; block "$(printf '# list the files\nls -l')";  run "comment line"                          "[comment] vks/GUIDE.md:83: a comment line"
fixture; block "$(printf 'if true; then\n  ls;# x\nfi')"; run "comment after a semicolon"           "[comment] vks/GUIDE.md:84: a comment on a command line"

# 3 prompt
fixture; block "$(printf 'sudo true\necho after')";    run "a line after sudo"                     "[prompt] vks/GUIDE.md:83: nothing may follow a line that can prompt: 'sudo' can prompt, and line 84 follows"
fixture; block "$(printf 'source ~/.fx.env\ntool_install /tmp/t\necho after')"
                                                       run "a line after a function that runs sudo" "'tool_install' can prompt"
fixture; block "$(printf 'read -r ANSWER\necho "$ANSWER"')"; run "a line after read"                "'read' can prompt"
fixture; block "$(printf 'ssh host.example.test uptime\necho after')"; run "a line after ssh"       "'ssh' can prompt"
fixture; block "$(printf 'X=1 argocd login server.example.test\necho after')"; run "a line after argocd login" "'argocd login' can prompt"
fixture; block "$(printf '/bin/bash -c "$(curl -fsSL https://example.test/install.sh)"\necho after')"
                                                       run "a line after a fetched installer"      "an installer run with bash -c"
fixture; block "$(printf 'if true; then\n  sudo true\nfi\necho after')"; run "a line after an if that holds sudo" "'sudo' can prompt, and line 86 follows"
fixture; block "$(printf 'ssh host.example.test uptime </dev/null\necho after')"; run "ssh with stdin redirected" pass
fixture; block "$(printf 'echo "run sudo yourself; sudo is not run here"\necho after')"; run "sudo only inside a message" pass

# 4 shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  fixture; block "$(printf 'X="a b"\nls $X')";         run "shellcheck finding"                    "[shellcheck] vks/GUIDE.md:84: shellcheck: "
else
  echo "SKIP  shellcheck finding (shellcheck is not installed)"
fi

# 5 env
fixture; block 'echo "$APP_HOST"';                     run "env variable without the source line"  "uses APP_HOST, which ~/.fx.env provides, but does not start with 'source ~/.fx.env'"
fixture; block "$(printf 'echo start\nsource ~/.fx.env\necho "$APP_HOST"')"
                                                       run "source line is not the first line"     "uses APP_HOST, which ~/.fx.env provides, but does not start with 'source ~/.fx.env'"
fixture; block 'fx_cfg admin';                         run "env function without the source line"  "uses fx_cfg, which ~/.fx.env provides, but does not start with"
fixture; block "$(printf 'source ~/.fx.env\necho "$EXTRA"')"; run "variable of another env file"    "uses EXTRA, which ~/.fx2.env provides, but starts by sourcing another file"
fixture; block 'echo "$NOWHERE_SET"';                  run "variable nothing sets"                 "uses \$NOWHERE_SET, which nothing sets"
fixture; block 'echo "$ID"';                           run "os-release name without sourcing it"   "uses \$ID, which nothing sets"
fixture; block "$(printf 'Y=2\necho "$Y ${Z:-default} $HOME"')"; run "set in the block, defaulted, ambient" pass
fixture; sed -i.bak 's/^Put your choice into this terminal:/Put your choice here:/' "$D/vks/GUIDE.md"
                                                       run "earlier block not marked this terminal" "uses \$CHOICE, which nothing sets"

# 6 expect, and the allowlist
fixture; printf '\n```sh\necho no-expect\n```\n\n## Next\n\n**Expect:** too late.\n' >> "$D/vks/GUIDE.md"
                                                       run "block without Expect"                  "[expect] vks/GUIDE.md:83: no **Expect:** between this block and the next block or heading"
fixture; printf '\n```sh\necho no-expect\n```\n' >> "$D/vks/GUIDE.md"
         echo 'expect | GUIDE.md | a reason | echo no-expect' > "$D/allow"
                                                       run "allowed finding"                       pass
fixture; echo 'expect | GUIDE.md | a reason | echo gone' > "$D/allow"
                                                       run "allowlist entry that allows nothing"   "[allowlist] $D/allow:1: this entry allows nothing any more"
fixture; printf '\n```sh\necho same\n```\n\n```sh\necho same\n```\n' >> "$D/vks/GUIDE.md"
         echo 'expect | GUIDE.md | a reason | echo same' > "$D/allow"
                                                       run "allowlist line found in two blocks"    "this entry's line is in 2 blocks of GUIDE.md"
fixture; echo 'expect GUIDE.md no separators' > "$D/allow"
                                                       run "malformed allowlist line"              "not 'check | file | reason | exact line'"

# 7 link
fixture; echo '[x](missing.md)' >> "$D/vks/GUIDE.md";  run "link to a missing file"                "[link] vks/GUIDE.md:81: the link target does not exist: missing.md"
fixture; echo '[x](OTHER.md#no-such-heading)' >> "$D/vks/GUIDE.md"; run "anchor no heading makes"   "no heading in OTHER.md makes the anchor #no-such-heading"
fixture; echo '[x](#3-nothing)' >> "$D/vks/GUIDE.md";  run "anchor in the same file"               "no heading in GUIDE.md makes the anchor #3-nothing"
fixture; echo '[x](OTHER.md#twice-2)' >> "$D/vks/GUIDE.md"; run "anchor of a third duplicate"       "makes the anchor #twice-2"
fixture; echo '![x](img/none.png)' >> "$D/vks/GUIDE.md"; run "image that is missing"                "the image file does not exist: img/none.png"
fixture; echo '[x](../outside.md)' > "$D/vks/sub/DEEP.md"; run "link in a guide in a subdirectory"  "[link] vks/sub/DEEP.md:1: the link target does not exist: ../outside.md"
fixture; echo '[x](missing.md)' >> "$D/vks/GUIDE.md"; echo 'link | GUIDE.md | a reason | missing.md' > "$D/allow"
                                                       run "allowed link"                          pass

# 8 details
fixture; printf '\n<details>\ntext\n' >> "$D/vks/GUIDE.md"; run "details not closed"                "[details] vks/GUIDE.md:82: <details> without a </details> after it"
fixture; printf '\n</details>\n' >> "$D/vks/GUIDE.md";  run "details closed twice"                  "[details] vks/GUIDE.md:82: </details> without a <details> before it"

# 9 secret
fixture; block "$(printf 'source ~/.fx.env\npodman login -u admin -p "$APP_TOKEN" "$APP_HOST" </dev/null')"
                                                       run "login -p"                              "a secret on a command line (login-p)"
fixture; block "$(printf 'source ~/.fx.env\ntool --password "$APP_TOKEN"')"; run "--password value" "a secret on a command line (password-flag)"
fixture; block 'tool --password=hunter2';              run "--password=literal"                    "a secret on a command line (password-flag)"
fixture; block "$(printf 'source ~/.fx.env\ncurl -s \\\n  -u "admin:$APP_TOKEN" "https://$APP_HOST/"')"
                                                       run "curl -u on a continued line"           "[secret] vks/GUIDE.md:84: a secret on a command line (curl-user)"
fixture; block "$(printf 'source ~/.fx.env\necho "$APP_TOKEN"')"; run "echo of a secret"            "a secret on a command line (echo-secret)"
fixture; block "$(printf 'source ~/.fx.env\nkubectl create secret generic s --from-literal=password="$APP_TOKEN"')"
                                                       run "--from-literal"                        "a secret on a command line (from-literal)"

# 10 count
fixture;                                               run "fewer blocks than the floor"           "checked 5 block(s), fewer than the floor of 999" VKS_DOCS_MIN_BLOCKS=999
fixture;                                               run "fewer files than the floor"            "read 2 file(s), fewer than the floor of 99" VKS_DOCS_MIN_FILES=99
fixture; rm "$D/vks/GUIDE.md";                         run "no blocks at all"                      "checked 0 block(s), fewer than the floor of 1"
fixture; rm "$D/vks/GUIDE.md" "$D/vks/OTHER.md";       run "no guide at all"                       "read 0 file(s), fewer than the floor of 1" VKS_DOCS_MIN_BLOCKS=0

# The repository's own guides pass, with the floors and the allowlist it ships.
out=$(cd "$ROOT" && bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^check-vks-docs: checked [1-9][0-9]* block(s) in [1-9][0-9]* file(s); 0 error(s)' <<<"$out"; then
  echo "PASS  the repository's guides ($(grep '^check-vks-docs: checked' <<<"$out"))"
else
  echo "FAIL  the repository's guides: rc=$rc: $out"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "check-vks-docs tests: all passed"; else echo "check-vks-docs tests: $fails FAILED"; exit 1; fi
