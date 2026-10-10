#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1003  # the fixtures are shell and markdown text in single quotes, on purpose
# Tests for check-vks-docs.sh (run by `make scripts-test`). Each case builds a small vks/ tree
# with one correct guide, plants one defect (or none), runs the gate on it and compares the
# result with the expected pass or with the gate's reason line. A planted defect must produce
# exactly ONE error, so a case cannot pass because some other check happened to fire.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/check-vks-docs.sh
ROOT=$(cd "$HERE/../.." && pwd)
WALK=$ROOT/vks/test/walk.sh
fails=0; cases=0
F3='```'

# A correct guide. It holds, on purpose, every shape a check must NOT flag: `#` inside a
# heredoc, inside quotes and in ${#x}; a prompting command that is last, or inside an `if`;
# `read` fed by a pipe; a login with --password-stdin; an optional ${VAR:-default}; a
# "this terminal" variable used by a later block of the same step; single-quoted $text; an
# alternative; data fences; `<<` as a shift and $'…\'…' quoting.
fixture() {
  D=$(mktemp -d)
  mkdir -p "$D/vks/img" "$D/vks/sub"
  : > "$D/vks/img/a.png"
  : > "$D/allow"
  RECOUNT=1
  printf '# Other\n\n## Second part — the `tools`\n\ntext\n\n## Twice\n\n## Twice\n' > "$D/vks/OTHER.md"
  printf '# Internal\n\n```sh\nif then # not checked\n```\n\n~~~bash\n~~~\n[x](nowhere.md)\n' > "$D/vks/HANDOFF.md"
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

A request to send, and two data files:

```text
Please create a namespace # not a shell block, not a comment
```

- a list item

    ```yaml
    name: indented-data
    ```

```json
{"a": 1}
```
GUIDE
}

# The table of guides, as the gate wants it: every *.md that is not internal, with its count.
recount() {
  ( cd "$D/vks" && find . -type f -name '*.md' ! -name HANDOFF.md ! -name PLAN.md | sed 's|^\./||' | sort \
      | while IFS= read -r g; do echo "$g $(grep -c '^ \{0,3\}```sh *$' "$g")"; done ) > "$D/blocks"
}

# block <text>: appends one more `sh` block, followed by an Expect, to the guide.
block() { printf '\n```sh\n%s\n```\n\n**Expect:** something.\n' "$1" >> "$D/vks/GUIDE.md"; }
# raw <markdown>: appends text as it is.
raw() { printf '\n%b\n' "$1" >> "$D/vks/GUIDE.md"; }

gate() { # [extra env assignments] -> sets $out and $rc
  [ "${RECOUNT:-1}" -eq 0 ] || recount
  out=$(cd "$D" && env -u CI VKS_DOCS_ALLOW="$D/allow" VKS_DOCS_WALK="$WALK" VKS_DOCS_BLOCKS="$D/blocks" "$@" bash "$SCRIPT" 2>&1); rc=$?
  cases=$((cases + 1))
}

# VKS_DOCS_TEST_ONLY=<extended regex>: run only the cases whose label matches (for work on one check).
wanted() {
  [ -z "${VKS_DOCS_TEST_ONLY:-}" ] || grep -Eq -e "$VKS_DOCS_TEST_ONLY" <<<"$1" || { rm -rf "$D"; return 1; }
}

