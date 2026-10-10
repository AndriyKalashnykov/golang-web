#!/usr/bin/env bash
# shellcheck disable=SC2016  # the awk programs and the patterns are single-quoted on purpose
# Check the end-user guides under vks/ (run by `make check-vks-docs`, part of `make static-check`).
#
# Reads every vks/**/*.md except the internal files (INTERNAL below) and checks:
#   [syntax]     every fenced `sh` block parses with `bash -n`, and with `zsh -n` when zsh exists
#   [comment]    no `#` comment in a block (macOS's interactive zsh passes it as arguments);
#                heredoc bodies and quoted text are data, not comments
#   [prompt]     nothing follows a command that can prompt (a shell without bracketed paste hands
#                the rest of the paste to the prompt). "Follows" means after the top-level command
#                that holds it: a whole `if … fi` is read before any of it runs
#   [shellcheck] each block, when shellcheck exists (exclusions: SHELLCHECK_EXCLUDE below);
#                [tool]: when CI is set, a missing shellcheck is an error, not a skip
#   [env]        a block that uses a name its env file provides starts with `source ~/<env file>`,
#                and every $VAR is set in the block, by the env contract, by an earlier
#                "this terminal" block, or is a shell built-in name (AMBIENT below). The contract is
#                read from the guides' own `cat > ~/<file> <<'EOF'` blocks (and `cat >> ~/<file>`
#                heredocs and `… >> ~/<file>` lines that append to one); it is not typed here.
#                What a "this terminal" block assigns counts to the END OF ITS NUMBERED STEP
#                (the next `## N.` heading ends it), or to the end of step N when the guide's
#                sentence says "this terminal until the end of step N"
#   [expect]     every block is followed by **Expect:** before the next block or heading
#   [fence]      every opening fence is either exactly ```sh at the left margin or a data fence
#                (DATA_FENCES below): ~~~, another tag, no tag, a fence indented 4+ spaces or
#                inside a > quote would hold a block that no check reads
#   [file]       no *.MD, *.markdown or similar: only *.md is read
#   [link]       every relative link and image resolves to a file; every #anchor to a heading
#   [details]    <details> and </details> balance
#   [secret]     no secret on a command line (SECRET PATTERNS below)
#   [count]      each guide has exactly the number of `sh` blocks check-vks-docs.blocks records
#                for it, and every guide is listed there; the totals are printed
# The block extractor is vks/test/walk.sh, so this gate and a walk see the same blocks.
#
# A NEW GUIDE needs one line in check-vks-docs.blocks: `<file relative to vks/> <sh blocks>`.
# The error for a guide that is not listed prints that line.
#
# A finding that is known and accepted goes into check-vks-docs.allow, one per line:
#   check | file | reason | one exact line of the block (or the link target, for link)
# An entry must allow exactly ONE finding: one that matches nothing fails the gate, as does one
# whose line is in two blocks or that matches a second finding. count, file and tool findings
# cannot be allowed. A block whose syntax finding is allowed still gets every other check.
#
# Not detected: a comment inside `$( … )` within double quotes when a case pattern closes the
# parenthesis early; commands hidden in `eval` or `bash -c "…"`; reference-style links
# (`[a]: url`); headings whose non-ASCII punctuation is not in the list in the slug function.
# Run from the repository root. Needs bash 3.2+, a POSIX awk, sed, grep, sort, find.
set -u
export LC_ALL=C

DIR=${VKS_DOCS_DIR:-vks}
ALLOW=${VKS_DOCS_ALLOW:-.github/scripts/check-vks-docs.allow}
WALK=${VKS_DOCS_WALK:-vks/test/walk.sh}
# The guides and how many `sh` blocks each has: `<file relative to vks/> <number>` per line, 0 for
# a guide with none. The count must be EQUAL: a block that is removed, or no longer fenced as
# `sh`, cannot hide behind blocks added elsewhere. A guide that is not listed is an error.
BLOCKS=${VKS_DOCS_BLOCKS:-.github/scripts/check-vks-docs.blocks}
SHELLCHECK=${VKS_DOCS_SHELLCHECK:-shellcheck}

# Internal working files, not end-user guides (paths relative to $DIR).
INTERNAL="PLAN.md HANDOFF.md test/README.md"

# Tags a fence that holds DATA may carry. Every other opening fence must be exactly ```sh at the
# left margin (at most 3 spaces, not inside a > quote): `bash`, `shell`, `console`, `zsh`, no
# tag, ~~~ and a fence indented under a list item are errors, because no check would read them.
DATA_FENCES="text yaml json"

# Names a block may use without setting them: the shell and the login session provide them.
AMBIENT="HOME USER PWD OLDPWD PATH SHELL EDITOR TMPDIR HOSTNAME UID IFS LANG RANDOM LINENO SECONDS REPLY"
# Names `. /etc/os-release` sets; counted only in a block that sources that file.
OS_RELEASE_VARS="ID ID_LIKE NAME PRETTY_NAME VERSION VERSION_ID VERSION_CODENAME UBUNTU_CODENAME"

# Commands that can prompt on the terminal whatever their stdin is. A function the guides define
# whose body runs one of them is added automatically (today: kubectl_install, through sudo).
# `sudo -n` is exempt (it fails instead of asking); `env X=1 sudo` and `command sudo` are seen.
PROMPT_TTY="sudo|su|argocd login|argocd logout|podman login|docker login|vcf context create|vcf context refresh"
# Commands that read the pasted text through stdin, unless they stand on the RIGHT of a pipe,
# have a `<` of their own, or sit inside a compound command that ends with one (`done < file`).
# On the LEFT of a pipe they still read the paste: `ssh host cmd | tee log`.
PROMPT_STDIN="read|ssh|colima ssh"
# Plus: an installer fetched and run in one line (`bash -c "$(curl …)"`), matched on the raw line.

# Exclusions for shellcheck, each needed by blocks that are correct as written:
#   SC1090 SC1091  `source ~/.vks-….env` cannot be followed: the file exists only on the reader's machine
#   SC2034         a variable set for a later block or for the reader ("appears unused")
#   SC2155         `export X="$(…)"` in one line, kept short for pasting; the Expect text shows the value
#   SC2164         `cd golang-web` without `|| exit`: `exit` would close the reader's terminal
#   SC2016         `printf '… "$HOME/…"'` and 'robot$apps+…' hold a literal $ on purpose
SHELLCHECK_EXCLUDE="SC1090,SC1091,SC2034,SC2155,SC2164,SC2016"

