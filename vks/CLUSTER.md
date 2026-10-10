# Create a guest cluster with kubectl

This chapter comes after the Supervisor login of [the main guide](README.md) and after
[Use or create a vSphere Namespace](NAMESPACE.md). You need the main guide's env file, its tools
and its Supervisor login, and a vSphere Namespace that passed *Check the namespace you have*. At
the end you have a Kubernetes cluster (a *VKS guest cluster*), its kubeconfig, and a `kubectl`
that matches it.

The cluster is one object, described in one file,
[`templates/cluster.yaml`](templates/cluster.yaml). You look up what your Supervisor offers,
write your choices into the env file, fill the file from it, and apply it to your vSphere
Namespace; VKS then builds the virtual machines. It was written for VMware Cloud Foundation
9.1.1 and VKS 3.7.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside
your `golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where
it can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells
you what to do.

## Install envsubst

`envsubst` fills the `${…}` places of a file from your settings. Skip the install if
`envsubst --version` already works.

**macOS:**

```sh
brew install gettext
```

**Linux (Debian/Ubuntu):**

```sh
sudo apt-get update && sudo apt-get install -y gettext-base
```

**Expect:** the install ends without an error. Then check the tools and the namespace:

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
  the main guide's Homebrew `PATH` block.
- `MISSING: vks/templates/cluster.yaml`: `cd` into your clone, then run the block again.
- `NotFound` or `Forbidden`: do [NAMESPACE.md](NAMESPACE.md) first. `Unauthorized`: run the main
  guide's *Renew the Supervisor login* block.

## Add the cluster's settings

This adds the cluster's nine settings to your env file, each only if it is not there yet. Values
you already set are kept.

```sh
E="$HOME/.vks-golang-web.env"
if [ -f "$E" ]; then
  grep -qs '^export K8S_VERSION=' "$E" || printf '%s\n' 'export K8S_VERSION=""' >> "$E"
  grep -qs '^export CLUSTER_CLASS=' "$E" || printf '%s\n' 'export CLUSTER_CLASS=""' >> "$E"
  grep -qs '^export CLUSTER_CLASS_NAMESPACE=' "$E" || printf '%s\n' 'export CLUSTER_CLASS_NAMESPACE="vmware-system-vks-public"' >> "$E"
  grep -qs '^export VM_CLASS=' "$E" || printf '%s\n' 'export VM_CLASS=""' >> "$E"
  grep -qs '^export STORAGE_CLASS=' "$E" || printf '%s\n' 'export STORAGE_CLASS=""' >> "$E"
  grep -qs '^export CONTROL_PLANE_REPLICAS=' "$E" || printf '%s\n' 'export CONTROL_PLANE_REPLICAS="1"' >> "$E"
  grep -qs '^export WORKER_REPLICAS=' "$E" || printf '%s\n' 'export WORKER_REPLICAS="2"' >> "$E"
  grep -qs '^export PODS_CIDR=' "$E" || printf '%s\n' 'export PODS_CIDR="172.20.0.0/16"' >> "$E"
  grep -qs '^export SERVICES_CIDR=' "$E" || printf '%s\n' 'export SERVICES_CIDR="172.21.0.0/16"' >> "$E"
  grep -c -E '^export (K8S_VERSION|CLUSTER_CLASS|CLUSTER_CLASS_NAMESPACE|VM_CLASS|STORAGE_CLASS|CONTROL_PLANE_REPLICAS|WORKER_REPLICAS|PODS_CIDR|SERVICES_CIDR)=' "$E"
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `9`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 9 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

## Look up what your Supervisor offers

Four lookups, each read-only. Note one value from each; the next section writes them down.

### List the Kubernetes releases

