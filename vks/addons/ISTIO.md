# Istio: a service mesh and a gateway for the guest cluster

[Istio](https://istio.io/) adds two things to a cluster: a *gateway*, which brings traffic from
outside to your apps through one address, and a *mesh*, which puts a small proxy beside each app
pod. This chapter installs Istio as a VKS add-on and brings `golang-web` behind a gateway. The
mesh part is an option at the end.

This chapter is optional and comes after the main guide's deploy step: `golang-web` runs on the
guest cluster. You need [the main guide](../README.md)'s env file, its Supervisor login, the
guest cluster's kubeconfig, and `envsubst` ([Install envsubst](../SETUP.md#install-envsubst)).
Your SSO user needs the **Edit** role on the vSphere Namespace. It was written for VMware Cloud
Foundation 9.1.1 and VKS 3.7.

Istio is installed from the **Supervisor**: you describe it in one object there, and VKS puts it
into the guest cluster. What you do with it afterwards (the gateway, the route) is done on the
**guest cluster**. Each block says which one it talks to.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside
your `golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where
it can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells
you what to do.

## What Istio changes in the main guide

| in the main guide | without Istio | with Istio |
|---|---|---|
| the app's Service | type `LoadBalancer`: the app has an address of its own | type `ClusterIP`: reachable only inside the cluster |
| how you reach the app | `http://<the Service's address>:8080/myhello/` | `http://<the gateway's address>/myhello/` (port 80) |

Nothing else in the main guide changes.

## What Istio adds to the nodes

| what | where it runs | what it asks for |
|---|---|---|
| `istiod`, Istio's control program | worker nodes only | 2 GB of memory per copy, and two copies, unless you change it below |
| `istio-cni-node` | every node, one pod each | little |
| one proxy pod per gateway | worker nodes | little |
| one proxy beside each app pod, only if you switch on the mesh | with the app | little per pod |

Two workers of 4 GB cannot hold two copies of `istiod` at 2 GB each beside your apps: the copies
stay `Pending`. Either make the workers larger
([Choose the cluster's values](../CLUSTER.md#choose-the-clusters-values) has the row), or keep
this chapter's settings, which ask for one copy with 1 GB. One copy means Istio's control
program is away while its node is replaced; gateways and proxies that already run keep working
during that time.

## Add Istio's settings

This adds Istio's nine settings to your env file, each only if it is not there yet. Values you
already set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export ADDON_CATALOG_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ADDON_CATALOG_NAMESPACE="vmware-system-vks-public"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_VERSION=""' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_PILOT_REPLICAS=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_PILOT_REPLICAS="1"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_PILOT_MEMORY=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_PILOT_MEMORY="1024Mi"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_SYSTEM_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_SYSTEM_NAMESPACE="istio-system"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_GATEWAY_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_GATEWAY_NAMESPACE="istio-ingress"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_GATEWAY=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_GATEWAY="golang-web-gateway"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_APP_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_APP_NAMESPACE="golang-web"' >> ~/.vks-golang-web.env
  grep -qs '^export ISTIO_WAIT_MINUTES=' ~/.vks-golang-web.env || printf '%s\n' 'export ISTIO_WAIT_MINUTES="15"' >> ~/.vks-golang-web.env
  grep -c -E '^export (ADDON_CATALOG_NAMESPACE|ISTIO_VERSION|ISTIO_PILOT_REPLICAS|ISTIO_PILOT_MEMORY|ISTIO_SYSTEM_NAMESPACE|ISTIO_GATEWAY_NAMESPACE|ISTIO_GATEWAY|ISTIO_APP_NAMESPACE|ISTIO_WAIT_MINUTES)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `9`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 9 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

| setting | meaning |
|---|---|
| `ISTIO_VERSION` | the Istio release to install; empty until you choose one below |
| `ISTIO_PILOT_REPLICAS` | how many copies of `istiod` run: `1` here, `2` is VKS's own default |
| `ISTIO_PILOT_MEMORY` | the memory each copy asks for: `1024Mi` here, `2048Mi` is VKS's own default |
| `ISTIO_SYSTEM_NAMESPACE` | the namespace on the guest cluster Istio runs in. The add-on uses `istio-system`; this chapter only reads it |
| `ISTIO_GATEWAY_NAMESPACE` | the namespace this chapter creates for the gateway |
| `ISTIO_GATEWAY` | the gateway's name |
| `ISTIO_APP_NAMESPACE` | the namespace `golang-web` runs in |
| `ISTIO_WAIT_MINUTES` | how long *Wait for Istio* waits |
| `ADDON_CATALOG_NAMESPACE` | where the Supervisor keeps its add-on catalogue |

## Choose the Istio release

This lists the Istio releases your Supervisor offers, oldest first. It is read-only.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease -o name | sed -n 's|^.*/istio\.kubernetes\.vmware\.com\.||p' | sort -t. -k1,1n -k2,2n -k3,3n
```

**Expect:** one release per line, such as `1.30.4-vmware.1-vks.1`. Which ones you see depends on
your VKS version. Take the newest unless you need another one: Broadcom's release notes for your
VKS version say which Istio releases go with which Kubernetes versions.

**If not:**
- No output: this Supervisor's catalogue has no Istio. Right after VKS was installed or
  updated the catalogue arrives over about ten minutes: run the block again then. If it stays
  empty, tell your administrator.
- `the server doesn't have a resource type "addonrelease"`: this Supervisor's VKS has no add-on
  catalogue; this chapter cannot be used on it.
- `Unauthorized`: run the main guide's *Renew the Supervisor login* block.

Open the env file and set `ISTIO_VERSION` to one line of the list, exactly as printed:

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
block reads the new value.

Later, to move to a newer release, set `ISTIO_VERSION` to it and run the next two blocks again.
Do not go back to an older release that way: VKS writes the older settings over the newer ones
and does not undo what the newer release changed.

## Fill and check the install description

This fills [`templates/addoninstall.yaml`](templates/addoninstall.yaml) from your env file, saves
the result as `~/.config/vks-golang-web/istio-addoninstall.yaml`, shows it, and asks the
Supervisor to check it without creating anything (`--dry-run=server`). It first checks that the
release exists: the Supervisor accepts an install description that names a release it does not
have, and then never installs anything.

```sh
source ~/.vks-golang-web.env
export ADDON_NAME="istio" ADDON_INSTALL="${VKS_CLUSTER}-istio-addon" ADDON_RELEASE="istio.kubernetes.vmware.com.${ISTIO_VERSION//+/-}"
OUT="$HOME/.config/vks-golang-web/istio-addoninstall.yaml"
M=""
for v in VKS_CLUSTER VKS_NAMESPACE ADDON_CATALOG_NAMESPACE ISTIO_VERSION; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
REL=""
[ -n "$M" ] || REL="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease "$ADDON_RELEASE" --ignore-not-found -o name)" || REL=unknown
if [ -n "$M" ]; then
  echo "Not filled: no value for:$M"
elif [ "$REL" = unknown ]; then
  echo "Not filled: the Supervisor did not answer (see the error above)"
elif [ -z "$REL" ]; then
  echo "Not filled: the Supervisor offers no Istio release '${ISTIO_VERSION}'. Set ISTIO_VERSION to a line from 'Choose the Istio release'."
elif [ ! -f vks/addons/templates/addoninstall.yaml ]; then
  echo "Not filled: run this block from inside your golang-web clone"
elif ! command -v envsubst >/dev/null 2>&1; then
  echo "Not filled: envsubst is missing (SETUP.md, 'Install envsubst')"
else
  mkdir -p "$(dirname "$OUT")"
  ( umask 077; envsubst '${ADDON_INSTALL} ${VKS_NAMESPACE} ${ADDON_NAME} ${ADDON_CATALOG_NAMESPACE} ${VKS_CLUSTER} ${ADDON_RELEASE}' \
      < vks/addons/templates/addoninstall.yaml > "$OUT" )
  grep -v '^#' "$OUT"
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply --dry-run=server -f "$OUT"
fi
```

**Expect:** the description, with your cluster's name in `name:` and in the `matchLabels` line,
your vSphere Namespace, the release name, and no `${` left in it; then
`addoninstall.addons.kubernetes.vmware.com/<your cluster>-istio-addon created (server dry run)`
(`configured` or `unchanged` when Istio is already installed).

**If not:**
- `Not filled: no value for: …`: each name listed is empty in the env file, or its line lacks
  the word `export`.
- `Not filled: the Supervisor offers no Istio release …`: `ISTIO_VERSION` is not a line of the
  list. Copy one again.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.
- `no matches for kind "AddonInstall"`: this Supervisor's VKS has no add-on catalogue.

## Install Istio

This applies the description on the Supervisor and waits (up to five minutes) until VKS has
taken it up: VKS then creates two objects of its own in your vSphere Namespace, both named
`<your cluster>-istio` — a `ClusterAddon`, which reports how the install goes, and an
`AddonConfig`, which holds the settings. VKS starts installing Istio at once, at its own default
size; the next block sets the size, and VKS then changes the Istio that runs.

The block refuses an `AddonInstall` of that name that this guide did not make, and a cluster
that already has Istio from another `AddonInstall`: two of them would fight over one cluster.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/istio-addoninstall.yaml"
AI="${VKS_CLUSTER}-istio-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-istio" --ignore-not-found -o name)" || CA=unknown
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not installed: VKS_CLUSTER is empty"
elif [ "$(awk '$1 == "name:" {print $2; exit}' "$OUT" 2>/dev/null)" != "$AI" ]; then
  echo "Not installed: the filled description is missing, or is for another cluster. Run 'Fill and check the install description' again."
elif [ "$MINE" = unknown ] || [ "$CA" = unknown ]; then
  echo "Not installed: the Supervisor did not answer (see the error above)"
elif [ -n "$MINE" ] && [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not installed: an AddonInstall '${AI}' exists and this guide did not make it. Nothing was changed."
elif [ -z "$MINE" ] && [ -n "$CA" ]; then
  echo "Not installed: '${VKS_CLUSTER}' already has Istio from another AddonInstall. Nothing was changed: use that Istio, or ask who installed it."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply -f "$OUT"; then
  n=0; CN=""
  until [ "$CN" = "$VKS_CLUSTER" ] || [ "$n" -ge 30 ]; do
    sleep 10; n=$((n + 1))
    CN="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "${VKS_CLUSTER}-istio" --ignore-not-found -o jsonpath='{.spec.clusterName}' 2>/dev/null)"
  done
  if [ "$CN" = "$VKS_CLUSTER" ]; then
    echo "taken up after $((n * 10)) s: VKS made the settings object ${VKS_CLUSTER}-istio"
  else
    echo "NOT TAKEN UP after $((n * 10)) s: VKS has not made the settings object ${VKS_CLUSTER}-istio. Read 'If not' below."
  fi
else
  echo "Not installed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:** `addoninstall.addons.kubernetes.vmware.com/<your cluster>-istio-addon created`
(`unchanged` when you run it again), then `taken up after … s: VKS made the settings object
<your cluster>-istio`.

**If not:**
- `Not installed: the filled description is missing …`: you changed `VKS_CLUSTER` after filling
  the file, or did not fill it. Run the block above again.
- `Not installed: … already has Istio from another AddonInstall`: Istio is on the cluster
  already. Go on with *Check Istio on the guest cluster*; this guide's uninstall block will not
  remove it.
- `NOT TAKEN UP after 300 s`: VKS did not match the description with your cluster. This shows
  what it says:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "${VKS_CLUSTER}-istio-addon" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'`.
  Check that `VKS_CLUSTER` is a cluster in `VKS_NAMESPACE`
  (`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io`).

## Set Istio's size

Istio's settings live in the `AddonConfig` that VKS made. **You change that object; you never
create one.** An `AddonConfig` you create yourself is accepted, stored, and applies nothing: VKS
acts only on the one it made for the cluster, and nothing tells you so.

This writes `ISTIO_PILOT_REPLICAS` and `ISTIO_PILOT_MEMORY` into that object and waits (up to two
minutes) until VKS has worked them in. It replaces all values in the object with these two: a
value somebody else set there is removed. It refuses an object that VKS did not make.

```sh
source ~/.vks-golang-web.env
AC="${VKS_CLUSTER}-istio"
WANT="$(jq -cn --arg r "$ISTIO_PILOT_REPLICAS" --arg m "$ISTIO_PILOT_MEMORY" 'if ($r | test("^[1-9][0-9]*$")) and ($m | test("^[1-9][0-9]*(Mi|Gi)$")) then {istio: {pilot: {replicas: ($r | tonumber), resources: {requests: {memory: $m}}}}} else empty end')"
CUR="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "$AC" -o json)" || CUR=""
CN="$(printf '%s' "$CUR" | jq -r '.spec.clusterName // empty' 2>/dev/null)"
H0="$(printf '%s' "$CUR" | jq -r '.status.outputHash // empty' 2>/dev/null)"
if [ -z "$WANT" ]; then
  echo "Not changed: ISTIO_PILOT_REPLICAS must be a whole number from 1 (it is '${ISTIO_PILOT_REPLICAS}') and ISTIO_PILOT_MEMORY a number with Mi or Gi (it is '${ISTIO_PILOT_MEMORY}')"
elif [ -z "$CUR" ]; then
  echo "Not changed: the settings object '${AC}' could not be read (see the error above). Run 'Install Istio' first."
elif [ "$CN" != "$VKS_CLUSTER" ]; then
  echo "Not changed: '${AC}' is not an object VKS made for this cluster (its cluster name is '${CN:-empty}'), so VKS would ignore it."
elif [ "$(printf '%s' "$CUR" | jq -cS '.spec.values // {}')" = "$(printf '%s' "$WANT" | jq -cS .)" ]; then
  echo "unchanged: ${AC} already holds $(printf '%s' "$WANT" | jq -c .istio.pilot)"
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" patch addonconfig "$AC" --type=json -p "$(jq -cn --argjson v "$WANT" '[{op: "add", path: "/spec/values", value: $v}]')"; then
  n=0; H1="$H0"; V=""
  until { [ -n "$H1" ] && [ "$H1" != "$H0" ]; } || [ "$V" = False ] || [ "$n" -ge 24 ]; do
    sleep 5; n=$((n + 1))
    H1="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "$AC" -o jsonpath='{.status.outputHash}' 2>/dev/null)"
    V="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "$AC" -o jsonpath='{.status.conditions[?(@.type=="ValidConfig")].status}' 2>/dev/null)"
  done
  if [ "$V" = False ]; then
    echo "REFUSED by VKS:"
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "$AC" -o jsonpath='{range .status.fieldErrors[*]}{.field}{": "}{.detail}{"\n"}{end}'
  elif [ -n "$H1" ] && [ "$H1" != "$H0" ]; then
    echo "worked in after $((n * 5)) s: $(printf '%s' "$WANT" | jq -c .istio.pilot)"
  else
    echo "NOT WORKED IN after $((n * 5)) s: the settings are stored, but VKS has not used them yet. Read 'If not' below."
  fi
else
  echo "Not changed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:** `addonconfig.addons.kubernetes.vmware.com/<your cluster>-istio patched`, then
`worked in after … s: {"replicas":1,"resources":{"requests":{"memory":"1024Mi"}}}`. When you run
it again with the same values: `unchanged: <your cluster>-istio already holds …`.

**If not:**
- `Not changed: … could not be read`, under `NotFound`: *Install Istio* has not ended with
  `taken up`. Run it first.
- `Not changed: … is not an object VKS made for this cluster`: somebody created an `AddonConfig`
  of that name by hand, before Istio was installed. Ask them; this chapter does not delete it.
- `REFUSED by VKS:` and a line that names a setting: the value has the wrong form. Fix it in the
  env file and run the block again.
- `NOT WORKED IN after 120 s`: run the block again; it then waits again or prints `unchanged`.
  If `istiod` on the guest cluster (*Check Istio on the guest cluster*) still shows the old
  values after that, tell your administrator.

VKS does not check setting names: a misspelled name in that object is accepted and dropped
without a word. This block writes only the two names above.

## Wait for Istio

This waits until VKS reports Istio ready on your cluster, and prints one line every 15 seconds.
On a small lab it took under a minute. It gives up after `ISTIO_WAIT_MINUTES` (15); run the
block again to keep waiting.

```sh
source ~/.vks-golang-web.env
MIN="${ISTIO_WAIT_MINUTES:-15}"
case "$MIN" in
  ''|*[!0-9]*) echo "ISTIO_WAIT_MINUTES is '${MIN}', not a whole number: waiting 15 minutes"; MIN=15 ;;
esac
n=0; R=""; MAX=$((MIN * 4))
if kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-istio" -o name; then
  until [ "$R" = True ] || [ "$n" -ge "$MAX" ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    R="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-istio" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    W="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-istio" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)"
    echo "$(((n - 1) * 15)) s: Ready=${R:-not yet}  ${W}"
  done
  [ "$R" = True ] || echo "NOT READY after $(((n - 1) * 15)) s. Run this block again to keep waiting, or read 'If not' below."
else
  echo "Not waiting: VKS has no ClusterAddon '${VKS_CLUSTER}-istio' (see the error above). Run 'Install Istio' first."
fi
```

**Expect:** `clusteraddon.addons.kubernetes.vmware.com/<your cluster>-istio`, then lines such as
`15 s: Ready=False  …`, the last one with `Ready=True`.

**If not:**
- `NOT READY after …`: look at Istio's pods on the guest cluster:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_SYSTEM_NAMESPACE" get pods`. An `istiod`
  pod that stays `Pending` does not fit on the workers:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_SYSTEM_NAMESPACE" describe pod -l app=istiod`
  ends with `Insufficient memory`. Lower `ISTIO_PILOT_MEMORY` or `ISTIO_PILOT_REPLICAS` and run
  *Set Istio's size* again, or add workers (*What Istio adds to the nodes*).
- `ImagePullBackOff` on those pods: the cluster's nodes cannot reach Broadcom's registry
  (`projects.packages.broadcom.com`).
- `Not waiting: …`: *Install Istio* did not end with `taken up`.

## Check Istio on the guest cluster

The Supervisor's `Ready=True` is VKS's report. This looks at the guest cluster itself.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_SYSTEM_NAMESPACE" get deployment istiod -o jsonpath='istiod: {.status.readyReplicas} of {.spec.replicas} ready, memory asked for: {.spec.template.spec.containers[0].resources.requests.memory}{"\n"}'
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_SYSTEM_NAMESPACE" get daemonset istio-cni-node -o jsonpath='istio-cni-node: {.status.numberReady} of {.status.desiredNumberScheduled} ready{"\n"}'
echo "Istio's admission webhooks: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -c -i istio)"
```

**Expect:** `istiod: 1 of 1 ready, memory asked for: 1024Mi` (your two settings),
`istio-cni-node: <n> of <n> ready` with one per node, and `Istio's admission webhooks: 2` or
more.

**If not:**
- `istiod: 2 of 2 ready, memory asked for: 2048Mi` while your settings say otherwise: the
  settings were not worked in. Run *Set Istio's size* again and read its last line.
- `istiod:  of 1 ready` (no first number): the pod is not ready yet; wait and run the block
  again. If it stays, see *Wait for Istio*, **If not**.
- `NotFound`: Istio is not on this cluster, or `ISTIO_SYSTEM_NAMESPACE` is not where it runs:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" get deployments --all-namespaces | grep istiod` shows
  the namespace.

## Check that the cluster can make gateways

Istio installs **no gateway** by itself: after the steps above nothing listens for traffic from
outside. You create a gateway with the Kubernetes Gateway API: a `Gateway` object, for which
Istio starts a proxy pod and a `LoadBalancer` Service, and an `HTTPRoute` that sends requests
from it to the app.

This checks that the Gateway API is on the cluster and that Istio serves it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io -o name
kubectl --kubeconfig "$GUEST_KUBECONFIG" get gatewayclasses.gateway.networking.k8s.io istio -o jsonpath='GatewayClass istio: Accepted={.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
```

**Expect:** two lines that start with `customresourcedefinition.apiextensions.k8s.io/`, then
`GatewayClass istio: Accepted=True`.

**If not:**
- `customresourcedefinitions… "gateways.gateway.networking.k8s.io" not found`: the cluster has
  no Gateway API. On VKS it is an add-on of its own, `gateway-api`, which VKS installs on new
  clusters by itself. This shows whether your cluster has it:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-gateway-api"`.
  If it is missing, ask your administrator; do not install the Gateway API from the internet
  beside VKS's own.
- `gatewayclasses… "istio" not found` while the first two lines are there: `istiod` started
  before the Gateway API was on the cluster. Restart it:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_SYSTEM_NAMESPACE" rollout restart deployment istiod`,
  wait a minute, and run the block again.

## Create the gateway's namespace

The gateway gets a namespace of its own, so that its rights and its Pod Security level are
separate from your app's. A guest cluster accepts only pods of the Pod Security level
`restricted` unless a namespace says otherwise; this namespace says `baseline`, the level meant
for infrastructure pods such as a gateway's proxy. *Check whether the gateway needs `baseline`*
below shows whether your Istio release needs it.

This creates the namespace, marked as made by this guide. It refuses a namespace of that name
that it did not create.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$ISTIO_GATEWAY_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || NS=unknown
if [ -z "$ISTIO_GATEWAY_NAMESPACE" ]; then
  echo "Not created: ISTIO_GATEWAY_NAMESPACE is empty"
elif [ "$NS" = unknown ]; then
  echo "Not created: the guest cluster did not answer (see the error above)"
elif [ "$NS" = "${ISTIO_GATEWAY_NAMESPACE}/addons-guide" ]; then
  echo "namespace/${ISTIO_GATEWAY_NAMESPACE} is already there, made by this guide"
elif [ -n "$NS" ]; then
  echo "Not created: a namespace '${ISTIO_GATEWAY_NAMESPACE}' exists and this guide did not make it. Set ISTIO_GATEWAY_NAMESPACE to another name."
else
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    vks-golang-web/created-by: addons-guide\n    pod-security.kubernetes.io/enforce: baseline\n' "$ISTIO_GATEWAY_NAMESPACE" \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" create -f -
fi
```

**Expect:** `namespace/istio-ingress created`, or `namespace/istio-ingress is already there, made
by this guide` when you run it again.

**If not:** `Not created: a namespace … exists and this guide did not make it` — set
`ISTIO_GATEWAY_NAMESPACE` in the env file to a name that is free, then run the block again.

## Make the app's Service internal

With a gateway in front, the app needs no address of its own. If the app's Service is a
`LoadBalancer` (the main guide's alternative deploy), this changes it to `ClusterIP` and notes on
the Service what it was, so that removing the gateway can put it back; the cluster then gives the
Service's address back. A Service that is already `ClusterIP` (the main guide's default) is left
as it is.

Skip this block if you want to keep both ways in. The app is then also reachable directly, past
the gateway, on every path it serves.

```sh
source ~/.vks-golang-web.env
T="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get service golang-web-service -o jsonpath='{.spec.type}')"
if [ "$T" = LoadBalancer ]; then
  kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" annotate service golang-web-service vks-golang-web/type-before-gateway=LoadBalancer --overwrite
  kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" patch service golang-web-service --type=merge -p '{"spec":{"type":"ClusterIP"}}'
fi
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get service golang-web-service
```

**Expect:** the Service with `TYPE` `ClusterIP` and `EXTERNAL-IP` `<none>`; before it, when the
Service was a `LoadBalancer`, `service/golang-web-service annotated` and
`service/golang-web-service patched`.

**If not:** `services "golang-web-service" not found` — the app is not deployed in
`ISTIO_APP_NAMESPACE`: do the main guide's deploy step first.

Deploying the app again with the main guide's `LoadBalancer` alternative makes the Service a
`LoadBalancer` again; run this block after such a deploy.

If ArgoCD deployed the app ([ARGOCD-app.md](../ARGOCD-app.md)), it puts back whatever this block
and the mesh option below change by hand (its `selfHeal`). Choose the Service's type there, with
`APP_SERVICE_TYPE`, and make the mesh change in Git (that chapter's *Use your own Git
repository*).

## Create the gateway and the route

This fills [`templates/istio-gateway.yaml`](templates/istio-gateway.yaml) and applies it to the
guest cluster: a `Gateway` in the gateway's namespace, listening on port 80, and an `HTTPRoute`
in the app's namespace that sends requests under `/myhello` to the app. Only the app's namespace
may attach routes to this gateway, and only `/myhello` is routed: the app's other paths cannot
be reached through it. Then it waits (up to five minutes) for the gateway's address.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/istio-gateway.yaml"
M=""
for v in ISTIO_GATEWAY ISTIO_GATEWAY_NAMESPACE ISTIO_APP_NAMESPACE; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
L=""
[ -n "$M" ] || L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$ISTIO_GATEWAY_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ -n "$M" ]; then
  echo "Not applied: no value for:$M"
elif [ "$L" != addons-guide ]; then
  echo "Not applied: the namespace '${ISTIO_GATEWAY_NAMESPACE}' is missing, was not made by this guide, or could not be read. Run 'Create the gateway's namespace' first."
elif ! kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get service golang-web-service -o name; then
  echo "Not applied: no Service 'golang-web-service' in '${ISTIO_APP_NAMESPACE}' (see the error above). Deploy the app first."
elif [ ! -f vks/addons/templates/istio-gateway.yaml ]; then
  echo "Not applied: run this block from inside your golang-web clone"
elif ! command -v envsubst >/dev/null 2>&1; then
  echo "Not applied: envsubst is missing (SETUP.md, 'Install envsubst')"
else
  mkdir -p "$(dirname "$OUT")"
  ( umask 077; envsubst '${ISTIO_GATEWAY} ${ISTIO_GATEWAY_NAMESPACE} ${ISTIO_APP_NAMESPACE}' \
      < vks/addons/templates/istio-gateway.yaml > "$OUT" )
  if kubectl --kubeconfig "$GUEST_KUBECONFIG" apply -f "$OUT"; then
    n=0; P=""; A=""
    until { [ "$P" = True ] && [ -n "$A" ]; } || [ "$n" -ge 30 ]; do
      sleep 10; n=$((n + 1))
      P="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_GATEWAY_NAMESPACE" get gateways.gateway.networking.k8s.io "$ISTIO_GATEWAY" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
      A="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_GATEWAY_NAMESPACE" get gateways.gateway.networking.k8s.io "$ISTIO_GATEWAY" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
      echo "$((n * 10)) s: Programmed=${P:-not yet}  address=${A:-none yet}"
    done
    echo "route accepted by the gateway: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get httproutes.gateway.networking.k8s.io golang-web -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
    { [ "$P" = True ] && [ -n "$A" ]; } || echo "NO ADDRESS after $((n * 10)) s: read 'If not' below"
  else
    echo "Not applied: the guest cluster refused (see the error above), so nothing is waited for."
  fi
fi
```

**Expect:** `service/golang-web-service`, then
`gateway.gateway.networking.k8s.io/golang-web-gateway created` and
`httproute.gateway.networking.k8s.io/golang-web created` (`unchanged` when you run it again),
lines every 10 seconds, the last one `… s: Programmed=True  address=<an address>`, then
`route accepted by the gateway: True`.

**If not:**
- `NO ADDRESS after 300 s` with `Programmed=False`: the gateway's proxy pod did not start.
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_GATEWAY_NAMESPACE" get events --sort-by=.lastTimestamp`
  says why. `violates PodSecurity` — the namespace is not at the level `baseline`: it was not
  made by *Create the gateway's namespace*. `Insufficient memory` or `Insufficient cpu` — the
  workers are full.
- `Programmed=True  address=none yet` to the end: the cluster's load balancer has no free
  address. Tell your administrator.
- `route accepted by the gateway:` with nothing or `False` after it: the route's namespace is
  not the one the gateway allows. `ISTIO_APP_NAMESPACE` must be the namespace the app runs in.
- `no matches for kind "Gateway"`: run *Check that the cluster can make gateways* first.

### Check whether the gateway needs `baseline`

This asks the guest cluster what would happen if the gateway's namespace were set to
`restricted`, without changing it (`--dry-run=server`). The cluster answers with the pods that
would break that level, and why.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" label --dry-run=server --overwrite namespace "$ISTIO_GATEWAY_NAMESPACE" pod-security.kubernetes.io/enforce=restricted
```

**Expect:** one of two answers, both ending with `namespace/istio-ingress labeled (server dry
run)`:

- `Warning: existing pods in namespace "istio-ingress" violate the new PodSecurity enforce level
  "restricted:latest"`, and a `Warning:` line that names the gateway's pod and the settings it
  lacks. The gateway needs `baseline`: leave the namespace as it is.
- No `Warning:` line. The gateway's pod of your Istio release meets `restricted`. You may tighten
  the namespace: run the same line without `--dry-run=server`.

**If not:** `namespaces "istio-ingress" not found` — check `ISTIO_GATEWAY_NAMESPACE`.

## Reach the app through the gateway

This reads the gateway's address and calls the app through it, then calls a path that is not
routed.

```sh
source ~/.vks-golang-web.env
GW_IP="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_GATEWAY_NAMESPACE" get gateways.gateway.networking.k8s.io "$ISTIO_GATEWAY" -o jsonpath='{.status.addresses[0].value}')"
echo "http://${GW_IP}/myhello/"
curl -sS --max-time 10 "http://${GW_IP}/myhello/"
echo "a path that is not routed: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${GW_IP}/healthz")"
```

**Expect:** the URL, then `Hello, World` and the pod's details, then
`a path that is not routed: HTTP 404`.

**If not:**
- `http:///myhello/` (no address): the gateway has no address yet; run *Create the gateway and
  the route* again and read its last lines.
