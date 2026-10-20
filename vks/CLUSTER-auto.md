# Create a guest cluster, with scripts

This guide creates a Kubernetes cluster (a *VKS guest cluster*) in your vSphere Namespace with
command blocks only: `kubectl` on the Supervisor and one file. Every value it needs is printed
by a block.

The same result by hand, in the vSphere Client, is in [CLUSTER-manual.md](CLUSTER-manual.md). If
you already have a cluster, you need neither: see [CLUSTER.md](CLUSTER.md).

It continues [the main guide](README.md) after its Supervisor login, and comes after
[Use or create a vSphere Namespace](NAMESPACE.md). You need the main guide's env file, its tools
and its Supervisor login, and a vSphere Namespace that passed
[Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have). The **Edit** role on
that namespace is enough: you do not have to be a vCenter administrator.

The cluster is one object, described in one file,
[`templates/cluster.yaml`](templates/cluster.yaml). You look up what your Supervisor offers,
write your choices into the env file, fill the file from it, and apply it to your vSphere
Namespace; VKS then builds the virtual machines. It needs VKS 3.5 or later (the form of the
`Cluster` object used here, `cluster.x-k8s.io/v1beta2`, arrived with 3.5), and was written for
VMware Cloud Foundation 9.1.1 and VKS 3.7.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside
your `golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where
it can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells
you what to do.

## Install envsubst

`envsubst` fills the `${…}` places of a file from your settings. The block installs it only when
it is missing: with Homebrew on macOS, with apt on Debian and Ubuntu.

```sh
if command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is already installed"
elif [ "$(uname -s)" = Darwin ]; then
  brew install gettext
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y gettext-base
else
  echo "Not macOS, Debian or Ubuntu: install gettext with your system's package manager"
fi
```

**Expect:** `envsubst is already installed`, or the install's lines ending without an error. On
Linux, `sudo` may ask for your password.

Then, on both, check the tools and the namespace:

```sh
source ~/.vks-golang-web.env
for t in envsubst jq kubectl; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
[ -f vks/templates/cluster.yaml ] || echo "MISSING: vks/templates/cluster.yaml (run this from inside your golang-web clone)"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** no `MISSING` line, then your vSphere Namespace, `Active`.

