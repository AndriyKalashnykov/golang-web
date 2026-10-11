#!/usr/bin/env bash
# shellcheck disable=SC2016  # the stand-ins and fixtures are text in single quotes
# Tests for blocks of the vks/ guides (run by `make scripts-test`). Offline: each block is taken
# from its guide with `walk.sh extract`, found by its section title, and run as written in bash
# and in zsh, with a scratch HOME and stand-in `curl`, `kubectl` and `sleep` first on PATH. The
# helper commands (`vc_login`, `vc_api`, `vc`, `vc_cluster_id`, `vc_logout`, `kubectl_install`)
# are the ones the main guide's first block writes: that block is run first, in the scratch HOME.
#
# What is tested:
#   - the blocks that show a vCenter answer, for the answers vCenter gives: a list, an empty
#     list, a NOT_FOUND object, an UNAUTHORIZED object, and the body-plus-`HTTP 403` shape of a
#     refused registration. Each must print its line, and none may print a `jq: error`.
#   - `kubectl_install`: the same version, a version within one minor, and an install.
#   - the Headlamp settings block: it restarts Headlamp once, after the certificate for the new
#     name is in the cluster, and never when nothing changed.
# What it does not prove: what a real vCenter, cert-manager or Headlamp answers (the stand-ins
# hold the answers seen on a lab), a block in bash 3.2, or a block pasted into a terminal.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WALK=$HERE/walk.sh
VKS=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
# A version manager's shim for jq needs the real HOME and does not run in the scratch one the
# blocks get. Put the real program first: a directory holding one link to it.
mkdir -p "$T/real"
JQ_REAL="$(command -v jq || true)"
case "$JQ_REAL" in
  */shims/*) JQ_REAL="$(mise which jq 2>/dev/null || true)" ;;
esac
[ -x "$JQ_REAL" ] && ln -s "$JQ_REAL" "$T/real/jq"
PATH="$T/real:$PATH"
trap 'rm -rf "$T"' EXIT
fails=0
checks=0
ok()    { echo "PASS  $1"; checks=$((checks + 1)); }
bad()   { echo "FAIL  $1: $2"; fails=$((fails + 1)); checks=$((checks + 1)); }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "did not want '$3' in: $2"; else ok "$1"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
line()  { if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want the line '$3' in: $2"; fi; }
harness() { echo "blocks_test.sh: the test's own setup failed (not a finding about a guide): $*" >&2; exit 2; }

SHELLS=bash
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else echo "SKIP  zsh (not installed): every block below runs in bash only"; fi

# --- the blocks, by section title -------------------------------------------------------------
for g in README.md NAMESPACE-auto.md HARBOR-auto.md ARGOCD-auto.md addons/HEADLAMP.md; do
  d="$T/x-$(printf '%s' "$g" | tr '/' '_')"
  bash "$WALK" extract "$VKS/$g" "$d" || harness "walk.sh extract $g"
done
# blk <guide> <section title> [nth block of that section] -> the block's file
blk() {
  local d n
  d="$T/x-$(printf '%s' "$1" | tr '/' '_')"
  n=$(awk -F'\t' -v t="$2" -v want="${3:-1}" '
    { h = $5; s = " > " t
      if (h == t || (length(h) > length(s) && substr(h, length(h) - length(s) + 1) == s)) { c++; if (c == want) print $1 } }' "$d/manifest.tsv")
  [ -n "$n" ] && [ -s "$d/$n.sh" ] || harness "no block ${3:-1} under '$2' in $1 (was the section renamed?)"
  printf '%s\n' "$d/$n.sh"
}
B_ENV=$(blk README.md "Set the variables")
NS_OPEN=$(blk NAMESPACE-auto.md "Open a vCenter session and find the Supervisor's cluster")
NS_NET=$(blk NAMESPACE-auto.md "Read the Supervisor's network type")
NS_POL=$(blk NAMESPACE-auto.md "List the storage policies")
NS_VMC=$(blk NAMESPACE-auto.md "List the VM classes")
NS_CREATE=$(blk NAMESPACE-auto.md "Create the namespace")
HB_OPEN=$(blk HARBOR-auto.md "Open a vCenter session")
HB_REG=$(blk HARBOR-auto.md "Register the service with vCenter")
HB_INST=$(blk HARBOR-auto.md "Install it on your Supervisor")
AR_OPEN=$(blk ARGOCD-auto.md "Open a vCenter session")
AR_REG=$(blk ARGOCD-auto.md "Register the service with vCenter")
AR_INST=$(blk ARGOCD-auto.md "Install it on your Supervisor")
HL_SET=$(blk addons/HEADLAMP.md "Change the add-on's settings (optional)" 1)
grep -q 'patch addonconfig' "$HL_SET" || harness "the first block of Headlamp's settings section is not the one that patches"

# --- the stand-ins ----------------------------------------------------------------------------
mkdir -p "$T/stub" "$T/home" "$T/work" "$T/fix"
cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
method=GET; out=""; wfmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -o) out=$2; shift ;;
    -w) wfmt=$2; shift ;;
    --data-binary) [ "$2" != "@-" ] || cat >/dev/null; shift ;;
    -K|-H|--cacert|--connect-timeout|--max-time|--retry|--resolve) shift ;;
    -fsIL) method=HEAD ;;
    http*://*) url=$1 ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_DIR/curl.log"
CODE=200; BODY=""; BODYFILE=""; RC=0
. "$FAKE_DIR/case.env"
. "$FAKE_DIR/route.sh"
if [ -n "$BODYFILE" ]; then
  if [ -n "$out" ]; then cat "$BODYFILE" > "$out"; else cat "$BODYFILE"; fi
elif [ -n "$out" ]; then printf '%s' "$BODY" > "$out"
else printf '%s' "$BODY"
fi
# shellcheck disable=SC2059
[ -z "$wfmt" ] || printf "${wfmt//%\{http_code\}/$CODE}"
exit "$RC"
STUB
cat > "$T/stub/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/kubectl.log"
. "$FAKE_DIR/case.env"
case "$*" in
  "version --client"*) echo "Client Version: ${CUR_KUBECTL:-v0.0.0}" ;;
  *"get addonconfig"*outputHash*) if [ -e "$FAKE_DIR/patched" ]; then printf hash-2; else printf hash-1; fi ;;
  *"get addonconfig"*ValidConfig*) printf True ;;
  *"get addonconfig"*"-o json") cat "$FAKE_DIR/addonconfig.json" ;;
  *"patch addonconfig"*) : > "$FAKE_DIR/patched"; echo "addonconfig.addons.kubernetes.vmware.com/c1-headlamp patched" ;;
  *gatewayclasses*) printf True ;;
  *"get secret headlamp-tls-cert"*)
    k=$(( $(cat "$FAKE_DIR/secret.n" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$FAKE_DIR/secret.n"
    if [ "$k" -gt "${OLD_READS:-0}" ]; then f=$NEW_CERT; else f=$OLD_CERT; fi
    base64 < "$f" | tr -d '\n' ;;
  *"rollout restart deployment headlamp"*) echo "deployment.apps/headlamp restarted" ;;
  *"rollout status deployment headlamp"*) echo 'deployment "headlamp" successfully rolled out' ;;
esac
STUB
cat > "$T/stub/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/sleep.log"
STUB
chmod +x "$T/stub/curl" "$T/stub/kubectl" "$T/stub/sleep"

# What the stand-in vCenter answers. A case chooses per call (case.env): ok, empty, notfound,
# unauth (the body and 403 seen for an SSO user with no vCenter privilege), unauthn, ise.
cat > "$T/route.sh" <<'ROUTES'
NF='{"error_type":"NOT_FOUND","messages":[{"args":[],"default_message":"The object was not found.","id":"stand.in.not.found"}]}'
UA='{"error_type":"UNAUTHORIZED","messages":[{"args":[],"default_message":"Permission to perform this operation was denied","id":"vapi.security.authorization.permission.denied"}]}'
UN='{"error_type":"UNAUTHENTICATED","messages":[{"args":[],"default_message":"Authentication required.","id":"stand.in.unauthenticated"}]}'
ISE='{"error_type":"INTERNAL_SERVER_ERROR","messages":[]}'
ans() {
  case "$1" in
    ok) BODY=$2; CODE=200 ;;
    empty) BODY='[]'; CODE=200 ;;
    notfound) BODY=$NF; CODE=404 ;;
    unauth) BODY=$UA; CODE=403 ;;
    unauthn) BODY=$UN; CODE=401 ;;
    ise) BODY=$ISE; CODE=500 ;;
    *) echo "stand-in curl: no answer named '$1' for $method $url" >&2; RC=97 ;;
  esac
}
SVC_OK="{\"config_status\":\"CONFIGURED\",\"current_version\":\"${VERSION:-}\",\"messages\":[{\"details\":{\"default_message\":\"Reason: ReconcileSucceeded.\"}}]}"
case "$method $url" in
  "POST https://vcsa.example.test/api/session") BODY='"0123456789abcdef0123"'; CODE=201 ;;
  "DELETE https://vcsa.example.test/api/session") CODE=204 ;;
  "GET https://vcsa.example.test/api/vcenter/cluster")
    ans "${A_CLUSTER:-}" '[{"cluster":"domain-c8","name":"cluster-1"}]' ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/clusters/"*)
    ans "${A_SUP:-}" '{"network_provider":"VSPHERE_NETWORK","config_status":"RUNNING"}' ;;
  "GET https://vcsa.example.test/api/vcenter/storage/policies")
    ans "${A_POL:-}" '[{"name":"b-policy","policy":"p-2"},{"name":"a-policy","policy":"p-1"}]' ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/virtual-machine-classes")
    ans "${A_VMC:-}" '[{"id":"best-effort-small","cpu_count":2,"memory_MB":4096}]' ;;
  "GET https://vcsa.example.test/api/vcenter/namespaces/instances/"*)
    if [ -e "$FAKE_DIR/created" ]; then
      k=$(( $(cat "$FAKE_DIR/ns.n" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$FAKE_DIR/ns.n"
      if [ "${A_NS_AFTER:-ok}" = late ] && [ "$k" -gt 1 ]; then ans unauthn ""
      else ans ok '{"config_status":"RUNNING","networks":["net-1"],"vm_service_spec":{"vm_classes":["best-effort-small"]}}'; fi
    else ans notfound ""; fi ;;
  "POST https://vcsa.example.test/api/vcenter/namespaces/instances") CODE=204; : > "$FAKE_DIR/created" ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/supervisor-services")
    ans "${A_SVCS:-}" '[{"supervisor_service":"tkg.vsphere.vmware.com","state":"ACTIVATED"}]' ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/supervisor-services/"*/versions)
    if [ -e "$FAKE_DIR/registered" ]; then ans ok "[{\"version\":\"${VERSION:-}\",\"state\":\"ACTIVATED\"}]"
    else ans "${A_VER:-}" "[{\"version\":\"${VERSION:-}\",\"state\":\"ACTIVATED\"}]"; fi ;;
  "POST https://vcsa.example.test/api/vcenter/namespace-management/supervisor-services")
    if [ "${A_REG:-}" = 201 ]; then CODE=201; : > "$FAKE_DIR/registered"; else ans "${A_REG:-}" ""; fi ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/supervisors/summaries")
    case "${A_SUMS:-}" in
      one) BODY='{"items":[{"supervisor":"sup-1","info":{"name":"first"}}]}' ;;
      two) BODY='{"items":[{"supervisor":"sup-1","info":{"name":"first"}},{"supervisor":"sup-2","info":{"name":"second"}}]}' ;;
      none) BODY='{"items":[]}' ;;
      *) ans "${A_SUMS:-}" "" ;;
    esac ;;
  "GET https://vcsa.example.test/api/vcenter/namespace-management/supervisors/sup-1/supervisor-services/"*)
    k=$(( $(cat "$FAKE_DIR/svc.n" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$FAKE_DIR/svc.n"
    if [ "${A_SVC:-}" = late ] && [ "$k" -gt 2 ]; then ans unauthn ""; else ans ok "$SVC_OK"; fi ;;
  "HEAD https://dl.k8s.io/"*) : ;;
  "GET https://dl.k8s.io/"*/kubectl.sha256) BODYFILE=$DL_SHA ;;
  "GET https://dl.k8s.io/"*/kubectl) BODYFILE=$DL_BIN ;;
  *) echo "stand-in curl: no route for $method $url" >&2; RC=98 ;;