- A timeout: the address is not reachable from your machine. It is on the same network as the
  app's own `LoadBalancer` address was: what reached that one reaches this one.
- `HTTP 404` on `/myhello/` too: the route is not attached. Run *Create the gateway and the
  route* again; its line `route accepted by the gateway:` must end with `True`.
- `HTTP 503`, or `no healthy upstream`: the gateway runs, the app does not.
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get pods` shows it.

<details>
<summary><b>Option: put the app into the mesh</b> (a proxy beside the app's pod)</summary>

The gateway works without this. Do it only if you want what the mesh gives between pods:
encrypted traffic inside the cluster and per-request numbers. It costs one more container in
each app pod, and it **restarts the app**.

`k8s/golang-web.yaml` switches the proxy off for the app's pod (the annotation
`sidecar.istio.io/inject: "false"`). So two things are needed: the namespace says that its pods
get a proxy, and the app's pod stops saying no. This block does both, waits for the restart, and
lists the pod's containers.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" label namespace "$ISTIO_APP_NAMESPACE" istio-injection=enabled --overwrite
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" patch deployment golang-web --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"true"}}}}}'
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" rollout status deployment/golang-web --timeout=150s
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get pods -l app=golang-web -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}'
```

**Expect:** `namespace/golang-web labeled`, `deployment.apps/golang-web patched`,
`deployment "golang-web" successfully rolled out`, then the pod with `istio-proxy` among its
containers, such as `golang-web-…: istio-validation istio-proxy golang-web`.

