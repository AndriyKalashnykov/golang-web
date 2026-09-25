#!/usr/bin/env bash
# Tests for ghcr-prune-untagged.sh with fake `gh` and `docker` (run by `make scripts-test`).
# Each case builds a registry of versions + manifests, runs the script for real (DELETE calls
# are logged by the fake gh), and compares the deleted digests with the expected set.
set -u
SCRIPT=${1:-$(dirname "$0")/ghcr-prune-untagged.sh}
OLD=2026-01-01T00:00
fails=0

# ---- fixture helpers -------------------------------------------------------------------
new_case() {
  D=$(mktemp -d); mkdir -p "$D/bin" "$D/m"; : > "$D/v"; ID=0; PAGES=1
  cat > "$D/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *--paginate*) if [ "\$(cat "$D/pages")" = 2 ]; then
                  jq -c '.[0:(length/2|floor)]' "$D/v.json"; jq -c '.[(length/2|floor):]' "$D/v.json"
                else cat "$D/v.json"; fi ;;
  "api orgs/"*) exit 1 ;;
  "api users/"*--silent) exit 0 ;;
  "api --method DELETE "*) echo "\$4" | sed 's#.*/##' >> "$D/deleted-ids" ;;
  *) echo "unexpected gh \$*" >&2; exit 9 ;;
esac
EOF
  cat > "$D/bin/docker" <<EOF
#!/usr/bin/env bash
ref="\${*: -1}"; d="\${ref##*@sha256:}"
if [ -f "$D/m/\$d" ]; then cat "$D/m/\$d"; exit 0; fi
echo "ERROR: \$ref: not found" >&2; exit 1
EOF
  chmod +x "$D/bin/gh" "$D/bin/docker"
}
# ver <name> <created: old-seconds | now> [tag]
ver() {
  local created
  if [ "$2" = now ]; then created=$(date -u +%Y-%m-%dT%H:%M:%SZ); else created="${OLD}:$2Z"; fi
  ID=$((ID + 1))
  printf '{"id":%s,"name":"sha256:%s","created_at":"%s","metadata":{"container":{"tags":[%s]}}}\n' \
    "$ID" "$1" "$created" "${3:+\"$3\"}" >> "$D/v"
}
index() { local n=$1 c="" x; shift; for x in "$@"; do c="${c:+$c,}{\"digest\":\"sha256:$x\"}"; done
          printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}' "$c" > "$D/m/$n"; }
image() { local x; for x in "$@"; do echo '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}' > "$D/m/$x"; done; }
referrer() { printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","subject":{"digest":"sha256:%s"}}' "$2" > "$D/m/$1"; }

# run_case <name> <KEEP_MINIMUM> <expect: "del x y z" | abort>
run_case() {
  local name=$1 keep=$2 expect=$3 out rc got want
  jq -s . "$D/v" > "$D/v.json"; echo "$PAGES" > "$D/pages"; : > "$D/deleted-ids"
  out=$(PATH="$D/bin:$PATH" OWNER=o PACKAGE=p KEEP_MINIMUM=$keep bash "$SCRIPT" 2>&1); rc=$?
  got=""
  while read -r id; do
    [ -n "$id" ] && got+="$(jq -r --argjson i "$id" '.[] | select(.id == $i) | .name[7:]' "$D/v.json") "
  done < "$D/deleted-ids"
  got=$(tr ' ' '\n' <<<"$got" | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')
  if [ "$expect" = abort ]; then
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then echo "PASS  $name (aborted, nothing deleted)"
    else echo "FAIL  $name: rc=$rc deleted [$got], want abort with no deletes"; echo "$out"; fails=$((fails + 1)); fi
  else
    want=$(tr ' ' '\n' <<<"${expect#del}" | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then echo "PASS  $name (deleted [$got])"
    else echo "FAIL  $name: rc=$rc deleted [$got], want [$want]"; echo "$out"; fails=$((fails + 1)); fi
  fi
  rm -rf "$D"
}

# Shared base: tagged index T {a,b, dangling z}; untagged U1 {c,d} older than lone g older than U2 {e,f};
# referrer r (signature of a); y is 1 minute old.
base() {
  ver T 01 1.0; ver a 01; ver b 01; ver U1 02; ver c 02; ver d 02; ver g 03; ver U2 04; ver e 04; ver f 04
  ver r 05; ver y now
  index T a b z; index U1 c d; index U2 e f; image a b c d e f g y; referrer r a
}

# ---- cases -------------------------------------------------------------------------------
new_case; base;                                  run_case "orphan groups deleted whole"     1 "del U1 c d g"
new_case; base; PAGES=2;                         run_case "two pages of versions"           1 "del U1 c d g"
new_case; base;                                  run_case "KEEP_MINIMUM covers all"         5 "del"
new_case; base; index U1 c d e;                  run_case "child shared with a kept image"  1 "del U1 c d g"
new_case; base; index U1 c d e; index U2 e f g;  run_case "child shared by two deleted"     0 "del U1 U2 c d e f g"
new_case; base; rm "$D/m/T";                     run_case "tagged version not found"        1 abort
new_case; base; ver Y now; ver h 06; ver i 06; index Y h i; image h i
                                                 run_case "young index keeps old children" 0 "del U1 U2 c d e f g"
new_case; base; ver N1 07; ver N2 07; ver j 07; index N1 N2; index N2 j; image j
                                                 run_case "nested kept index"              1 "del U1 U2 c d e f g"

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