# run <label> <pass | text of the expected reason line> [extra env assignments for the gate]
run() {
  local label=$1 want=$2 n; shift 2
  wanted "$label" || return 0
  gate "$@"
  n=$(grep -c '^ERROR ' <<<"$out")
  if [ "$want" = pass ]; then
    if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ] && grep -q '^check-vks-docs: checked [1-9][0-9]* block(s) in [1-9][0-9]* file(s); 0 error(s)' <<<"$out"; then echo "PASS  $label"
    else echo "FAIL  $label: rc=$rc: $out"; fails=$((fails + 1)); fi
  elif [ "$rc" -ne 0 ] && [ "$n" -eq 1 ] && grep '^ERROR ' <<<"$out" | grep -qF -- "$want"; then echo "PASS  $label (fails: $want)"
  else echo "FAIL  $label: rc=$rc, $n error(s), want exactly one containing '$want': $out"; fails=$((fails + 1)); fi
  rm -rf "$D"
}
# run_has <label> <text>: the gate fails and ONE OF its errors holds the text (cases where a
# second error is part of the design: an allowed parse error, an allowlist entry that is refused).
run_has() {
  local label=$1 want=$2; shift 2
  wanted "$label" || return 0
  gate "$@"
  if [ "$rc" -ne 0 ] && grep '^ERROR ' <<<"$out" | grep -qF -- "$want"; then echo "PASS  $label (fails: $want)"
  else echo "FAIL  $label: rc=$rc, want an error containing '$want': $out"; fails=$((fails + 1)); fi
  rm -rf "$D"
}

fixture;                                               run "correct guide"                         pass

# 1 syntax
fixture; block 'if true; then';                        run "bash syntax error"                     "[syntax] vks/GUIDE.md:99: the block does not parse in bash"
if command -v zsh >/dev/null 2>&1; then
  fixture; block 'end';                                run "parses in bash, not in zsh"            "the block does not parse in zsh"
else
  echo "SKIP  parses in bash, not in zsh (zsh is not installed)"
fi

# 2 comment
fixture; block 'ls -l # list the files';               run "comment after a command"               "[comment] vks/GUIDE.md:99: a comment on a command line"
fixture; block "$(printf '# list the files\nls -l')";  run "comment line"                          "[comment] vks/GUIDE.md:99: a comment line"
fixture; block "$(printf 'if true; then\n  ls;# x\nfi')"; run "comment after a semicolon"           "[comment] vks/GUIDE.md:100: a comment on a command line"
# the sanitiser: a shift is not a heredoc, and \' does not end $'…'
fixture; block "$(printf 'N=$(( 1 << 4 ))\nls -l # after a shift\necho "$N"')"
                                                       run "comment after \$(( 1 << 4 ))"          "[comment] vks/GUIDE.md:100: a comment on a command line"
fixture; block "$(printf '(( 1 << 4 )) && echo big\nls -l # after a shift')"
                                                       run "comment after (( 1 << 4 ))"            "[comment] vks/GUIDE.md:100: a comment on a command line"
fixture; block "$(printf 'printf "%%s\\\\n" $'"'"'it\\'"'"'s'"'"'\nls -l # after the quote')"
                                                       run "comment after \$'it\\'s'"              "[comment] vks/GUIDE.md:100: a comment on a command line"
fixture; block "$(printf 'N=$(( 1 << 4 ))\nprintf "%%s\\\\n" $'"'"'it\\'"'"'s # not a comment'"'"' "$N"\ncat <<EOF\n# data\nEOF')"
                                                       run "shift, \$'…' and a real heredoc"       pass

# 3 prompt
fixture; block "$(printf 'sudo true\necho after')";    run "a line after sudo"                     "[prompt] vks/GUIDE.md:99: nothing may follow a line that can prompt: 'sudo' can prompt, and line 100 follows"
fixture; block "$(printf 'source ~/.fx.env\ntool_install /tmp/t\necho after')"
                                                       run "a line after a function that runs sudo" "'tool_install' can prompt"