**If not:**
- The rollout times out: the new pod was refused or cannot start, and the old pod still serves.
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get events --sort-by=.lastTimestamp`
  says why. Run the block below to go back.
- No `istio-proxy` in the list: `istiod` did not add it. *Check Istio on the guest cluster*
  must show the admission webhooks.

Deploying the app again from `k8s/golang-web.yaml` takes the pod out of the mesh again (the
file's annotation wins).

This takes the app out of the mesh again, and restarts it once more.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" label namespace "$ISTIO_APP_NAMESPACE" istio-injection-
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" patch deployment golang-web --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}}}'
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" rollout status deployment/golang-web --timeout=150s
```

**Expect:** `namespace/golang-web unlabeled` (`label "istio-injection" not found` when it was not
set), `deployment.apps/golang-web patched`, then `successfully rolled out`.

</details>

## Remove the gateway and the route

This deletes the route and the gateway, then the gateway's namespace, each only if this guide
made it. If *Make the app's Service internal* changed the Service from `LoadBalancer`, it is
changed back; otherwise the Service is left as it is. Take the app out of the mesh first if you
put it in.

```sh
source ~/.vks-golang-web.env
L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$ISTIO_GATEWAY_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ -z "$ISTIO_GATEWAY_NAMESPACE" ] || [ -z "$ISTIO_APP_NAMESPACE" ]; then
  echo "Not removing: ISTIO_GATEWAY_NAMESPACE or ISTIO_APP_NAMESPACE is empty"
elif [ -n "$L" ] && [ "$L" != "${ISTIO_GATEWAY_NAMESPACE}/addons-guide" ]; then
  echo "Not removing: this guide did not make the namespace '${ISTIO_GATEWAY_NAMESPACE}', or it could not be read. Nothing was changed."
else
  kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" delete httproutes.gateway.networking.k8s.io -l vks-golang-web/created-by=addons-guide --ignore-not-found
  [ -z "$L" ] || kubectl --kubeconfig "$GUEST_KUBECONFIG" delete namespace "$ISTIO_GATEWAY_NAMESPACE" --ignore-not-found
  if [ "$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" get service golang-web-service --ignore-not-found -o jsonpath='{.metadata.annotations.vks-golang-web/type-before-gateway}')" = LoadBalancer ]; then
    kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" patch service golang-web-service --type=merge -p '{"spec":{"type":"LoadBalancer"}}'
    kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$ISTIO_APP_NAMESPACE" annotate service golang-web-service vks-golang-web/type-before-gateway-
  fi
  rm -f "$HOME/.config/vks-golang-web/istio-gateway.yaml"
  echo "left (nothing after the colon means gone): $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$ISTIO_GATEWAY_NAMESPACE" --ignore-not-found -o name || echo unknown)"
fi
```

