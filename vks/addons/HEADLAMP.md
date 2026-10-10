# Headlamp: look at the guest cluster in a web page

[Headlamp](https://headlamp.dev/) shows what runs on a Kubernetes cluster: nodes, namespaces,
pods, their logs and events. This chapter is optional and comes after the main guide's *Check the
guest cluster*. You need [the main guide](../README.md)'s env file and the guest cluster's
kubeconfig (`$GUEST_KUBECONFIG`).

There are three ways to use it. The first is VKS's own: take it unless the table sends you
elsewhere.

| your situation | go to | what it puts on the cluster |
|---|---|---|
| You want Headlamp as part of the platform: installed and kept by VKS, with an address of its own | [Headlamp as a VKS add-on](#headlamp-as-a-vks-add-on) | the cert-manager add-on first; then one namespace, one pod, a `LoadBalancer` address and an administrator account |
| Your Supervisor offers no Headlamp add-on, or nothing on the cluster may have administrator rights or an address | [Headlamp in the cluster, with helm](#headlamp-in-the-cluster-with-helm) | one namespace, one pod, a read-only account; no address |
| You want to look at the cluster from your own machine | [Headlamp on your machine](#headlamp-on-your-machine) | nothing |

Use the add-on or the helm chart on one cluster, not both: each makes a namespace `headlamp` and
a binding named `headlamp-admin`. The install blocks refuse when the other one is there.

Run the blocks by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside your
`golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where it
can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells you
what to do.

## Add Headlamp's settings

This adds Headlamp's eleven settings to your env file, each only if it is not there yet. Values
you already set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export ADDON_CATALOG_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ADDON_CATALOG_NAMESPACE="vmware-system-vks-public"' >> ~/.vks-golang-web.env
  grep -qs '^export ADDON_WAIT_MINUTES=' ~/.vks-golang-web.env || printf '%s\n' 'export ADDON_WAIT_MINUTES="10"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_ADDON_RELEASE=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_ADDON_RELEASE=""' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_ADDON_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_ADDON_NAMESPACE="headlamp"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_ADDON_HOSTNAME=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_ADDON_HOSTNAME=""' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_ADDON_GATEWAY=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_ADDON_GATEWAY="false"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_TOKEN_HOURS=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_TOKEN_HOURS="8"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_CHART_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_CHART_VERSION="0.45.0"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_NAMESPACE="headlamp"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_LOCAL_PORT=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_LOCAL_PORT="8081"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_VERSION="0.45.0"' >> ~/.vks-golang-web.env
  grep -c -E '^export (ADDON_CATALOG_NAMESPACE|ADDON_WAIT_MINUTES|HEADLAMP_ADDON_RELEASE|HEADLAMP_ADDON_NAMESPACE|HEADLAMP_ADDON_HOSTNAME|HEADLAMP_ADDON_GATEWAY|HEADLAMP_TOKEN_HOURS|HEADLAMP_CHART_VERSION|HEADLAMP_NAMESPACE|HEADLAMP_LOCAL_PORT|HEADLAMP_VERSION)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `11`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 11 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

| setting | used by | meaning |
|---|---|---|
| `HEADLAMP_ADDON_RELEASE` | the add-on | the Headlamp release to install; empty until you choose one below |
| `HEADLAMP_ADDON_NAMESPACE` | the add-on | the namespace on the guest cluster the add-on runs in. The add-on uses `headlamp`; this chapter only reads it |
| `HEADLAMP_ADDON_HOSTNAME` | the add-on, optional | the DNS name for Headlamp's certificate; empty keeps the add-on's own |
| `HEADLAMP_ADDON_GATEWAY` | the add-on, optional | `true` lets the add-on make an Istio gateway for Headlamp |
| `ADDON_WAIT_MINUTES` | the add-on | how long an install block waits for an add-on to become ready |
| `ADDON_CATALOG_NAMESPACE` | the add-on | where the Supervisor keeps its add-on catalogue |
| `HEADLAMP_TOKEN_HOURS` | the add-on, helm | how long a login token is valid |
| `HEADLAMP_CHART_VERSION` | helm | the helm chart's version; chart 0.45.0 installs Headlamp 0.45.0 |
| `HEADLAMP_NAMESPACE` | helm | the namespace on the guest cluster that the chart's Headlamp runs in |
| `HEADLAMP_LOCAL_PORT` | helm | the port on your machine the page is served on |
| `HEADLAMP_VERSION` | your machine | the desktop program's version, for the Linux download |

The project's newest versions are listed on
[Headlamp's releases page](https://github.com/kubernetes-sigs/headlamp/releases) (the program is
`v0.45.0`, the chart `headlamp-helm-0.45.0`). To use another one, change the setting in the env
file; no block below names a version.

## Headlamp as a VKS add-on

VKS offers Headlamp in its add-on catalogue. You describe it in one object on the
**Supervisor**, and VKS puts it into the guest cluster and keeps it there. You also need the
main guide's Supervisor login, `envsubst` ([Install envsubst](../SETUP.md#install-envsubst))
and the **Edit** role on the vSphere Namespace. It was written for VMware Cloud Foundation 9.1.1
and VKS 3.7.

**The add-on needs cert-manager on the guest cluster first.** Without it VKS accepts the install
and Headlamp never starts: the add-on stays not ready with `Expected to find kind
'cert-manager.io/v1/Issuer', but did not`.

**Know what you get before you install it.** With its own settings the add-on gives Headlamp a
`LoadBalancer` address on port 443: its login page is open to everyone who can reach that
network. Its namespace is at the Pod Security level `privileged`. And the add-on's own account
is bound to `cluster-admin`: anyone who may create a token for it, or run a command in a pod of
that namespace, is a full administrator of the cluster. If that is more than you want on this
cluster, take [Headlamp in the cluster, with helm](#headlamp-in-the-cluster-with-helm): a
read-only account and no `LoadBalancer`. *What the add-on put on the cluster* shows all three on
your cluster after the install.

### Check that the cluster has cert-manager

This looks for cert-manager's object types on the guest cluster. It is read-only.

```sh
source ~/.vks-golang-web.env
CRD="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd issuers.cert-manager.io --ignore-not-found -o name)" || CRD=unknown
if [ "$CRD" = unknown ]; then
  echo "cert-manager on '${VKS_CLUSTER}': NOT KNOWN, the guest cluster did not answer (see the error above)"
elif [ -n "$CRD" ]; then
  echo "cert-manager on '${VKS_CLUSTER}': there"
else
  echo "cert-manager on '${VKS_CLUSTER}': none. Install it first: vks/addons/CERT-MANAGER.md"
fi
```

**Expect:** `cert-manager on '<your cluster>': there`.

**If not:** `… none. Install it first …` — do [cert-manager](CERT-MANAGER.md) from its start to
*Check cert-manager on the guest cluster*, then come back here.

### Choose the Headlamp release

This lists the Headlamp releases your Supervisor offers, oldest first. It is read-only.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease -o name | sed -n 's|^.*/\(headlamp\.\)|\1|p' | sort -t. -k5,5n -k6,6n -k7,7n -k8,8n
```

**Expect:** one release per line, such as `headlamp.kubernetes.vmware.com.0.45.0-vmware.1-vks.1`.
Which ones you see depends on your VKS version. Take the newest (the last line) unless you need
another one.

**If not:**
- No output: this Supervisor's catalogue has no Headlamp (VKS 3.7 has it). Use
  [Headlamp in the cluster, with helm](#headlamp-in-the-cluster-with-helm).
- `Unauthorized`: run the main guide's *Renew the Supervisor login* block.

Open the env file and set `HEADLAMP_ADDON_RELEASE` to one line of the list, exactly as printed:

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
block reads the new value.

### Fill and check the install description

This fills [`templates/addoninstall.yaml`](templates/addoninstall.yaml) from your env file, saves
the result as `~/.config/vks-golang-web/headlamp-addoninstall.yaml`, shows it, and asks the
Supervisor to check it without creating anything (`--dry-run=server`). It first checks that the
release exists: the Supervisor accepts an install description that names a release it does not
have, and then never installs anything.

```sh
source ~/.vks-golang-web.env
export ADDON_NAME="headlamp" ADDON_INSTALL="${VKS_CLUSTER}-headlamp-addon" ADDON_RELEASE="$HEADLAMP_ADDON_RELEASE"
OUT="$HOME/.config/vks-golang-web/headlamp-addoninstall.yaml"
M=""
for v in VKS_CLUSTER VKS_NAMESPACE ADDON_CATALOG_NAMESPACE HEADLAMP_ADDON_RELEASE; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
REL=""
[ -n "$M" ] || REL="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease "$ADDON_RELEASE" --ignore-not-found -o name)" || REL=unknown
if [ -n "$M" ]; then
  echo "Not filled: no value for:$M"
elif [ "$REL" = unknown ]; then
  echo "Not filled: the Supervisor did not answer (see the error above)"
elif [ -z "$REL" ]; then
  echo "Not filled: the Supervisor offers no release '${ADDON_RELEASE}'. Set HEADLAMP_ADDON_RELEASE to a line from 'Choose the Headlamp release'."
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
`addoninstall.addons.kubernetes.vmware.com/<your cluster>-headlamp-addon created (server dry run)`
(`configured` or `unchanged` when Headlamp is already installed).

**If not:**
- `Not filled: no value for: …`: each name listed is empty in the env file, or its line lacks
  the word `export`.
- `Not filled: the Supervisor offers no release …`: `HEADLAMP_ADDON_RELEASE` is not a line of
  the list. Copy one again.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.

### Install the add-on

This applies the description on the Supervisor and waits until VKS reports Headlamp ready on your
cluster, with one line every 15 seconds. On a small lab it took 20 seconds. It gives up after
`ADDON_WAIT_MINUTES` (10); run the block again to keep waiting.

The block refuses:

- a cluster without cert-manager;
- an `AddonInstall` of that name that this guide did not make, and a cluster that already has
  the Headlamp add-on from another `AddonInstall`;
- a cluster that has another Headlamp (a namespace of the add-on's name, or a binding named
  `headlamp-admin`): the add-on would take both over.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/headlamp-addoninstall.yaml"
AI="${VKS_CLUSTER}-headlamp-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-headlamp" --ignore-not-found -o name)" || CA=unknown
CRD="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd issuers.cert-manager.io --ignore-not-found -o name)" || CRD=unknown
OTHER="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get "namespace/${HEADLAMP_ADDON_NAMESPACE}" clusterrolebinding/headlamp-admin --ignore-not-found -o name)" || OTHER=unknown
MIN="${ADDON_WAIT_MINUTES:-10}"
case "$MIN" in
  ''|*[!0-9]*) echo "ADDON_WAIT_MINUTES is '${MIN}', not a whole number: waiting 10 minutes"; MIN=10 ;;
esac
if [ -z "$VKS_CLUSTER" ] || [ -z "$HEADLAMP_ADDON_NAMESPACE" ]; then
  echo "Not installed: VKS_CLUSTER or HEADLAMP_ADDON_NAMESPACE is empty"
elif [ "$(awk '$1 == "name:" {print $2; exit}' "$OUT" 2>/dev/null)" != "$AI" ]; then
  echo "Not installed: the filled description is missing, or is for another cluster. Run 'Fill and check the install description' again."
elif [ "$MINE" = unknown ] || [ "$CA" = unknown ] || [ "$CRD" = unknown ] || [ "$OTHER" = unknown ]; then
  echo "Not installed: a cluster did not answer (see the error above)"
elif [ -z "$CRD" ]; then
  echo "Not installed: '${VKS_CLUSTER}' has no cert-manager, and the Headlamp add-on needs it. Install it first: vks/addons/CERT-MANAGER.md"
elif [ -n "$MINE" ] && [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not installed: an AddonInstall '${AI}' exists and this guide did not make it. Nothing was changed."
elif [ -z "$MINE" ] && [ -n "$CA" ]; then
  echo "Not installed: '${VKS_CLUSTER}' already has the Headlamp add-on from another AddonInstall. Nothing was changed: use that one."
elif [ -z "$CA" ] && [ -n "$OTHER" ]; then
  echo "Not installed: '${VKS_CLUSTER}' already has another Headlamp ($(printf '%s' "$OTHER" | tr '\n' ' ')). Uninstall that one first, or use it."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply -f "$OUT"; then
  n=0; R=""; MAX=$((MIN * 4))
  until [ "$R" = True ] || [ "$n" -ge "$MAX" ]; do
    sleep 15; n=$((n + 1))
    R="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-headlamp" --ignore-not-found -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    echo "$((n * 15)) s: Ready=${R:-not yet}"
  done
  if [ "$R" != True ]; then
    echo "NOT READY after $((n * 15)) s. What VKS reports:"
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-headlamp" --ignore-not-found -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  fi
else
  echo "Not installed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:** `addoninstall.addons.kubernetes.vmware.com/<your cluster>-headlamp-addon created`
(`unchanged` when you run it again), then a line every 15 seconds, the last one with
`Ready=True`.

**If not:**
- `Not installed: … has no cert-manager …`: do [cert-manager](CERT-MANAGER.md) first.
- `Not installed: … already has another Headlamp (…)`: the brackets name what is there. If it is
  this chapter's helm install, run [Uninstall Headlamp](#uninstall-headlamp) first.
- `Not installed: the filled description is missing …`: you changed `VKS_CLUSTER` after filling
  the file, or did not fill it. Run the block above again.
- `NOT READY after …`, and under it VKS's own report, one condition per line.
  `Reconciled=False ReconcileFailed: … Expected to find kind 'cert-manager.io/v1/Issuer'` —
  cert-manager went missing; install it, then run this block again. Another reason: look at the
  pod, `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get pods`.
  `ImagePullBackOff` — the cluster's nodes cannot reach Broadcom's registry
  (`projects.packages.broadcom.com`).

### What the add-on put on the cluster

This shows what VKS installed.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get deployment,service headlamp
echo "the add-on's own account has the role: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get clusterrolebinding headlamp-admin -o jsonpath='{.roleRef.name}')"
echo "the namespace's Pod Security level: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_ADDON_NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
```

**Expect:** the deployment `headlamp` with `READY` `1/1`; the service `headlamp` with `TYPE`
`LoadBalancer`, an address under `EXTERNAL-IP` and `443` under `PORT(S)`; then
`the add-on's own account has the role: cluster-admin` and
`the namespace's Pod Security level: privileged`.

That is what the add-on does unless you change its settings:

| what | the add-on's own choice |
|---|---|
| namespace on the guest cluster | `headlamp`, at the Pod Security level `privileged` |
| how it is reached | a `LoadBalancer` address, HTTPS on port 443 |
| its certificate | made by cert-manager, signed by a certificate authority the add-on creates in that namespace, for the name `headlamp.vks.example.com` |
| its own account | `headlamp`, bound to `cluster-admin` |
| login | a token of any account of the cluster; what you see and can do is what that account may do |

This chapter never makes a token for the add-on's own account: the next block makes an account
that can only read, and you log in with that one.

**If not:** `Error from server (NotFound)` on the first line — the add-on is not ready (run
*Install the add-on* again), or it runs in another namespace: set `HEADLAMP_ADDON_NAMESPACE`.

### Make an account that can only read

This creates an account `headlamp-viewer` in Headlamp's namespace and binds it to `view`,
Kubernetes' built-in read-only role: it lists and reads workloads in every namespace, cannot
read Secrets, and cannot change anything. Both objects are marked as made by this guide. Then it
asks the cluster what the account may do.

```sh
source ~/.vks-golang-web.env
E="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get clusterrolebinding headlamp-viewer-guide --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || E=unknown
if [ "$E" = unknown ]; then
  echo "Not created: the guest cluster did not answer (see the error above)"
elif [ -n "$E" ] && [ "$E" != headlamp-viewer-guide/headlamp-guide ]; then
  echo "Not created: a binding 'headlamp-viewer-guide' exists and this guide did not make it. Nothing was changed."
elif ! kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_ADDON_NAMESPACE" -o name; then
  echo "Not created: no namespace '${HEADLAMP_ADDON_NAMESPACE}' on the guest cluster (see the error above). Install the add-on first."
else
  printf 'apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: headlamp-viewer\n  namespace: %s\n  labels:\n    vks-golang-web/created-by: headlamp-guide\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata:\n  name: headlamp-viewer-guide\n  labels:\n    vks-golang-web/created-by: headlamp-guide\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: view\nsubjects:\n  - kind: ServiceAccount\n    name: headlamp-viewer\n    namespace: %s\n' "$HEADLAMP_ADDON_NAMESPACE" "$HEADLAMP_ADDON_NAMESPACE" \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" apply -f -
  SA="system:serviceaccount:${HEADLAMP_ADDON_NAMESPACE}:headlamp-viewer"
  echo "list pods everywhere: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i list pods --all-namespaces --as "$SA")"
  echo "read secrets: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i get secrets --all-namespaces --as "$SA")"
  echo "delete pods: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i delete pods --all-namespaces --as "$SA")"
  echo "change roles: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i create clusterrolebindings --all-namespaces --as "$SA")"
fi
```

**Expect:** `namespace/headlamp`, `serviceaccount/headlamp-viewer created` and
`clusterrolebinding.rbac.authorization.k8s.io/headlamp-viewer-guide created` (`unchanged` when
you run it again), then `list pods everywhere: yes`, `read secrets: no`, `delete pods: no` and
`change roles: no`.

**If not:** a `yes` on one of the last three lines — somebody gave the account more rights:
`kubectl --kubeconfig "$GUEST_KUBECONFIG" get clusterrolebindings,rolebindings --all-namespaces -o wide | grep headlamp-viewer`
lists its bindings. Do not make a token until only this guide's binding is left.

### Make a login token for it

**This block shows a secret.** It prints a token that logs in as the read-only account for
`HEADLAMP_TOKEN_HOURS` hours (8 unless you changed it). It is not stored anywhere: copy it from
the terminal into Headlamp's login page, then clear the terminal. Whoever has the token can read
everything on the cluster except Secrets until it ends. Run the block again for a new one.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" create token headlamp-viewer --duration="${HEADLAMP_TOKEN_HOURS}h"
```

**Expect:** one long line of letters, digits, `.`, `-` and `_`, starting with `eyJ`.

**If not:** `serviceaccounts "headlamp-viewer" not found` — run *Make an account that can only
read* first. `invalid duration` — `HEADLAMP_TOKEN_HOURS` is not a whole number.

### Open the page

This prints Headlamp's address, checks that it answers, and prints the fingerprint of its
certificate twice: read from the cluster through your kubeconfig, and as the address presents
it.

```sh
source ~/.vks-golang-web.env
IP="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get service headlamp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
PORT="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get service headlamp -o jsonpath='{.spec.ports[0].port}')"
if [ -z "$IP" ] || [ -z "$PORT" ]; then
  echo "No address: the service 'headlamp' in '${HEADLAMP_ADDON_NAMESPACE}' has none (see any error above)"
else
  echo "https://${IP}:${PORT}/"
  echo "answers: HTTP $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${IP}:${PORT}/")"
  echo "from the cluster: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get secret headlamp-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256)"
  echo "from the address: $(openssl s_client -connect "${IP}:${PORT}" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256)"
fi
```

**Expect:** the address, such as `https://10.0.0.20:443/`, then `answers: HTTP 200`, then two
lines with the same `Fingerprint=` value.

Open the address in your browser. **The browser warns that the connection is not private**
(Chrome: *Your connection is not private*; Firefox: *Warning: Potential Security Risk Ahead*;
Safari: *This Connection Is Not Private*). That is expected, for two reasons: the certificate is
for the name `headlamp.vks.example.com`, not for the address you typed, and it is signed by a
certificate authority that exists only inside your cluster. You have two honest options:

1. **Check it yourself, then go on.** Open the certificate from the warning page (*Advanced*, or
   the *Not secure* mark, then the certificate viewer), find its **SHA-256 fingerprint** and
   compare it with the two lines printed above, ignoring colons, spaces and upper/lower case.
   If it is the same, you are talking to your cluster's Headlamp: accept the warning for this
   address.
2. **Give Headlamp a real name.** Make a DNS record for a name of yours that points to the
   address, tell the add-on that name, and have your machine trust the add-on's certificate
   authority. [Change the add-on's settings](#change-the-add-ons-settings-optional) does the cluster's
   part.

On Headlamp's login page, paste the token into **ID token** and click **Authenticate**. The
overview lists the namespaces and workloads. Pages for things the read-only role does not cover
(Secrets, nodes) say that access is denied; that is the read-only role at work.

**If not:**
- `No address …`: the cluster's load balancer gave the service no address. That is a matter
  for whoever set up the Supervisor's load balancer.
- `answers: HTTP 000`: the address is not reachable from your machine. It is on the same network
  as an app's `LoadBalancer` address: what reaches one reaches the other.
- Two different fingerprints, or only one line: do not log in. Something between you and the
  cluster presents another certificate (a proxy that opens HTTPS), or the secret has another
  name on your VKS version:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get secrets` lists
  them.
- The login page says the token is not valid: it ended, or it was copied with a line break.
  Make a new one.

### Change the add-on's settings (optional)

Nothing above needs this. Open it when you want a name of your own for Headlamp's certificate,
or an Istio gateway in front of it.

<details>
<summary><b>The two settings, the block that writes them, and the check</b></summary>

The add-on's settings live in an object VKS made in your vSphere Namespace when it took the
install up: `<your cluster>-headlamp`, of the kind `AddonConfig`. **You change that object; you
never create one.** An `AddonConfig` you create yourself is accepted, stored, and applies
nothing.

This chapter sets two of the add-on's settings:

| env file | the add-on's setting | meaning |
|---|---|---|
| `HEADLAMP_ADDON_HOSTNAME` | `hostname` | the DNS name Headlamp's certificate is for, and the name a gateway routes. Empty keeps the add-on's own, `headlamp.vks.example.com` |
| `HEADLAMP_ADDON_GATEWAY` | `gatewayApi.enabled` | `true`: the add-on also makes a `Gateway` for that name. Its own settings for it are the class `istio` and the name `headlamp-gateway`, so the cluster needs [Istio](ISTIO.md) up to *Check that the cluster can make gateways* |

Set them in the env file first. Then this block writes them into VKS's object and waits (up to
two minutes) until VKS has worked them in. It replaces all values in the object with these: a
value somebody else set there is removed. It refuses an object that VKS did not make, and it
refuses the gateway setting on a cluster where Istio does not serve gateways.

```sh
source ~/.vks-golang-web.env
AC="${VKS_CLUSTER}-headlamp"
WANT="$(jq -cn --arg h "$HEADLAMP_ADDON_HOSTNAME" --arg g "$HEADLAMP_ADDON_GATEWAY" 'if ($h | test("^([a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+)?$")) and ($g | test("^(true|false)$")) then (if $h == "" then {} else {hostname: $h} end) + (if $g == "true" then {gatewayApi: {enabled: true}} else {} end) else empty end')"
CUR="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addonconfig "$AC" -o json)" || CUR=""
CN="$(printf '%s' "$CUR" | jq -r '.spec.clusterName // empty' 2>/dev/null)"
H0="$(printf '%s' "$CUR" | jq -r '.status.outputHash // empty' 2>/dev/null)"
GC=""
[ "$HEADLAMP_ADDON_GATEWAY" != true ] || GC="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get gatewayclasses.gateway.networking.k8s.io istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"
if [ -z "$WANT" ]; then
  echo "Not changed: HEADLAMP_ADDON_HOSTNAME must be empty or a DNS name in lower case (it is '${HEADLAMP_ADDON_HOSTNAME}'), and HEADLAMP_ADDON_GATEWAY true or false (it is '${HEADLAMP_ADDON_GATEWAY}')"
elif [ -z "$CUR" ]; then
  echo "Not changed: the settings object '${AC}' could not be read (see the error above). Install the add-on first."
elif [ "$CN" != "$VKS_CLUSTER" ]; then
  echo "Not changed: '${AC}' is not an object VKS made for this cluster (its cluster name is '${CN:-empty}'), so VKS would ignore it."
elif [ "$HEADLAMP_ADDON_GATEWAY" = true ] && [ "$GC" != True ]; then
  echo "Not changed: HEADLAMP_ADDON_GATEWAY is true, and Istio does not serve gateways on '${VKS_CLUSTER}' (see any error above). Do vks/addons/ISTIO.md up to 'Check that the cluster can make gateways' first."
elif [ "$(printf '%s' "$CUR" | jq -cS '.spec.values // {}')" = "$(printf '%s' "$WANT" | jq -cS .)" ]; then
  echo "unchanged: ${AC} already holds ${WANT}"
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
    echo "worked in after $((n * 5)) s: ${WANT}"
  else
    echo "NOT WORKED IN after $((n * 5)) s: the settings are stored, but VKS has not used them yet. Read 'If not' below."
  fi
else
  echo "Not changed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:** `addonconfig.addons.kubernetes.vmware.com/<your cluster>-headlamp patched`, then
`worked in after … s:` and the values, such as `{"hostname":"headlamp.example.test"}`. When you
run it again with the same values: `unchanged: <your cluster>-headlamp already holds …`.

**If not:**
- `Not changed: … must be empty or a DNS name …`: fix the two lines in the env file.
- `Not changed: … Istio does not serve gateways …`: install Istio first, or set
  `HEADLAMP_ADDON_GATEWAY="false"`.
- `Not changed: … is not an object VKS made for this cluster`: somebody created an `AddonConfig`
  of that name by hand. Ask them; this chapter does not delete it.
- `REFUSED by VKS:` and a line that names a setting: the value has the wrong form.
- `NOT WORKED IN after 120 s`: run the block again; it then waits again or prints `unchanged`.

VKS does not check setting names: a misspelled name in that object is accepted and dropped
without a word. This block writes only the two names above. The add-on has more settings (its
namespace, the service's type and port, OIDC login, resources); they are not covered here.

**Check the name and the certificate.** This saves the add-on's certificate authority as `~/.config/vks-golang-web/headlamp-ca.crt` (a
certificate, not a secret), and calls Headlamp by its name with only that authority trusted. It
does not need the DNS record yet: `curl` is told the address.

```sh
source ~/.vks-golang-web.env
H="${HEADLAMP_ADDON_HOSTNAME:-headlamp.vks.example.com}"
CA="$HOME/.config/vks-golang-web/headlamp-ca.crt"
IP="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get service headlamp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
PORT="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get service headlamp -o jsonpath='{.spec.ports[0].port}')"
mkdir -p "$(dirname "$CA")"
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get secret headlamp-tls-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"
echo "certificate authority: $(openssl x509 -noout -subject -in "$CA")"
echo "https://${H}:${PORT}/ at ${IP:-no address}, trusting only that authority: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA" --resolve "${H}:${PORT}:${IP}" "https://${H}:${PORT}/")"
echo "gateways in ${HEADLAMP_ADDON_NAMESPACE}: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get gateways.gateway.networking.k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[0].value}{"; "}{end}' 2>/dev/null)"
```

**Expect:** `certificate authority: subject=…` with the authority's name, then
`https://<the name>:443/ at <the address>, trusting only that authority: HTTP 200`: the
certificate is for that name and signed by that authority. The last line names a gateway and its
address only when `HEADLAMP_ADDON_GATEWAY` is `true`; otherwise nothing follows its colon.

To finish option 2 of *Open the page*: make the DNS record `<the name>` → `<the address>`, and
add `headlamp-ca.crt` to the certificate authorities your browser or operating system trusts,
the way your system does that. Then `https://<the name>/` opens without a warning. Removing the
add-on makes that authority worthless; take it out of your trust store then.

**If not:**
- `HTTP 000` right after a change of the name: cert-manager is still making the new certificate.
  Wait a minute and run the block again.
- `HTTP 000` that stays, while *Open the page* answers 200: the certificate is not for that
  name. `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get certificates.cert-manager.io -o wide`
  shows the certificates and whether they are ready.
- `unable to load certificate`: the secret holds no authority under `ca.crt`:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_ADDON_NAMESPACE" get secrets` lists
  what is there.

</details>

### Remove the add-on

**This removes Headlamp from the guest cluster.** The block deletes this guide's `AddonInstall`
on the Supervisor, only if this guide made it; VKS then removes what it installed. Only if the
Supervisor accepted the delete does it wait (up to `ADDON_WAIT_MINUTES`). **cert-manager stays**:
other things may use it, and [its own chapter](CERT-MANAGER.md) removes it.

Whenever the block finds neither the `AddonInstall` nor the Headlamp add-on on the Supervisor
(after its own delete, or when you run it again later), it cleans up what this chapter made
beside the add-on: the read-only account's binding on the guest cluster, and the files it saved
on this machine. So if a run ends before Headlamp is gone, run the block again.

```sh
source ~/.vks-golang-web.env
AI="${VKS_CLUSTER}-headlamp-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-headlamp" --ignore-not-found -o name)" || CA=unknown
MIN="${ADDON_WAIT_MINUTES:-10}"
case "$MIN" in
  ''|*[!0-9]*) MIN=10 ;;
esac
GONE=""
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not removing: VKS_CLUSTER is empty"
elif [ "$MINE" = unknown ] || [ "$CA" = unknown ]; then
  echo "Not removing '${AI}': the Supervisor did not answer (see the error above). Nothing was changed."
elif [ -z "$MINE" ] && [ -z "$CA" ]; then
  echo "Nothing to remove on the Supervisor: no AddonInstall '${AI}' in '${VKS_NAMESPACE}', and no Headlamp add-on on '${VKS_CLUSTER}'"
  GONE=yes
elif [ -z "$MINE" ]; then
  echo "Not removing: the Headlamp add-on is still on '${VKS_CLUSTER}' and this guide's AddonInstall is not there. VKS is still removing it (run this block again in a minute), or another AddonInstall holds it."
elif [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not removing '${AI}': this guide did not make it. Nothing was changed."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete addoninstall "$AI" --wait=false; then
  n=0; LEFT=unknown; MAX=$((MIN * 4))
  until [ -z "$LEFT" ] || [ "$n" -ge "$MAX" ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get "addoninstall/${AI}" "clusteraddon/${VKS_CLUSTER}-headlamp" --ignore-not-found -o name || echo unknown)"
  done
  echo "left on the Supervisor (nothing after the colon means gone): ${LEFT}"
  [ -n "$LEFT" ] || GONE=yes
else
  echo "Not removed: the Supervisor refused (see the error above), so nothing is waited for."
fi
if [ "$GONE" = yes ]; then
  if kubectl --kubeconfig "$GUEST_KUBECONFIG" delete clusterrolebinding -l vks-golang-web/created-by=headlamp-guide --ignore-not-found; then
    rm -f "$HOME/.config/vks-golang-web/headlamp-addoninstall.yaml" "$HOME/.config/vks-golang-web/headlamp-ca.crt"
    echo "cleaned: the read-only account's binding on the guest cluster (a 'deleted' line above, or it was gone already), and this chapter's two files on this machine"
    echo "left on the guest cluster (nothing after the colon means gone): $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get "namespace/${HEADLAMP_ADDON_NAMESPACE}" clusterrolebinding/headlamp-admin clusterrolebinding/headlamp-viewer-guide --ignore-not-found -o name | tr '\n' ' ' || echo unknown)"
  else
    echo "NOT CLEANED: the guest cluster did not answer (see the error above). The read-only account's binding may still be there: run this block again."
  fi
fi
```

**Expect:** `addoninstall.addons.kubernetes.vmware.com "<your cluster>-headlamp-addon" deleted`,
then `left on the Supervisor (nothing after the colon means gone):` with nothing after it,
`clusterrolebinding.rbac.authorization.k8s.io "headlamp-viewer-guide" deleted`, the line
`cleaned: …`, and `left on the guest cluster (nothing after the colon means gone):` with nothing
after it. Tokens made earlier stop working. When you run it again afterwards:
`Nothing to remove on the Supervisor: …`, then the `cleaned` and `left on the guest cluster`
lines again.

**If not:**
- `Not removing … this guide did not make it`: the `AddonInstall` does not carry this guide's
  mark. Whoever installed Headlamp removes it.
- A name, or `unknown`, after the first colon, and no `cleaned` line: VKS is still removing the
  add-on, or the Supervisor login ended. **Run the block again**: the read-only account's
  binding is removed only by a run that finds Headlamp gone.
- `Not removing: the Headlamp add-on is still on … and this guide's AddonInstall is not there`:
  after your own delete, wait a minute and run the block again. If it stays, somebody else
  installed Headlamp with another `AddonInstall`.
- `NOT CLEANED: …`: this machine could not reach the guest cluster. Run the block again when it
  can.
- A name after the last colon: `namespace/headlamp` right after the removal is the namespace
  still being deleted; run the block again a minute later. A binding there that stays is not
  this guide's to remove.

## Headlamp in the cluster, with helm

This installs Headlamp on the guest cluster with the project's own helm chart, in a namespace of
its own. Take this way when your Supervisor offers no Headlamp add-on, or when nothing on the
cluster may have administrator rights or an address of its own: here the page is reached through
a port-forward, and Headlamp's only account can only read.

Two things in the chart's defaults do not fit a VKS guest cluster, and
[`templates/headlamp-values.yaml`](templates/headlamp-values.yaml) changes both:

- A guest cluster accepts only pods that meet the Pod Security level `restricted`. The chart's
  default pod does not, and is rejected. The values file adds the security settings that level
  asks for.
- The chart gives Headlamp's account the `cluster-admin` role. The values file gives it `view`,
  Kubernetes' built-in read-only role: it lists and reads workloads in every namespace, cannot
  read Secrets, and cannot change anything.

### Check helm

`helm` is needed for this section only; nothing else in these guides uses it.

```sh
helm version --short
```

**Expect:** a version line, `v3.…` or `v4.…`.

**If not:** `command not found` — install helm: [SETUP.md](../SETUP.md#install-helm), then run
the block again.

### Create Headlamp's namespace

This creates the namespace, marked as made by this guide and set to the Pod Security level
`restricted`. It refuses a namespace of that name that it did not create.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || NS=unknown
if [ -z "$HEADLAMP_NAMESPACE" ]; then
  echo "Not created: HEADLAMP_NAMESPACE is empty"
elif [ "$NS" = unknown ]; then
  echo "Not created: the guest cluster did not answer (see the error above)"
elif [ "$NS" = "${HEADLAMP_NAMESPACE}/headlamp-guide" ]; then
  echo "namespace/${HEADLAMP_NAMESPACE} is already there, made by this guide"
elif [ -n "$NS" ]; then
  echo "Not created: a namespace '${HEADLAMP_NAMESPACE}' exists and this guide did not make it. Set HEADLAMP_NAMESPACE to another name."
else
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    vks-golang-web/created-by: headlamp-guide\n    pod-security.kubernetes.io/enforce: restricted\n' "$HEADLAMP_NAMESPACE" \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" create -f -
fi
```

**Expect:** `namespace/headlamp created`, or `namespace/headlamp is already there, made by this
guide` when you run it again.

**If not:**
- `Not created: a namespace … exists and this guide did not make it`: somebody else uses that
  name: the Headlamp add-on, or a Headlamp of their own. Set `HEADLAMP_NAMESPACE` in the env file to another
  name, then run the block again.
- `Not created: the guest cluster did not answer`: the line above it says why. `Unable to
  connect` — this machine cannot reach the cluster; `Unauthorized` — the kubeconfig is not this
  cluster's: get it again (main guide).

### Check the chart against the cluster

This fills the chart with the values file and asks the guest cluster to check the result without
creating anything (`--dry-run=server`). The cluster applies its Pod Security rules in this check.

```sh
source ~/.vks-golang-web.env
if [ -f vks/addons/templates/headlamp-values.yaml ]; then
  helm template headlamp headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version "$HEADLAMP_CHART_VERSION" \
    --namespace "$HEADLAMP_NAMESPACE" -f vks/addons/templates/headlamp-values.yaml \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" apply --dry-run=server -f -
else
  echo "Not checked: run this block from inside your golang-web clone"
fi
```

**Expect:** four lines that end with `created (server dry run)`: `serviceaccount/headlamp`,
`clusterrolebinding.rbac.authorization.k8s.io/headlamp-admin`, `service/headlamp` and
`deployment.apps/headlamp`; and no line that starts with `Warning: would violate PodSecurity`.
The chart names the binding `headlamp-admin` whatever role it binds; here the role is `view`.

**If not:**
- `Warning: would violate PodSecurity "restricted:latest": …`: the line names the setting that
  is missing. With this guide's values file and chart 0.45.0 there is none; a newer chart may
  have added a container. Do not install: set `HEADLAMP_CHART_VERSION` back to `0.45.0`.
- `Error: chart "headlamp" version "…" not found`: `HEADLAMP_CHART_VERSION` is not a published
  chart version.
- `namespaces "headlamp" not found`: run *Create Headlamp's namespace* first.
- `Error: … no such host` or a timeout: this machine cannot reach
  `kubernetes-sigs.github.io` and `github.com`, where the chart is published.

### Install Headlamp

This installs the chart into the namespace this guide made, and waits up to five minutes for the
pod. It refuses any other namespace.

```sh
source ~/.vks-golang-web.env
L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ "$L" != headlamp-guide ]; then
  echo "Not installed: the namespace '${HEADLAMP_NAMESPACE}' is missing, was not made by this guide, or could not be read. Run 'Create Headlamp's namespace' first."
elif [ ! -f vks/addons/templates/headlamp-values.yaml ]; then
  echo "Not installed: run this block from inside your golang-web clone"
elif helm --kubeconfig "$GUEST_KUBECONFIG" upgrade --install headlamp headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version "$HEADLAMP_CHART_VERSION" \
    --namespace "$HEADLAMP_NAMESPACE" -f vks/addons/templates/headlamp-values.yaml --wait --timeout 5m; then
  kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" get deployment headlamp
else
  echo "Not installed, or not ready in time: see the error above"
fi
```

**Expect:** `Release "headlamp" does not exist. Installing it now.` (`has been upgraded` when you
run it again), helm's summary with `STATUS: deployed`, then the deployment with `READY` `1/1`.

**If not:**
- `Not installed, or not ready in time`, under `context deadline exceeded`: the pod did not
  become ready. `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" get events --sort-by=.lastTimestamp`
  says why. `violates PodSecurity` — the values file was not used: run the block from inside
  your clone. `ImagePullBackOff` — the cluster's nodes cannot reach `ghcr.io`. `Insufficient
  memory` — the workers are full (Headlamp asks for 128 MB).
- `ClusterRoleBinding "headlamp-admin" … exists and cannot be imported into the current
  release`: another Headlamp is on this cluster: the VKS add-on, or one installed with the same
  chart. Use that one, or ask its owner; this guide does not replace it.

### Check that Headlamp's account can only read

This asks the cluster what Headlamp's account may do.

```sh
source ~/.vks-golang-web.env
SA="system:serviceaccount:${HEADLAMP_NAMESPACE}:headlamp"
echo "list pods everywhere: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i list pods --all-namespaces --as "$SA")"
echo "read secrets: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i get secrets --all-namespaces --as "$SA")"
echo "delete pods: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i delete pods --all-namespaces --as "$SA")"
echo "change roles: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i create clusterrolebindings --all-namespaces --as "$SA")"
```

**Expect:** `list pods everywhere: yes`, then `read secrets: no`, `delete pods: no` and
`change roles: no`.

**If not:** a `yes` on one of the last three lines — the account has more than the `view` role.
Run `kubectl --kubeconfig "$GUEST_KUBECONFIG" get clusterrolebinding headlamp-admin -o jsonpath='{.roleRef.name}'`:
it must print `view`. `cluster-admin` there means the chart was installed without the values
file; run *Install Headlamp* again from inside your clone.

### Make a login token for the chart's Headlamp

**This block shows a secret.** It prints a token that logs in as Headlamp's read-only account
for `HEADLAMP_TOKEN_HOURS` hours (8 unless you changed it). It is not stored anywhere: copy it
from the terminal into Headlamp's login page, then clear the terminal. Whoever has the token can
read everything on the cluster except Secrets until it ends. Run the block again for a new one.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" create token headlamp --duration="${HEADLAMP_TOKEN_HOURS}h"
```

**Expect:** one long line of letters, digits, `.`, `-` and `_`, starting with `eyJ`.

**If not:** `serviceaccounts "headlamp" not found` — Headlamp is not installed in
`HEADLAMP_NAMESPACE`. `invalid duration` — `HEADLAMP_TOKEN_HOURS` is not a whole number.

### Open the chart's page

This forwards a port on your machine to Headlamp, through your kubeconfig. Run it in a second
terminal and leave it running; press Ctrl+C to stop it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" port-forward service/headlamp "${HEADLAMP_LOCAL_PORT}:80"
```

**Expect:** `Forwarding from 127.0.0.1:8081 -> 4466`. Open `http://localhost:8081` in your
browser, paste the token into **ID token** and click **Authenticate**. The overview lists the
namespaces and workloads. Pages for things the read-only role does not cover (Secrets, nodes)
say that access is denied; that is the read-only role at work.

**If not:**
- `address already in use`: another program uses that port. Set `HEADLAMP_LOCAL_PORT` in the env
  file to a free one.
- The login page says the token is not valid: it ended, or it was copied with a line break.
  Make a new one.
- The page loads and stays empty: wait a few seconds; then check that the port-forward is still
  running.

The page is reachable only from your own machine while the port-forward runs. This chapter does
not give Headlamp an address of its own: a page that shows the whole cluster should not be
reachable by everyone who reaches the cluster's network.

### Uninstall Headlamp

This removes the helm release and then the namespace, only if this guide made the namespace.

```sh
source ~/.vks-golang-web.env
L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ -z "$HEADLAMP_NAMESPACE" ]; then
  echo "Not removing: HEADLAMP_NAMESPACE is empty"
elif [ -z "$L" ]; then
  echo "Nothing to remove: the guest cluster has no namespace '${HEADLAMP_NAMESPACE}'"
elif [ "$L" != "${HEADLAMP_NAMESPACE}/headlamp-guide" ]; then
  echo "Not removing '${HEADLAMP_NAMESPACE}': this guide did not make that namespace, or it could not be read. Nothing was changed."
elif helm --kubeconfig "$GUEST_KUBECONFIG" --namespace "$HEADLAMP_NAMESPACE" uninstall headlamp --ignore-not-found --wait; then
  kubectl --kubeconfig "$GUEST_KUBECONFIG" delete namespace "$HEADLAMP_NAMESPACE" --ignore-not-found
  echo "left (nothing after the colon means gone): $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o name || echo unknown)"
else
  echo "Not removed: helm refused (see the error above), so the namespace is kept."
fi
```

**Expect:** `release "headlamp" uninstalled`, `namespace "headlamp" deleted` (it can take a
minute), then `left (nothing after the colon means gone):` with nothing after it. Tokens made
earlier stop working: their account is gone.

**If not:**
- `Not removing … this guide did not make that namespace`: the namespace does not carry this
  guide's mark. If it is yours, remove it the way it was made.
- `Not removed: helm refused`: the line above says why; `Kubernetes cluster unreachable` means
  this machine cannot reach the cluster.

## Headlamp on your machine

The desktop program runs on your machine and reads the guest cluster's kubeconfig. Nothing is
installed on the cluster.

**Read this first.** `$GUEST_KUBECONFIG` is the cluster's administrator login. Headlamp opened
with it can do everything on the cluster: delete workloads, read every Secret, open a shell in a
pod. Whoever sits at your machine while it is open has those rights. For a page other people
open, with a login that can only read, use one of the two ways above.

### Install the desktop program

**macOS:**

```sh
brew install --cask headlamp
```

**Expect:** Homebrew's install lines, ending with `headlamp was successfully installed!`.

**Linux (Debian/Ubuntu, Intel or AMD):** this downloads Headlamp's package and compares it with
the checksum the project publishes.

```sh
source ~/.vks-golang-web.env
D="$(mktemp -d)"
F="headlamp_${HEADLAMP_VERSION}-1_amd64.deb"
curl -fsSL --connect-timeout 10 -o "$D/checksums.txt" "https://github.com/kubernetes-sigs/headlamp/releases/download/v${HEADLAMP_VERSION}/checksums.txt"
curl -fsSL --connect-timeout 10 -o "$D/$F" "https://github.com/kubernetes-sigs/headlamp/releases/download/v${HEADLAMP_VERSION}/${F}"
if ( cd "$D" && grep " ${F}\$" checksums.txt | sha256sum -c - ); then
  mkdir -p "$HOME/Downloads"
  mv "$D/$F" "$HOME/Downloads/$F"
  echo "saved: $HOME/Downloads/$F"
else
  echo "NOT saved: the download failed or its checksum does not match (see the lines above)"
fi
rm -rf "$D"
```

**Expect:** `headlamp_<version>-1_amd64.deb: OK`, then `saved: <your home>/Downloads/headlamp_<version>-1_amd64.deb`.

**If not:** `NOT saved: …` — a `curl: (22) … 404` line above it means `HEADLAMP_VERSION` is not a
released version; `curl: (28)` or `(6)`, that this machine cannot reach github.com. A line with
`FAILED` means the file is not the one the project published: do not install it; run the block
again.

Then install the package:

```sh
source ~/.vks-golang-web.env
sudo apt-get install -y "$HOME/Downloads/headlamp_${HEADLAMP_VERSION}-1_amd64.deb"
```

**Expect:** the install ends without an `E:` line. A line starting with `N: Download is performed
unsandboxed as root` is fine.

On other Linux machines (ARM, or not Debian/Ubuntu) the project publishes an AppImage, a
`tar.gz` and a Flatpak:
[Headlamp's Linux installation page](https://headlamp.dev/docs/latest/installation/desktop/linux-installation/).
The Flatpak can read only `~/.kube/config`, not `$GUEST_KUBECONFIG`.

### Open Headlamp with the guest cluster

This starts Headlamp with the guest cluster's kubeconfig and no other.

**macOS:**

```sh
source ~/.vks-golang-web.env
if [ -s "$GUEST_KUBECONFIG" ]; then
  KUBECONFIG="$GUEST_KUBECONFIG" open -n -a Headlamp --args "$GUEST_KUBECONFIG"
else
  echo "No kubeconfig at ${GUEST_KUBECONFIG}: run the main guide's 'Get the guest cluster's kubeconfig' first"
fi
```

**Expect:** nothing is printed, and the Headlamp window opens.

**Linux:** the program runs until you close its window; the terminal is busy until then.

```sh
source ~/.vks-golang-web.env
if [ -s "$GUEST_KUBECONFIG" ]; then
  KUBECONFIG="$GUEST_KUBECONFIG" "$(command -v headlamp || echo /opt/Headlamp/headlamp)" "$GUEST_KUBECONFIG"
else
  echo "No kubeconfig at ${GUEST_KUBECONFIG}: run the main guide's 'Get the guest cluster's kubeconfig' first"
fi
```

**Expect:** the Headlamp window opens; the terminal may print the program's own log lines.

On both, the window shows one cluster, named after your guest cluster's context. Click it: the
overview shows the nodes, all `Ready`, and the namespaces. You are not asked for a token: the
kubeconfig is the login.

**If not:**
- `No kubeconfig at …`: the file is missing or empty. The main guide's *Get the guest cluster's
  kubeconfig* writes it.
- The window shows other clusters, and not yours: Headlamp was already running and kept its
  earlier list. Quit it, then run the block again.
- The cluster is listed, and opening it shows an error or never loads: this machine cannot
  reach the cluster's address. `kubectl --kubeconfig "$GUEST_KUBECONFIG" get nodes` in the
  terminal fails the same way; fix that first (main guide, *Check the guest cluster*).
- Linux, `The SUID sandbox helper binary was found, but is not configured correctly`, or no
  window at all: install the `.deb` package as above, not the AppImage or the `tar.gz`.

To remove the desktop program: `brew uninstall --cask headlamp` on macOS,
`sudo apt-get remove -y headlamp` on Linux. Nothing was put on the cluster.

## Fix common problems

| symptom | fix |
|---|---|
| The add-on stays `Ready=False`: `Expected to find kind 'cert-manager.io/v1/Issuer', but did not` | The cluster has no cert-manager. Install it ([cert-manager](CERT-MANAGER.md)), then run *Install the add-on* again. |
| The browser warns about the certificate at Headlamp's address | Expected with the add-on's own settings: *Open the page* says why and what to do. |
| You created an `AddonConfig` yourself and nothing changed | VKS acts only on the one it made, `<your cluster>-headlamp`. *Change the add-on's settings* changes that one. |
| The chart's pod is rejected: `violates PodSecurity "restricted:latest"` | The chart was installed without this guide's values file. Run *Install Headlamp* from inside your clone. |
| Headlamp's page shows `Forbidden` on Secrets or nodes | The read-only role does not cover them. That is intended. |
| The token stopped working | It is valid for `HEADLAMP_TOKEN_HOURS` hours. Make a new one. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended. Run the main guide's *Renew the Supervisor login* block. |
| `helm: command not found` | *Check helm* says how to install it. Only the helm way needs it. |

## Next

Go back to [the add-ons overview](README.md) or to [the main guide](../README.md).