**If not:**
- `MISSING: envsubst` on macOS after the install: Homebrew's folder is not in your `PATH`; run
  the Homebrew `PATH` block under [Install Homebrew (macOS only)](SETUP.md#install-homebrew-macos-only).
- `MISSING: vks/templates/cluster.yaml`: `cd` into your clone, then run the block again.
- `NotFound` or `Forbidden`: do [NAMESPACE.md](NAMESPACE.md) first. `Unauthorized`: run the main
  guide's *Renew the Supervisor login* block.

## Add the cluster's settings

This adds the cluster's ten settings to your env file, each only if it is not there yet. Values
you already set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export K8S_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export K8S_VERSION=""' >> ~/.vks-golang-web.env
  grep -qs '^export CLUSTER_CLASS=' ~/.vks-golang-web.env || printf '%s\n' 'export CLUSTER_CLASS=""' >> ~/.vks-golang-web.env
  grep -qs '^export CLUSTER_CLASS_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export CLUSTER_CLASS_NAMESPACE="vmware-system-vks-public"' >> ~/.vks-golang-web.env
  grep -qs '^export VM_CLASS=' ~/.vks-golang-web.env || printf '%s\n' 'export VM_CLASS=""' >> ~/.vks-golang-web.env
  grep -qs '^export STORAGE_CLASS=' ~/.vks-golang-web.env || printf '%s\n' 'export STORAGE_CLASS=""' >> ~/.vks-golang-web.env
  grep -qs '^export CONTROL_PLANE_REPLICAS=' ~/.vks-golang-web.env || printf '%s\n' 'export CONTROL_PLANE_REPLICAS="1"' >> ~/.vks-golang-web.env
  grep -qs '^export WORKER_REPLICAS=' ~/.vks-golang-web.env || printf '%s\n' 'export WORKER_REPLICAS="2"' >> ~/.vks-golang-web.env
  grep -qs '^export PODS_CIDR=' ~/.vks-golang-web.env || printf '%s\n' 'export PODS_CIDR="172.20.0.0/16"' >> ~/.vks-golang-web.env
  grep -qs '^export SERVICES_CIDR=' ~/.vks-golang-web.env || printf '%s\n' 'export SERVICES_CIDR="172.21.0.0/16"' >> ~/.vks-golang-web.env
  grep -qs '^export CLUSTER_WAIT_MINUTES=' ~/.vks-golang-web.env || printf '%s\n' 'export CLUSTER_WAIT_MINUTES="15"' >> ~/.vks-golang-web.env
  grep -c -E '^export (K8S_VERSION|CLUSTER_CLASS|CLUSTER_CLASS_NAMESPACE|VM_CLASS|STORAGE_CLASS|CONTROL_PLANE_REPLICAS|WORKER_REPLICAS|PODS_CIDR|SERVICES_CIDR|CLUSTER_WAIT_MINUTES)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `10`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 10 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

## Look up what your Supervisor offers

Four lookups, each read-only. Note one value from each; the next section writes them down.

### List the Kubernetes releases

This lists the Kubernetes versions the Supervisor can build a cluster with: the releases that
are both ready and compatible, newest last.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr -o json | jq -r '.items[] | select([.status.conditions[]? | select(.type == "Ready" or .type == "Compatible") | .status] | length == 2 and all(. == "True")) | .spec.version | sub("-vkr\\.[0-9]+$"; "")' | sort -u | sort -t. -k2,2n -k3,3n -k4,4n | tail -5
```

**Expect:** up to five versions, such as `v1.36.2+vmware.2`. The list shows each version
without the `-vkr.N` ending its release name has: that is how the Supervisor stores it, and how
you write it. (The full name that `kubectl get kr` prints is accepted too; the Supervisor then
stores the short form.)

**If not:** no output — no release is both ready and compatible. On a Supervisor that was
switched on minutes ago, wait ten minutes and run the block again. If the list stays empty,
the Supervisor's Kubernetes content library has not synchronized, or holds no release this
Supervisor can use: **If not** under *Create the cluster and wait for it* says what to do
(synchronize that library in the vSphere Client; these guides do not show its page).
`Unauthorized`: run the main guide's *Renew the Supervisor login* block.

### List the VM classes

This lists the virtual machine sizes your vSphere Namespace may use.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineclass
```

**Expect:** at least one class with its `CPU` and `MEMORY`, such as `best-effort-small   2   4Gi`.

**If not:** `No resources found in <your namespace> namespace.` — no VM class is assigned to the
namespace: see [NAMESPACE.md](NAMESPACE.md).

### List the storage classes

This lists the storage classes your vSphere Namespace may use.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get storagepolicyquota -o jsonpath='{range .items[*].status.total[*]}{.storageClassName}{"\n"}{end}' | sort -u
```

**Expect:** at least one name. A name that ends in `-latebinding` is the same disk with a
different timing; take the name without that ending.

`kubectl get storageclass` lists more: every storage class of the whole Supervisor, including
those of other namespaces, which your cluster cannot use. Choose from the list above.

**If not:** no output — no storage policy is assigned to the namespace, or your user may not
read it: see [NAMESPACE.md](NAMESPACE.md).

### List the cluster classes

A cluster class is VKS's own template for a cluster; each one supports a range of Kubernetes
versions. This lists them with that range.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get clusterclass -o json | jq -r '.items[] | "\(.metadata.name)  Kubernetes \(.metadata.labels["kubernetes.vmware.com/min-version-supported"] // "?") to \(.metadata.labels["kubernetes.vmware.com/max-version-supported"] // "?")"' | sort -t. -k1,1 -k2,2n
```

**Expect:** one class per line, such as `builtin-generic-v3.7.0  Kubernetes v1.33 to v1.36`. Take
the newest class whose range includes the version you chose. A class that is too old for the
version is refused when you apply the cluster. The number in a class's name is not your VKS
version: a class is made for each minor release of VKS, so `builtin-generic-v3.7.0` is still the
newest one under VKS 3.7.2.

**If not:** a range shown as `? to ?`: this VKS version does not publish the range; take the
newest class. No output: the VKS service is not running on this Supervisor. Its row,
**Kubernetes Service**, is in the list of the Supervisor's services: the Supervisor's
**Configure** tab → **Supervisor Services** → **Overview**.

## Choose the cluster's values

Open the env file and set these lines:

| setting | value |
|---|---|
| `VKS_CLUSTER` | the cluster's name: lower-case letters, digits and `-`. **Use a name no cluster in this namespace ever had** (see *Never reuse a cluster's name* below) |
| `K8S_VERSION` | one version from the first list, exactly as printed (no `-vkr.N` ending) |
| `CLUSTER_CLASS` | one class from the last list |
| `VM_CLASS` | one class from the VM class list; every node gets this size |
| `STORAGE_CLASS` | one name from the storage class list |
| `CONTROL_PLANE_REPLICAS` | `1`, or `3` for a cluster that must stay up when a node fails |
| `WORKER_REPLICAS` | the number of worker nodes (see the sizes below) |
| `PODS_CIDR`, `SERVICES_CIDR` | the address ranges used inside the cluster |
| `CLUSTER_WAIT_MINUTES` | how long *Create the cluster and wait for it* waits; keep `15` |

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
block reads the new values.

