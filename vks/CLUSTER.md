# Use or create a guest cluster

This chapter comes after [Use or create a vSphere Namespace](NAMESPACE.md). At the end you have
a Kubernetes cluster (a *VKS guest cluster*) in your vSphere Namespace, its kubeconfig on this
machine, and a `kubectl` that matches it.

**You need the Edit role on your vSphere Namespace to create a guest cluster; to check and use
one you need only your role in that namespace.** The by-hand guide also needs a user who can
open the namespace in the vSphere Client: a vCenter administrator can.

| your situation | go to |
|---|---|
| You have a guest cluster | [Use the cluster you have](#use-the-cluster-you-have), below |
| You have none: create it by hand | [CLUSTER-manual.md](CLUSTER-manual.md): the vSphere Client, with screenshots. It also shows where the client keeps each value the cluster needs |
| You have none: create it with scripts | [CLUSTER-auto.md](CLUSTER-auto.md): command blocks only, `kubectl` and one file. It needs `envsubst`: [Install envsubst](CLUSTER-auto.md#install-envsubst) |
| You want the cluster described in Git | [ARGOCD.md](ARGOCD.md): ArgoCD on the Supervisor creates the same cluster from a chart |

All three ways end at the two blocks below, and each deletes only a cluster it created. Before
you create one, read [Install Harbor before you create clusters](#install-harbor-before-you-create-clusters).

<a id="if-you-are-not-a-vcenter-administrator"></a>

<details>
<summary><b>If you are not a vCenter administrator</b></summary>

You do not have to be one to create a cluster with scripts. You need, from a vCenter
administrator:

- a vSphere Namespace that passes [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have);
- the **Edit** role (the vSphere Client calls it **Can edit**) on it for your SSO user;
- the Supervisor's address, for the main guide's login.

</details>

## Use the cluster you have

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each block is
followed by **Expect:** — what you should see — and, where it can go wrong, **If not:** — what
to do.

This lists the guest clusters in your vSphere Namespace.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io
```

**Expect:** one line per cluster, with `AVAILABLE` `True` for a cluster that is ready, its
control-plane and worker counts and its version. `VKS_CLUSTER` in `~/.vks-golang-web.env` must
be the name of the cluster you will use: set it now if it is not.

**If not:**
- `No resources found in <your namespace> namespace.`: the namespace has no guest cluster.
  Create one [by hand](CLUSTER-manual.md) or [with scripts](CLUSTER-auto.md).
- `AVAILABLE` `False`: the cluster is still being built, or cannot be. Wait some minutes and run
  the block again; [Create the cluster and wait for it](CLUSTER-auto.md#create-the-cluster-and-wait-for-it)
  lists the reasons under its **If not**.
- `Forbidden` or `NotFound`: do [NAMESPACE.md](NAMESPACE.md) first. `Unauthorized`: run the main
  guide's *Renew the Supervisor login* block.

### Get the cluster's kubeconfig

This reads the guest cluster's kubeconfig from the Supervisor, saves it as `$GUEST_KUBECONFIG`
(the env file already points `kubectl` there), and compares your kubectl with the cluster's
version. Kubernetes supports a kubectl within one minor version of the cluster, so within that
range the block changes nothing. Further away, it installs the cluster's version into
`KUBECTL_DIR` (`/usr/local/bin`), or into `~/.local/bin` when that needs a password: it never
asks for one. Set `KUBECTL_MATCH="exact"` in the env file to always get the cluster's exact
version.

```sh
source ~/.vks-golang-web.env
( umask 077
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "${GUEST_KUBECONFIG}.new" )
if [ -s "${GUEST_KUBECONFIG}.new" ]; then
  mv "${GUEST_KUBECONFIG}.new" "$GUEST_KUBECONFIG"
else
  rm -f "${GUEST_KUBECONFIG}.new"; echo "No kubeconfig read (see the error above): ${GUEST_KUBECONFIG} is as it was"
fi
V="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Guest cluster: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Guest cluster: v1.<minor>…`, then
`kubectl v1.… is within one minor version of v1.…: supported, not changed`, or, when kubectl was
further away, `Client Version:` with the cluster's `v1.<minor>`.

**If not:**
- `No kubeconfig read …`, under a `kubectl` error: `secrets "<name>-kubeconfig" not found` —
  check `VKS_CLUSTER`, and that the block above shows the cluster with `AVAILABLE` `True`; `Forbidden` — the
  **Edit** role is missing; `Unauthorized` — the Supervisor login ended (main guide, *Renew the
  Supervisor login*). A kubeconfig you saved earlier is kept. With none, `Guest cluster: unknown`
  and `kubectl_install: no version` follow: fix the cause and run the block again.
- `… installing into <your home>/.local/bin instead`: not an error. If `… was not on your PATH`
  follows, add the line it prints to `~/.zshrc` (zsh) or `~/.bashrc` (bash).
- `kubectl_install: cannot reach dl.k8s.io`, `… the checksum of the download does not match` or
  `… could not write …`: the kubeconfig is saved and kubectl is unchanged. [Install kubectl](SETUP.md#install-kubectl)
  says what to do for each.

### Check the cluster

This confirms that kubectl now reaches the guest cluster, shows its version beside the
cluster's, and checks that the cluster has a default storage class.

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
kubectl get storageclass -o json | jq -r '"default storage class: \([.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(",") | if . == "" then "NONE" else . end)"'
```

**Expect:** every node `Ready`, client and server at most one minor version apart (e.g. `v1.37.1`
and `v1.36.2+vmware.2`), then `default storage class: <your storage class>`. From here on, kubectl
talks to the guest cluster; the Supervisor is reached only with
`--kubeconfig "$SUPERVISOR_KUBECONFIG"`.

**If not:**
- A node `NotReady` in the first minutes: wait and run the block again. If it stays, tell your
  administrator.
- `default storage class: NONE`: the cluster was created without a default storage class, so an
  app that asks for a disk without naming a storage class waits forever. A cluster from
  [CLUSTER-auto.md](CLUSTER-auto.md): fill the description from the unchanged
  [`templates/cluster.yaml`](templates/cluster.yaml) and apply it again. A cluster made another
  way: name the storage class in every disk request, or create the cluster with that guide.

## Install Harbor before you create clusters

**Installing or uninstalling Harbor on the Supervisor replaces every node of every guest
cluster on it.** VKS adds the registry's CA to (or removes it from) the configuration every node starts with,
and a node gets a new configuration only by being replaced: VKS builds a new machine, moves the
work over and deletes the old one, one node at a time, in every cluster of that Supervisor.
Apps with one copy stop for a moment when their node goes.

So install Harbor **before** you create clusters, or in a maintenance window. A cluster that is
being created at that moment takes longer (about 15 minutes more on a small lab) and shows
`Available False`, with new machines appearing beside the first ones.

This lists your namespace's machines; it shows whether a replacement is running.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get machine
```

**Expect:** `No resources found` before your first cluster. With a cluster: one machine per
node, each `Running`, with `UP-TO-DATE` `True`. During a replacement the old machines show
`UP-TO-DATE` `False` and new ones appear; it is over when every machine shows `True` again.

**If not:** machines that stay `UP-TO-DATE` `False` for more than an hour, with no new machine
appearing: tell your administrator; do not delete machines or switch virtual machines off
yourself.

## Next

Go back to the main guide's [Deploy the app](README.md#deploy-the-app) and deploy the app onto
the cluster.