**Expect:** `httproute.gateway.networking.k8s.io "golang-web" deleted`,
`namespace "istio-ingress" deleted` (it can take a minute; the gateway and its proxy go with
it), then `left (nothing after the colon means gone):` with nothing after it; before that
line, `service/golang-web-service patched` and `annotated` when the Service was a `LoadBalancer`
before the gateway. The app is reached as before the gateway (main guide, *Reach the app*).

**If not:**
- `Not removing: this guide did not make the namespace …`: the namespace does not carry this
  guide's mark. If it is yours, delete the gateway in it yourself.

## Uninstall Istio

**This removes Istio from the guest cluster.** Gateways that Istio serves stop working, and
pods in the mesh keep their proxy until they are restarted. The block deletes this guide's
`AddonInstall` on the Supervisor; VKS then removes what it installed. It refuses an
`AddonInstall` this guide did not make, and it refuses while a gateway on the cluster still uses
Istio. Only if the Supervisor accepted the delete does it wait (up to ten minutes). Whenever it
finds neither the `AddonInstall` nor Istio on the Supervisor (after its own delete, or when you
run it again later), it removes the install description this chapter saved.

```sh
source ~/.vks-golang-web.env
AI="${VKS_CLUSTER}-istio-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-istio" --ignore-not-found -o name)" || CA=unknown
GW="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get gateways.gateway.networking.k8s.io --all-namespaces -o jsonpath='{range .items[?(@.spec.gatewayClassName=="istio")]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{end}' 2>&1)" || case "$GW" in
  *"doesn't have a resource type"*) GW="" ;;
  *) GW="unknown (${GW})" ;;
esac
GONE=""
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not removing: VKS_CLUSTER is empty"
elif [ "$MINE" = unknown ] || [ "$CA" = unknown ]; then
  echo "Not removing '${AI}': the Supervisor did not answer (see the error above). Nothing was changed."
elif [ -z "$MINE" ] && [ -z "$CA" ]; then
  echo "Nothing to remove on the Supervisor: no AddonInstall '${AI}' in '${VKS_NAMESPACE}', and no Istio add-on on '${VKS_CLUSTER}'"
  GONE=yes
elif [ -z "$MINE" ]; then
  echo "Not removing: Istio is still on '${VKS_CLUSTER}' and this guide's AddonInstall is not there. VKS is still removing it (run this block again in a minute), or another AddonInstall holds it."
elif [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not removing '${AI}': this guide did not make it. Nothing was changed."
elif [ -n "$GW" ]; then
  echo "Not removing: gateways on the cluster still use Istio, or could not be listed: ${GW}"
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete addoninstall "$AI" --wait=false; then
  n=0; LEFT=unknown
  until [ -z "$LEFT" ] || [ "$n" -ge 40 ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get "addoninstall/${AI}" "clusteraddon/${VKS_CLUSTER}-istio" --ignore-not-found -o name || echo unknown)"
  done
  echo "left on the Supervisor (nothing after the colon means gone): ${LEFT}"
  [ -n "$LEFT" ] || GONE=yes
else
  echo "Not removed: the Supervisor refused (see the error above), so nothing is waited for."
fi
if [ "$GONE" = yes ]; then
  rm -f "$HOME/.config/vks-golang-web/istio-addoninstall.yaml"
  echo "cleaned on this machine: the saved install description (istio-addoninstall.yaml)"
fi
```