**Sizes.** Only worker nodes run your apps; the control-plane node does not.

| what will run | control plane | workers | VM class |
|---|---|---|---|
| this guide's app | 1 | 2 | 2 CPUs and 4 GB (`best-effort-small`) |
| the app and the Istio add-on | 1 | 2 | 2 CPUs and 8 GB (`best-effort-medium`), or 3 workers of the smaller class |

Istio's control program asks for 2 GB of memory per copy and runs two copies unless you change
it; a 4 GB worker has less than 3 GB free for apps, so two small workers leave no room beside
it. You can also start small: changing `WORKER_REPLICAS` and applying the file again adds
workers. A `guaranteed-…` class reserves its whole CPU and memory on the
hosts; choose `best-effort-…` unless you know the hosts have the room.

**Address ranges.** `PODS_CIDR` and `SERVICES_CIDR` exist only inside the cluster, but they
**must not overlap any network the cluster has to reach**: your vSphere management and workload
networks, the Supervisor's own service range, Harbor, your DNS servers, your workstation. A
cluster with an overlapping range starts and then cannot reach those addresses. The two defaults
are right for most sites; ask your network administrator if your company uses `172.20.x.x` or
`172.21.x.x`. The ranges cannot be changed after the cluster is created.

## Fill the cluster's description

This fills [`templates/cluster.yaml`](templates/cluster.yaml) from your env file, saves the
result as `~/.config/vks-golang-web/cluster.yaml`, and shows it. It refuses while any value is
empty: `envsubst` would write an empty value into the file without an error. It creates nothing.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/cluster.yaml"
M=""
for v in VKS_CLUSTER VKS_NAMESPACE PODS_CIDR SERVICES_CIDR CLUSTER_CLASS CLUSTER_CLASS_NAMESPACE K8S_VERSION CONTROL_PLANE_REPLICAS WORKER_REPLICAS VM_CLASS STORAGE_CLASS; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
if [ -n "$M" ]; then
  echo "Not filled: no value for:$M"
elif [ ! -f vks/templates/cluster.yaml ]; then
  echo "Not filled: run this block from inside your golang-web clone"
elif ! command -v envsubst >/dev/null 2>&1; then
  echo "Not filled: envsubst is missing (Install envsubst, above)"
else
  mkdir -p "$(dirname "$OUT")"
  ( umask 077; envsubst '${VKS_CLUSTER} ${VKS_NAMESPACE} ${PODS_CIDR} ${SERVICES_CIDR} ${CLUSTER_CLASS} ${CLUSTER_CLASS_NAMESPACE} ${K8S_VERSION} ${CONTROL_PLANE_REPLICAS} ${WORKER_REPLICAS} ${VM_CLASS} ${STORAGE_CLASS}' \
      < vks/templates/cluster.yaml > "$OUT" )
  cat "$OUT"
