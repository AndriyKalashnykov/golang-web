# cert-manager: certificates for what runs on the guest cluster

[cert-manager](https://cert-manager.io/) makes and renews TLS certificates inside a cluster.
Software on the cluster asks for a certificate with a `Certificate` object, and cert-manager
writes the certificate into a Secret. In these guides you need it for one reason: **other
add-ons need it.** The [Headlamp](HEADLAMP.md) add-on does not start without it, and a gateway
that serves HTTPS can get its certificate from it.

This chapter installs cert-manager as a VKS add-on. It is optional and comes after the main
guide's *Check the guest cluster*. You need [the main guide](../README.md)'s env file, its
Supervisor login, the guest cluster's kubeconfig, and `envsubst`
([Install envsubst](../CLUSTER.md#install-envsubst)). Your SSO user needs the **Edit** role on the
vSphere Namespace. It was written for VMware Cloud Foundation 9.1.1 and VKS 3.7.

cert-manager is installed from the **Supervisor**: you describe it in one object there, and VKS
puts it into the guest cluster. Each block says which one it talks to.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside
your `golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where
it can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells
you what to do.

## Add cert-manager's settings

This adds cert-manager's four settings to your env file, each only if it is not there yet.
Values you already set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export ADDON_CATALOG_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export ADDON_CATALOG_NAMESPACE="vmware-system-vks-public"' >> ~/.vks-golang-web.env
  grep -qs '^export ADDON_WAIT_MINUTES=' ~/.vks-golang-web.env || printf '%s\n' 'export ADDON_WAIT_MINUTES="10"' >> ~/.vks-golang-web.env
  grep -qs '^export CERT_MANAGER_ADDON_RELEASE=' ~/.vks-golang-web.env || printf '%s\n' 'export CERT_MANAGER_ADDON_RELEASE=""' >> ~/.vks-golang-web.env
  grep -qs '^export CERT_MANAGER_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export CERT_MANAGER_NAMESPACE="cert-manager"' >> ~/.vks-golang-web.env
  grep -c -E '^export (ADDON_CATALOG_NAMESPACE|ADDON_WAIT_MINUTES|CERT_MANAGER_ADDON_RELEASE|CERT_MANAGER_NAMESPACE)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `4`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 4 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

| setting | meaning |
|---|---|
| `CERT_MANAGER_ADDON_RELEASE` | the cert-manager release to install; empty until you choose one below |
| `CERT_MANAGER_NAMESPACE` | the namespace on the guest cluster cert-manager runs in. The add-on uses `cert-manager`; this chapter only reads it |
| `ADDON_WAIT_MINUTES` | how long an install block waits for an add-on to become ready |
| `ADDON_CATALOG_NAMESPACE` | where the Supervisor keeps its add-on catalogue |

## Check whether the cluster already has cert-manager

A cluster can have cert-manager already: as a VKS add-on that you or a colleague installed, or
put there another way (a helm chart, a manifest). This block looks for both and says which it
found. It is read-only.

```sh
source ~/.vks-golang-web.env
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-cert-manager" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.status.conditions[?(@.type=="Ready")].status}')" || CA=unknown
CRD="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd certificates.cert-manager.io --ignore-not-found -o name)" || CRD=unknown
if [ "$CA" = unknown ] || [ "$CRD" = unknown ]; then
  echo "cert-manager on '${VKS_CLUSTER}': NOT KNOWN, a cluster did not answer (see the error above)"
elif [ -n "$CA" ]; then
  echo "cert-manager on '${VKS_CLUSTER}': a VKS add-on, Ready=${CA#*/}"
elif [ -n "$CRD" ]; then
  echo "cert-manager on '${VKS_CLUSTER}': installed another way, not as a VKS add-on. Its pods:"
  kubectl --kubeconfig "$GUEST_KUBECONFIG" get pods --all-namespaces | grep -i cert-manager
else
  echo "cert-manager on '${VKS_CLUSTER}': none"
fi
```

**Expect:** one of three answers:

- `cert-manager on '<your cluster>': none` — go on with this chapter.
- `cert-manager on '<your cluster>': a VKS add-on, Ready=True` — it is installed. Skip to
  [Check cert-manager on the guest cluster](#check-cert-manager-on-the-guest-cluster).
- `cert-manager on '<your cluster>': installed another way, not as a VKS add-on. Its pods:` and
  the pods — somebody put it there with helm or a manifest. Use that one and stop here: the
  install block below refuses, because two cert-managers on one cluster work against each
  other.

**If not:**
- `… a VKS add-on, Ready=False`, or nothing after `Ready=`: the add-on is being installed, or
  cannot finish. [Install cert-manager](#install-cert-manager), **If not**, shows how to read
  why.
- `… NOT KNOWN …`: the line above says which cluster did not answer. `Unauthorized` from the
  Supervisor: run the main guide's *Renew the Supervisor login* block.

## Choose the cert-manager release

This lists the cert-manager releases your Supervisor offers, oldest first. It is read-only.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease -o name | sed -n 's|^.*/\(cert-manager\.\)|\1|p' | sort -t. -k5,5n -k6,6n -k7,7n -k8,8n
```

**Expect:** one release per line, such as `cert-manager.kubernetes.vmware.com.1.21.1-vmware.2-vks.1`.
Which ones you see depends on your VKS version. Take the newest (the last line) unless you need
another one.

**If not:**
- No output: this Supervisor's catalogue has no cert-manager. Right after VKS was installed or
  updated the catalogue arrives over about ten minutes: run the block again then. If it stays
  empty, tell your administrator.
- `the server doesn't have a resource type "addonrelease"`: this Supervisor's VKS has no add-on
  catalogue; this chapter cannot be used on it.
- `Unauthorized`: run the main guide's *Renew the Supervisor login* block.

Open the env file and set `CERT_MANAGER_ADDON_RELEASE` to one line of the list, exactly as
printed:

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
block reads the new value.

## Fill and check the install description

This fills [`templates/addoninstall.yaml`](templates/addoninstall.yaml) from your env file, saves
the result as `~/.config/vks-golang-web/cert-manager-addoninstall.yaml`, shows it, and asks the
Supervisor to check it without creating anything (`--dry-run=server`). It first checks that the
release exists: the Supervisor accepts an install description that names a release it does not
have, and then never installs anything.

```sh
source ~/.vks-golang-web.env
export ADDON_NAME="cert-manager" ADDON_INSTALL="${VKS_CLUSTER}-cert-manager-addon" ADDON_RELEASE="$CERT_MANAGER_ADDON_RELEASE"
OUT="$HOME/.config/vks-golang-web/cert-manager-addoninstall.yaml"
M=""
for v in VKS_CLUSTER VKS_NAMESPACE ADDON_CATALOG_NAMESPACE CERT_MANAGER_ADDON_RELEASE; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
REL=""
[ -n "$M" ] || REL="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$ADDON_CATALOG_NAMESPACE" get addonrelease "$ADDON_RELEASE" --ignore-not-found -o name)" || REL=unknown
if [ -n "$M" ]; then
  echo "Not filled: no value for:$M"
elif [ "$REL" = unknown ]; then
  echo "Not filled: the Supervisor did not answer (see the error above)"
elif [ -z "$REL" ]; then
  echo "Not filled: the Supervisor offers no release '${ADDON_RELEASE}'. Set CERT_MANAGER_ADDON_RELEASE to a line from 'Choose the cert-manager release'."
elif [ ! -f vks/addons/templates/addoninstall.yaml ]; then
  echo "Not filled: run this block from inside your golang-web clone"
elif ! command -v envsubst >/dev/null 2>&1; then
  echo "Not filled: envsubst is missing (CLUSTER.md, 'Install envsubst')"
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
`addoninstall.addons.kubernetes.vmware.com/<your cluster>-cert-manager-addon created (server dry run)`
(`configured` or `unchanged` when cert-manager is already installed).

**If not:**
- `Not filled: no value for: …`: each name listed is empty in the env file, or its line lacks
  the word `export`.
- `Not filled: the Supervisor offers no release …`: `CERT_MANAGER_ADDON_RELEASE` is not a line
  of the list. Copy one again.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.
- `no matches for kind "AddonInstall"`: this Supervisor's VKS has no add-on catalogue.

## Install cert-manager

This applies the description on the Supervisor and waits until VKS reports cert-manager ready on
your cluster, with one line every 15 seconds. On a small lab it took 30 seconds. It gives up
after `ADDON_WAIT_MINUTES` (10); run the block again to keep waiting.

The block refuses an `AddonInstall` of that name that this guide did not make, a cluster that
already has cert-manager from another `AddonInstall`, and a cluster that has a cert-manager put
there another way.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/cert-manager-addoninstall.yaml"
AI="${VKS_CLUSTER}-cert-manager-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
CA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-cert-manager" --ignore-not-found -o name)" || CA=unknown
CRD="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd certificates.cert-manager.io --ignore-not-found -o name)" || CRD=unknown
MIN="${ADDON_WAIT_MINUTES:-10}"
case "$MIN" in
  ''|*[!0-9]*) echo "ADDON_WAIT_MINUTES is '${MIN}', not a whole number: waiting 10 minutes"; MIN=10 ;;
esac
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not installed: VKS_CLUSTER is empty"
elif [ "$(awk '$1 == "name:" {print $2; exit}' "$OUT" 2>/dev/null)" != "$AI" ]; then
  echo "Not installed: the filled description is missing, or is for another cluster. Run 'Fill and check the install description' again."
elif [ "$MINE" = unknown ] || [ "$CA" = unknown ] || [ "$CRD" = unknown ]; then
  echo "Not installed: a cluster did not answer (see the error above)"
elif [ -n "$MINE" ] && [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not installed: an AddonInstall '${AI}' exists and this guide did not make it. Nothing was changed."
elif [ -z "$MINE" ] && [ -n "$CA" ]; then
  echo "Not installed: '${VKS_CLUSTER}' already has cert-manager from another AddonInstall. Nothing was changed: use that one."
elif [ -z "$CA" ] && [ -n "$CRD" ]; then
  echo "Not installed: '${VKS_CLUSTER}' already has a cert-manager that is not a VKS add-on. Nothing was changed: use that one."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply -f "$OUT"; then
  n=0; R=""; MAX=$((MIN * 4))
  until [ "$R" = True ] || [ "$n" -ge "$MAX" ]; do
    sleep 15; n=$((n + 1))
    R="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-cert-manager" --ignore-not-found -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    echo "$((n * 15)) s: Ready=${R:-not yet}"
  done
  if [ "$R" != True ]; then
    echo "NOT READY after $((n * 15)) s. What VKS reports:"
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-cert-manager" --ignore-not-found -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  fi
else
  echo "Not installed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:**
`addoninstall.addons.kubernetes.vmware.com/<your cluster>-cert-manager-addon created`
(`unchanged` when you run it again), then a line every 15 seconds, the last one with
`Ready=True`.

**If not:**
- `Not installed: the filled description is missing …`: you changed `VKS_CLUSTER` after filling
  the file, or did not fill it. Run the block above again.
- `Not installed: … already has cert-manager from another AddonInstall`, or `… that is not a VKS
  add-on`: cert-manager is on the cluster already. Use it; this guide's remove block will not
  remove it.
- `NOT READY after …`, and under it VKS's own report, one condition per line. A line with
  `Reconciled=False` holds the reason. Then look at the pods:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$CERT_MANAGER_NAMESPACE" get pods`.
  `ImagePullBackOff` — the cluster's nodes cannot reach Broadcom's registry
  (`projects.packages.broadcom.com`); `Pending` with `Insufficient memory` — the workers are
  full.
- No condition lines at all under `NOT READY`: VKS did not match the description with your
  cluster. Check that `VKS_CLUSTER` is a cluster in `VKS_NAMESPACE`
  (`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io`).

VKS also makes an object named `<your cluster>-cert-manager` of the kind `AddonConfig` in your
vSphere Namespace. It holds cert-manager's settings. This chapter changes none of them. If you
ever do: change that object; an `AddonConfig` you create yourself applies nothing.

## Check cert-manager on the guest cluster

The Supervisor's `Ready=True` is VKS's report. This looks at the guest cluster itself: the
programs cert-manager consists of, and the object types it adds.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$CERT_MANAGER_NAMESPACE" get deployments
kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd certificates.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io -o name
```

**Expect:** three deployments, each with `READY` `1/1`: cert-manager itself, its `cainjector`
and its `webhook`; then three lines that start with
`customresourcedefinition.apiextensions.k8s.io/`.

**If not:**
- `No resources found in cert-manager namespace`: cert-manager is not on this cluster, or runs
  in another namespace:
  `kubectl --kubeconfig "$GUEST_KUBECONFIG" get deployments --all-namespaces | grep cert-manager`
  shows it; set `CERT_MANAGER_NAMESPACE` to that namespace.
- A deployment with `0/1`: wait a minute and run the block again.
- `… "issuers.cert-manager.io" not found`: the install has not finished; run *Install
  cert-manager* again and read its last line.

## Remove cert-manager

**This removes cert-manager from the guest cluster, and every certificate it keeps renewing
stops being renewed.** The block deletes this guide's `AddonInstall` on the Supervisor; VKS then
removes what it installed. It refuses:

- an `AddonInstall` this guide did not make;
- while the Headlamp add-on is on the cluster: it needs cert-manager. Remove Headlamp first
  ([Headlamp](HEADLAMP.md), *Remove the add-on*);
- while any `Certificate` object is left on the cluster: something still uses cert-manager.

Only if the Supervisor accepted the delete does it wait, up to `ADDON_WAIT_MINUTES`.

```sh
source ~/.vks-golang-web.env
AI="${VKS_CLUSTER}-cert-manager-addon"
MINE="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get addoninstall "$AI" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || MINE=unknown
HL="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusteraddon "${VKS_CLUSTER}-headlamp" --ignore-not-found -o name)" || HL=unknown
CERTS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get certificates.cert-manager.io --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{end}' 2>&1)" || case "$CERTS" in
  *"doesn't have a resource type"*) CERTS="" ;;
  *) CERTS="unknown (${CERTS})" ;;
esac
MIN="${ADDON_WAIT_MINUTES:-10}"
case "$MIN" in
  ''|*[!0-9]*) MIN=10 ;;