esac
ROUTES

# The scratch HOME: an env file as the main guide's first block would leave it after the reader
# filled it, and the helper commands as that block writes them.
cat > "$T/home/.vks-golang-web.env" <<'ENVFILE'
export SUPERVISOR_ENDPOINT="supervisor.example.test"
export VCENTER_FQDN="vcsa.example.test"
export VKS_CLUSTER="c1"
export VKS_NAMESPACE="ns1"
export SSO_USERNAME="reader@vsphere.local"
export VCF_CLI_VSPHERE_PASSWORD='stand-in'
export SUPERVISOR_CA="$HOME/ca.pem"
export SUPERVISOR_KUBECONFIG="$HOME/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/guest.kubeconfig"
export VC_SESSION="$HOME/.config/vks-golang-web/vc-session"
export KUBECTL_DIR="$HOME/bin"
export KUBECTL_MATCH="minor"
export HARBOR_MANIFEST="$HOME/manifest.yml"
export HARBOR_VALUES="$HOME/values.yml"
export HARBOR_SERVICE_VERSION='2.15.2+vmware.1-vks.1'
export HEADLAMP_ADDON_NAMESPACE="headlamp-ns"
export HEADLAMP_ADDON_HOSTNAME=""
export HEADLAMP_ADDON_GATEWAY="false"
. "$HOME/.vks-golang-web.functions"
[ ! -f "$HOME/.overrides" ] || . "$HOME/.overrides"
ENVFILE
printf '%s\n' 'export ARGOCD_MANIFEST="$HOME/manifest.yml"' '. "$HOME/.vks-golang-web.env"' > "$T/home/.vks-argocd.env"
printf 'stand-in: true\n' > "$T/home/manifest.yml"
printf 'stand-in: true\n' > "$T/home/values.yml"
( cd "$T/work" && env -i HOME="$T/home" PATH="$PATH" TERM=dumb bash "$B_ENV" >/dev/null 2>&1 )
for f in vc_login vc_api vc vc_cluster_id vc_logout kubectl_install; do
  grep -q "^${f}() {" "$T/home/.vks-golang-web.functions" 2>/dev/null || harness "the main guide's first block did not write the helper command $f"