fi
```

**Expect:** the cluster's description, with your name, namespace, version and classes, and no
`${` left in it. Your storage class appears twice: as `storageClass`, for the nodes' own disks,
and as `defaultStorageClass`, for the disks your apps ask for. Without the second one the
cluster starts and looks healthy, and every app that asks for a disk then waits forever.

**If not:** `Not filled: no value for: …` — each name listed is empty in the env file, or its
line lacks the word `export`. Set it (*Choose the cluster's values*), then run the block again.

## Never reuse a cluster's name

A guest cluster created under a name that another cluster in the same namespace had before can
come up with the old cluster's address. Its virtual machines start, and it never becomes
available; nothing in its status says why. Deleting it and creating it again under the same name
does not help. So `VKS_CLUSTER` must be a name that was never used in this namespace: after a
`dev-1`, take `dev-2`. The next block refuses a name that is in use or not yet released, and the
wait after it stops as soon as it sees the wrong address.

## Install Harbor first, if you will install it

Installing or uninstalling Harbor on the Supervisor replaces every node of every guest cluster
on it. If you will install Harbor on this Supervisor, do it before you create the cluster:
[Install Harbor before you create clusters](CLUSTER.md#install-harbor-before-you-create-clusters)
says why, and has a block that shows whether a replacement is running.

## Check the description on the Supervisor

This asks the Supervisor to check the description without creating anything
(`--dry-run=server`). The Supervisor checks the version, the classes and your permissions.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/cluster.yaml"
if [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found -o name || echo unknown)" ]; then
  echo "A cluster named '${VKS_CLUSTER}' already exists in '${VKS_NAMESPACE}', or the Supervisor did not answer: not checked"
elif [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineservice "$VKS_CLUSTER" --ignore-not-found -o name || echo unknown)" ]; then
  echo "STOP: the name '${VKS_CLUSTER}' still holds the address of an earlier cluster. Choose a name that was never used here."
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply --dry-run=server -f "$OUT"
fi
```

**Expect:** `cluster.cluster.x-k8s.io/<your cluster> created (server dry run)`.

**If not:**
- `A cluster named … already exists …`: if it is the cluster you are creating, go on to the next
  block, which changes nothing on a cluster that already matches. If it is someone else's,
  choose another `VKS_CLUSTER` and fill the description again. If a `kubectl` error is printed
  above the line, the Supervisor login ended: renew it (main guide).
- `STOP: the name … still holds the address …`: set `VKS_CLUSTER` to a new name, then run *Fill
  the cluster's description* and this block again.
- `the path "…cluster.yaml" does not exist`: run *Fill the cluster's description* first.
- `admission webhook … denied the request`, with a reason: the reason names the value.
  `Could not resolve KR/OSImage` — `K8S_VERSION` is not one of the listed versions.
  A message about the `ClusterClass` — `CLUSTER_CLASS` is not in the list, or is too old for the
  version. A message about the VM class or the storage class — that class is not assigned to
  your namespace. Fix the value, fill the description again, then run this block again.
- `no matches for kind "Cluster" in version "cluster.x-k8s.io/v1beta2"`: this Supervisor's VKS
  is older than 3.5 and does not know this form of the object. This chapter needs VKS 3.5 or
  later; it covers neither the older form nor the update of VKS.
- `Forbidden`: your SSO user lacks the **Edit** role on the namespace.

## Create the cluster and wait for it

This applies the description, then waits until VKS reports the cluster available. It prints one
line every 30 seconds, with what the first machine is waiting for. On a small lab a cluster of
three nodes took 4 to 9 minutes; yours depends on your hosts and storage. The first cluster of a
Kubernetes release takes longer: vCenter downloads that release's node image (several GB) once,
and until it has it the line ends with `cached files not ready`. The wait gives up after 15
minutes; set `CLUSTER_WAIT_MINUTES` in the env file for another limit, and run the block again
to keep waiting.

The block refuses a cluster of that name that it did not create itself: one ArgoCD manages, or
one made another way (in the vSphere Client, for example). Applying this description to such a
cluster would change its size and classes. Running the block again on your own cluster is fine.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/cluster.yaml"
EX=""
[ -z "$VKS_CLUSTER" ] || EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found -o name)" || EX=unknown
LA="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null)"
AR="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)"
MIN="${CLUSTER_WAIT_MINUTES:-15}"
case "$MIN" in
  ''|*[!0-9]*) echo "CLUSTER_WAIT_MINUTES is '${MIN}', not a whole number: waiting 15 minutes"; MIN=15 ;;
esac
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not applied: VKS_CLUSTER is empty"
elif [ "$(awk '$1 == "name:" {print $2; exit}' "$OUT" 2>/dev/null)" != "$VKS_CLUSTER" ]; then
  echo "Not applied: the filled description is missing, or is for another cluster. Run 'Fill the cluster's description' again."
elif [ "$EX" = unknown ]; then
  echo "Not applied: the Supervisor did not say whether '${VKS_CLUSTER}' exists (see the error above)"
elif [ -n "$EX" ] && [ -n "$AR" ]; then
  echo "Not applied: ArgoCD manages the cluster '${VKS_CLUSTER}'. Nothing was changed: change it in ArgoCD, or choose another VKS_CLUSTER."