**Expect:** `addoninstall.addons.kubernetes.vmware.com "<your cluster>-istio-addon" deleted`,
within a few minutes `left on the Supervisor (nothing after the colon means gone):` with nothing
after it, then `cleaned on this machine: …`. When you run it again afterwards:
`Nothing to remove on the Supervisor: …` and the `cleaned` line.

**If not:**
- `Not removing: gateways on the cluster still use Istio …`: the line names them
  (`namespace/name`). Run *Remove the gateway and the route*, and delete gateways other people
  made only with their agreement. `unknown (…)` holds the error that stopped the listing.
- `Not removing … this guide did not make it`: the `AddonInstall` does not carry this guide's
  mark. Whoever installed Istio removes it.
- A name, or `unknown`, after the colon, and no `cleaned` line: VKS is still removing Istio, or
  the Supervisor login ended. Run the block again: it finishes the clean-up when Istio is gone.
- `Not removing: Istio is still on … and this guide's AddonInstall is not there`: after your own
  delete, wait a minute and run the block again. If it stays, somebody else installed Istio with
  another `AddonInstall`: `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall` lists them.

This shows what is left on the guest cluster.

```sh
source ~/.vks-golang-web.env
echo "namespace ${ISTIO_SYSTEM_NAMESPACE}: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$ISTIO_SYSTEM_NAMESPACE" --ignore-not-found -o jsonpath='{.status.phase}' || echo unknown)"
echo "Istio's object types: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd -o name | grep -c 'istio\.io$')"
echo "namespaces that ask for a proxy: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}')"
```