This lists the Kubernetes versions the Supervisor can build a cluster with: the releases that
are both ready and compatible, newest last.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr -o json | jq -r '.items[] | select([.status.conditions[]? | select(.type == "Ready" or .type == "Compatible") | .status] | length == 2 and all(. == "True")) | .spec.version | sub("-vkr\\.[0-9]+$"; "")' | sort -t. -k2,2n -k3,3n -k4,4n | tail -5
```

**Expect:** up to five versions, such as `v1.36.2+vmware.2`. The list shows each version
without the `-vkr.N` ending its release name has: that is how the Supervisor stores it, and how
you write it.

**If not:** no output — no release is both ready and compatible. On a Supervisor that was
switched on minutes ago, wait ten minutes and run the block again; if the list stays empty, tell
your administrator. `Unauthorized`: run the main guide's *Renew the Supervisor login* block.

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
version is refused when you apply the cluster.

**If not:** a range shown as `? to ?`: this VKS version does not publish the range; take the
newest class. No output: the VKS service is not running on this Supervisor; tell your
administrator.

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

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Sizes.** Only worker nodes run your apps; the control-plane node does not.

| what will run | control plane | workers | VM class |
|---|---|---|---|
| this guide's app | 1 | 2 | 2 CPUs and 4 GB (`best-effort-small`) |
| the app and the Istio add-on | 1 | 2 | 2 CPUs and 8 GB (`best-effort-medium`), or 3 workers of the smaller class |

Istio's control program asks for 2 GB of memory per copy and runs two copies unless you change
it; a 4 GB worker has less than 3 GB free for apps, so two small workers leave no room beside
it. You can also start small: changing `WORKER_REPLICAS` and applying the file again adds
workers in under a minute each. A `guaranteed-…` class reserves its whole CPU and memory on the
hosts; choose `best-effort-…` unless your administrator says the hosts have the room.

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
- `Forbidden`: your SSO user lacks the **Edit** role on the namespace.

## Create the cluster and wait for it

This applies the description, then waits until VKS reports the cluster available. It prints one
line every 30 seconds. Expect 4 to 9 minutes; the wait gives up after 30.

```sh
source ~/.vks-golang-web.env
OUT="$HOME/.config/vks-golang-web/cluster.yaml"
if [ "$(awk '$1 == "name:" {print $2; exit}' "$OUT" 2>/dev/null)" != "$VKS_CLUSTER" ]; then
  echo "Not applied: the filled description is missing, or is for another cluster. Run 'Fill the cluster's description' again."
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" apply -f "$OUT"; then
  n=0; A=""; W=""
  until [ "$A" = True ] || [ -n "$W" ] || [ "$n" -ge 60 ]; do
    sleep 30; n=$((n + 1))
    A="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
    H="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null)"
    L="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineservice "$VKS_CLUSTER" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    echo "$((n / 2)) min $((n % 2 * 30)) s: Available=${A:-not yet}  address=${H:-none yet}"
    if [ -n "$H" ] && [ -n "$L" ] && [ "$H" != "$L" ]; then W="$H"; fi
  done
  if [ -n "$W" ]; then
    echo "STOP: the cluster uses the address ${W}, but its load balancer has ${L}. This cluster will never become available: delete it and create it under a name that was never used here."
  else
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io "$VKS_CLUSTER"
  fi
else
  echo "Not applied: see the error above"
fi
```

**Expect:** `cluster.cluster.x-k8s.io/<your cluster> created` (`unchanged` when you run it
again), then a line every 30 seconds — first `Available=not yet  address=none yet`, after a
minute or so with an address, and finally `Available=True` — then the cluster with
`AVAILABLE True` and its control-plane and worker counts.

**If not:**
- `STOP: the cluster uses the address …`: the name was used before. Run *Delete the cluster*
  below, set `VKS_CLUSTER` to a new name, and start again at *Fill the cluster's description*.
- Still `Available=not yet` after 30 minutes:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe clusters.cluster.x-k8s.io "$VKS_CLUSTER"`
  shows the condition that is waiting. A VM class that is too small, a namespace limit that is
  reached, or a storage policy without room shows there. Other conditions go to `False` and
  back while the cluster is built; only `Available` says it is usable.
- `Not applied: the filled description is missing …`: you changed `VKS_CLUSTER` after filling
  the file. Fill it again.

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

## Get the cluster's kubeconfig

This reads the guest cluster's kubeconfig from the Supervisor, saves it as `$GUEST_KUBECONFIG`
(the env file already points `kubectl` there), and installs the kubectl version that matches the
guest cluster; its `sudo` may ask for your password.

```sh
source ~/.vks-golang-web.env
( umask 077
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "$GUEST_KUBECONFIG" )
V="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Guest cluster: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Guest cluster: v1.<minor>…`, then `Client Version:` with the same `v1.<minor>`.