fixture; block "$(printf 'read -r ANSWER\necho "$ANSWER"')"; run "a line after read"                "'read' can prompt"
fixture; block "$(printf 'ssh host.example.test uptime\necho after')"; run "a line after ssh"       "'ssh' can prompt"
fixture; block "$(printf 'X=1 argocd login server.example.test\necho after')"; run "a line after argocd login" "'argocd login' can prompt"
fixture; block "$(printf '/bin/bash -c "$(curl -fsSL https://example.test/install.sh)"\necho after')"
                                                       run "a line after a fetched installer"      "an installer run with bash -c"
fixture; block "$(printf 'if true; then\n  sudo true\nfi\necho after')"; run "a line after an if that holds sudo" "'sudo' can prompt, and line 102 follows"
fixture; block "$(printf 'ssh host.example.test uptime </dev/null\necho after')"; run "ssh with stdin redirected" pass
fixture; block "$(printf 'echo "run sudo yourself; sudo is not run here"\necho after')"; run "sudo only inside a message" pass
fixture; block "$(printf 'ssh host.example.test uptime | tee log\necho after')"
                                                       run "ssh on the LEFT of a pipe still reads the paste" "'ssh' can prompt"
fixture; block "$(printf 'printf "x\\\\n" | ssh host.example.test cat\necho after')"
                                                       run "ssh on the RIGHT of a pipe is fed"     pass
fixture; block "$(printf 'while read -r L; do echo "$L"; done < /etc/hostname\necho after')"
                                                       run "read inside a loop that is redirected" pass
fixture; block "$(printf 'sudo -n true\necho after')"; run "sudo -n never prompts"                 pass
fixture; block "$(printf 'su - admin\necho after')";   run "a line after su"                       "'su' can prompt"
fixture; block "$(printf 'env X=1 sudo true\necho after')"; run "a line after env X=1 sudo"         "'sudo' can prompt"
fixture; block "$(printf 'command sudo true\necho after')"; run "a line after command sudo"         "'sudo' can prompt"

# 4 shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  fixture; block "$(printf 'X="a b"\nls $X')";         run "shellcheck finding"                    "[shellcheck] vks/GUIDE.md:100: shellcheck: "
else
  echo "SKIP  shellcheck finding (shellcheck is not installed)"
fi
fixture;                                               run "no shellcheck, CI set: an error"       "[tool] vks: shellcheck is not installed and CI is set" CI=true VKS_DOCS_SHELLCHECK=no-such-shellcheck
fixture;                                               run "no shellcheck, CI not set: skipped"    pass VKS_DOCS_SHELLCHECK=no-such-shellcheck

# 5 env
fixture; block 'echo "$APP_HOST"';                     run "env variable without the source line"  "uses APP_HOST, which ~/.fx.env provides, but does not start with 'source ~/.fx.env'"
fixture; block "$(printf 'echo start\nsource ~/.fx.env\necho "$APP_HOST"')"
                                                       run "source line is not the first line"     "uses APP_HOST, which ~/.fx.env provides, but does not start with 'source ~/.fx.env'"
fixture; block 'fx_cfg admin';                         run "env function without the source line"  "uses fx_cfg, which ~/.fx.env provides, but does not start with"
fixture; block "$(printf 'source ~/.fx.env\necho "$EXTRA"')"; run "variable of another env file"    "uses EXTRA, which ~/.fx2.env provides, but starts by sourcing another file"
# A later chapter appends helper commands and settings to the files step 1 wrote.
APPEND=$(printf '%s\n' "[ ! -f ~/.fx.functions ] || grep -qs '^fx_more()' ~/.fx.functions || cat >> ~/.fx.functions <<'EOF'" 'fx_more() {' '  local n="$1"' '  echo "more $n"' '}' 'EOF' "grep -qs '^export MORE_HOST=' ~/.fx.env || printf '%s\\n' 'export MORE_HOST=\"\"' >> ~/.fx.env")
fixture; block "$APPEND"; block "$(printf 'source ~/.fx.env\nfx_more 1\necho "$MORE_HOST"')"
                                                       run "appended function and setting, sourced" pass
fixture; block "$APPEND"; block 'fx_more 1';           run "appended function without the source line" "uses fx_more, which ~/.fx.env provides, but does not start with"
fixture; block "$APPEND"; block 'echo "$MORE_HOST"';   run "appended setting without the source line" "uses MORE_HOST, which ~/.fx.env provides, but does not start with"
fixture; block "$(printf '%s\n' 'E="$HOME/.fx.env"' "printf '%s\\n' 'export HIDDEN_HOST=\"\"' >> \"\$E\"")"; block "$(printf 'source ~/.fx.env\necho "$HIDDEN_HOST"')"
                                                       run "setting appended through a variable path is not in the contract" "uses \$HIDDEN_HOST, which nothing sets"