done
grep -q '^export VCENTER_FQDN="vcsa.example.test"$' "$T/home/.vks-golang-web.env" || harness "the main guide's first block replaced the scratch env file"
( env -i HOME="$T/home" PATH="$T/stub:$PATH" TERM=dumb jq -n '1' >/dev/null 2>&1 ) || harness "jq does not run with a scratch HOME and a scrubbed environment"

# newcase NAME=value...: a new stand-in state; the values choose the answers
newcase() {
  rm -rf "$T/fake" "$T/home/bin" "$T/home/.config"
  mkdir -p "$T/fake"
  cp "$T/route.sh" "$T/fake/route.sh"
  : > "$T/fake/case.env"; : > "$T/home/.overrides"
  : > "$T/fake/curl.log"; : > "$T/fake/kubectl.log"; : > "$T/fake/sleep.log"
  local a
  for a in "$@"; do printf '%s\n' "$a" >> "$T/fake/case.env"; done
}
ovr() { printf '%s\n' "$1" >> "$T/home/.overrides"; }
session() {
  mkdir -p "$T/home/.config/vks-golang-web"
  ( umask 077; printf 'header = "vmware-api-session-id: stand-in"\n' > "$T/home/.config/vks-golang-web/vc-session" )
}
# run <shell> <script>: sets OUT (stdout and stderr). A block is judged by what it prints, not
# by its exit status, which is only its last command's.
run() {
  OUT=$(cd "$T/work" && env -i HOME="$T/home" PATH="$T/stub:$PATH" TERM=dumb FAKE_DIR="$T/fake" "$1" "$2" </dev/null 2>&1)
  hasnt "$L: no jq error" "$OUT" "jq: error"
  hasnt "$L: every call had a stand-in answer" "$OUT" "stand-in curl:"
}
calls() { grep -c -- "$1" "$2" || true; }
UA_LINE="ERROR: UNAUTHORIZED  Permission to perform this operation was denied"
NF_LINE="ERROR: NOT_FOUND  The object was not found."

