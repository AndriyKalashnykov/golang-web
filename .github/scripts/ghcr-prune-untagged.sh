#!/usr/bin/env bash
# Delete orphaned untagged versions of a GHCR container package.
#
# A multi-arch image is a tagged index whose platform images and attestations are UNTAGGED
# versions. GHCR has no OCI referrers API, so cosign stores signatures as untagged children of
# a `sha256-<digest>` tagged index. Deleting "untagged" blindly therefore breaks `docker pull`
# of released tags and deletes signatures.
#
# PROTECTED = everything reachable (through nested indexes) from:
#   - tagged versions (a tagged version whose manifest cannot be read aborts the run);
#   - versions newer than MIN_AGE_MINUTES (a release may still be pushing);
#   - referrers (manifests with a `subject`, e.g. signatures);
#   - the newest KEEP_MINIMUM orphaned images (an untagged index with its descendants,
#     or a lone untagged manifest).
# Only untagged versions outside PROTECTED are deleted, each once, index before children.
# Kept forever (safe, by design): signature indexes whose subject was deleted, and referrers.
#
# Env: OWNER, PACKAGE (required); KEEP_MINIMUM (default 5); MIN_AGE_MINUTES (default 60);
#      DRY_RUN=1 lists without deleting. Needs bash 3.2+, gh (authenticated), jq, docker buildx.
set -euo pipefail

: "${OWNER:?set OWNER}" "${PACKAGE:?set PACKAGE}"
KEEP_MINIMUM="${KEEP_MINIMUM:-5}"
MIN_AGE_MINUTES="${MIN_AGE_MINUTES:-60}"
DRY_RUN="${DRY_RUN:-0}"
image="ghcr.io/$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')/${PACKAGE}"

die() { echo "ERROR: $*" >&2; exit 1; }
has() { grep -qxF "$1" <<<"$2"; }   # has <line> <newline-separated set>

# RAW = raw manifest of $1. Returns 2 if the registry says it does not exist; retries other
# errors and dies after the last attempt.
RAW=""
raw_manifest() {
  local i out
  for i in 1 2 3; do
    if out=$(docker buildx imagetools inspect --raw "${image}@$1" 2>&1); then RAW=$out; return 0; fi
    case "$out" in *": not found"*) return 2 ;; esac
    if [ "$i" -lt 3 ]; then sleep $((i * 5)); fi
  done
  die "cannot read the manifest of ${image}@$1: ${out}"
}

# Append $1 and every digest below it to DESC (runs in this shell, so `die` stops the run).
# $2=must: the digest itself must exist. Children that no longer exist are dangling: skipped.
DESC=""
collect() {
  local rc=0 children child
  DESC+="$1"$'\n'
  raw_manifest "$1" || rc=$?
  if [ "$rc" -eq 2 ]; then
    if [ "${2:-}" = must ]; then
      die "${image}@$1 is listed as tagged but the registry says it does not exist; refusing to prune"
    fi
    return 0
  fi
  children=$(jq -r '.manifests[]?.digest' <<<"$RAW")
  for child in $children; do collect "$child"; done
}

# The package lives under either an org or a user; use whichever answers.
scope=""
for s in orgs users; do
  if gh api "${s}/${OWNER}/packages/container/${PACKAGE}" --silent 2>/dev/null; then scope=$s; break; fi
done
[ -n "$scope" ] || die "package ${OWNER}/${PACKAGE} not found (or no access) under orgs/ or users/."
api="${scope}/${OWNER}/packages/container/${PACKAGE}/versions"

versions=$(gh api --paginate "$api" | jq -s 'add // []')
total=$(jq 'length' <<<"$versions")
[ "$total" -gt 0 ] || die "${api} returned no versions."
cutoff=$(jq -rn --argjson m "$MIN_AGE_MINUTES" 'now - $m * 60 | todate')

# 1. Protect what tagged versions reach.
DESC=""
for digest in $(jq -r '.[] | select(.metadata.container.tags | length > 0) | .name' <<<"$versions"); do
  collect "$digest" must
done
protected=$DESC

# 2. Classify untagged versions (newest first): young ones and referrers are protected with
#    their descendants; the rest are candidates; children of candidate indexes are not roots.
untagged=$(jq -r '[.[] | select(.metadata.container.tags | length == 0)] | sort_by(.created_at) | reverse | .[] | "\(.name) \(.created_at)"' <<<"$versions")
candidates="" children="" young=0 referrers=0
while read -r digest created; do
  [ -n "$digest" ] || continue
  if has "$digest" "$protected"; then continue; fi
  if [[ "$created" > "$cutoff" ]]; then
    young=$((young + 1)); DESC=""; collect "$digest"; protected+=$DESC; continue
  fi
  rc=0; raw_manifest "$digest" || rc=$?
  if [ "$rc" -eq 2 ]; then continue; fi           # listed but already gone
  if [ "$(jq -r 'has("subject")' <<<"$RAW")" = true ]; then
    referrers=$((referrers + 1)); DESC=""; collect "$digest"; protected+=$DESC; continue
  fi
  candidates+="$digest"$'\n'
  children+=$(jq -r '.manifests[]?.digest' <<<"$RAW")$'\n'
done <<<"$untagged"

# 3. Roots = candidates that are not a child of another candidate index (still newest first).
#    The newest KEEP_MINIMUM roots are kept with all their descendants.
roots="" n=0
for digest in $candidates; do
  if ! has "$digest" "$children"; then roots+="$digest"$'\n'; n=$((n + 1)); fi
done
kept=0
for root in $roots; do
  [ "$kept" -lt "$KEEP_MINIMUM" ] || break
  DESC=""; collect "$root"; protected+=$DESC; kept=$((kept + 1))
done

echo "${image}: ${total} versions; ${n} orphaned images, keeping the newest ${kept};" \
     "protected ${young} newer than ${MIN_AGE_MINUTES} min and ${referrers} referrers."

# 4. Delete the unprotected descendants of the remaining roots, each once, index first.
deleted=""
for root in $roots; do
  if has "$root" "$protected"; then continue; fi
  DESC=""; collect "$root"
  for digest in $DESC; do
    if has "$digest" "$protected" || has "$digest" "$deleted"; then continue; fi
    id=$(jq -r --arg d "$digest" '.[] | select(.name == $d) | .id' <<<"$versions")
    [ -n "$id" ] || continue                       # dangling: nothing to delete
    if [ "$DRY_RUN" = 1 ]; then
      echo "would delete ${digest} (version ${id}, image ${root})"
    else
      gh api --method DELETE "${api}/${id}" --silent
      echo "deleted ${digest} (version ${id}, image ${root})"
    fi
    deleted+="$digest"$'\n'
  done
done
