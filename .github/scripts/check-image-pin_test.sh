#!/usr/bin/env bash
# Tests check-image-pin.sh against stand-in `cosign` and `crane` that record their arguments, in a
# throwaway git repository. Proves the script's parsing, counting and exact verify arguments; it
# does not prove cosign's behaviour. The real-registry cases (a released pin passes, 0.0.4's digest
# labelled 0.0.5 fails, unsigned 0.0.3 fails) are in CLAUDE.md, measured with cosign 3.1.3.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/check-image-pin.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

IMG=ghcr.io/example/app
REPO=Example/app
DIG5=$(printf '5%.0s' $(seq 64))
DIG4=$(printf '4%.0s' $(seq 64))

# Stand-ins. FAKE_CRANE_DIGEST: what `crane digest` prints (empty = fail like a network error).
# FAKE_COSIGN: ok | nosig | mismatch | tuf.
mkdir -p "$D/bin"
cat > "$D/bin/crane" <<'EOF'
#!/usr/bin/env bash
[ "$1" = version ] && { [ -z "${FAKE_CRANE_BROKEN:-}" ] || { echo "mise ERROR No version is set for shim: crane" >&2; exit 1; }; echo 0-fake; exit 0; }
echo "$*" >> "$FAKE_LOG/crane.args"
[ -z "${FAKE_CRANE_MISSING:-}" ] || { echo "Error: GET https://ghcr.io/v2/example/app/manifests/0.0.5: MANIFEST_UNKNOWN: manifest unknown" >&2; exit 1; }
[ -n "${FAKE_CRANE_DIGEST:-}" ] || { echo "GET https://ghcr.io/token: dial tcp: i/o timeout" >&2; exit 1; }
echo "$FAKE_CRANE_DIGEST"
EOF
cat > "$D/bin/cosign" <<'EOF'
#!/usr/bin/env bash
[ "$1" = version ] && { echo "GitVersion: v0-fake"; exit 0; }
printf '%s\n' "$@" > "$FAKE_LOG/cosign.args.$(date +%s%N)"
case "${FAKE_COSIGN:-ok}" in
  ok) echo "Verification for x --" >&2; echo '[{}]' ;;
  nosig) echo "Error: no signatures found" >&2; exit 10 ;;
  # The texts cosign 3.1.3 prints (measured 2026-10-16), not cosign 2's.
  mismatch) echo 'Error: no matching attestations: failed to verify certificate identity: no matching CertificateIdentity found, last error: expected SAN value "https://github.com/Example/app/.github/workflows/ci.yml@refs/tags/v0.0.5", got "https://github.com/Example/app/.github/workflows/ci.yml@refs/tags/v0.0.4"' >&2; exit 1 ;;
  repo) echo 'Error: no matching attestations: expected GithubWorkflowRepository to be "Example/app", got "evil/fork"' >&2; exit 1 ;;
  tuf) echo "Error: getting trusted root: tuf refresh failed: Get https://tuf-repo-cdn.sigstore.dev/15.root.json: dial tcp: i/o timeout" >&2; exit 1 ;;
esac
EOF
chmod +x "$D/bin/crane" "$D/bin/cosign"

pass=0; failc=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; failc=$((failc + 1)); }