for sh in $SHELLS; do
  # --- NAMESPACE-auto: the cluster list ------------------------------------------------------
  L="[$sh] NAMESPACE-auto, cluster list, one cluster"
  newcase A_CLUSTER=ok; run "$sh" "$NS_OPEN"
  line "$L: the session opens" "$OUT" "vCenter session opened"
  line "$L: the cluster" "$OUT" "domain-c8  cluster-1"
  L="[$sh] NAMESPACE-auto, cluster list, empty"
  newcase A_CLUSTER=empty; run "$sh" "$NS_OPEN"
  line "$L: says so" "$OUT" "no cluster: vCenter shows this user none"
  L="[$sh] NAMESPACE-auto, cluster list, NOT_FOUND"
  newcase A_CLUSTER=notfound; run "$sh" "$NS_OPEN"
  line "$L: the error and vCenter's sentence" "$OUT" "$NF_LINE"
  L="[$sh] NAMESPACE-auto, cluster list, UNAUTHORIZED"
  newcase A_CLUSTER=unauth; run "$sh" "$NS_OPEN"
  line "$L: the error and vCenter's sentence" "$OUT" "$UA_LINE"

  # --- NAMESPACE-auto: the network type (the block is unchanged; its If-not names these lines) ---
  L="[$sh] NAMESPACE-auto, network type, a Supervisor"
  newcase A_CLUSTER=ok A_SUP=ok; session; run "$sh" "$NS_NET"
  line "$L" "$OUT" "domain-c8  network provider: VSPHERE_NETWORK  Supervisor: RUNNING"
  L="[$sh] NAMESPACE-auto, network type, empty cluster list"
  newcase A_CLUSTER=empty; session; run "$sh" "$NS_NET"
  has "$L: asks for VSPHERE_CLUSTER_ID" "$OUT" "Set VSPHERE_CLUSTER_ID in ~/.vks-golang-web.env"
  L="[$sh] NAMESPACE-auto, network type, NOT_FOUND"
  newcase A_SUP=notfound; ovr 'export VSPHERE_CLUSTER_ID="domain-c9"'; session; run "$sh" "$NS_NET"
  line "$L" "$OUT" "domain-c9  network provider: UNKNOWN  Supervisor: NOT_FOUND"
  L="[$sh] NAMESPACE-auto, network type, UNAUTHORIZED"
  newcase A_SUP=unauth; ovr 'export VSPHERE_CLUSTER_ID="domain-c9"'; session; run "$sh" "$NS_NET"
  line "$L" "$OUT" "domain-c9  network provider: UNKNOWN  Supervisor: UNAUTHORIZED"

  # --- NAMESPACE-auto: storage policies and VM classes ---------------------------------------
  L="[$sh] NAMESPACE-auto, storage policies, a list"
  newcase A_POL=ok; session; run "$sh" "$NS_POL"
  eq "$L: the names, sorted" "$OUT" "a-policy