**If not:** `secrets "<name>-kubeconfig" not found` — check `VKS_CLUSTER`, and that the block
above ended with `Available=True`. `Forbidden` — the **Edit** role is missing. Either way
`kubectl_install: no version` follows (the kubeconfig file is left empty): fix the cause and run
the block again.

## Check the cluster

This confirms that kubectl now reaches the guest cluster, that its version matches the
cluster's, and that the cluster has a default storage class.

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
kubectl get storageclass -o json | jq -r '"default storage class: \([.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(",") | if . == "" then "NONE" else . end)"'
```

**Expect:** every node `Ready`, client and server on the same `v1.<minor>` (e.g. `v1.36.2` and
`v1.36.2+vmware.2`), then `default storage class: <your storage class>`. From here on, kubectl
talks to the guest cluster; the Supervisor is reached only with
`--kubeconfig "$SUPERVISOR_KUBECONFIG"`.

**If not:**
- A node `NotReady` in the first minutes: wait and run the block again. If it stays, tell your
  administrator.
- `default storage class: NONE`: the description was applied without `defaultStorageClass`. Fill
  it from the unchanged [`templates/cluster.yaml`](templates/cluster.yaml) and apply it again.

<details>
<summary><b>Alternative: the same cluster with ArgoCD</b> (when you want the cluster described in Git)</summary>

Do this INSTEAD of this chapter, from *Fill the cluster's description* on.
[Install ArgoCD onto Supervisor and create a VKS guest cluster with it](ARGOCD.md) installs
ArgoCD on the Supervisor and has it create the cluster from a chart in Git. The chart describes
the same object as `templates/cluster.yaml`, and takes the same values (`K8S_VERSION`,
`VM_CLASS`, `STORAGE_CLASS`, `CLUSTER_CLASS`).

</details>

## Delete the cluster

**This destroys the cluster, its virtual machines and every disk its apps created.** The block
deletes the cluster on the Supervisor and waits until it and its address are gone (a few
minutes; it gives up after 30). Do not switch the virtual machines off yourself.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete clusters.cluster.x-k8s.io "$VKS_CLUSTER" --ignore-not-found --wait=false
n=0
until [ -z "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io,virtualmachineservice "$VKS_CLUSTER" --ignore-not-found -o name || echo unknown)" ] || [ "$n" -ge 120 ]; do
  n=$((n + 1)); sleep 15
done
echo "left (nothing after the colon means gone): $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io,virtualmachineservice "$VKS_CLUSTER" --ignore-not-found -o name || echo unknown)"
rm -f "$GUEST_KUBECONFIG" "$HOME/.config/vks-golang-web/cluster.yaml"
```

**Expect:** `cluster.cluster.x-k8s.io "<your cluster>" deleted`, and within a few minutes
`left (nothing after the colon means gone):` with nothing after it.

**If not:** a name, or `unknown`, after the colon: the cluster is still being deleted, or the
Supervisor login ended (main guide, *Renew the Supervisor login*). Run the block again before
you create another cluster. Do not create the next cluster under the same name.

If ArgoCD created the cluster, delete it with the ArgoCD guide's clean-up step instead, or
ArgoCD creates it again.

## Fix common problems

| symptom | fix |
|---|---|
| `envsubst: command not found` | Run *Install envsubst*. |
| `Not filled: no value for: …` | A setting is empty, or its line in the env file lacks `export`. *Choose the cluster's values* lists them. |
| The cluster stays `Available=not yet` and the block prints `STOP: the cluster uses the address …` | The name was used before in this namespace. Delete the cluster and use a new name. |
| The cluster is available but an app's disk request (`PersistentVolumeClaim`) stays `Pending` | *Check the cluster* prints the default storage class. `NONE` means the description lacked `defaultStorageClass`. |
| `admission webhook … denied the request: Could not resolve KR/OSImage` | `K8S_VERSION` is not a release that is ready and compatible. Take one from *List the Kubernetes releases*, exactly as printed. |
| A node's pods stay `Pending` with `Insufficient memory` or `Insufficient cpu` | The workers are too small for what you run. Raise `WORKER_REPLICAS`, fill the description and apply it again; or create a new cluster with a larger `VM_CLASS`. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block. |

## Next

Go back to [the main guide](README.md) and deploy the app onto the new cluster.