esac
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not removing: VKS_CLUSTER is empty"
elif [ -z "$MINE" ]; then
  echo "Nothing to remove: no AddonInstall '${AI}' in '${VKS_NAMESPACE}'"
elif [ "$MINE" != "${AI}/addons-guide" ]; then
  echo "Not removing '${AI}': this guide did not make it, or it could not be read. Nothing was changed."
elif [ -n "$HL" ]; then
  echo "Not removing: the Headlamp add-on on '${VKS_CLUSTER}' needs cert-manager, or it could not be looked up (${HL}). Remove Headlamp first."
elif [ -n "$CERTS" ]; then
  echo "Not removing: certificates on the cluster still use cert-manager, or could not be listed: ${CERTS}"
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete addoninstall "$AI" --wait=false; then
  n=0; LEFT=unknown; MAX=$((MIN * 4))
  until [ -z "$LEFT" ] || [ "$n" -ge "$MAX" ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get "addoninstall/${AI}" "clusteraddon/${VKS_CLUSTER}-cert-manager" --ignore-not-found -o name || echo unknown)"
  done
  echo "left on the Supervisor (nothing after the colon means gone): ${LEFT}"
  if [ -z "$LEFT" ]; then rm -f "$HOME/.config/vks-golang-web/cert-manager-addoninstall.yaml"; fi
