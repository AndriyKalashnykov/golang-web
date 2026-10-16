#!/usr/bin/env bash
# Checks that every pin of this repo's image under k8s/ names a RELEASED image: the registry tag
# still points at the pinned digest, and that digest was signed by this repository's own release
# run for the matching tag (ci.yml, on a push of refs/tags/v<version>). Run by `make
# check-image-pin`, part of `make static-check`, which is a required check on main.
#
# What it guards: a Renovate PR (the `golang-web image` group, not automerged) that pins a tag
# someone pushed to the registry by hand. Such an image is unsigned, or signed by another tag's run.
# What it does NOT guard: a PR that also edits this script or the Makefile; it runs the PR's copy.
#
# Files: every tracked k8s/**/*.yaml|yml, the set Renovate's kubernetes manager reads. Each line
# that names the image must parse as `image: <image>:<semver>@sha256:<64 hex>`; a line that names
# the image and does not parse fails the check, so no pin is skipped in silence.
#
# Network: the registry (crane) and Sigstore's TUF CDN (cosign needed it on every run measured,
# even with a warm ~/.sigstore; the Rekor entry is inside the signature bundle). Either one unreachable is reported as such,
# after IMAGE_PIN_TRIES attempts, never as a bad pin.
#
# Inputs (environment): IMAGE_PIN_IMAGE (the image, no tag), IMAGE_PIN_REPO (owner/name on GitHub,
# case as GitHub spells it: the certificate identity is case-sensitive), IMAGE_PIN_TRIES (default
# 3). IMAGE_PIN_RETRY_SLEEP (seconds, default 10, times the attempt number) exists for the test.
set -uo pipefail

IMAGE=${IMAGE_PIN_IMAGE:-}
REPO=${IMAGE_PIN_REPO:-}
TRIES=${IMAGE_PIN_TRIES:-3}
SLEEP=${IMAGE_PIN_RETRY_SLEEP:-10}
ISSUER=https://token.actions.githubusercontent.com

fail() { echo "check-image-pin: FAIL: $*" >&2; exit 1; }
infra() { echo "check-image-pin: FAIL (infrastructure, not the pin): $*" >&2; exit 1; }

[ -n "$IMAGE" ] || fail "IMAGE_PIN_IMAGE is not set"
[ -n "$REPO" ] || fail "IMAGE_PIN_REPO is not set"
[[ $TRIES =~ ^[1-9][0-9]*$ ]] || fail "IMAGE_PIN_TRIES must be a positive integer, not '$TRIES'"
[[ $SLEEP =~ ^[0-9]+$ ]] || fail "IMAGE_PIN_RETRY_SLEEP must be a whole number of seconds, not '$SLEEP'"
# Run each tool, not just `command -v`: a version-manager shim exists on PATH and still fails.
for t in cosign crane; do
  v=$("$t" version 2>&1) || fail "$t does not run (make deps): $(head -1 <<< "$v")"
done

FILES=$(git ls-files -- 'k8s/' | grep -E '\.ya?ml$' || true)
[ -n "$FILES" ] || fail "no tracked k8s/**/*.yaml or *.yml file"

# A literal image name inside a regex: escape the ERE metacharacters it can hold (. and /).
IMG_RE=$(printf '%s' "$IMAGE" | sed 's/[.[\*^$/]/\\&/g')
PIN_RE="^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]+${IMG_RE}:([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)@(sha256:[0-9a-f]{64})[[:space:]]*$"

mentions=0; pins=0; verified=0; nfiles=0; bad=""; PINS=""
while IFS= read -r f || [ -n "$f" ]; do
  [ -n "$f" ] || continue
  seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [[ $line == *"$IMAGE"* ]] || continue
    mentions=$((mentions + 1)); seen=1
    if [[ $line =~ $PIN_RE ]]; then
      pins=$((pins + 1))
      PINS="${PINS}${f} ${BASH_REMATCH[2]} ${BASH_REMATCH[4]}"$'\n'
    else
      bad="${bad}  ${f}: ${line}"$'\n'
    fi
  done < "$f"
  [ "$seen" -eq 0 ] || nfiles=$((nfiles + 1))
done <<< "$FILES"

[ "$mentions" -gt 0 ] || fail "no pin of $IMAGE in any tracked k8s/**/*.y{a,}ml file"
if [ "$mentions" -ne "$pins" ]; then
  fail "$mentions line(s) name $IMAGE; $((mentions - pins)) are not in the form image: $IMAGE:<semver>@sha256:<64 hex>:
${bad}"
fi

# retry CMD...: run CMD up to $TRIES times; its stderr is kept in $ERR, its stdout in $OUT.
# Stops early when STOP_ON (a regex) matches stderr: that answer will not change on a retry.
retry() {
  local i rc
  for i in $(seq 1 "$TRIES"); do
    OUT=$("$@" 2>"$ERRF" </dev/null); rc=$?
    ERR=$(cat "$ERRF")
    [ "$rc" -ne 0 ] || return 0
    if [ -n "${STOP_ON:-}" ] && grep -Eq "$STOP_ON" <<< "$ERR"; then return "$rc"; fi
    [ "$i" -ge "$TRIES" ] || sleep $((i * SLEEP))
  done
  return "$rc"
}
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT

while read -r f ver digest || [ -n "${f:-}" ]; do
  [ -n "${f:-}" ] || continue
  # 1. The registry tag must still name the pinned digest: a signed digest whose tag step failed,
  #    or a tag moved since, is not the released image.
  STOP_ON='MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown'
  if ! retry crane digest "$IMAGE:$ver"; then
    if grep -Eq "$STOP_ON" <<< "$ERR"; then fail "$f: the registry has no tag $ver ($ERR)"; fi
    infra "could not ask the registry for $IMAGE:$ver after $TRIES attempt(s): $ERR"
  fi
  [ "$OUT" = "$digest" ] || fail "$f: $digest is not the image the tag $ver names ($OUT)"

  # 2. The digest must be signed by THIS repository's release run for v<version>, on a tag push.
  ref="refs/tags/v$ver"
  STOP_ON='no signatures found|no matching signatures|no matching attestations|no matching CertificateIdentity|none of the expected identities|expected .* to be|expected SAN|expected issuer'
  if ! retry cosign verify "$IMAGE@$digest" \
      --certificate-identity "https://github.com/$REPO/.github/workflows/ci.yml@$ref" \
      --certificate-oidc-issuer "$ISSUER" \
      --certificate-github-workflow-repository "$REPO" \
      --certificate-github-workflow-trigger push \
      --certificate-github-workflow-ref "$ref"; then
    if grep -Eq "$STOP_ON" <<< "$ERR"; then
      fail "$f: $IMAGE:$ver@$digest is not signed by $REPO's release run for $ref.
  cosign: $ERR
  A tag pushed by hand is unsigned. If this is a real release, its signature may have been
  deleted: read the log of the cleanup workflow (cleanup-runs.yml, ghcr-prune-untagged.sh)."
    fi
    infra "could not ask Sigstore to verify $IMAGE@$digest after $TRIES attempt(s): $ERR"
  fi
  verified=$((verified + 1))
  echo "check-image-pin: $f: $ver@${digest:0:19}… is the release v$ver, signed by $REPO"
done <<< "$PINS"

[ "$verified" -eq "$pins" ] || fail "verified $verified of $pins pin(s)"
echo "check-image-pin: checked $verified pin(s) in $nfiles file(s)"