fixture; block 'echo "$NOWHERE_SET"';                  run "variable nothing sets"                 "uses \$NOWHERE_SET, which nothing sets"
fixture; block 'echo "$ID"';                           run "os-release name without sourcing it"   "uses \$ID, which nothing sets"
fixture; block "$(printf 'Y=2\necho "$Y ${Z:-default} $HOME"')"; run "set in the block, defaulted, ambient" pass
fixture; sed -i.bak 's/^Put your choice into this terminal:/Put your choice here:/' "$D/vks/GUIDE.md"; rm -f "$D/vks/GUIDE.md.bak"
                                                       run "earlier block not marked this terminal" "uses \$CHOICE, which nothing sets"
# "this terminal" ends with its numbered step, unless the guide says until which step
fixture; raw '## 3. Third\n\n```sh\necho "$CHOICE"\n```\n\n**Expect:** one.'
                                                       run "this-terminal variable used in the next step" "[env] vks/GUIDE.md:101: uses \$CHOICE, which nothing sets"
fixture; sed -i.bak 's/^Put your choice into this terminal:/Put your choice into **this terminal**; keep using this\nterminal until the end of step 3:/' "$D/vks/GUIDE.md"; rm -f "$D/vks/GUIDE.md.bak"
         raw '## 3. Third\n\n```sh\necho "$CHOICE"\n```\n\n**Expect:** one.'
                                                       run "this terminal until the end of step 3"  pass
fixture; sed -i.bak 's/^Put your choice into this terminal:/Put your choice into this terminal until the end of step 3:/' "$D/vks/GUIDE.md"; rm -f "$D/vks/GUIDE.md.bak"
         raw '## 3. Third\n\ntext\n\n## 4. Fourth\n\n```sh\necho "$CHOICE"\n```\n\n**Expect:** one.'
                                                       run "… and not beyond step 3"               "uses \$CHOICE, which nothing sets"

# 6 expect, and the allowlist
fixture; raw '```sh\necho no-expect\n```\n\n## Next\n\n**Expect:** too late.'
                                                       run "block without Expect"                  "[expect] vks/GUIDE.md:99: no **Expect:** between this block and the next block or heading"
fixture; raw '```sh\necho no-expect\n```'
         echo 'expect | GUIDE.md | a reason | echo no-expect' > "$D/allow"
                                                       run "allowed finding"                       pass
fixture; echo 'expect | GUIDE.md | a reason | echo gone' > "$D/allow"
                                                       run "allowlist entry that allows nothing"   "[allowlist] $D/allow:1: this entry allows nothing any more"
fixture; raw '```sh\necho same\n```\n\n```sh\necho same\n```'
         echo 'expect | GUIDE.md | a reason | echo same' > "$D/allow"
                                                       run "allowlist line found in two blocks"    "this entry's line is in 2 blocks of GUIDE.md"
fixture; echo 'expect GUIDE.md no separators' > "$D/allow"
                                                       run "malformed allowlist line"              "not 'check | file | reason | exact line'"
fixture; block 'ls -l # list'; block 'ls -l # list'
         echo 'comment | GUIDE.md | a reason | ls -l # list' > "$D/allow"
                                                       run "line-level entry that matches two findings" "this entry allows 2 findings in GUIDE.md (line 105, line 99); an entry may allow exactly one"
fixture; block 'ls -l # list'
         echo 'comment | GUIDE.md | a reason | ls -l # list' > "$D/allow"
                                                       run "line-level entry that matches one finding" pass
fixture; block "$(printf 'ls -l # list\nif true; then')"
         echo 'syntax | GUIDE.md | a reason | if true; then' > "$D/allow"
                                                       run_has "allowed syntax finding does not hide the block's other findings" "[comment] vks/GUIDE.md:99: a comment on a command line"