**Expect:** `namespace istio-system:` with nothing after it (or `Terminating` for a minute),
`Istio's object types: 0`, and `namespaces that ask for a proxy:` with nothing after it.

**If not:**
- `Istio's object types:` above 0: VKS left Istio's object types on the cluster. Without Istio
  they do nothing.
- A namespace after the last colon: its `istio-injection` label is still set. Without Istio it
  does nothing; *Option: put the app into the mesh* has the block that removes it.

The Gateway API itself stays: it is a separate add-on that VKS manages. Istio's settings stay in
your env file, which the main guide's last clean-up block deletes.

## Fix common problems

| symptom | fix |
|---|---|
| `Ready=False` for many minutes and an `istiod` pod `Pending` with `Insufficient memory` | The workers are too small for Istio's control program. Lower `ISTIO_PILOT_MEMORY` or `ISTIO_PILOT_REPLICAS` and run *Set Istio's size*, or add workers. |
| You created an `AddonConfig` yourself and nothing changed | VKS acts only on the one it made. Delete yours if it has another name, and use *Set Istio's size*. |
| The install description was accepted and nothing ever happens | It names a release the Supervisor does not have. *Fill and check the install description* checks that first; fill it again. |
| The gateway never gets a pod: `violates PodSecurity` in the namespace's events | The gateway's namespace is at the level `restricted`. *Create the gateway's namespace* makes it `baseline`. |
| `error: the server doesn't have a resource type "gateway"`, or `kubectl get gateway` shows nothing | Istio has an older object type that is also called `Gateway`. This chapter always writes the full name, `gateways.gateway.networking.k8s.io`. |
| `HTTP 404` from the gateway's address | Only `/myhello` is routed. `/` and every other path answer 404 by design. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended. Run the main guide's *Renew the Supervisor login* block. |

## Next

Go back to [the add-ons overview](README.md) or to [the main guide](../README.md).