b-policy"
  L="[$sh] NAMESPACE-auto, storage policies, empty"
  newcase A_POL=empty; session; run "$sh" "$NS_POL"
  eq "$L: nothing printed" "$OUT" ""
  L="[$sh] NAMESPACE-auto, storage policies, NOT_FOUND"
  newcase A_POL=notfound; session; run "$sh" "$NS_POL"
  line "$L" "$OUT" "$NF_LINE"
  L="[$sh] NAMESPACE-auto, storage policies, UNAUTHORIZED"
  newcase A_POL=unauth; session; run "$sh" "$NS_POL"
  line "$L" "$OUT" "$UA_LINE"
  L="[$sh] NAMESPACE-auto, storage policies, INTERNAL_SERVER_ERROR without a message"
  newcase A_POL=ise; session; run "$sh" "$NS_POL"
  has "$L" "$OUT" "ERROR: INTERNAL_SERVER_ERROR"
  L="[$sh] NAMESPACE-auto, VM classes, a list"
  newcase A_VMC=ok; session; run "$sh" "$NS_VMC"
  line "$L" "$OUT" "best-effort-small  2 CPU  4096 MB"
  L="[$sh] NAMESPACE-auto, VM classes, empty"
  newcase A_VMC=empty; session; run "$sh" "$NS_VMC"
  eq "$L: nothing printed" "$OUT" ""
  L="[$sh] NAMESPACE-auto, VM classes, NOT_FOUND"
  newcase A_VMC=notfound; session; run "$sh" "$NS_VMC"
  line "$L" "$OUT" "$NF_LINE"
  L="[$sh] NAMESPACE-auto, VM classes, UNAUTHORIZED"
  newcase A_VMC=unauth; session; run "$sh" "$NS_VMC"
  line "$L" "$OUT" "$UA_LINE"

  # --- NAMESPACE-auto: create ------------------------------------------------------------------
  spec() { mkdir -p "$T/home/.config/vks-golang-web"; printf '{"namespace":"ns1","cluster":"domain-c9"}\n' > "$T/home/.config/vks-golang-web/namespace-spec.json"; }
  for a in notfound unauth; do
    L="[$sh] NAMESPACE-auto, create, the Supervisor is not shown ($a)"
    newcase "A_SUP=$a"; session; spec; run "$sh" "$NS_CREATE"
    line "$L: stops and says why" "$OUT" "STOP: vCenter did not show this user the Supervisor on 'domain-c9' (no cluster, or no privilege: see 'Read the Supervisor's network type'). Nothing was created."
    eq "$L: nothing is sent" "$(calls '^POST ' "$T/fake/curl.log")" 0
    line "$L: the session is closed" "$OUT" "vCenter session closed"
  done
  L="[$sh] NAMESPACE-auto, create, accepted"
  newcase A_SUP=ok; session; spec; run "$sh" "$NS_CREATE"
  line "$L: the create call" "$OUT" "create: HTTP 204"
  line "$L: the last line" "$OUT" "RUNNING  networks: net-1  VM classes: best-effort-small"
  L="[$sh] NAMESPACE-auto, create, accepted and the last read fails"
  newcase A_SUP=ok A_NS_AFTER=late; session; spec; run "$sh" "$NS_CREATE"
  line "$L: the create call" "$OUT" "create: HTTP 204"
  line "$L: the error, not 'null'" "$OUT" "ERROR: UNAUTHENTICATED  Authentication required."

  # --- HARBOR-auto and ARGOCD-auto: the list of services ------------------------------------
  for g in HARBOR ARGOCD; do
    if [ "$g" = HARBOR ]; then OPEN=$HB_OPEN; REG=$HB_REG; INST=$HB_INST; VER='2.15.2+vmware.1-vks.1'
    else OPEN=$AR_OPEN; REG=$AR_REG; INST=$AR_INST; VER='1.2.0-25642124'; fi
    L="[$sh] $g-auto, services, a list"
    newcase A_SVCS=ok; run "$sh" "$OPEN"
    line "$L: the session opens" "$OUT" "vCenter session opened"
    line "$L: the service" "$OUT" "tkg.vsphere.vmware.com  ACTIVATED"
    L="[$sh] $g-auto, services, empty"
    newcase A_SVCS=empty; run "$sh" "$OPEN"
    eq "$L: only the session line" "$OUT" "vCenter session opened"
    L="[$sh] $g-auto, services, NOT_FOUND"
    newcase A_SVCS=notfound; run "$sh" "$OPEN"
    line "$L" "$OUT" "$NF_LINE"
    L="[$sh] $g-auto, services, UNAUTHORIZED"
    newcase A_SVCS=unauth; run "$sh" "$OPEN"
    line "$L" "$OUT" "$UA_LINE"

    # --- register ---
    L="[$sh] $g-auto, register, accepted"
    newcase A_VER=notfound A_REG=201 "VERSION='$VER'"; session; run "$sh" "$REG"
    line "$L: the answer code" "$OUT" "HTTP 201"
    line "$L: the version" "$OUT" "version $VER  ACTIVATED"
    L="[$sh] $g-auto, register, already there"
    newcase A_VER=ok "VERSION='$VER'"; session; run "$sh" "$REG"
    line "$L" "$OUT" "already registered"
    line "$L: the version" "$OUT" "version $VER  ACTIVATED"
    eq "$L: nothing is sent" "$(calls '^POST ' "$T/fake/curl.log")" 0
    L="[$sh] $g-auto, register, refused with 403"
    newcase A_VER=unauth A_REG=unauth "VERSION='$VER'"; session; run "$sh" "$REG"
    has "$L: vCenter's raw answer, then the code" "$OUT" '"id":"vapi.security.authorization.permission.denied"}]}HTTP 403'
    line "$L: then the error line" "$OUT" "$UA_LINE"
    L="[$sh] $g-auto, register, refused and the service is not known"
    newcase A_VER=notfound A_REG=unauth "VERSION='$VER'"; session; run "$sh" "$REG"
    line "$L" "$OUT" "$NF_LINE"
    L="[$sh] $g-auto, register, an empty list of versions"
    newcase A_VER=empty A_REG=unauth "VERSION='$VER'"; session; run "$sh" "$REG"
    has "$L: the code" "$OUT" "HTTP 403"

    # --- install: the list of Supervisors, and the last line ---
    L="[$sh] $g-auto, install, two Supervisors"
    newcase A_SUMS=two "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L: listed" "$OUT" "sup-2  second"
    has "$L: asks for SUPERVISOR_ID" "$OUT" "Set SUPERVISOR_ID in ~/.vks-"
    eq "$L: nothing is sent" "$(calls '^POST ' "$T/fake/curl.log")" 0
    L="[$sh] $g-auto, install, no Supervisor shown"
    newcase A_SUMS=none "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L" "$OUT" "no Supervisor: vCenter shows this user none"
    hasnt "$L: does not ask for an ID from an empty list" "$OUT" "Set SUPERVISOR_ID"
    L="[$sh] $g-auto, install, NOT_FOUND"
    newcase A_SUMS=notfound "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L" "$OUT" "$NF_LINE"
    L="[$sh] $g-auto, install, UNAUTHORIZED"
    newcase A_SUMS=unauth "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L" "$OUT" "$UA_LINE"
    eq "$L: nothing is sent" "$(calls '^POST ' "$T/fake/curl.log")" 0
    line "$L: the session is closed" "$OUT" "vCenter session closed"
    L="[$sh] $g-auto, install, already installed"
    newcase A_SUMS=one "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L: the last line" "$OUT" "CONFIGURED  $VER  Reason: ReconcileSucceeded."
    L="[$sh] $g-auto, install, already installed and the last read fails"
    newcase A_SUMS=one A_SVC=late "VERSION='$VER'"; session; run "$sh" "$INST"
    line "$L: the error, not 'null'" "$OUT" "ERROR: UNAUTHENTICATED  Authentication required."
  done
