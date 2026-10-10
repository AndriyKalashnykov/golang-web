# Use or create a vSphere Namespace

This chapter comes after the Supervisor login of [the main guide](README.md) and before you get
a guest cluster. At the end you have a vSphere Namespace that can hold a guest cluster.

A vSphere Namespace is your team's area on the Supervisor. It is made in vCenter, not in
Kubernetes: vCenter decides which virtual machine sizes (*VM classes*) and which disks (*storage
classes*) it may use, and who may work in it.

**You need vCenter administrator rights to create a namespace; to check and use one you need
only your role in that namespace.**

| your situation | go to |
|---|---|
| You have a namespace | [Check the namespace you have](#check-the-namespace-you-have), below |
| You have none: create it by hand | [NAMESPACE-manual.md](NAMESPACE-manual.md): the vSphere Client, with screenshots. It also shows where the client keeps each value these guides ask for |
| You have none: create it with scripts | [NAMESPACE-auto.md](NAMESPACE-auto.md): command blocks only, with vCenter's API, or with `kubectl` where Namespace Self-Service is on |

Both guides end at the check below, and each removes only a namespace it created.

<a id="if-you-are-not-a-vcenter-administrator"></a>

<details>
<summary><b>If you are not a vCenter administrator</b></summary>

Ask a vCenter administrator for these three things, then run the check below:

- a vSphere Namespace on your Supervisor, with one storage policy and the VM classes
  `best-effort-small` and `best-effort-medium` (2 CPUs with 4 GB and with 8 GB of memory);
- the **Edit** role (the vSphere Client calls it **Can edit**) on it for your SSO user;
- the namespace's name, for `VKS_NAMESPACE` in `~/.vks-golang-web.env`.

</details>

## Check the namespace you have

Whichever way you got the namespace, these two blocks prove it can hold a guest cluster. Set
`VKS_NAMESPACE` in `~/.vks-golang-web.env` to its name first.

This checks that the namespace exists, that you can read it, and that you may create a cluster
in it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" auth can-i create clusters.cluster.x-k8s.io
```

**Expect:** your vSphere Namespace, `Active`, then `yes`.

**If not:**
- `NotFound`: no namespace has that name. Check `VKS_NAMESPACE`; if it is right, the namespace
  does not exist yet: create it [by hand](NAMESPACE-manual.md) or
  [with scripts](NAMESPACE-auto.md).
- `Forbidden`, or `no` on the second line: the namespace exists but your SSO user has no role
  that lets it create clusters there. Give it the **Edit** role on the namespace
  ([Give your user a role](NAMESPACE-manual.md#4-give-your-user-a-role) shows where). If the role was given after
  you logged in, run the main guide's *Delete the Supervisor login* block and log in again.
- `Unauthorized`, or a login prompt: the Supervisor login ended. Run the main guide's *Renew the
  Supervisor login* block, then this block again.

This lists what the namespace offers a guest cluster: VM classes, storage classes, Kubernetes
releases and cluster classes.

```sh
source ~/.vks-golang-web.env
echo "VM classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineclass --no-headers
echo "Storage classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get storagepolicyquota -o jsonpath='{range .items[*].status.total[*]}{.storageClassName}{"\n"}{end}' | sort -u
echo "Kubernetes releases ready to use: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr -o json | jq '[.items[] | select([.status.conditions[]? | select(.type == "Ready" or .type == "Compatible") | .status] | length == 2 and all(. == "True"))] | length')"
echo "Cluster classes: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get clusterclass -o name | wc -l | tr -d ' ')"
```

**Expect:** at least one line under `VM classes:` (a name with its CPU and memory), at least one
name under `Storage classes:`, then `Kubernetes releases ready to use:` and `Cluster classes:`,
each with a number above 0. Then the namespace is ready: go to **Next** at the end of this
chapter.

**If not:**
- `No resources found in <your namespace> namespace.` under `VM classes:`: no VM class is
  assigned to the namespace, so a cluster has no machine size to use. Assign at least one:
  [Add the VM classes](NAMESPACE-manual.md#6-add-the-vm-classes).
- Nothing under `Storage classes:`: no storage policy is assigned to the namespace, or your user
  may not read it. Assign one: [Add a storage policy](NAMESPACE-manual.md#5-add-a-storage-policy).
- `Kubernetes releases ready to use: 0`: the Supervisor has no usable Kubernetes release. On a
  Supervisor that was switched on minutes ago, wait ten minutes and run the block again. If it
  stays 0, the Supervisor's content library has no release it can use:
  [Find the Kubernetes releases](CLUSTER-manual.md#find-the-kubernetes-releases) shows where
  that library is.
- `Cluster classes: 0`: the VKS service on this Supervisor is not running. Its row, **Kubernetes
  Service**, is in the list of the Supervisor's services: the Supervisor's **Configure** tab →
  **Supervisor Services** → **Overview**.

## Next

Go on with [Use or create a guest cluster](CLUSTER.md), or go back to
[the main guide](README.md#get-your-guest-cluster) if you already have a cluster in this
namespace.
