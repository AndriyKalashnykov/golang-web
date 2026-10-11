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
#   - the blocks that install ONE program (argocd in both ArgoCD guides, the Supervisor's
#     kubectl, the VCF CLI, helm) and `kubectl_install`: a directory the user may write to, a
#     `sudo -n` that works, one that refuses, one that makes the directory and refuses the copy,
#     and nothing writable at all; never a `sudo` without `-n`; another argocd is never replaced;
#     the ArgoCD clean-up removes this guide's argocd and no other.
# What it does not prove: what a real vCenter, cert-manager or Headlamp answers (the stand-ins
# hold the answers seen on a lab), a block in bash 3.2, or a block pasted into a terminal. For
# the install blocks: the real sudo (a password prompt, a remembered password, sudoers rules),
# the real /usr/local/bin, the real programs, the Helm project's real script (the stand-in only
# prints the two settings it was given), and macOS.
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
  "GET https://supervisor.example.test/wcp/plugin/linux-amd64/vsphere-plugin.zip") BODY=stand-in ;;
  "GET https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4")
    if [ "${HELM_DL:-}" = fail ]; then echo "curl: (22) The requested URL returned error: 503" >&2; RC=22; else BODYFILE=$HELM_SCRIPT; fi ;;
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

# --- the blocks that install ONE program: a writable directory, `sudo -n`, or ~/.local/bin ------
# Each block names its directory on ONE line (`D=/usr/local/bin`); the test puts a scratch
# directory there and nowhere else, so the block under test is otherwise the guide's text.
REAL_INSTALL="$(command -v install)" || harness "no install program"
mkdir -p "$T/stub2"
cat > "$T/stub2/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/sudo.log"
. "$FAKE_DIR/case.env"
[ "${1:-}" = -n ] || { echo "stand-in sudo: called without -n, where the real one could ask for a password: $*" >&2; exit 1; }
shift
case "${SUDO_MODE:-refuse}" in
  ok) ;;
  half) case "$*" in "install -d "*) exit 0 ;; esac
        echo "stand-in sudo: this command is refused" >&2; exit 1 ;;
  *) echo "sudo: a password is required" >&2; exit 1 ;;
esac
if [ -f "${SUDO_UNBLOCK:-}" ]; then rm -f "$SUDO_UNBLOCK"; elif [ -d "${SUDO_UNBLOCK:-}" ]; then chmod u+w "$SUDO_UNBLOCK"; fi
exec "$@"
STUB
printf '%s\n' '#!/usr/bin/env bash' '. "$FAKE_DIR/case.env"' \
  'if [ -n "${INSTALL_FAIL:-}" ]; then echo "stand-in install: no space left on device" >&2; exit 1; fi' \
  "exec '$REAL_INSTALL' \"\$@\"" > "$T/stub2/install"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac' > "$T/stub2/uname"
cat > "$T/stub2/unzip" <<'STUB'
#!/usr/bin/env bash
. "$FAKE_DIR/case.env"
while [ $# -gt 1 ]; do [ "$1" != -d ] || dir=$2; shift; done
mkdir -p "$dir/bin" && cp "$ZIP_KUBECTL" "$dir/bin/kubectl"
STUB
chmod +x "$T/stub2/sudo" "$T/stub2/install" "$T/stub2/uname" "$T/stub2/unzip"

# The programs the blocks install, as stand-ins that answer what the blocks ask.
mkdir -p "$T/fix/vcfsrc" "$T/fix/plugsrc" "$T/fix/dl"
printf '#!/bin/sh\necho "argocd: v3.4.4+stand-in-vcf"\n' > "$T/fix/argocd"
printf '#!/bin/sh\necho "argocd: v3.0.0+stand-in"\n' > "$T/fix/argocd-other"
cat > "$T/fix/vcfsrc/vcf-cli-linux_amd64" <<'STUB'
#!/bin/sh
. "$FAKE_DIR/case.env"
case "$1 $2" in
  "plugin install")
    if [ -n "${VCF_PLUGINS_FAIL:-}" ]; then echo "stand-in vcf: the plugin bundle is damaged" >&2; exit 1; fi
    echo "stand-in plugins installed from a local source" ;;
  "plugin list") echo "stand-in-plugin  installed" ;;
  "version "*) echo "version: v9.1.1-stand-in" ;;