# 7 link
fixture; raw '[x](missing.md)';                        run "link to a missing file"                "[link] vks/GUIDE.md:98: the link target does not exist: missing.md"
fixture; raw '[x](OTHER.md#no-such-heading)';          run "anchor no heading makes"               "no heading in OTHER.md makes the anchor #no-such-heading"
fixture; raw '[x](#3-nothing)';                        run "anchor in the same file"               "no heading in GUIDE.md makes the anchor #3-nothing"
fixture; raw '[x](OTHER.md#twice-2)';                  run "anchor of a third duplicate"           "makes the anchor #twice-2"
fixture; raw '![x](img/none.png)';                     run "image that is missing"                 "the image file does not exist: img/none.png"
fixture; echo '[x](../outside.md)' > "$D/vks/sub/DEEP.md"; run "link in a guide in a subdirectory"  "[link] vks/sub/DEEP.md:1: the link target does not exist: ../outside.md"
fixture; raw '[x](missing.md)'; echo 'link | GUIDE.md | a reason | missing.md' > "$D/allow"
                                                       run "allowed link"                          pass

# 8 details
fixture; raw '<details>\ntext';                        run "details not closed"                    "[details] vks/GUIDE.md:98: <details> without a </details> after it"
fixture; raw '</details>';                             run "details closed twice"                  "[details] vks/GUIDE.md:98: </details> without a <details> before it"

# 9 secret: the flag first, the flag later, and the widened forms; then the near misses
S='source ~/.fx.env'
sec() { # <label> <pattern name> <command line(s)>
  fixture; block "$(printf '%s\n%s' "$S" "$3")"; run "$1" "a secret on a command line ($2)"
}
sec "login -p after another option"        login-p       'podman login -u admin -p "$APP_TOKEN" "$APP_HOST" </dev/null'
sec "login -p as the first option"         login-p       'podman login -p "$APP_TOKEN" -u admin "$APP_HOST" </dev/null'
sec "sshpass -p as the first option"       login-p       'sshpass -p "$APP_TOKEN" ssh host.example.test true </dev/null'
sec "mysql -p glued to its value"          login-p       'mysql -u root -p"$APP_TOKEN" -e "select 1" </dev/null'
sec "--password value"                     password-flag 'tool --password "$APP_TOKEN"'
sec "--password=literal"                   password-flag 'tool --password=hunter2'
sec "--admin-password="                    password-flag 'tool --admin-password="$APP_TOKEN"'
sec "--client-secret value"                password-flag 'tool --client-secret "$APP_TOKEN"'
sec "--bearer-token value"                 password-flag 'tool --bearer-token "$APP_TOKEN"'
sec "curl -u as the first option"          curl-user     'curl -u admin:x "https://$APP_HOST/"'
sec "curl -su"                             curl-user     'curl -su "admin:$APP_TOKEN" "https://$APP_HOST/"'
sec "curl --user after another option"     curl-user     'curl -s --user "admin:$APP_TOKEN" "https://$APP_HOST/"'
fixture; block "$(printf '%s\ncurl -s \\\n  -u "admin:$APP_TOKEN" "https://$APP_HOST/"' "$S")"
                                                       run "curl -u on a continued line"           "[secret] vks/GUIDE.md:100: a secret on a command line (curl-user)"
sec "Authorization header with a variable" auth-header   'curl -s -H "Authorization: Bearer $APP_TOKEN" "https://$APP_HOST/"'
sec "user:password@ in a URL"              url-userinfo  'git ls-remote "https://admin:$APP_TOKEN@$APP_HOST/x.git"'
sec "echo of a secret"                     echo-secret   'echo "$APP_TOKEN"'
sec "--from-literal with a secret variable" from-literal 'kubectl create secret generic s --from-literal=pw="$APP_TOKEN"'
sec "--from-literal keyed password"        from-literal  'kubectl create secret generic s --from-literal=admin-password=hunter2'
fixture; block "$(sed 's/@AUTH@/Authori''zation: Bearer/' <<'NEAR'
source ~/.fx.env
fx_cfg admin
mkdir -p "$HOME/x"
curl -s --user-agent probe -K "$CFG" -H "Content-Type: application/json" -H '@AUTH@ literal-in-single-quotes' "https://${APP_HOST}:8443/users"
tool --password-stdin --token-file /tmp/t --secret-name s --passwordless
kubectl create secret generic s --from-literal=username="$APP_HOST" --from-literal=color=blue
git ls-remote "https://${APP_HOST}:8443/org/repo@v1.git"
mysql -u root -p -e "select 1" </dev/null
ssh -p 2222 host.example.test true </dev/null
NEAR
)";                                                    run "near misses of every secret pattern"   pass