done

# --- kubectl_install --------------------------------------------------------------------------
printf '#!/bin/sh\necho "Client Version: v9.9.9-downloaded"\n' > "$T/fix/kubectl"
( sha256sum "$T/fix/kubectl" 2>/dev/null || shasum -a 256 "$T/fix/kubectl" ) | awk '{print $1}' > "$T/fix/kubectl.sha256"
[ -s "$T/fix/kubectl.sha256" ] || harness "no sha256sum or shasum"
printf '%s\n' '. "$HOME/.vks-golang-web.env"' 'kubectl_install "$WANT_V"' 'echo "returned $?"' > "$T/fix/install.sh"
ki() { # <label> <installed> <asked for> <KUBECTL_MATCH>
  L=$1
  newcase "CUR_KUBECTL=$2" "DL_BIN=$T/fix/kubectl" "DL_SHA=$T/fix/kubectl.sha256"
  ovr "export WANT_V='$3'"; ovr "export KUBECTL_MATCH='$4'"
  run "$sh" "$T/fix/install.sh"
}
for sh in $SHELLS; do
  ki "[$sh] kubectl_install, the same version" v1.36.2 v1.36.2 minor
  line "$L: says so" "$OUT" "kubectl v1.36.2 is already installed: not changed"
  line "$L: returns 0" "$OUT" "returned 0"
  eq "$L: no download" "$(calls 'dl.k8s.io' "$T/fake/curl.log")" 0
  ki "[$sh] kubectl_install, the same version with a +vmware suffix" v1.36.2 v1.36.2+vmware.2 minor
  line "$L: says so" "$OUT" "kubectl v1.36.2 is already installed: not changed"
  eq "$L: no download" "$(calls 'dl.k8s.io' "$T/fake/curl.log")" 0
  ki "[$sh] kubectl_install, the same version, KUBECTL_MATCH exact" v1.36.2 v1.36.2 exact
  line "$L: says so" "$OUT" "kubectl v1.36.2 is already installed: not changed"
  eq "$L: no download" "$(calls 'dl.k8s.io' "$T/fake/curl.log")" 0
  ki "[$sh] kubectl_install, within one minor" v1.35.1 v1.36.2 minor
  line "$L: the message" "$OUT" 'kubectl v1.35.1 is within one minor version of v1.36.2: supported, not changed (set KUBECTL_MATCH="exact" in the env file to install v1.36.2)'
  eq "$L: no download" "$(calls 'dl.k8s.io' "$T/fake/curl.log")" 0
  ki "[$sh] kubectl_install, within one minor, KUBECTL_MATCH exact" v1.35.1 v1.36.2 exact
  has "$L: the download" "$(cat "$T/fake/curl.log")" "GET https://dl.k8s.io/release/v1.36.2/bin/"
  line "$L: the installed kubectl answers" "$OUT" "Client Version: v9.9.9-downloaded"
  line "$L: returns 0" "$OUT" "returned 0"
  eq "$L: installed into KUBECTL_DIR" "$(cksum < "$T/home/bin/kubectl" 2>/dev/null)" "$(cksum < "$T/fix/kubectl")"
  ki "[$sh] kubectl_install, three minors away" v1.33.0 v1.36.2 minor
  has "$L: the download" "$(cat "$T/fake/curl.log")" "GET https://dl.k8s.io/release/v1.36.2/bin/"
  line "$L: the installed kubectl answers" "$OUT" "Client Version: v9.9.9-downloaded"