# new_repo FILE CONTENT...: a fresh git repository holding the given files under k8s/.
new_repo() {
  R="$D/repo.$RANDOM$RANDOM"; mkdir -p "$R/k8s"
  git -C "$R" init -q
  while [ $# -gt 0 ]; do mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; shift 2; done
  git -C "$R" add -A
}

# run [ENV=VAL...]: run the script in $R; output in $OUT, status in $RC.
run() {
  rm -f "$D"/log/*; mkdir -p "$D/log"
  OUT=$(cd "$R" && env PATH="$D/bin:$PATH" FAKE_LOG="$D/log" IMAGE_PIN_IMAGE="$IMG" \
    IMAGE_PIN_REPO="$REPO" IMAGE_PIN_TRIES=2 IMAGE_PIN_RETRY_SLEEP=0 "$@" bash "$SCRIPT" 2>&1)
  RC=$?
}
cosign_args() { cat "$D"/log/cosign.args.* 2>/dev/null; }
cosign_calls() { find "$D/log" -name 'cosign.args.*' | wc -l | tr -d ' '; }

# 1. One released pin: passes, and cosign gets exactly the identity bound to this repo's tag run.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG5"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
want=$(printf '%s\n' verify "$IMG@sha256:$DIG5" \
  --certificate-identity "https://github.com/$REPO/.github/workflows/ci.yml@refs/tags/v0.0.5" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository "$REPO" \
  --certificate-github-workflow-trigger push \
  --certificate-github-workflow-ref refs/tags/v0.0.5)
if [ "$RC" -eq 0 ] && [ "$(cosign_args)" = "$want" ] && grep -q 'checked 1 pin(s) in 1 file(s)' <<<"$OUT" \
   && [ "$(cat "$D/log/crane.args")" = "digest $IMG:0.0.5" ]; then
  ok "a released pin passes; verify arguments are exact"
else bad "a released pin passes; verify arguments are exact (rc=$RC) $OUT
--- got:
$(cosign_args)"; fi

# 2. No pin at all: fails with a reason (never "checked 0").
new_repo k8s/other.yaml "        image: nginx:1"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -ne 0 ] && grep -q "no pin of $IMG" <<<"$OUT"; then ok "no pin fails"; else bad "no pin fails (rc=$RC) $OUT"; fi

# 3. A pin without a digest: fails, and nothing is verified.
new_repo k8s/app.yaml "        image: $IMG:0.0.5"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -ne 0 ] && grep -q 'not in the form' <<<"$OUT" && [ "$(cosign_calls)" = 0 ]; then
  ok "a pin without a digest fails"; else bad "a pin without a digest fails (rc=$RC) $OUT"; fi

# 4. A mention the parser does not understand (quoted, in a .yml under a sub-folder) fails instead
#    of being skipped: mentions and parsed pins must match.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG5" \
         k8s/sub/x.yml "  - image: \"$IMG:0.0.5@sha256:$DIG5\" # quoted"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -ne 0 ] && grep -q '2 line(s) name' <<<"$OUT" && grep -q 'k8s/sub/x.yml' <<<"$OUT"; then
  ok "an unparsed mention in k8s/**/*.yml fails"; else bad "an unparsed mention in k8s/**/*.yml fails (rc=$RC) $OUT"; fi

# 5. Two parsed pins in two files: both checked.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG5" \
         k8s/sub/b.yml "  - image: $IMG:0.0.5@sha256:$DIG5"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -eq 0 ] && [ "$(cosign_calls)" = 2 ] && grep -q 'checked 2 pin(s) in 2 file(s)' <<<"$OUT"; then
  ok "two pins in two files are both checked"; else bad "two pins in two files are both checked (rc=$RC) $OUT"; fi

# 6. The registry tag points elsewhere (signed but not the released image): fails before cosign.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG4"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -ne 0 ] && grep -q 'not the image the tag 0.0.5 names' <<<"$OUT" && [ "$(cosign_calls)" = 0 ]; then
  ok "a digest the tag does not name fails"; else bad "a digest the tag does not name fails (rc=$RC) $OUT"; fi

# 7. No signature: fails at once (no retry), naming the pruner as a possible cause.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG5"
run FAKE_CRANE_DIGEST="sha256:$DIG5" FAKE_COSIGN=nosig
if [ "$RC" -ne 0 ] && grep -q 'not signed by' <<<"$OUT" && grep -q 'cleanup' <<<"$OUT" && [ "$(cosign_calls)" = 1 ]; then
  ok "an unsigned digest fails without retry"; else bad "an unsigned digest fails without retry (rc=$RC, calls=$(cosign_calls)) $OUT"; fi

# 8. Signed by another tag's run: fails at once.
run FAKE_CRANE_DIGEST="sha256:$DIG5" FAKE_COSIGN=mismatch
if [ "$RC" -ne 0 ] && grep -q 'not signed by' <<<"$OUT" && [ "$(cosign_calls)" = 1 ]; then
  ok "a signature from another tag fails"; else bad "a signature from another tag fails (rc=$RC) $OUT"; fi

# 9. Sigstore unreachable: retried, then reported as infrastructure, not as a bad pin.
run FAKE_CRANE_DIGEST="sha256:$DIG5" FAKE_COSIGN=tuf
if [ "$RC" -ne 0 ] && grep -q 'could not ask Sigstore' <<<"$OUT" && ! grep -q 'not signed by' <<<"$OUT" \
   && [ "$(cosign_calls)" = 2 ]; then
  ok "Sigstore down is retried and reported as infrastructure"; else bad "Sigstore down is retried and reported as infrastructure (rc=$RC, calls=$(cosign_calls)) $OUT"; fi

# 10. Registry unreachable: reported as infrastructure.
run FAKE_CRANE_DIGEST=
if [ "$RC" -ne 0 ] && grep -q 'could not ask the registry' <<<"$OUT" && [ "$(cosign_calls)" = 0 ]; then
  ok "registry down is reported as infrastructure"; else bad "registry down is reported as infrastructure (rc=$RC) $OUT"; fi

# 11. IMAGE_PIN_REPO unset: the script refuses rather than build an identity from nothing.
run FAKE_CRANE_DIGEST="sha256:$DIG5" IMAGE_PIN_REPO=
if [ "$RC" -ne 0 ] && grep -q 'IMAGE_PIN_REPO is not set' <<<"$OUT"; then ok "IMAGE_PIN_REPO unset fails"; else bad "IMAGE_PIN_REPO unset fails (rc=$RC) $OUT"; fi

# 12. A tool that is on PATH but does not run (a version-manager shim with no version set): fails as
#     a setup problem, never as "infrastructure" or a bad pin.
new_repo k8s/app.yaml "        image: $IMG:0.0.5@sha256:$DIG5"
run FAKE_CRANE_DIGEST="sha256:$DIG5" FAKE_CRANE_BROKEN=1
if [ "$RC" -ne 0 ] && grep -q 'crane does not run' <<<"$OUT" && ! grep -q infrastructure <<<"$OUT"; then
  ok "a tool that does not run fails as setup"; else bad "a tool that does not run fails as setup (rc=$RC) $OUT"; fi

# 13. Signed by another repository's run (a caller of ci.yml through workflow_call): fails at once.
run FAKE_CRANE_DIGEST="sha256:$DIG5" FAKE_COSIGN=repo
if [ "$RC" -ne 0 ] && grep -q 'not signed by' <<<"$OUT" && [ "$(cosign_calls)" = 1 ]; then
  ok "a signature from another repository fails"; else bad "a signature from another repository fails (rc=$RC) $OUT"; fi

# 14. The registry has no such tag (pushed by hand, then deleted): fails at once, no cosign call.
run FAKE_CRANE_MISSING=1
if [ "$RC" -ne 0 ] && grep -q 'registry has no tag 0.0.5' <<<"$OUT" && [ "$(wc -l < "$D/log/crane.args" | tr -d ' ')" = 1 ] \
   && [ "$(cosign_calls)" = 0 ]; then
  ok "a missing registry tag fails without retry"; else bad "a missing registry tag fails without retry (rc=$RC) $OUT"; fi

# 15. Build metadata (+meta) cannot be an OCI tag: the line does not parse.
new_repo k8s/app.yaml "        image: $IMG:0.0.5+meta@sha256:$DIG5"
run FAKE_CRANE_DIGEST="sha256:$DIG5"
if [ "$RC" -ne 0 ] && grep -q 'not in the form' <<<"$OUT"; then ok "a +build version does not parse"; else bad "a +build version does not parse (rc=$RC) $OUT"; fi

# 16. A bad IMAGE_PIN_TRIES is named, not an unbound-variable crash.
run FAKE_CRANE_DIGEST="sha256:$DIG5" IMAGE_PIN_TRIES=0
if [ "$RC" -ne 0 ] && grep -q 'IMAGE_PIN_TRIES must be a positive integer' <<<"$OUT"; then ok "IMAGE_PIN_TRIES=0 is refused"; else bad "IMAGE_PIN_TRIES=0 is refused (rc=$RC) $OUT"; fi

echo "check-image-pin tests: $pass passed, $failc failed"
[ "$failc" -eq 0 ]