esac
STUB
printf '#!/bin/sh\necho "older vcf ran: $*"\necho "version: v0.0.1-older"\n' > "$T/fix/vcf-older"
cat > "$T/fix/get-helm" <<'STUB'
. "$FAKE_DIR/case.env"
echo "stand-in helm script: USE_SUDO=${USE_SUDO:-unset} HELM_INSTALL_DIR=${HELM_INSTALL_DIR:-unset}"
if [ -n "${HELM_SCRIPT_FAIL:-}" ]; then echo "stand-in helm script: the checksum does not match" >&2; exit 1; fi
if [ -n "${HELM_INSTALL_DIR:-}" ]; then
  printf '#!/bin/sh\necho stand-in-new-helm\n' > "$HELM_INSTALL_DIR/helm" && chmod +x "$HELM_INSTALL_DIR/helm" || exit 1
  if [ "$(command -v helm)" != "$HELM_INSTALL_DIR/helm" ]; then echo "helm not found. Is $HELM_INSTALL_DIR on your PATH?"; exit 1; fi
fi
STUB
chmod +x "$T/fix/argocd" "$T/fix/argocd-other" "$T/fix/vcfsrc/vcf-cli-linux_amd64" "$T/fix/vcf-older"
printf 'stand-in\n' > "$T/fix/plugsrc/stand-in-plugin"
gzip -c "$T/fix/argocd" > "$T/fix/dl/argocd-cli-linux-amd64-v3.4.4-vcf.gz" || harness "gzip"
tar -czf "$T/fix/dl/VCF-Consumption-CLI-Linux_AMD64-9.1.1.0100.25746586.tar.gz" -C "$T/fix/vcfsrc" vcf-cli-linux_amd64 || harness "tar"
tar -czf "$T/fix/dl/VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.1.0100.25793136.tar.gz" -C "$T/fix/plugsrc" stand-in-plugin || harness "tar"