done

# --- Headlamp: the settings block restarts Headlamp once, after the new certificate ----------
if command -v openssl >/dev/null 2>&1; then
  mkcert() { # <file> <subjectAltName value>
    printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=stand-in\n[v3]\nsubjectAltName=%s\n' "$2" > "$T/fix/openssl.cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/fix/key.pem" -out "$1" -days 2 -config "$T/fix/openssl.cnf" >/dev/null 2>&1
    openssl x509 -noout -text -in "$1" 2>/dev/null | grep -q 'DNS:' || harness "openssl made no certificate with a DNS name ($2)"
  }
  mkcert "$T/fix/default.pem" "DNS:headlamp.vks.example.com"
  mkcert "$T/fix/new.pem" "DNS:other.example.test,DNS:headlamp.example.test"
  mkcert "$T/fix/longer.pem" "DNS:headlamp.example.test.internal,DNS:xheadlamp.example.test"
  # hl <label> <values in the object> <new host name> <gateway> <old reads> <old cert> <new cert>
  hl() {
    L=$1
    newcase "OLD_READS=$5" "OLD_CERT=$T/fix/$6" "NEW_CERT=$T/fix/$7"
    printf '{"spec":{"clusterName":"c1","values":%s},"status":{"outputHash":"hash-1"}}\n' "$2" > "$T/fake/addonconfig.json"
    ovr "export HEADLAMP_ADDON_HOSTNAME='$3'"; ovr "export HEADLAMP_ADDON_GATEWAY='$4'"
    run "$sh" "$HL_SET"
    SEQ=$(awk '/get secret headlamp-tls-cert/ { printf "S" } /rollout restart/ { printf "R" } /rollout status/ { printf "W" }' "$T/fake/kubectl.log")
  }
  for sh in $SHELLS; do
    hl "[$sh] Headlamp settings, a new name, the certificate on the third read" '{}' headlamp.example.test false 2 default.pem new.pem
    line "$L: worked in" "$OUT" 'worked in after 5 s: {"hostname":"headlamp.example.test"}'
    eq "$L: two waits are printed" "$(calls '^no certificate for headlamp.example.test yet' <(printf '%s\n' "$OUT"))" 2
    eq "$L: three reads, then one restart, then the wait for it" "$SEQ" SSSRW
    line "$L: says what it did" "$OUT" "restarted Headlamp so that it serves the new certificate"
    hl "[$sh] Headlamp settings, the same values" '{"hostname":"headlamp.example.test"}' headlamp.example.test false 0 new.pem new.pem
    has "$L: unchanged" "$OUT" "unchanged: c1-headlamp already holds"
    eq "$L: no read, no restart" "$SEQ" ""
    eq "$L: nothing is patched" "$(calls 'patch addonconfig' "$T/fake/kubectl.log")" 0
    hl "[$sh] Headlamp settings, a new name, no certificate for it" '{}' headlamp.example.test false 99 default.pem new.pem
    eq "$L: 24 reads and no restart" "$SEQ" SSSSSSSSSSSSSSSSSSSSSSSS
    has "$L: says so" "$OUT" "NOT RESTARTED: cert-manager has made no certificate for headlamp.example.test yet"
    line "$L: prints the command with the reader's values" "$OUT" "  kubectl --kubeconfig \"$T/home/guest.kubeconfig\" -n \"headlamp-ns\" rollout restart deployment headlamp"
    hl "[$sh] Headlamp settings, a certificate for a longer name only" '{}' headlamp.example.test false 99 longer.pem longer.pem
    eq "$L: a longer name is not the name: no restart" "$SEQ" SSSSSSSSSSSSSSSSSSSSSSSS
    hl "[$sh] Headlamp settings, only the gateway changes" '{"hostname":"headlamp.example.test"}' headlamp.example.test true 0 new.pem new.pem
    has "$L: worked in" "$OUT" "worked in after 5 s:"
    eq "$L: the name did not change: no read, no restart" "$SEQ" ""
    hl "[$sh] Headlamp settings, back to the add-on's own name" '{"hostname":"headlamp.example.test"}' "" false 1 new.pem default.pem
    line "$L: one wait, for the default name" "$OUT" "no certificate for headlamp.vks.example.com yet (read 1 of 24)"
    eq "$L: two reads, then one restart" "$SEQ" SSRW
    hl "[$sh] Headlamp settings, the default name written out, then left empty" '{"hostname":"headlamp.vks.example.com"}' "" false 0 default.pem default.pem
    eq "$L: the certificate's name did not change: no read, no restart" "$SEQ" ""
    hl "[$sh] Headlamp settings, no name stored, the default name asked for" '{}' headlamp.vks.example.com false 0 default.pem default.pem
    eq "$L: the certificate's name did not change: no read, no restart" "$SEQ" ""
  done
else
  echo "SKIP  the Headlamp settings block (openssl is not installed)"
fi

if [ "$fails" -eq 0 ]; then echo "guide block tests: all $checks checks passed"; else echo "guide block tests: $fails of $checks FAILED"; exit 1; fi