# 10 fence: a block the extractor does not read must not pass unseen (each holds a bad block)
fence() { # <label> <reason> <markdown>
  fixture; raw "$3"; run "$1" "[fence] vks/GUIDE.md:$4: no check reads this fenced block, because $2"
}
fence "~~~ fence"                    'it is fenced with ~~~'      '~~~sh\nif then # bad\n~~~'  98
fence "fence indented under a list"  'it is indented 4 spaces'    '- item\n\n    ```sh\n    if then # bad\n    ```'  100
fence "fence in a quote"             'it is inside a > quote'     '> ```sh\n> if then # bad\n> ```'  98
fence "fence without a tag"          'it has no tag'              '```\nif then # bad\n```'  98
fence "four backticks"               'it has 4 backticks'         '````sh\nif then # bad\n````'  98
for tag in bash shell console zsh SH '{.sh}' sh-session; do
  fence "fence tagged $tag"          "its tag is \"$tag\""        "$F3$tag\nif then # bad\n$F3"                       98
done

# 11 count and the table of guides
fixture; RECOUNT=0; recount; sed -i.bak 's/^GUIDE.md 5$/GUIDE.md 6/' "$D/blocks"
                                                       run "fewer blocks than the table records"   "[count] vks/GUIDE.md: it has 5 sh block(s) and $D/blocks records 6"
fixture; RECOUNT=0; recount; block 'echo one-more'
                                                       run "more blocks than the table records"    "If that is intended, change the line to 'GUIDE.md 6'"
# three blocks retagged in one guide while a new guide brings three: the total is unchanged
fixture; RECOUNT=0; recount; sed -i.bak '/^Put your choice/,$ s/^```sh$/```text/' "$D/vks/GUIDE.md"; rm -f "$D/vks/GUIDE.md.bak"
         printf '# New\n\n```sh\necho 1\n```\n\n**Expect:** 1.\n\n```sh\necho 2\n```\n\n**Expect:** 2.\n\n```sh\necho 3\n```\n\n**Expect:** 3.\n' > "$D/vks/NEW.md"
         echo 'NEW.md 3' >> "$D/blocks"
                                                       run "blocks retagged in one guide, as many added in another" "[count] vks/GUIDE.md: it has 2 sh block(s) and $D/blocks records 5"
fixture; RECOUNT=0; recount; printf '# New\n\n```sh\necho 1\n```\n\n**Expect:** 1.\n' > "$D/vks/NEW.md"
                                                       run "new guide that is not in the table"    "[count] vks/NEW.md: this guide is not in $D/blocks: add the line 'NEW.md 1'"
fixture; RECOUNT=0; recount; printf '# Chooser\n\n[a](../GUIDE.md)\n' > "$D/vks/sub/HARBOR.md"
                                                       run "new guide without blocks, not in the table" "add the line 'sub/HARBOR.md 0'"
fixture; printf '# Chooser\n\n[a](../GUIDE.md)\n' > "$D/vks/sub/HARBOR.md"
                                                       run "new guide without blocks, listed with 0" pass
fixture; RECOUNT=0; recount; echo 'GONE.md 4' >> "$D/blocks"
                                                       run "table lists a guide that is gone"      "it lists 'GONE.md', which is not a guide under vks any more"