elif [ -n "$EX" ] && [ -z "$LA" ]; then
  echo "Not applied: a cluster named '${VKS_CLUSTER}' already exists in '${VKS_NAMESPACE}' and this block did not create it. Nothing was changed: use it as it is, or choose another VKS_CLUSTER."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply -f "$OUT"; then
  n=0; A=""; W=""; R=""; MAX=$((MIN * 2))
  until [ "$A" = True ] || [ -n "$W" ] || [ "$n" -ge "$MAX" ]; do
    sleep 30; n=$((n + 1))
    A="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
    H="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null)"
    L="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineservice "$VKS_CLUSTER" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    R="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachine -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[?(@.status=="False")]}{.message}{"; "}{end}{"\n"}{end}' 2>/dev/null | grep "^${VKS_CLUSTER}-" | grep -v ': $' | head -n 1)"
    echo "$((n / 2)) min $((n % 2 * 30)) s: Available=${A:-not yet}  address=${H:-none yet}  ${R:+waiting: $R}"
    if [ -n "$H" ] && [ -n "$L" ] && [ "$H" != "$L" ]; then W="$H"; fi
  done
  if [ -n "$W" ]; then
    echo "STOP: the cluster uses the address ${W}, but its load balancer has ${L}. This cluster will never become available: delete it and create it under a name that was never used here."
  elif [ "$A" = True ]; then
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER"
  else
    echo "NOT AVAILABLE after $((n / 2)) minutes. ${R:+The first machine is waiting: $R}"
    echo "The cluster is still being built; run this block again to keep waiting, or read 'If not' below."
  fi
else
  echo "Not applied: see the error above"
fi
```

**Expect:** `cluster.cluster.x-k8s.io/<your cluster> created` (`unchanged` when you run it
again), then a line every 30 seconds: first `0 min 30 s: Available=False  address=none yet`,
then lines with the cluster's address and what the first machine waits for
(`Available=False  address=<an address>  waiting: <a machine>: <a message>`), and finally a line
with `Available=True`, followed by the cluster with `AVAILABLE` `True` and its control-plane and
worker counts. If the limit is reached first, the last two lines are
`NOT AVAILABLE after 15 minutes. …` and `The cluster is still being built; …`.

**If not:**
- `STOP: the cluster uses the address …`: the name was used before. Run *Delete the cluster*
  below, set `VKS_CLUSTER` to a new name, and start again at *Fill the cluster's description*.
- `NOT AVAILABLE after … waiting: … cached files not ready`: vCenter is still downloading the
  node image for this Kubernetes release (once per release). Run the block again to keep
  waiting. If the line has not changed after 10 minutes, the download is failing: open the
  content library that holds the Kubernetes releases in the vSphere Client and synchronize it
  (if your user may not change that library, a user that may must do this). An error there
  about the publisher's certificate means the library's stored certificate fingerprint is out
  of date and must be accepted again. After the repair, a cluster that already tried keeps
  showing `cached files not ready` for up to about 30 minutes and then goes on by itself: do
  not delete it, keep waiting.
- `NOT AVAILABLE after …` with another reason, or none:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe clusters.cluster.x-k8s.io "$VKS_CLUSTER"`
  shows the condition that is waiting. A VM class that is too small, a namespace limit that is
  reached, or a storage policy without room shows there. Other conditions go to `False` and
  back while the cluster is built; only `Available` says it is usable.
- `Not applied: the filled description is missing …`: you changed `VKS_CLUSTER` after filling
  the file. Fill it again.