else
  echo "Not removed: the Supervisor refused (see the error above), so nothing is waited for."
fi
```

**Expect:**
`addoninstall.addons.kubernetes.vmware.com "<your cluster>-cert-manager-addon" deleted`, and
within a few minutes `left on the Supervisor (nothing after the colon means gone):` with nothing
after it.

**If not:**
- `Not removing: the Headlamp add-on … needs cert-manager`: remove Headlamp first. `unknown` in
  the brackets means the Supervisor did not answer: renew the Supervisor login (main guide).
- `Not removing: certificates on the cluster still use cert-manager …`: the line names them
  (`namespace/name`). Remove what owns them first, and other people's only with their agreement.
  `unknown (…)` holds the error that stopped the listing.
- `Not removing … this guide did not make it`: the `AddonInstall` does not carry this guide's
  mark. Whoever installed cert-manager removes it.
- A name, or `unknown`, after the colon: VKS is still removing cert-manager, or the Supervisor
  login ended. Run the block again.

This shows what is left on the guest cluster.

```sh
source ~/.vks-golang-web.env
echo "namespace ${CERT_MANAGER_NAMESPACE}: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$CERT_MANAGER_NAMESPACE" --ignore-not-found -o jsonpath='{.status.phase}' || echo unknown)"
echo "cert-manager's object types: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get crd -o name | grep -c 'cert-manager\.io$')"
```

**Expect:** `namespace cert-manager:` with nothing after it (or `Terminating` for a minute), and
`cert-manager's object types: 0`.

**If not:** a number above 0: VKS left cert-manager's object types on the cluster. Without
cert-manager they do nothing.

cert-manager's settings stay in your env file, which the main guide's last clean-up block
deletes.

## Fix common problems

| symptom | fix |
|---|---|
| Another add-on stays `Ready=False` with `Expected to find kind 'cert-manager.io/v1/Issuer', but did not` | That add-on needs cert-manager and the cluster has none. Install it with this chapter, then run the other add-on's install block again: it waits until that add-on is ready. |
| The install description was accepted and nothing ever happens | It names a release the Supervisor does not have. *Fill and check the install description* checks that first; fill it again. |
| You created an `AddonConfig` yourself and nothing changed | VKS acts only on the one it made, `<your cluster>-cert-manager`. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended. Run the main guide's *Renew the Supervisor login* block. |

## Next

Go on with [Headlamp](HEADLAMP.md), or back to [the add-ons overview](README.md) or
[the main guide](../README.md).
