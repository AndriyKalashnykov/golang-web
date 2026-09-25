#!/usr/bin/env bash
# Tests for check-env.sh (run by `make scripts-test`). Each case builds a small repository
# (Makefile, main.go, .env.example, .gitignore), optionally changes it, runs the check, and
# compares the result with the expected pass or the expected error text.
set -u
SCRIPT=$(cd "$(dirname "$0")" && pwd)/check-env.sh
fails=0

# A consistent fixture: 3 Makefile settings, 2 app settings, APP_ENV_VARS covering the app.
fixture() {
  D=$(mktemp -d)
  cat > "$D/Makefile" <<'EOF'
-include .env
OWNER ?= me
APP_PORT ?= 8080
APP_ENV_VARS := APP_CONTEXT MESSAGE_TO
export $(APP_ENV_VARS)
export REGISTRY_TOKEN
PROJECT := app
EOF
  cat > "$D/main.go" <<'EOF'
package main
func main() { _ = getenv("APP_CONTEXT", "/"); _ = getenv("MESSAGE_TO", "World"); _ = getenv("PORT", "8080") }
EOF
  printf 'package main\nfunc TestX() { _ = getenv("TEST_ONLY", "") }\n' > "$D/main_test.go"
  cat > "$D/.env.example" <<'EOF'
# Settings.
# OWNER ?= me
# APP_PORT ?= 8080
# REGISTRY_TOKEN ?=
# APP_CONTEXT ?= /
# MESSAGE_TO ?= World
# PORT ?= 8080
EOF
  printf '.env\n' > "$D/.gitignore"
}

# run <label> <expect: pass | warn:<text> | text of the expected error>, after the case edited $D
run() {
  local label=$1 want=$2 out rc
  out=$(cd "$D" && bash "$SCRIPT" 2>&1); rc=$?
  if [ "$want" = pass ]; then
    if [ "$rc" -eq 0 ] && ! grep -q WARNING <<<"$out"; then echo "PASS  $label"; else echo "FAIL  $label: rc=$rc: $out"; fails=$((fails + 1)); fi
  elif [ "${want#warn:}" != "$want" ]; then
    if [ "$rc" -eq 0 ] && grep -qF -- "${want#warn:}" <<<"$out"; then echo "PASS  $label (warns: ${want#warn:})"
    else echo "FAIL  $label: rc=$rc, want a pass with a warning '${want#warn:}': $out"; fails=$((fails + 1)); fi
  elif [ "$rc" -ne 0 ] && grep -qF -- "$want" <<<"$out"; then echo "PASS  $label (fails: $want)"
  else echo "FAIL  $label: rc=$rc, want an error containing '$want': $out"; fails=$((fails + 1)); fi
  rm -rf "$D"
}
add_mk() { printf '%s\n' "$1" >> "$D/Makefile"; }
add_go() { printf 'package main\nfunc f() { _ = %s }\n' "$1" > "$D/$2"; }

fixture;                                                 run "consistent repository"            pass
fixture; (cd "$D" && git init -q && git add -A);         run "consistent repository, git"       pass
fixture; rm "$D/.env.example";                           run "no .env.example"                  ".env.example is missing"
fixture; : > "$D/.gitignore";                            run ".env not in .gitignore"           ".env is not listed in .gitignore"
fixture; : > "$D/.gitignore"; (cd "$D" && git init -q);  run ".env not ignored, git"            ".env is not gitignored"
fixture; sed -i.bak '/OWNER/d' "$D/.env.example";        run "undocumented Makefile setting"    "not documented in .env.example"
fixture; echo '# OLD_KNOB ?= 1' >> "$D/.env.example";    run "stale documented setting"         "no longer read anywhere"
fixture; sed -i.bak 's/^# OWNER ?= me/# OWNER=me/' "$D/.env.example"
                                                         run "doc line without ?="              "not documented in .env.example"
fixture; add_mk 'NEW_X ?= 1';                            run "plain ?="                          "NEW_X"
fixture; add_mk 'export FOO_Y ?= 1';                     run "export NAME ?="                    "FOO_Y"
fixture; add_mk 'override OV_Q ?= 1';                    run "override NAME ?="                  "OV_Q"
fixture; add_mk '  INDENT_Z ?= 1';                       run "indented ?="                       "INDENT_Z"
fixture; add_mk "$(printf 'TABBED_W\t?= 1')";            run "tab before ?="                     "TABBED_W"
fixture; add_mk 'K8S_VER ?= 1';                          run "digit in a Makefile name"         "K8S_VER"
fixture; add_go 'getenv("S3_BUCKET", "")' extra.go;      run "digit in a Go name, second file"  "S3_BUCKET"
fixture; add_go 'os.Getenv("DIRECT_V")' extra.go;        run "os.Getenv"                         "DIRECT_V"
fixture; add_go 'os.LookupEnv("LOOKUP_L")' extra.go;     run "os.LookupEnv"                      "LOOKUP_L"
fixture; add_go 'getenv("NEW_APP", "")' extra.go; echo '# NEW_APP ?=' >> "$D/.env.example"
                                                         run "Go setting not in APP_ENV_VARS"   "not in the Makefile's APP_ENV_VARS"
fixture; : > "$D/Makefile"; rm "$D/main.go";             run "nothing found"                     "found no settings"
fixture; printf 'package main\nfunc main() {}\n' > "$D/main.go"
                                                         run "Go code without getenv"           "no longer read anywhere"
fixture; (cd "$D" && git init -q && git add -A); mkdir -p "$D/.claude/worktrees/a"; add_go 'getenv("WT_ONLY", "")' .claude/worktrees/a/main.go
                                                         run "untracked worktree copy ignored"  pass
fixture; mkdir -p "$D/testdata"; add_go 'os.Getenv("FIXTURE_VAR")' testdata/f.go
                                                         run "testdata ignored"                  pass
fixture; add_go 'xgetenv("NOPE_X", "")' extra.go;        run "xgetenv( is not getenv("            pass
fixture; awk '/^APP_ENV_VARS := /{print "APP_ENV_VARS := APP_CONTEXT \\"; print "  MESSAGE_TO"; next} {print}' "$D/Makefile" > "$D/M" && mv "$D/M" "$D/Makefile"
                                                         run "multi-line APP_ENV_VARS"          "continues on the next line"
fixture; printf 'OWNER=plain\nMESSAGE_TO ?= fine\n# comment\n\n' > "$D/.env"
                                                         run ".env line with plain ="           "warn:.env line(s) 1 are not"
fixture; printf 'OWNER ?= fine\n# comment\n' > "$D/.env"; run ".env with ?= only"               pass
fixture; printf 'export OWNER ?= a\noverride APP_PORT ?= 1\n' > "$D/.env"; run ".env export/override ?="  pass

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