LB="$T/home/.local/bin"
# icase NAME=value...: a new state for an install case: a writable directory ($T/dirs/w), a
# directory nobody can create, root included ($T/dirs/afile/bin: its parent is a regular file),
# no ~/.local, and the downloads in place.
icase() {
  [ ! -d "$T/dirs" ] || chmod -R u+w "$T/dirs"
  rm -rf "$T/dirs" "$T/home/.local" "$T/home/Downloads"
  mkdir -p "$T/dirs/w" "$T/dirs/other" "$T/home/Downloads"
  : > "$T/dirs/afile"
  cp "$T/fix/dl/"* "$T/home/Downloads/"
  printf '%s\n' 'export ARGOCD_MANIFEST="$HOME/manifest.yml"' '. "$HOME/.vks-golang-web.env"' > "$T/home/.vks-argocd.env"
  newcase "ZIP_KUBECTL=$T/fix/kubectl" "HELM_SCRIPT=$T/fix/get-helm" "DL_BIN=$T/fix/kubectl" "DL_SHA=$T/fix/kubectl.sha256" ${1+"$@"}
  : > "$T/fake/sudo.log"
}
# withdir <block> <directory>: sets SUBST to a copy of the block whose ONE `D=` line names the
# directory. Not called in a `$( )`: a block with no such line, or with two, stops the test here.
withdir() {
  local n
  n=$(grep -c '^[[:space:]]*D=' "$1" || true)
  [ "$n" = 1 ] || harness "$1 has $n lines that set D at the start of a line; the test replaces exactly one"
  SUBST="$T/fix/subst.sh"
  sed "s|^\\([[:space:]]*\\)D=.*\$|\\1D=\"$2\"|" "$1" > "$SUBST"
  [ "$(grep -cxF "D=\"$2\"" "$SUBST" || true)" = 1 ] || harness "the directory was not put into exactly one line of $1"
}
# prep <program> <block> <directory>: sets RUNF, the script to run. The Supervisor-kubectl block
# reads its directory from KUBECTL_DIR, so the env file names it and the block runs as written.
prep() {
  if [ "$1" = kubectl ]; then
    { [ "$(grep -c '^[[:space:]]*D=' "$2" || true)" = 1 ] && grep -qxF 'D="${KUBECTL_DIR:-/usr/local/bin}"' "$2"; } \
      || harness "the Supervisor-kubectl block does not read its directory from KUBECTL_DIR on one line"
    ovr "export KUBECTL_DIR='$3'"; RUNF=$2
  else
    withdir "$2" "$3"; RUNF=$SUBST
  fi
}
# run2 <shell> <script> [NAME=value...]: as run, with the stand-in sudo, install, uname and unzip.
run2() {
  local s=$1 f=$2; shift 2
  OUT=$(cd "$T/work" && env -i HOME="$T/home" PATH="$T/stub2:$T/stub:$PATH" TERM=dumb FAKE_DIR="$T/fake" ${1+"$@"} "$s" "$f" </dev/null 2>&1)
  hasnt "$L: every call had a stand-in answer" "$OUT" "stand-in curl:"
  eq "$L: sudo is never called without -n" "$(grep -vc '^-n ' "$T/fake/sudo.log" || true)" 0
}
same()  { if [ -f "$2" ] && cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 is not a copy of $3"; fi; }
emptydir() { if [ -d "$2" ] && [ -z "$(find "$2" -mindepth 1 | head -1)" ]; then ok "$1"; else bad "$1" "$2 is not an empty directory"; fi; }
gone()  { if [ -e "$2" ]; then bad "$1" "$2 exists"; else ok "$1"; fi; }
# shellcheck disable=SC2012  # one file of our own, for its mode column
mode()  { eq "$1" "$(ls -l "$2" 2>/dev/null | cut -c1-10)" "-rwxr-xr-x"; }
fallback_line() { printf '%s' "$1: $2 needs administrator rights and this block never asks for a password: installed into $LB instead. That is fine. To have it in $2 instead: rm $LB/$3, run 'sudo -v', then this block again."; }
path_line() { printf '%s' "$1: $2 was not on your PATH: added for this terminal only. Every later block needs it: add the next line to ~/.zshrc (zsh), ~/.bashrc (bash on Linux) or ~/.bash_profile (bash on macOS), then open a new terminal:"; }
NOTHING="Nothing installed: see the error above"

for g in ARGOCD-manual.md SETUP.md; do
  d="$T/x-$(printf '%s' "$g" | tr '/' '_')"
  bash "$WALK" extract "$VKS/$g" "$d" || harness "walk.sh extract $g"
done
AR_PROG=$(blk ARGOCD-auto.md "3. Install the argocd program" 2)
AM_PROG=$(blk ARGOCD-manual.md "Install the argocd program" 2)
AR_RM=$(blk ARGOCD-auto.md "Delete what this guide installed and wrote")
AM_RM=$(blk ARGOCD-manual.md "Remove the argocd program")
SU_KC=$(blk SETUP.md "Install kubectl" 3)
SU_VCF=$(blk SETUP.md "Install the VCF CLI and its plugins" 2)
SU_HELM=$(blk SETUP.md "Install helm" 2)
for f in "$AR_PROG" "$AM_PROG" "$SU_KC" "$SU_VCF" "$SU_HELM" "$AR_RM" "$AM_RM"; do
  [ -s "$f" ] || harness "an install or clean-up block was not found (see the message above)"
done
{ grep -q 'gunzip -c "\$ARGOCD_GZ"' "$AR_PROG" && grep -q 'gunzip -c "\$ARGOCD_GZ"' "$AM_PROG"; } || harness "the second block of an argocd install section is not the install"
grep -q 'vsphere-plugin.zip' "$SU_KC" || harness "the third block under Install kubectl is not the Supervisor download"
grep -q 'plugin install all' "$SU_VCF" || harness "the second block under Install the VCF CLI is not the install"
grep -q 'get-helm-4' "$SU_HELM" || harness "the second block under Install helm is not the Linux install"
for f in "$AR_PROG" "$AM_PROG" "$SU_VCF" "$AR_RM" "$AM_RM" "$SU_HELM"; do
  grep -qx 'D=/usr/local/bin' "$f" || harness "$f does not name /usr/local/bin on a line of its own"
done
for f in "$AR_PROG" "$AM_PROG" "$SU_KC" "$SU_VCF" "$SU_HELM" "$AR_RM" "$AM_RM"; do
  n=$(sed -e 's/"[^"]*"//g' -e 's/sudo -n //g' "$f" | grep -c 'sudo' || true)
  eq "no sudo that could ask, outside the text a block prints, in $(basename "$(dirname "$f")")/$(basename "$f")" "$n" 0
done

# The install core is the same text in the four blocks, but for the program's name.
corelines() { sed -n '/^[[:space:]]*\[ -e "\$D" \] || mkdir -p "\$D" 2>\/dev\/null$/,/|| echo "WARNING: /p' "$1" | sed -e 's/^[[:space:]]*//' -e "s/$2/PROGRAM/g"; }
CORE=$(corelines "$AR_PROG" argocd)
eq "the install core has its 18 lines" "$(printf '%s\n' "$CORE" | grep -c .)" 18
eq "the install core: ARGOCD-manual equals ARGOCD-auto" "$(corelines "$AM_PROG" argocd)" "$CORE"
eq "the install core: the Supervisor kubectl equals ARGOCD-auto" "$(corelines "$SU_KC" kubectl)" "$CORE"
eq "the install core: the VCF CLI equals ARGOCD-auto" "$(corelines "$SU_VCF" vcf)" "$CORE"

for sh in $SHELLS; do
  for c in "argocd|ARGOCD-auto|$AR_PROG|argocd: v3.4.4+stand-in-vcf|$T/fix/argocd" \
           "argocd|ARGOCD-manual|$AM_PROG|argocd: v3.4.4+stand-in-vcf|$T/fix/argocd" \
           "kubectl|SETUP, kubectl from the Supervisor|$SU_KC|Client Version: v9.9.9-downloaded|$T/fix/kubectl" \
           "vcf|SETUP, the VCF CLI|$SU_VCF|version: v9.1.1-stand-in|$T/fix/vcfsrc/vcf-cli-linux_amd64"; do
    IFS='|' read -r p name blkf vline src <<<"$c"
    W="$T/dirs/w"; A="$T/dirs/afile/bin"

    L="[$sh] $name, a directory you may write to"
    icase; prep "$p" "$blkf" "$W"; run2 "$sh" "$RUNF"
    same "$L: installed there" "$W/$p" "$src"
    mode "$L: mode 755" "$W/$p"
    eq "$L: sudo is not called" "$(grep -c . "$T/fake/sudo.log" || true)" 0
    line "$L: the installed program answers" "$OUT" "$vline"
    line "$L: the PATH line" "$OUT" "$(path_line "$p" "$W")"
    line "$L: the line to add" "$OUT" "  export PATH=\"$W:\$PATH\""
    hasnt "$L: no fallback" "$OUT" "instead"
    hasnt "$L: no failure line" "$OUT" "Nothing installed"
    hasnt "$L: no warning" "$OUT" "WARNING"
    gone "$L: nothing in ~/.local/bin" "$LB/$p"

    L="[$sh] $name, the directory is on PATH"
    icase; prep "$p" "$blkf" "$W"; run2 "$sh" "$RUNF" "PATH=$W:$T/stub2:$T/stub:$PATH"
    same "$L: installed there" "$W/$p" "$src"
    hasnt "$L: no PATH line" "$OUT" "was not on your PATH"
    hasnt "$L: no warning" "$OUT" "WARNING"

    L="[$sh] $name, another $p comes first on PATH"
    icase; prep "$p" "$blkf" "$W"; printf '#!/bin/sh\necho "the other program ran"\n' > "$T/dirs/other/$p"; chmod +x "$T/dirs/other/$p"
    run2 "$sh" "$RUNF" "PATH=$T/dirs/other:$W:$T/stub2:$T/stub:$PATH"
    line "$L: the warning" "$OUT" "WARNING: '$p' on your PATH is '$T/dirs/other/$p', not $W/$p"
    line "$L: the installed program answers" "$OUT" "$vline"
    hasnt "$L: the block runs the one it installed, not the other" "$OUT" "the other program ran"

    L="[$sh] $name, sudo works without asking"
    icase SUDO_MODE=ok "SUDO_UNBLOCK=$T/dirs/afile"; prep "$p" "$blkf" "$A"; run2 "$sh" "$RUNF"
    line "$L: sudo -n makes the directory" "$(cat "$T/fake/sudo.log")" "-n install -d $A"
    has "$L: sudo -n installs with mode 0755" "$(grep -- " $A/$p\$" "$T/fake/sudo.log" || true)" "-n install -m 0755 "
    same "$L: installed there" "$A/$p" "$src"
    line "$L: the installed program answers" "$OUT" "$vline"
    hasnt "$L: no fallback" "$OUT" "instead"
    gone "$L: nothing in ~/.local/bin" "$LB/$p"

    L="[$sh] $name, sudo would ask"
    icase SUDO_MODE=refuse; prep "$p" "$blkf" "$A"; run2 "$sh" "$RUNF"
    same "$L: installed into ~/.local/bin" "$LB/$p" "$src"
    mode "$L: mode 755" "$LB/$p"
    line "$L: says where it went and how to change that" "$OUT" "$(fallback_line "$p" "$A" "$p")"
    line "$L: the PATH line" "$OUT" "$(path_line "$p" "$LB")"
    line "$L: the line to add" "$OUT" "  export PATH=\"$LB:\$PATH\""
    line "$L: the installed program answers" "$OUT" "$vline"
    hasnt "$L: no failure line" "$OUT" "Nothing installed"
    hasnt "$L: no warning" "$OUT" "WARNING"
    hasnt "$L: sudo's own error is not shown" "$OUT" "a password is required"

    L="[$sh] $name, sudo makes the directory and then refuses the copy"
    icase SUDO_MODE=half; prep "$p" "$blkf" "$A"; run2 "$sh" "$RUNF"
    has "$L: the copy was tried through sudo -n" "$(cat "$T/fake/sudo.log")" "-n install -m 0755 "
    same "$L: installed into ~/.local/bin" "$LB/$p" "$src"
    line "$L: says where it went" "$OUT" "$(fallback_line "$p" "$A" "$p")"
    hasnt "$L: no failure line" "$OUT" "Nothing installed"

    L="[$sh] $name, a directory of your own that does not exist yet"
    icase SUDO_MODE=ok; prep "$p" "$blkf" "$T/dirs/new/bin"; run2 "$sh" "$RUNF"
    same "$L: created and installed there" "$T/dirs/new/bin/$p" "$src"
    eq "$L: sudo is not called" "$(grep -c . "$T/fake/sudo.log" || true)" 0
    hasnt "$L: no fallback" "$OUT" "instead"
    gone "$L: nothing in ~/.local/bin" "$LB/$p"

    L="[$sh] $name, a directory has the program's name"
    icase SUDO_MODE=ok; mkdir "$W/$p"; prep "$p" "$blkf" "$W"; run2 "$sh" "$RUNF"
    if [ "$p" = argocd ]; then
      has "$L: refused" "$OUT" "Not installing: $W/argocd is another argocd."
    else
      line "$L: says so, naming it" "$OUT" "Nothing installed: $W/$p is a directory, where the $p program must go. Remove or rename it, then run this block again."
    fi
    hasnt "$L: does not say installed" "$OUT" "installed into"
    hasnt "$L: no version line" "$OUT" "$vline"
    emptydir "$L: nothing is copied into it" "$W/$p"
    eq "$L: sudo is not called" "$(grep -c . "$T/fake/sudo.log" || true)" 0
    gone "$L: nothing in ~/.local/bin" "$LB/$p"
    if [ "$p" != argocd ]; then
      L="[$sh] $name, a directory has the program's name in ~/.local/bin"
      icase SUDO_MODE=refuse; mkdir -p "$LB/$p"; prep "$p" "$blkf" "$A"; run2 "$sh" "$RUNF"
      line "$L: says so, naming it" "$OUT" "Nothing installed: $LB/$p is a directory, where the $p program must go. Remove or rename it, then run this block again."
      emptydir "$L: nothing is copied into it" "$LB/$p"
    fi

    L="[$sh] $name, nothing can be written"
    icase SUDO_MODE=refuse INSTALL_FAIL=1; prep "$p" "$blkf" "$W"; run2 "$sh" "$RUNF"
    line "$L: says so" "$OUT" "$NOTHING"
    hasnt "$L: no fallback line" "$OUT" "installed into"
    hasnt "$L: no version line" "$OUT" "$vline"
    gone "$L: nothing in the directory" "$W/$p"
  done

  # --- argocd: another argocd is never replaced -------------------------------------------------
  for c in "ARGOCD-auto|$AR_PROG" "ARGOCD-manual|$AM_PROG"; do
    IFS='|' read -r name blkf <<<"$c"
    L="[$sh] $name, another argocd in the directory"
    icase; cp "$T/fix/argocd-other" "$T/dirs/w/argocd"; prep argocd "$blkf" "$T/dirs/w"; run2 "$sh" "$RUNF"
    has "$L: refused, naming it" "$OUT" "Not installing: $T/dirs/w/argocd is another argocd."
    same "$L: it is untouched" "$T/dirs/w/argocd" "$T/fix/argocd-other"
    gone "$L: nothing in ~/.local/bin" "$LB/argocd"
    L="[$sh] $name, another argocd in ~/.local/bin"
    icase; mkdir -p "$LB"; cp "$T/fix/argocd-other" "$LB/argocd"; prep argocd "$blkf" "$T/dirs/w"; run2 "$sh" "$RUNF"
    has "$L: refused, naming it" "$OUT" "Not installing: $LB/argocd is another argocd."
    same "$L: it is untouched" "$LB/argocd" "$T/fix/argocd-other"
    gone "$L: nothing in the directory" "$T/dirs/w/argocd"
    L="[$sh] $name, this guide's argocd is already there"
    icase; printf '#!/bin/sh\necho "argocd: v3.4.3+stand-in-vcf"\n' > "$T/dirs/w/argocd"; chmod +x "$T/dirs/w/argocd"
    prep argocd "$blkf" "$T/dirs/w"; run2 "$sh" "$RUNF"
    same "$L: replaced" "$T/dirs/w/argocd" "$T/fix/argocd"
  done

  # --- the VCF CLI: a failed install never lets an older vcf answer ----------------------------
  L="[$sh] SETUP, the VCF CLI, an older vcf is there and nothing can be written"
  icase SUDO_MODE=refuse INSTALL_FAIL=1; cp "$T/fix/vcf-older" "$T/dirs/w/vcf"; prep vcf "$SU_VCF" "$T/dirs/w"
  run2 "$sh" "$RUNF" "PATH=$T/dirs/w:$T/stub2:$T/stub:$PATH"
  line "$L: says so" "$OUT" "$NOTHING"
  hasnt "$L: the older vcf is not run" "$OUT" "older vcf ran"
  hasnt "$L: the older version is not shown" "$OUT" "v0.0.1-older"
  same "$L: the older vcf is unchanged" "$T/dirs/w/vcf" "$T/fix/vcf-older"
  L="[$sh] SETUP, the VCF CLI, the plugins come from the installed vcf"
  icase SUDO_MODE=refuse; prep vcf "$SU_VCF" "$T/dirs/afile/bin"; run2 "$sh" "$RUNF"
  line "$L: plugins" "$OUT" "stand-in plugins installed from a local source"
  line "$L: the list" "$OUT" "stand-in-plugin  installed"

  L="[$sh] SETUP, the VCF CLI, vcf installs and its plugins do not"
  icase VCF_PLUGINS_FAIL=1; prep vcf "$SU_VCF" "$T/dirs/w"; run2 "$sh" "$RUNF"
  line "$L: says so" "$OUT" "vcf is installed; its plugins are not: see the error above"
  line "$L: the version still shows" "$OUT" "version: v9.1.1-stand-in"
  hasnt "$L: not the failure line of the program" "$OUT" "Nothing installed"

  # --- helm: the project's script, told where to install ---------------------------------------
  L="[$sh] SETUP, helm, a directory you may write to"
  icase; prep helm "$SU_HELM" "$T/dirs/w"; run2 "$sh" "$RUNF"
  line "$L: the script runs without sudo" "$OUT" "stand-in helm script: USE_SUDO=false HELM_INSTALL_DIR=unset"
  eq "$L: sudo is not called" "$(grep -c . "$T/fake/sudo.log" || true)" 0
  L="[$sh] SETUP, helm, sudo works without asking"
  icase SUDO_MODE=ok; prep helm "$SU_HELM" "$T/dirs/afile/bin"; run2 "$sh" "$RUNF"
  line "$L: the script runs as the project wrote it" "$OUT" "stand-in helm script: USE_SUDO=unset HELM_INSTALL_DIR=unset"
  hasnt "$L: no fallback" "$OUT" "instead"
  L="[$sh] SETUP, helm, sudo would ask"
  icase SUDO_MODE=refuse; prep helm "$SU_HELM" "$T/dirs/afile/bin"; run2 "$sh" "$RUNF"
  line "$L: the script is sent to ~/.local/bin, without sudo" "$OUT" "stand-in helm script: USE_SUDO=false HELM_INSTALL_DIR=$LB"
  hasnt "$L: the script finds helm on PATH" "$OUT" "helm not found"
  line "$L: says where it went and how to change that" "$OUT" "$(fallback_line helm "$T/dirs/afile/bin" helm)"
  line "$L: the PATH line" "$OUT" "$(path_line helm "$LB")"
  line "$L: the line to add" "$OUT" "  export PATH=\"$LB:\$PATH\""

  hasnt "$L: no failure line" "$OUT" "Nothing installed"
  same "$L: the script wrote helm there" "$LB/helm" <(printf '#!/bin/sh\necho stand-in-new-helm\n')
  L="[$sh] SETUP, helm, sudo would ask, ~/.local/bin is on PATH"
  icase SUDO_MODE=refuse; prep helm "$SU_HELM" "$T/dirs/afile/bin"; run2 "$sh" "$RUNF" "PATH=$LB:$T/stub2:$T/stub:$PATH"
  line "$L: says where it went" "$OUT" "$(fallback_line helm "$T/dirs/afile/bin" helm)"
  hasnt "$L: no PATH line" "$OUT" "was not on your PATH"
  for arm in "a directory you may write to|$T/dirs/w|SUDO_MODE=refuse" "sudo works without asking|$T/dirs/afile/bin|SUDO_MODE=ok" "sudo would ask|$T/dirs/afile/bin|SUDO_MODE=refuse"; do
    IFS='|' read -r an ad am <<<"$arm"
    L="[$sh] SETUP, helm, $an, the download fails"
    icase "$am" HELM_DL=fail; mkdir -p "$LB"; printf '#!/bin/sh\necho stand-in-old-helm\n' > "$LB/helm"; chmod +x "$LB/helm"
    prep helm "$SU_HELM" "$ad"; run2 "$sh" "$RUNF"
    line "$L: says so" "$OUT" "$NOTHING"
    hasnt "$L: does not say installed" "$OUT" "installed into"
    hasnt "$L: no PATH line" "$OUT" "was not on your PATH"
    hasnt "$L: the script did not run" "$OUT" "stand-in helm script"
    L="[$sh] SETUP, helm, $an, the script fails"
    icase "$am" HELM_SCRIPT_FAIL=1; mkdir -p "$LB"; printf '#!/bin/sh\necho stand-in-old-helm\n' > "$LB/helm"; chmod +x "$LB/helm"
    prep helm "$SU_HELM" "$ad"; run2 "$sh" "$RUNF"
    has "$L: the script ran" "$OUT" "stand-in helm script: USE_SUDO="
    line "$L: says so" "$OUT" "$NOTHING"
    hasnt "$L: does not say installed" "$OUT" "installed into"
    hasnt "$L: no PATH line" "$OUT" "was not on your PATH"
  done
  L="[$sh] SETUP, helm, sudo would ask, ~/.local cannot be made"
  icase SUDO_MODE=refuse; : > "$T/home/.local"; prep helm "$SU_HELM" "$T/dirs/afile/bin"; run2 "$sh" "$RUNF"
  line "$L: says so" "$OUT" "$NOTHING"
  hasnt "$L: no PATH line for a directory that is not there" "$OUT" "was not on your PATH"
  hasnt "$L: the script did not run" "$OUT" "stand-in helm script"
  rm -f "$T/home/.local"

  # --- argocd: the clean-up removes this guide's argocd and no other ---------------------------
  for c in "ARGOCD-auto|$AR_RM" "ARGOCD-manual|$AM_RM"; do
    IFS='|' read -r name blkf <<<"$c"
    L="[$sh] $name clean-up, this guide's argocd in both directories"
    icase; mkdir -p "$LB"; cp "$T/fix/argocd" "$LB/argocd"; cp "$T/fix/argocd" "$T/dirs/w/argocd"
    withdir "$blkf" "$T/dirs/w"; run2 "$sh" "$SUBST"
    gone "$L: removed from ~/.local/bin" "$LB/argocd"
    gone "$L: removed from the directory" "$T/dirs/w/argocd"
    eq "$L: sudo is not called" "$(grep -c . "$T/fake/sudo.log" || true)" 0
    eq "$L: no output" "$OUT" ""
    L="[$sh] $name clean-up, another argocd in both directories"
    icase; mkdir -p "$LB"; cp "$T/fix/argocd-other" "$LB/argocd"; cp "$T/fix/argocd-other" "$T/dirs/w/argocd"
    withdir "$blkf" "$T/dirs/w"; run2 "$sh" "$SUBST"
    same "$L: untouched in ~/.local/bin" "$LB/argocd" "$T/fix/argocd-other"
    same "$L: untouched in the directory" "$T/dirs/w/argocd" "$T/fix/argocd-other"
    eq "$L: no output" "$OUT" ""
    if [ "$(id -u)" = 0 ]; then
      echo "SKIP  [$sh] $name clean-up, a directory you may not write to (the test runs as root, which may write anywhere)"
    else
      L="[$sh] $name clean-up, a directory you may not write to, sudo would ask"
      icase SUDO_MODE=refuse; cp "$T/fix/argocd" "$T/dirs/w/argocd"; chmod 555 "$T/dirs/w"
      withdir "$blkf" "$T/dirs/w"; run2 "$sh" "$SUBST"
      line "$L: says who can remove it, and the command" "$OUT" "Left in place: $T/dirs/w/argocd is in a directory you may not write to. An administrator must remove it; with sudo rights, run: sudo rm -f $T/dirs/w/argocd"
      same "$L: left in place" "$T/dirs/w/argocd" "$T/fix/argocd"
      L="[$sh] $name clean-up, a directory you may not write to, sudo works without asking"
      icase SUDO_MODE=ok "SUDO_UNBLOCK=$T/dirs/w"; cp "$T/fix/argocd" "$T/dirs/w/argocd"; chmod 555 "$T/dirs/w"
      withdir "$blkf" "$T/dirs/w"; run2 "$sh" "$SUBST"
      line "$L: removed through sudo -n" "$(cat "$T/fake/sudo.log")" "-n rm -f $T/dirs/w/argocd"
      gone "$L: removed" "$T/dirs/w/argocd"
      eq "$L: no output" "$OUT" ""
    fi
  done

  # --- kubectl_install: the same three places -------------------------------------------------
  ki2() { # <label> <KUBECTL_DIR> [NAME=value...]: an install of v1.36.2 with no kubectl before
    L=$1; local d=$2; shift 2
    icase CUR_KUBECTL= ${1+"$@"}
    ovr "export WANT_V='v1.36.2'"; ovr "export KUBECTL_DIR='$d'"
    run2 "$sh" "$T/fix/install.sh"
  }
  ki2 "[$sh] kubectl_install, sudo works without asking" "$T/dirs/afile/bin" SUDO_MODE=ok "SUDO_UNBLOCK=$T/dirs/afile"
  line "$L: sudo -n makes the directory" "$(cat "$T/fake/sudo.log")" "-n install -d $T/dirs/afile/bin"
  has "$L: sudo -n installs with mode 0755" "$(cat "$T/fake/sudo.log")" "-n install -m 0755 "
  same "$L: installed there" "$T/dirs/afile/bin/kubectl" "$T/fix/kubectl"
  line "$L: returns 0" "$OUT" "returned 0"
  ki2 "[$sh] kubectl_install, sudo would ask" "$T/dirs/afile/bin" SUDO_MODE=refuse
  same "$L: installed into ~/.local/bin" "$LB/kubectl" "$T/fix/kubectl"
  line "$L: says where it went and how to change that" "$OUT" "$(fallback_line kubectl_install "$T/dirs/afile/bin" kubectl)"
  line "$L: the PATH line names the three start files" "$OUT" "$(path_line kubectl_install "$LB")"
  line "$L: returns 0" "$OUT" "returned 0"
  hasnt "$L: sudo's own error is not shown" "$OUT" "a password is required"
  ki2 "[$sh] kubectl_install, sudo makes the directory and then refuses the copy" "$T/dirs/afile/bin" SUDO_MODE=half
  same "$L: installed into ~/.local/bin" "$LB/kubectl" "$T/fix/kubectl"
  line "$L: returns 0" "$OUT" "returned 0"
  hasnt "$L: not the old failure" "$OUT" "NOT changed"
  L="[$sh] kubectl_install, a directory has the program's name"
  icase CUR_KUBECTL= SUDO_MODE=ok; mkdir "$T/dirs/w/kubectl"
  ovr "export WANT_V='v1.36.2'"; ovr "export KUBECTL_DIR='$T/dirs/w'"; run2 "$sh" "$T/fix/install.sh"
  has "$L: says so, naming it" "$OUT" "kubectl_install: $T/dirs/w/kubectl is a directory, where the kubectl program must go: remove or rename it — kubectl NOT changed"
  line "$L: returns 1" "$OUT" "returned 1"
  emptydir "$L: nothing is copied into it" "$T/dirs/w/kubectl"
  ki2 "[$sh] kubectl_install, nothing can be written" "$T/dirs/afile/bin" SUDO_MODE=refuse INSTALL_FAIL=1
  has "$L: says so" "$OUT" "kubectl_install: could not write $LB/kubectl (see the error above) — kubectl NOT changed"
  line "$L: returns 1" "$OUT" "returned 1"
done

if [ "$fails" -eq 0 ]; then echo "guide block tests: all $checks checks passed"; else echo "guide block tests: $fails of $checks FAILED"; exit 1; fi