# SECRET PATTERNS: `label|case|regex` (extended regular expressions; case `i` = matched without
# regard to case). Applied to each command line with single-quoted text blanked, continuation
# lines joined. A secret in argv is visible in `ps` and stays in shell history.
#   login-p        `-p VALUE` or `-pVALUE` of a login, sshpass or database client, wherever the
#                  flag stands (a bare `-p`, which asks, and --password-stdin are not matched)
#   password-flag  --password, --passwd, --token, --secret and any --<word>-… form of them, with
#                  a value (--password-stdin, --token-file and the like are not matched)
#   curl-user      curl -u / -su / --user with a value
#   auth-header    an Authorization header that carries a variable
#   url-userinfo   user:password@ inside a URL
#   echo-secret    echo of a variable whose name says it is a secret
#   from-literal   --from-literal whose KEY, or whose variable, is named like a secret
SECRET_PATTERNS='login-p|-|(^|[^A-Za-z-])(login|sshpass|mysql|mariadb|psql)[[:space:]](.*[[:space:]])?-p[[:space:]]*"?[$A-Za-z0-9]
password-flag|i|--([a-z0-9]+-)*(password|passwd|token|secret)(=|[[:space:]]+)"?[$a-z0-9]
curl-user|-|(^|[^A-Za-z])curl[[:space:]](.*[[:space:]])?(-[A-Za-z]*u|--user)[[:space:]=]*"?[^[:space:]"=-]
auth-header|i|(-h|--header)[[:space:]=]*"[^"]*authorization:[^"]*[$]
url-userinfo|i|[a-z][a-z0-9+.-]*://[^/[:space:]"@]*:[^/[:space:]"@]*@
echo-secret|-|(^|[^A-Za-z])echo[[:space:]].*[$][{]?[A-Za-z_]*(PASSWORD|PASSWD|TOKEN|SECRET)
from-literal|i|--from-literal[=[:space:]]"?([a-z0-9_.-]*(password|passwd|token|secret)[a-z0-9_.-]*=|.*[$][{]?[a-z_]*(password|passwd|token|secret|key|cred))'

TMP=$(mktemp -d) || { echo "ERROR: mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FINDINGS=$TMP/findings; : > "$FINDINGS"

# finding <check> <file> <line> <key> <message>
#   key: the exact text an allowlist entry must give, or @<path of the block> when any line of
#   the block will do (block-level findings).
finding() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FINDINGS"; }
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
line_of() { sed -n "${2}p" "$1" | trim; } # <file> <n>

[ -d "$DIR" ] || { echo "ERROR: no directory '$DIR' (run from the repository root)"; exit 1; }
[ -f "$WALK" ] || { echo "ERROR: the block extractor $WALK is missing"; exit 1; }

# ---------------------------------------------------------------------------------------------
# awk programs
# ---------------------------------------------------------------------------------------------

# Two views of a block, line for line. BASE.san: single-quoted text, quoted-heredoc bodies and
# comments blanked (what the shell expands). BASE.cmd: double-quoted text and every heredoc body
# blanked too, command substitutions kept (what the shell runs). BASE.st: per line, `open` while
# a quote, heredoc, parenthesis or continuation is unfinished. BASE.cmt: `line<TAB>kind` per comment.
SANITIZE='
function blank(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
function put(a, b) { san = san a; cmd = cmd b }
function push() { sp++; sdq[sp] = dq; spar[sp] = par; dq = 0; par = 0; arith[sp] = 0 }
function pop() { dq = sdq[sp]; par = spar[sp]; sp-- }
BEGIN { SAN = base ".san"; CMD = base ".cmd"; ST = base ".st"; CMT = base ".cmt"
        printf "" > SAN; printf "" > CMD; printf "" > ST; printf "" > CMT }
{
  line = $0; L = length(line); san = ""; cmd = ""; cont = 0
  if (hi < nh) {
    t = line; if (hdash[hi + 1]) sub(/^\t+/, "", t)
    if (t == hdel[hi + 1]) { hi++; if (hi == nh) { hi = 0; nh = 0 }; san = blank(L) }
    else if (hquo[hi + 1]) san = blank(L)
    else { san = line; gsub(/\\\$/, "  ", san) }
    print san > SAN; print blank(L) > CMD
    print ((hi < nh || sq || asq || dq || sp > 0 || par > 0) ? "open" : "ok") > ST
    next
  }
  i = 1; prev = ""
  while (i <= L) {
    c = substr(line, i, 1); n = substr(line, i + 1, 1)
    if (sq) { if (c == "\047") { sq = 0; put(c, c) } else put(" ", " "); prev = c; i++; continue }
    if (asq) {                                # inside $'"'"'…'"'"': a backslash escapes the next character
      if (c == "\\" && i < L) { put("  ", "  "); i += 2 }
      else { if (c == "\047") { asq = 0; put(c, c) } else put(" ", " "); i++ }
      prev = "x"; continue
    }
    if (c == "\\") {
      if (i == L) { cont = 1; put(" ", " "); i++ } else { put("  ", "  "); i += 2 }
      prev = "x"; continue
    }
    if (dq) {
      if (c == "\"") { dq = 0; put(c, c) }
      else if (c == "$" && n == "(") { push(); put("$(", "$("); i++ }
      else put(c, " ")
      prev = c; i++; continue
    }
    if (c == "$" && n == "\047") { asq = 1; put("$\047", "$\047"); prev = "x"; i += 2; continue }
    if (c == "\047") { sq = 1; put(c, c); prev = c; i++; continue }
    if (c == "\"") { dq = 1; put(c, c); prev = c; i++; continue }
    if (c == "$" && n == "(") {
      push(); put("$(", "$("); prev = "("; i += 2
      if (substr(line, i, 1) == "(") { arith[sp] = 1; abase[sp] = 1 }      # $(( … )): << is a shift
      continue
    }
    if (c == "(") {
      if (n == "(" && !arith[sp] && (prev == "" || index(" \t;&|", prev))) { arith[sp] = 1; abase[sp] = par + 1 }
      par++
    }
    else if (c == ")") {
      if (par > 0) { par--; if (arith[sp] && par < abase[sp]) arith[sp] = 0 }
      else if (sp > 0) pop()
    }
    else if (c == "#" && (prev == "" || index(" \t;&|()<>", prev))) {
      print NR "\t" (san ~ /^[ \t]*$/ ? "line" : "trailing") > CMT
      put(blank(L - i + 1), blank(L - i + 1)); break
    }
    else if (c == "<" && n == "<" && prev != "<" && substr(line, i + 2, 1) != "<" && !arith[sp]) {
      j = i + 2; dash = 0; quo = 0; del = ""
      if (substr(line, j, 1) == "-") { dash = 1; j++ }
      while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
      q = substr(line, j, 1)
      if (q == "\047" || q == "\"") {
        k = index(substr(line, j + 1), q)
        if (k > 0) { del = substr(line, j + 1, k - 1); j = j + k + 1; quo = 1 }
      } else {
        if (q == "\\") { quo = 1; j++ }
        rest = substr(line, j)
        if (match(rest, /^[A-Za-z0-9_.-]+/)) { del = substr(rest, 1, RLENGTH); j += RLENGTH }
      }
      if (del != "") {
        nh++; hdel[nh] = del; hquo[nh] = quo; hdash[nh] = dash
        seg = substr(line, i, j - i); put(seg, seg); prev = "x"; i = j; continue
      }
    }
    put(c, c); prev = c; i++
  }
  print san > SAN; print cmd > CMD
  print ((sq || asq || dq || sp > 0 || par > 0 || cont || nh > hi) ? "open" : "ok") > ST
}'

# Shared by the prompt and env checks: split a .cmd line into simple commands, each with its
# leading NAME=value words and its `env`/`command`/`exec`/`nohup` prefix removed. Fills C[1..nc];
# PIPED[k] is 1 when command k reads the output of a pipe (it stands on the RIGHT of a `|`).
CMDLIB='
function simple(line,   s, k, m, parts, piped, again) {
  s = line
  gsub(/\$\(/, " ; ", s); gsub(/\|\|/, " ; ", s); gsub(/\|&?/, " ;\001 ", s)
  gsub(/&&|[;(){}!&]/, " ; ", s)
  s = " " s " "
  for (k = 0; k < 2; k++) gsub(/[ \t](then|else|elif|do|if|while|until|time)[ \t]/, " ; ", s)
  m = split(s, parts, ";"); nc = 0; piped = 0
  for (k = 1; k <= m; k++) {
    s = parts[k]
    if (sub(/^\001/, "", s)) piped = 1
    sub(/^[ \t]+/, "", s)
    again = 1
    while (again) {
      again = 0
      while (match(s, /^[A-Za-z_][A-Za-z0-9_]*\+?=("[^"]*"|\047[^\047]*\047|[^ \t]*)[ \t]+/)) { s = substr(s, RLENGTH + 1); again = 1 }
      if (match(s, /^(env|command|exec|nohup|builtin)([ \t]+-[^ \t]+)*[ \t]+/)) { s = substr(s, RLENGTH + 1); again = 1 }
    }
    gsub(/[ \t]+/, " ", s); sub(/ $/, "", s)
    if (s != "") { C[++nc] = s; PIPED[nc] = piped; piped = 0 }
  }
}
function starts(s, w) { return s == w || index(s, w " ") == 1 }'

# Reads every guide block, in order, and prints what each file written with
# `cat > ~/FILE <<EOF` provides:  FILE<TAB>var|func|inc|prompt<TAB>NAME
# The heredoc may also be APPENDED (`cat >> ~/FILE <<EOF`, a chapter adding its helper commands to
# a file an earlier guide wrote), and one line may append one `export NAME=` or one include
# (`printf … >> ~/FILE`). The target must be written as ~/FILE: a path held in a variable is not
# read, and the names it adds then count as provided by nothing.
CONTRACT="$CMDLIB"'
function isname(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }
function out(kind, name) { if (!seen[tgt, kind, name]++) print tgt "\t" kind "\t" name }
FNR == 1 { inhd = 0; fn = "" }
!inhd {
  if (match($0, /cat >[>|]? *~\/[^ ]+ <<-?[\047"]?[A-Za-z0-9_]+/)) {
    s = substr($0, RSTART, RLENGTH)
    del = s; sub(/.*<<-?[\047"]?/, "", del)
    tgt = s; sub(/^cat >[>|]? *~\//, "", tgt); sub(/ .*/, "", tgt)
    inhd = 1; fn = ""; delete loc
  } else if (match($0, />> *~\/[^ ;|&]+/)) {
    tgt = substr($0, RSTART, RLENGTH); sub(/^>> *~\//, "", tgt)
    s = $0
    while (match(s, /export [A-Za-z_][A-Za-z0-9_]*=/)) { out("var", substr(s, RSTART + 7, RLENGTH - 8)); s = substr(s, RSTART + RLENGTH) }
    if (match($0, /(\.|source) "\$HOME\/[^"]+"/)) { s = substr($0, RSTART, RLENGTH); sub(/.*HOME\//, "", s); sub(/"$/, "", s); out("inc", s) }
  }
  next
}
$0 == del { inhd = 0; next }
/^[ \t]*#/ { next }
/^export [A-Za-z_][A-Za-z0-9_]*=/ { s = $0; sub(/^export /, "", s); sub(/=.*/, "", s); out("var", s); next }
/^(\.|source) +("\$HOME|~)\// { s = $0; sub(/^(\.|source) +("\$HOME|~)\//, "", s); sub(/"? *$/, "", s); out("inc", s); next }
/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $0; sub(/\(.*/, "", fn); out("func", fn); for (k in loc) delete loc[k]; next }
/^\}/ { fn = ""; next }
fn != "" {
  s = $0
  if (match(s, /(^|[ \t;])local /)) {
    m = split(substr(s, RSTART + RLENGTH), w, /[ \t;]+/)
    for (k = 1; k <= m; k++) { x = w[k]; sub(/=.*/, "", x); if (isname(x)) loc[x] = 1 }
  }
  s = " " $0
  while (match(s, /[ \t;({][A-Za-z_][A-Za-z0-9_]*=/)) {
    x = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
    if (!(x in loc)) out("var", x)
  }
  t = $0; gsub(/"[^"]*"/, "\"\"", t); gsub(/\047[^\047]*\047/, "\047\047", t)
  simple(t)
  for (k = 1; k <= nc; k++) if (starts(C[k], "sudo")) out("prompt", fn)
}'

# Prompt check for one block. Input: BASE.cmd; -v chk=FILE holds one top-level-command number
# per line (empty: only report whether the block has a command that can prompt at all).
# Output: `line<TAB>command<TAB>next line` when something follows the prompting command.
PROMPT="$CMDLIB"'
BEGIN {
  nt = split(tty, T, "|"); ns = split(stdin, S, "|")
  nf = split(funcs, F, " "); for (k = 1; k <= nf; k++) T[++nt] = F[k]
  while ((getline r < raw) > 0) RAW[++nr] = r
  if (chk != "") while ((getline r < chk) > 0) CH[++nch] = r
}
{
  id = (chk == "") ? 1 : CH[NR]
  if ($0 !~ /^[ \t]*$/) { last[id] = NR; if (!(id in firstl)) firstl[id] = NR }
  # A redirect on the end of a compound command feeds every command inside it: `done < file`.
  if ($0 ~ /(done|\}|\)|fi|esac)[ \t]*<|^[ \t]*<|\|[ \t]*(while|until|if|\{|\()/) redir[id] = 1
  simple($0)
  for (k = 1; k <= nc; k++) {
    if (C[k] ~ /^sudo (-[A-Za-z]*n[A-Za-z]*|--non-interactive)( |$)/) continue      # sudo -n never prompts
    for (j = 1; j <= nt; j++) if (starts(C[k], T[j]) && !(C[k] ~ /--password-stdin/) && !(id in pt)) { pt[id] = NR; pw[id] = T[j] }
    # A stdin reader is fed when it stands on the right of a pipe or has its own `<`.
    for (j = 1; j <= ns; j++) if (starts(C[k], S[j]) && !PIPED[k] && C[k] !~ /</ && !(id in ps)) { ps[id] = NR; psw[id] = S[j] }
  }
  if (RAW[NR] ~ /(^|[ \t\/])bash -c "\$\(curl / && !(id in pt)) { pt[id] = NR; pw[id] = "an installer run with bash -c \"$(curl …)\"" }
  if (id > maxid) maxid = id
}
END {
  for (id = 1; id <= maxid; id++) {
    if (!(id in pt) && (id in ps) && !(id in redir)) { pt[id] = ps[id]; pw[id] = psw[id] }
    if (id in pt) {
      if (chk == "") exit 0
      for (j = id + 1; j <= maxid; j++) if (j in firstl) { print pt[id] "\t" pw[id] "\t" firstl[j]; exit 0 }
      exit 0
    }
  }
  if (chk == "") exit 1
}'

# Env check for one block. Input: BASE.san; -v cmdf=BASE.cmd, prov=the contract file,
# carried/ambient/osrel = space-separated names. Output: `line<TAB>kind<TAB>name<TAB>file`
#   kind nosource: NAME comes from env file FILE and the block does not start by sourcing it
#        wrongsource: the block starts by sourcing another file, which does not provide NAME
#        undefined: nothing sets NAME
ENVCHECK="$CMDLIB"'
function isname(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }
function closure(f,   k, x, more) {       # names FILE provides, with the files it includes
  delete IN; IN[f] = 1; more = 1
  while (more) { more = 0; for (k = 1; k <= ni; k++) if ((incf[k] in IN) && !(inct[k] in IN)) { IN[inct[k]] = 1; more = 1 } }
}
function provided_by_sourced(name,   f) { for (f in SRC) { closure(f); for (x in IN) if ((x, name) in P) return 1 } return 0 }
function envfile_for(name,   f, best) {   # the .env file to source for NAME (the one providing least)
  best = ""
  for (f in FILES) if (f ~ /\.env$/) { closure(f); for (x in IN) if ((x, name) in P) { if (best == "" || size[f] < size[best]) best = f } }
  if (best == "") for (f in FILES) if ((f, name) in P) best = f
  return best
}
function report(kind, name,   f) {
  if ((kind, name) in done) return
  done[kind, name] = 1; print NR "\t" kind "\t" name "\t" envfile_for(name)
}
function need(name, isfunc) {
  if (name in DEF) return
  if (provided_by_sourced(name)) { if (!firstsrc) report("nosource", name); return }
  if (name in ANY) { report(firstsrc ? "wrongsource" : "nosource", name); return }
  if (!isfunc) report("undefined", name)
}
BEGIN {
  while ((getline r < prov) > 0) {
    split(r, a, "\t"); FILES[a[1]] = 1
    if (a[2] == "inc") { ni++; incf[ni] = a[1]; inct[ni] = a[3]; FILES[a[3]] = 1 }
    else if (a[2] == "var" || a[2] == "func") { P[a[1], a[3]] = 1; ANY[a[3]] = 1; if (a[2] == "func") FUNC[a[3]] = 1 }
  }
  for (f in FILES) { closure(f); c = 0; for (x in IN) for (k in P) { split(k, kk, SUBSEP); if (kk[1] == x) c++ }; size[f] = c }
  m = split(carried " " ambient, a, " "); for (k = 1; k <= m; k++) DEF[a[k]] = 1
  while ((getline r < cmdf) > 0) CL[++ncl] = r
}
{
  cl = CL[NR]
  if (cl !~ /^[ \t]*$/) nonblank++
  # what this line sources
  simple(cl)
  for (k = 1; k <= nc; k++) {
    if (match(C[k], /^(source|\.) ~\/[^ ]+/)) {
      f = substr(C[k], RSTART, RLENGTH); sub(/^(source|\.) ~\//, "", f); SRC[f] = 1
      if (nonblank == 1) firstsrc = 1
    }
    if (C[k] ~ /^(source|\.) \/etc\/os-release/) { m = split(osrel, a, " "); for (j = 1; j <= m; j++) DEF[a[j]] = 1 }
  }
  # what this line sets
  s = " " cl
  while (match(s, /[ \t;(&|][A-Za-z_][A-Za-z0-9_]*\+?=/)) {
    x = substr(s, RSTART + 1, RLENGTH - 2); sub(/\+$/, "", x); DEF[x] = 1; s = substr(s, RSTART + RLENGTH)
  }
  s = cl
  while (match(s, /(^|[ \t;|&()"])read[ \t]/)) {      # also `IFS="$(…)" read -r a b`
    s = substr(s, RSTART + RLENGTH); x = s; sub(/[;|&<)].*/, "", x)
    m = split(x, w, " "); for (j = 1; j <= m; j++) if (isname(w[j])) DEF[w[j]] = 1
  }
  for (k = 1; k <= nc; k++) {
    m = split(C[k], w, " ")
    if (w[1] == "for" && isname(w[2])) DEF[w[2]] = 1
    if (w[1] == "local" || w[1] == "export" || w[1] == "declare" || w[1] == "getopts")
      for (j = 2; j <= m; j++) { x = w[j]; sub(/=.*/, "", x); if (isname(x)) DEF[x] = 1 }
    if (w[1] in FUNC) need(w[1], 1)
  }
  # what this line uses
  s = $0
  while (match(s, /\$\{?[#!]?[A-Za-z_][A-Za-z0-9_]*/)) {
    x = substr(s, RSTART, RLENGTH); braced = (x ~ /^\$\{/); sub(/^\$\{?[#!]?/, "", x)
    after = substr(s, RSTART + RLENGTH, 2); s = substr(s, RSTART + RLENGTH)
    if (braced && after ~ /^(:[-+=]|[-+=])/) { if (after ~ /=/) DEF[x] = 1; continue }
    need(x, 0)
  }
}'

# Links, headings and <details> of one markdown file. Output:
#   H<TAB>slug          an anchor GitHub makes for a heading (or an explicit <a id="…">)
#   L<TAB>line<TAB>target<TAB>link|image
#   D<TAB>line<TAB>message
#   F<TAB>line<TAB>why the fence that opens there is not one the gate reads
# shellcheck disable=SC1112  # the typographic quotes are data: punctuation GitHub drops from an anchor
MDSCAN='
function slug(t,   i, c, o, k, m, p) {
  sub(/[ \t]+#+[ \t]*$/, "", t)
  while (match(t, /\[[^]]*\]\([^)]*\)/)) { p = substr(t, RSTART, RLENGTH); sub(/\]\(.*/, "", p); t = substr(t, 1, RSTART - 1) substr(p, 2) substr(t, RSTART + RLENGTH) }
  gsub(/<[^>]*>/, "", t)
  # Punctuation outside ASCII that GitHub drops; letters outside ASCII are kept.
  m = split("— – … ‘ ’ “ ” → ← · × « »", p_, " "); for (k = 1; k <= m; k++) gsub(p_[k], "", t)
  t = tolower(t); o = ""
  for (i = 1; i <= length(t); i++) { c = substr(t, i, 1); if (c ~ /[a-z0-9_-]/ || c > "\177") o = o c; else if (c == " ") o = o "-" }
  if (o in nslug) { k = nslug[o]++; return o "-" k }
  nslug[o] = 1; return o
}
BEGIN { m = split(data, p_, " "); for (k = 1; k <= m; k++) DATA[p_[k]] = 1 }
{
  if (infence) {
    if (match($0, /^[ \t>]*(```+|~~~+)[ \t]*$/)) { t = $0; gsub(/[ \t>]/, "", t); if (substr(t, 1, 1) == fch && length(t) >= flen) infence = 0 }
    next
  }
  # Every opening fence is classified: a block the extractor would not read must not pass unseen.
  if (match($0, /^[ \t>]*(```+|~~~+)/)) {
    pre = substr($0, 1, RLENGTH); info = substr($0, RLENGTH + 1)
    fence = pre; sub(/^[ \t>]*/, "", fence); pre = substr(pre, 1, length(pre) - length(fence))
    gsub(/^[ \t]+|[ \t]+$/, "", info); tag = info; sub(/[ \t].*/, "", tag)
    fch = substr(fence, 1, 1); flen = length(fence); quoted = index(pre, ">"); gsub(/\t/, "    ", pre)
    why = ""
    if (fch == "~") why = "it is fenced with ~~~"
    else if (length(fence) != 3) why = "it has " length(fence) " backticks"
    else if (tag == "") why = "it has no tag"
    else if (tag == "sh") { if (quoted) why = "it is inside a > quote"; else if (length(pre) > 3) why = "it is indented " length(pre) " spaces" }
    else if (!(tag in DATA)) why = "its tag is \"" tag "\""
    if (why != "") print "F\t" NR "\t" why
    infence = 1; next
  }
  if ($0 ~ /^##?#?#?#?#? /) { t = $0; sub(/^#+ +/, "", t); print "H\t" slug(t) }
  s = $0; gsub(/`[^`]*`/, "", s)
  t = s
  while (match(t, /<a [^>]*(id|name)="[^"]*"/)) { p = substr(t, RSTART, RLENGTH); sub(/.*="/, "", p); sub(/"$/, "", p); print "H\t" p; t = substr(t, RSTART + RLENGTH) }
  t = s
  while (match(t, /<\/?details/)) {
    if (substr(t, RSTART, 2) == "</") { depth--; if (depth < 0) { print "D\t" NR "\t</details> without a <details> before it"; depth = 0 } }
    else { depth++; opened = NR }
    t = substr(t, RSTART + RLENGTH)
  }
  t = s
  while (match(t, /\]\([^)]*\)/)) {
    rs = RSTART; rl = RLENGTH
    p = substr(t, rs + 2, rl - 3); img = (substr(t, 1, rs) ~ /!\[[^]]*\]$/) ? "image" : "link"
    t = substr(t, rs + rl)
    sub(/^[ \t]*<?/, "", p); sub(/[ \t].*$/, "", p); sub(/>$/, "", p)
    if (p != "") print "L\t" NR "\t" p "\t" img
  }
}
END {
  if (infence) print "D\t" NR "\ta fenced block is not closed"
  if (depth > 0) print "D\t" opened "\t<details> without a </details> after it (" depth " left open)"
}'

# ---------------------------------------------------------------------------------------------
# the files
# ---------------------------------------------------------------------------------------------
is_internal() { local x; for x in $INTERNAL; do [ "$1" = "$DIR/$x" ] && return 0; done; return 1; }

FILES=$TMP/files; : > "$FILES"
find "$DIR" -type f \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mdown' -o -iname '*.mkd' \) | sort > "$TMP/all"
while IFS= read -r f; do
  is_internal "$f" && continue
  case "$f" in
    *.md) echo "$f" >> "$FILES" ;;
    *)    finding file "$f" 0 "${f#"$DIR"/}" "a markdown file the gate does not read: name it *.md (lower case), as every guide is" ;;
  esac
done < "$TMP/all"
nfiles=$(grep -c . "$FILES" || true)

have_zsh=0; command -v zsh >/dev/null 2>&1 && have_zsh=1
have_sc=0; command -v "$SHELLCHECK" >/dev/null 2>&1 && have_sc=1
# CI installs shellcheck (mise): there, its absence means the check silently stopped running.
if [ "$have_sc" -eq 0 ] && [ -n "${CI:-}" ]; then
  finding tool "$DIR" 0 "shellcheck" "shellcheck is not installed and CI is set: the shellcheck check would be skipped (install it: make deps)"
fi

# The allowlist is read first: a block whose syntax finding is allowed still gets every other check.
: > "$TMP/entries"
if [ -f "$ALLOW" ]; then
  ln=0
  # shellcheck disable=SC2094  # `finding` appends to $FINDINGS, never to $ALLOW
  while IFS= read -r l || [ -n "$l" ]; do
    ln=$((ln + 1))
    case "$l" in ''|'#'*) continue ;; esac
    c=${l%% | *}; r1=${l#* | }; file=${r1%% | *}; r2=${r1#* | }; reason=${r2%% | *}; key=${r2#* | }
    if [ "$r1" = "$l" ] || [ "$r2" = "$r1" ] || [ "$key" = "$r2" ] || [ -z "$reason" ] || [ -z "$key" ]; then
      finding allowlist "$ALLOW" "$ln" "-" "not 'check | file | reason | exact line': $l"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$ln" "$c" "$file" "$reason" "$key" >> "$TMP/entries"
  done < "$ALLOW"
fi
has_line() { K="$1" awk 'BEGIN { k = ENVIRON["K"] } { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == k) f = 1 } END { exit !f }' "$2"; }
syntax_allowed() { # <guide> <block>: is there an allowlist entry for this block's syntax finding?
  local ln ec ef reason ekey
  while IFS=$'\t' read -r ln ec ef reason ekey; do
    [ "$ec" = syntax ] && [ "$DIR/$ef" = "$1" ] && has_line "$ekey" "$2" && return 0
  done < "$TMP/entries"
  return 1
}

# Pass 1: extract every file's blocks, build the two views, read the env contract.
nblocks=0; idx=0; : > "$TMP/blocklist"; : > "$TMP/percount"
while IFS= read -r f; do
  idx=$((idx + 1)); d=$TMP/b$idx
  if ! bash "$WALK" extract "$f" "$d" 2> "$TMP/err"; then
    finding syntax "$f" 0 "@/dev/null" "the blocks cannot be extracted: $(tr '\n' ' ' < "$TMP/err")"
    continue
  fi
  n=$(grep -c . "$d/manifest.tsv" || true)
  nblocks=$((nblocks + n)); echo "${f#"$DIR"/} $n" >> "$TMP/percount"
  printf '%s\t%s\n' "$f" "$d" >> "$TMP/blocklist"
  for b in "$d"/[0-9][0-9][0-9].sh; do
    [ -f "$b" ] || continue
    awk -v base="${b%.sh}" "$SANITIZE" "$b"
    echo "$b" >> "$TMP/allblocks"
  done
done < "$FILES"
PROV=$TMP/provides; : > "$PROV"
if [ -s "$TMP/allblocks" ]; then
  # shellcheck disable=SC2046  # our own temp paths, one per line, no spaces
  awk "$CONTRACT" $(cat "$TMP/allblocks") > "$PROV"
fi
PROMPT_FUNCS=$(awk -F'\t' '$2 == "prompt" { print $3 }' "$PROV" | sort -u | tr '\n' ' ')

# ---------------------------------------------------------------------------------------------
# the checks, per file and per block
# ---------------------------------------------------------------------------------------------
check_block() { # <guide> <block.sh> <first line in the guide> <expect text>
  local f=$1 b=$2 at=$3 expect=$4 base=${2%.sh} key="@$2" out l kind what nxt name file acc st id c pat label rest

  # syntax
  if ! out=$(bash -n "$b" 2>&1); then
    finding syntax "$f" "$at" "$key" "the block does not parse in bash: $(head -1 <<<"$out" | sed 's/^[^:]*: //')"
    # One defect, one finding: the other checks would only repeat the parse error. But when
    # the parse error is ALLOWED, the block is not skipped: its other checks run as usual.
    if ! syntax_allowed "$f" "$b"; then
      [ "$expect" != - ] || finding expect "$f" "$at" "$key" "no **Expect:** between this block and the next block or heading"
      : > "$base.bad"
      return 0
    fi
  fi
  if [ "$have_zsh" -eq 1 ] && ! out=$(zsh -n "$b" 2>&1); then
    finding syntax "$f" "$at" "$key" "the block does not parse in zsh: $(head -1 <<<"$out" | sed 's/^[^:]*:[0-9]*: //')"
  fi

  # comment
  while IFS=$'\t' read -r l kind; do
    [ -n "$l" ] || continue
    if [ "$kind" = trailing ]; then what="a comment on a command line"; else what="a comment line"; fi
    finding comment "$f" $((at + l - 1)) "$(line_of "$b" "$l")" "$what in a block (interactive zsh on macOS runs it as text): remove it or say it in the prose"
  done < "$base.cmt"

  # prompt: only blocks that hold a prompting command are split into top-level commands
  if awk -v tty="$PROMPT_TTY" -v stdin="$PROMPT_STDIN" -v funcs="$PROMPT_FUNCS" -v raw="$b" -v chk="" "$PROMPT" "$base.cmd"; then
    acc=""; id=1; : > "$base.chk"
    while IFS= read -r l <&3 && IFS= read -r st <&4; do
      echo "$id" >> "$base.chk"
      acc="$acc$l
"
      if [ "$st" = ok ] && bash -n <<<"$acc" 2>/dev/null; then
        case "$acc" in *[![:space:]]*) id=$((id + 1)) ;; esac
        acc=""
      fi
    done 3< "$b" 4< "$base.st"
    out=$(awk -v tty="$PROMPT_TTY" -v stdin="$PROMPT_STDIN" -v funcs="$PROMPT_FUNCS" -v raw="$b" -v chk="$base.chk" "$PROMPT" "$base.cmd")
    if [ -n "$out" ]; then
      IFS=$'\t' read -r l what nxt <<<"$out"
      finding prompt "$f" $((at + l - 1)) "$(line_of "$b" "$l")" "nothing may follow a line that can prompt: '$what' can prompt, and line $((at + nxt - 1)) follows it (a shell without bracketed paste feeds the rest of the paste to the prompt)"
    fi
  fi

  # env
  while IFS=$'\t' read -r l kind name file; do
    [ -n "$l" ] || continue
    case "$kind" in
      nosource)    what="uses $name, which ~/$file provides, but does not start with 'source ~/$file'" ;;
      wrongsource) what="uses $name, which ~/$file provides, but starts by sourcing another file" ;;
      *)           what="uses \$$name, which nothing sets: not this block, not the env contract, not an earlier \"this terminal\" block" ;;
    esac
    finding env "$f" $((at + l - 1)) "$(line_of "$b" "$l")" "$what"
  done < <(awk -v cmdf="$base.cmd" -v prov="$PROV" -v carried="$CARRIED" -v ambient="$AMBIENT" -v osrel="$OS_RELEASE_VARS" "$ENVCHECK" "$base.san")

  # expect
  [ "$expect" != - ] || finding expect "$f" "$at" "$key" "no **Expect:** between this block and the next block or heading"

  # secret: logical lines (continuations joined), single-quoted text already blanked
  while IFS=$'\t' read -r l rest; do
    while IFS='|' read -r label c pat; do
      if [ "$c" = i ]; then c=-Eqi; else c=-Eq; fi
      if grep "$c" -e "$pat" <<<"$rest"; then
        finding secret "$f" $((at + l - 1)) "$(line_of "$b" "$l")" "a secret on a command line ($label): it shows in 'ps' and in shell history; pass it on stdin, in a file or in the environment"
      fi
    done <<<"$SECRET_PATTERNS"
  done < <(awk '{ if (!start) start = NR; buf = buf $0; if ((getline s < st) > 0 && s == "open" && buf ~ / $/) next; print start "\t" buf; buf = ""; start = 0 }
               END { if (buf != "") print start "\t" buf }' st="$base.st" "$base.san")
}

check_file() { # <guide> <dir with its blocks>
  local f=$1 d=$2 n kind term at heading expect b l msg rest target what path anchor tfile step limit carry="" x
  while IFS=$'\t' read -r n _ term at heading _ expect; do
    b=$d/$n.sh
    # The numbered step the block is in ("## 7. …" -> 7); empty outside the numbered steps.
    step=${heading%%[!0-9]*}
    case "$heading" in "$step".*) ;; *) step="" ;; esac
    # What earlier "this terminal" blocks assigned is still set, up to the end of their scope.
    CARRIED=""
    for x in $carry; do
      [ -n "$step" ] && [ "$step" -le "${x%%:*}" ] && CARRIED="$CARRIED ${x#*:}"
    done
    check_block "$f" "$b" "$at" "$expect"
    # A "this terminal" block (T, or T<N> when the guide says "until the end of step N"):
    # later blocks may use what it assigns, to the end of its own step, or of step N.
    case "$term" in
      T*) limit=${term#T}; [ -n "$limit" ] || limit=$step
          if [ -n "$limit" ]; then
            # shellcheck disable=SC2013  # one variable name per line, no spaces
            for x in $(sed -n 's/^\(export  *\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$b"); do carry="$carry $limit:$x"; done
          fi ;;
    esac
  done < "$d/manifest.tsv"

  # all blocks of the file through shellcheck, in one run
  set --
  for b in "$d"/[0-9][0-9][0-9].sh; do [ -f "$b" ] && [ ! -e "${b%.sh}.bad" ] && set -- "$@" "$b"; done
  if [ "$have_sc" -eq 1 ] && [ $# -gt 0 ]; then
    while IFS= read -r l; do
      # <dir>/NNN.sh:LINE:COL: level: message [SCnnnn]
      b=${l%%:*}; rest=${l#*:}; n=${rest%%:*}; msg=${rest#*:*: }
      at=$(awk -F'\t' -v n="$(basename "$b" .sh)" '$1 == n { print $4 }' "$d/manifest.tsv")
      finding shellcheck "$f" $((at + n - 1)) "$(line_of "$b" "$n")" "shellcheck: $msg"
    done < <("$SHELLCHECK" -s bash -f gcc -e "$SHELLCHECK_EXCLUDE" "$@" 2>/dev/null | grep -E '^[^:]+:[0-9]+:[0-9]+: ' || true)
  fi

  # fence, link, details
  while IFS=$'\t' read -r kind l target what; do
    case "$kind" in
      D) finding details "$f" "$l" "$target" "$target" ;;
      F) finding fence "$f" "$l" "$(line_of "$f" "$l")" "no check reads this fenced block, because $target: a shell block opens with exactly \`\`\`sh at the left margin; a data block is tagged ${DATA_FENCES// /, }" ;;
      L) case "$target" in [A-Za-z][A-Za-z0-9+.-]*:*|//*) continue ;; esac
         path=${target%%#*}; anchor=""
         case "$target" in *'#'*) anchor=${target#*#} ;; esac
         path=${path//%20/ }
         if [ -z "$path" ]; then tfile=$f; else tfile=$(dirname "$f")/$path; fi
         if [ ! -e "$tfile" ]; then
           if [ "$what" = image ]; then msg="the image file does not exist: $path"; else msg="the link target does not exist: $path"; fi
           finding link "$f" "$l" "$target" "$msg"
         elif [ -n "$anchor" ] && [ -f "$tfile" ]; then
           case "$tfile" in
             *.md) awk -v data="$DATA_FENCES" "$MDSCAN" "$tfile" | awk -F'\t' -v a="$anchor" '$1 == "H" && $2 == a { ok = 1 } END { exit !ok }' \
                     || finding link "$f" "$l" "$target" "no heading in ${tfile#"$DIR"/} makes the anchor #$anchor" ;;
           esac
         fi ;;
    esac
  done < <(awk -v data="$DATA_FENCES" "$MDSCAN" "$f")
}

while IFS=$'\t' read -r f d; do check_file "$f" "$d"; done < "$TMP/blocklist"
# Files with no extractable blocks still get their links and <details> checked.
while IFS= read -r f; do
  grep -q "^$(printf '%s' "$f" | sed 's/[][\.*^$]/\\&/g')$(printf '\t')" "$TMP/blocklist" && continue
  : > "$TMP/empty.tsv"; mkdir -p "$TMP/empty"; cp "$TMP/empty.tsv" "$TMP/empty/manifest.tsv"
  check_file "$f" "$TMP/empty"
done < "$FILES"

# ---------------------------------------------------------------------------------------------
# EXTENSION POINT — checks that belong to later phases of vks/PLAN.md go here, each as a function
# that calls `finding <check> <file> <line> <key> <message>`:
#   step-ref    no step-number reference crosses files (phase 2)
#   template    vks/templates/* render from the example env with no empty substitution (phase 5)
#   chart       `helm template` of vks/argocd/guest-cluster equals the rendered template, and the
#               commit pinned in the guides is the chart's (phase 5)
# ---------------------------------------------------------------------------------------------

# count: each guide against the table, so that adding a guide is one line there
[ "$nfiles" -gt 0 ] || finding count "$DIR" 0 "files" "read 0 file(s): no guide (*.md) under $DIR"
[ "$nblocks" -gt 0 ] || finding count "$DIR" 0 "blocks" "checked 0 block(s): no guide under $DIR has a fenced \`sh\` block"
if [ ! -f "$BLOCKS" ]; then
  finding count "$BLOCKS" 0 "table" "the table of guides is missing: it lists each guide under $DIR with its number of sh blocks"
else
  while read -r g n; do
    want=$(awk -v g="$g" '$1 == g { print $2; exit }' "$BLOCKS")
    if [ -z "$want" ]; then
      finding count "$DIR/$g" 0 "$g" "this guide is not in $BLOCKS: add the line '$g $n' (the file and its number of sh blocks; 0 for a guide that has none)"
    elif [ "$want" != "$n" ]; then
      finding count "$DIR/$g" 0 "$g" "it has $n sh block(s) and $BLOCKS records $want: a block was added, removed, or is no longer fenced as sh. If that is intended, change the line to '$g $n'"
    fi
  done < "$TMP/percount"
  # shellcheck disable=SC2094  # `finding` appends to $FINDINGS, never to $BLOCKS
  while read -r g n; do
    case "$g" in ''|'#'*) continue ;; esac
    case "$n" in ''|*[!0-9]*) finding count "$BLOCKS" 0 "$g" "not '<file> <number of sh blocks>': $g $n"; continue ;; esac
    grep -q "^$(printf '%s' "$g" | sed 's/[][\.*^$]/\\&/g') " "$TMP/percount" \
      || finding count "$BLOCKS" 0 "$g" "it lists '$g', which is not a guide under $DIR any more: remove the line, or restore the guide"
  done < "$BLOCKS"
fi

# ---------------------------------------------------------------------------------------------
# allowlist, report
# ---------------------------------------------------------------------------------------------
errors=0; allowed=0; : > "$TMP/used"
while IFS=$'\t' read -r c f l key msg; do
  hit=""
  while IFS=$'\t' read -r ln ec ef reason ekey; do
    case "$c" in count|file|tool|allowlist) break ;; esac     # these cannot be allowed
    [ "$ec" = "$c" ] && [ "$DIR/$ef" = "$f" ] || continue
    case "$key" in
      @*) has_line "$ekey" "${key#@}" || continue; unit=$key ;;
      *)  [ "$ekey" = "$key" ] || continue; unit="$f:$l" ;;
    esac
    hit=$reason; printf '%s\t%s\n' "$ln" "$unit" >> "$TMP/used"; break
  done < "$TMP/entries"
  where=$f; [ "$l" = 0 ] || where="$f:$l"
  if [ -n "$hit" ]; then
    allowed=$((allowed + 1)); echo "ALLOWED [$c] $where: $msg — allowed: $hit"
  else
    errors=$((errors + 1)); echo "ERROR [$c] $where: $msg"
  fi
done < "$FINDINGS"

while IFS=$'\t' read -r ln ec ef reason ekey; do
  uses=$(awk -F'\t' -v n="$ln" '$1 == n' "$TMP/used" | cut -f2 | sort -u | grep -c . || true)
  if [ "$uses" -eq 0 ]; then
    errors=$((errors + 1)); echo "ERROR [allowlist] $ALLOW:$ln: this entry allows nothing any more (remove it): $ec | $ef | $ekey"
  elif [ "$uses" -gt 1 ] && awk -F'\t' -v n="$ln" '$1 == n && $2 ~ /^@/' "$TMP/used" | grep -q .; then
    errors=$((errors + 1)); echo "ERROR [allowlist] $ALLOW:$ln: this entry's line is in $uses blocks of $ef; give a line only one block has: $ekey"
  elif [ "$uses" -gt 1 ]; then
    # One entry accepts ONE known finding: the same line appearing a second time is a new finding.
    errors=$((errors + 1)); echo "ERROR [allowlist] $ALLOW:$ln: this entry allows $uses findings in $ef ($(awk -F'\t' -v n="$ln" '$1 == n { sub(/.*:/, "line ", $2); print $2 }' "$TMP/used" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')); an entry may allow exactly one: $ec | $ekey"
  fi
done < "$TMP/entries"

if [ "$have_zsh" -eq 1 ]; then zsh_note="zsh -n used ($(zsh --version 2>/dev/null | cut -d' ' -f1-2))"; else zsh_note="zsh not installed: zsh -n SKIPPED"; fi
if [ "$have_sc" -eq 1 ]; then sc_note="shellcheck used ($("$SHELLCHECK" --version 2>/dev/null | sed -n 's/^version: //p'))"; else sc_note="shellcheck not installed: SKIPPED"; fi
echo "check-vks-docs: per file: $(tr '\n' ';' < "$TMP/percount" | sed 's/;$//; s/;/; /g')"
echo "check-vks-docs: bash -n used ($(bash -c 'echo "$BASH_VERSION"')); $zsh_note; $sc_note"
echo "check-vks-docs: checked $nblocks block(s) in $nfiles file(s); $errors error(s), $allowed allowed finding(s)"
[ "$errors" -eq 0 ]