fixture; RECOUNT=0; recount; echo 'GUIDE.md five' > "$D/blocks.new"; grep -v '^GUIDE' "$D/blocks" >> "$D/blocks.new"; mv "$D/blocks.new" "$D/blocks"
                                                       run_has "malformed table line"              "not '<file> <number of sh blocks>': GUIDE.md five"
fixture; RECOUNT=0; rm -f "$D/blocks";                 run "no table"                              "the table of guides is missing"
fixture; RECOUNT=0; recount; printf '# New\n' > "$D/vks/NEW.md"; echo 'count | NEW.md | a reason | NEW.md' > "$D/allow"
                                                       run_has "a count finding cannot be allowed" "[count] vks/NEW.md: this guide is not in"
fixture; rm "$D/vks/GUIDE.md";                         run "no blocks at all"                      "checked 0 block(s): no guide under vks has a fenced"
fixture; rm "$D/vks/GUIDE.md" "$D/vks/OTHER.md";       run_has "no guide at all"                   "read 0 file(s): no guide (*.md) under vks"

# 12 file names the gate would not read
fixture; printf '# Shout\n\n```sh\nif then\n```\n' > "$D/vks/LOUD.MD"
                                                       run "a guide named *.MD"                    "[file] vks/LOUD.MD: a markdown file the gate does not read: name it *.md"
fixture; printf '# Long\n' > "$D/vks/sub/long.markdown"
                                                       run "a guide named *.markdown"              "[file] vks/sub/long.markdown: a markdown file the gate does not read"

# 13 a guide in a subdirectory (vks/addons/) gets every block check, and its table row and its
# allowlist entries are written with the directory: `sub/DEEP.md`
deep() { printf '# Deep\n\n```sh\n%s\n```\n%b' "$1" "$2" > "$D/vks/sub/DEEP.md"; }
fixture; deep 'echo ok' '\n**Expect:** ok.\n';         run "subdirectory: a correct guide"         pass
fixture; deep 'if then' '\n**Expect:** ok.\n';         run "subdirectory: block that does not parse" "[syntax] vks/sub/DEEP.md:4: the block does not parse in bash"
fixture; deep 'echo ok # why' '\n**Expect:** ok.\n';   run "subdirectory: comment in a block"      "[comment] vks/sub/DEEP.md:4: a comment on a command line"
fixture; deep 'echo "$APP_HOST"' '\n**Expect:** ok.\n'; run "subdirectory: env variable without the source line" "[env] vks/sub/DEEP.md:4: uses APP_HOST, which ~/.fx.env provides"
fixture; deep 'echo ok' '';                            run "subdirectory: block without an Expect" "[expect] vks/sub/DEEP.md:4: no **Expect:**"
fixture; deep 'echo ok' ''; echo 'expect | sub/DEEP.md | a reason | echo ok' > "$D/allow"
                                                       run "subdirectory: allowed finding, file written with its directory" pass
fixture; deep 'echo ok' ''; echo 'expect | DEEP.md | a reason | echo ok' > "$D/allow"
                                                       run_has "subdirectory: an allowlist entry without the directory allows nothing" "this entry allows nothing any more"
fixture; RECOUNT=0; recount; deep 'echo ok' '\n**Expect:** ok.\n'
                                                       run "subdirectory: new guide with a block, not in the table" "add the line 'sub/DEEP.md 1'"

# The repository's own guides pass, with the table and the allowlist it ships.
out=$(cd "$ROOT" && env -u CI bash "$SCRIPT" 2>&1); rc=$?; cases=$((cases + 1))
if [ "$rc" -eq 0 ] && grep -q '^check-vks-docs: checked [1-9][0-9]* block(s) in [1-9][0-9]* file(s); 0 error(s)' <<<"$out"; then
  echo "PASS  the repository's guides ($(grep '^check-vks-docs: checked' <<<"$out"))"
else
  echo "FAIL  the repository's guides: rc=$rc: $out"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "check-vks-docs tests: all $cases cases passed"; else echo "check-vks-docs tests: $fails of $cases FAILED"; exit 1; fi