- `Not applied: ArgoCD manages the cluster …`: the cluster carries ArgoCD's mark. Change its
  values in ArgoCD (the ArgoCD guide's *Create a guest cluster with ArgoCD*), not here.
- `Not applied: a cluster named … already exists … and this block did not create it`: the
  cluster was made another way. This chapter does not change it. To use it, go on with
  [Get the cluster's kubeconfig](CLUSTER.md#get-the-clusters-kubeconfig); to make your own,
  choose another `VKS_CLUSTER`.
- `CLUSTER_WAIT_MINUTES is '…', not a whole number`: the block still runs, with 15 minutes. Fix
  the line in the env file.

Never switch a guest cluster's virtual machines on or off in the vSphere Client: VKS owns them
and puts them back the way it wants them.

### Check the machines

This lists the cluster's machines as VKS sees them.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get machine -l "cluster.x-k8s.io/cluster-name=${VKS_CLUSTER}"
```

**Expect:** one machine per node (control plane plus workers), each with `PHASE` `Running` and
the version you chose.

**If not:** a machine in `Provisioning` for more than 15 minutes: the `describe` command above
says why. `No resources found`: check `VKS_CLUSTER`.

## Get the kubeconfig and check the cluster

The cluster is built. Now run the two blocks under
[Get the cluster's kubeconfig](CLUSTER.md#get-the-clusters-kubeconfig) and
[Check the cluster](CLUSTER.md#check-the-cluster): they save the cluster's kubeconfig, match
your `kubectl` to it, and check the nodes and the default storage class.

## Delete the cluster

**This destroys the cluster, its virtual machines and every disk its apps created.** The block
deletes the cluster on the Supervisor and, only if the Supervisor accepted that, waits until the
cluster and its address are gone (a few minutes; it gives up after 30). It refuses a cluster
ArgoCD manages. Do not switch the virtual machines off yourself.

```sh
source ~/.vks-golang-web.env
AR="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)"
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not deleting: VKS_CLUSTER is empty"
elif [ -n "$AR" ]; then
  echo "Not deleting '${VKS_CLUSTER}': ArgoCD manages it and would create it again. Delete it with the ArgoCD guide's clean-up step."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found --wait=false; then
  n=0; LEFT=unknown
  until [ -z "$LEFT" ] || [ "$n" -ge 120 ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io,virtualmachineservice "$VKS_CLUSTER" --ignore-not-found -o name || echo unknown)"
  done
  echo "left (nothing after the colon means gone): ${LEFT}"
  if [ -z "$LEFT" ]; then rm -f "$GUEST_KUBECONFIG" "$HOME/.config/vks-golang-web/cluster.yaml"; fi
else
  echo "Not deleted: the Supervisor refused (see the error above), so nothing is waited for and no file is removed."
fi
```

**Expect:** `cluster.cluster.x-k8s.io "<your cluster>" deleted`, and within a few minutes
`left (nothing after the colon means gone):` with nothing after it. The cluster's kubeconfig and
its filled description are then removed from this machine.

**If not:**
- `Not deleting: VKS_CLUSTER is empty`: set it in the env file.
- `Not deleting … ArgoCD manages it …`: the cluster carries ArgoCD's mark (the annotation
  `argocd.argoproj.io/tracking-id`, or the label `app.kubernetes.io/instance`). Use the ArgoCD
  guide's *Delete the guest cluster* block.
- `Not deleted: the Supervisor refused …`: `Forbidden` above it means your user lacks the
  **Edit** role; `Unauthorized`, that the Supervisor login ended (main guide, *Renew the
  Supervisor login*).
- A name, or `unknown`, after the colon: the cluster is still being deleted, or the Supervisor
  login ended. The kubeconfig is kept. Run the block again before you create another cluster.

Do not create the next cluster under the same name.

## Fix common problems

| symptom | fix |
|---|---|
| `envsubst: command not found` | Run *Install envsubst*. |
| `Not filled: no value for: …` | A setting is empty, or its line in the env file lacks `export`. *Choose the cluster's values* lists them. |
| The cluster stays `Available=not yet` and the block prints `STOP: the cluster uses the address …` | The name was used before in this namespace. Delete the cluster and use a new name. |
| The cluster is available but an app's disk request (`PersistentVolumeClaim`) stays `Pending` | [Check the cluster](CLUSTER.md#check-the-cluster) prints the default storage class. `NONE` means the description lacked `defaultStorageClass`. |
| `no matches for kind "Cluster" in version "cluster.x-k8s.io/v1beta2"` | The Supervisor's VKS is older than 3.5. This chapter needs 3.5 or later. |
| `admission webhook … denied the request: Could not resolve KR/OSImage` | `K8S_VERSION` is not a release that is ready and compatible. Take one from *List the Kubernetes releases*, exactly as printed. |
| A node's pods stay `Pending` with `Insufficient memory` or `Insufficient cpu` | The workers are too small for what you run. Raise `WORKER_REPLICAS`, fill the description and apply it again; or create a new cluster with a larger `VM_CLASS`. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block. |

## Next

Run the two blocks under
[Get the cluster's kubeconfig](CLUSTER.md#get-the-clusters-kubeconfig), then go back to the main
guide's [Deploy the app](README.md#deploy-the-app) and deploy the app onto the new cluster.
