# Create a vSphere Namespace, by hand

This guide creates a vSphere Namespace in the vSphere Client: you look up the values it needs,
create the namespace, give your user a role in it, and add a storage policy and VM classes. It
also shows where the client keeps the values the main guide asks for. It has 9 steps; step 9 is
optional clean-up. The names are those of the vSphere Client for VMware Cloud Foundation 9.1.1,
on a Supervisor with vSphere Distributed Switch networking and the Foundation Load Balancer; an
older client says **Workload Management** where this guide says **Supervisor Management**.

The same result with command blocks in place of clicks is in
[NAMESPACE-auto.md](NAMESPACE-auto.md). If you already have a namespace, you need neither: see
[NAMESPACE.md](NAMESPACE.md).

It continues [the main guide](README.md). Only the last two steps use a terminal: run their
blocks by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each is followed by
**Expect:** — what you should see — and, where it can go wrong, **If not:** — what to do. The
screenshots show example names and addresses; yours differ.

## Learn the terms

The main guide's [terms](README.md#learn-the-terms) apply. New here:

| term | meaning |
|---|---|
| vSphere Client | vCenter's web page, `https://<your vCenter>/ui` |
| storage policy | vCenter's name for a kind of disk; a namespace that has one offers it as a *storage class* |
| VM class | a virtual machine size (CPUs and memory) a namespace may use |
| role | what a user may do in a namespace: **Can view**, **Can edit** or **Owner** |

## Gather what you need

- A browser on a machine that reaches vCenter.
- A vCenter user who may create vSphere Namespaces: a vCenter administrator. Broadcom's page
  asks for the privileges *Namespaces.view*, *Namespace.edit* and *Namespaces.owner*
  ([Broadcom, VCF 9.1: create and configure a vSphere Namespace](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration/configuring-and-managing-vsphere-namespaces/create-and-configure-a-vsphere-namespace.html)).
  If you are not one, see
  [NAMESPACE.md](NAMESPACE.md#if-you-are-not-a-vcenter-administrator).
- A Supervisor that is running (step 1 shows where to see it).
- For steps 8 and 9: the main guide's env file and its Supervisor login on this machine.

## 1. Find the Supervisor, its address and vCenter's CA

The main guide's env file asks for the Supervisor's address (`SUPERVISOR_ENDPOINT`), and its
*Download and check the vCenter CA* asks you to compare a fingerprint. Both are in the vSphere
Client.

1. Open the vSphere Client and log in. From the menu (☰, top left) choose **Supervisor
   Management**, then the **Supervisors** tab.
2. Find your Supervisor's row. **Config Status** must show **Running**. The **Control Plane Node
   Address** column holds the Supervisor's address: that is `SUPERVISOR_ENDPOINT`.

   ![The Supervisors tab of Supervisor Management: one row, Config Status Running, and the Control Plane Node Address column](img/namespace/01-supervisors.jpg)

3. For vCenter's CA, open `https://<your vCenter>/` (without `/ui`) in the browser. On the right
   of that page click **Download trusted root CA certificates**. <!-- unverified -->
   The browser saves `download.zip`; the CA certificate is the file ending in `.0` in its
   `certs/lin` folder (`certs/mac` on macOS). <!-- unverified -->

   ![vCenter's start page, with the link Download trusted root CA certificates at the lower right](img/namespace/02-vcenter-ca.jpg)

**Expect:** you know the Supervisor's address, and you have vCenter's CA certificate from
vCenter's own page. The main guide's
[Download and check the vCenter CA](README.md#download-and-check-the-vcenter-ca) prints a
fingerprint: it must equal the fingerprint of this file (`openssl x509 -in <the file> -noout
-fingerprint -sha256` prints it).

**If not:** **Config Status** shows anything but **Running** — the Supervisor is not ready; a
namespace cannot be created on it yet. No Supervisor in the list — this vCenter has none.

## 2. Find the storage policies and the VM classes

A namespace needs one storage policy and at least one VM class. Look at what vCenter has before
you create the namespace.

1. From the menu (☰) choose **Policies and Profiles**, then **VM Storage Policies** in the list
   on the left.

   ![The VM Storage Policies list under Policies and Profiles](img/namespace/03-storage-policies.jpg)

2. Choose one policy and note its name. Take the policy your Supervisor itself uses when you are
   not sure: your Supervisor → **Configure** → **Supervisor** → **Storage** names it.
   <!-- unverified --> A policy with **Encryption** in its name needs a key provider; do not
   choose one unless you know the vCenter has it.
3. From the menu (☰) choose **Supervisor Management**, then the **Services** tab. On the **VM
   Service** card click **MANAGE**, then open the **VM Classes** tab. <!-- unverified -->

   ![The VM Classes page of the VM Service: one card per class with its CPUs and memory](img/namespace/04-vm-classes.jpg)

4. Note the classes the cluster may use. A class with 2 CPUs and 4 GB (`best-effort-small`) is
   enough for this app; add one with 8 GB (`best-effort-medium`) if you plan to add Istio later
   ([Choose the cluster's values](CLUSTER-auto.md#choose-the-clusters-values) has the sizes).

**Expect:** one storage policy name and one or two VM class names.

**If not:** no **VM Service** card — the Supervisor's VM Service is not there; a guest cluster
cannot be built without it.

## 3. Create the namespace

1. From the menu (☰) choose **Supervisor Management**. On the **Namespaces** tab click **New
   Namespace**.

   ![The Namespaces tab of Supervisor Management, with the New Namespace button above the list](img/namespace/05-namespaces-new.jpg)

2. In the window that opens, select your Supervisor. <!-- unverified -->
3. Type the namespace's **Name**: lower-case letters, digits and `-`, and a name no namespace has
   yet. <!-- unverified -->
4. Leave the network as it is offered. <!-- unverified --> On a Supervisor with NSX the window
   asks for more network values: take what your network administrator names; this guide was not
   run there.
5. In **Description** type who made the namespace and why, for example
   `Made by <your name> for the golang-web guest cluster`. Step 9 reads it before you delete
   anything. <!-- unverified -->

   ![The new namespace window, filled in: Supervisor, name, network and description](img/namespace/06-new-namespace.jpg)

6. Click **Finish** (some versions of the client label the button **Create**).
   <!-- unverified -->

**Expect:** the client opens the new namespace's **Summary** page. Its **Status** card shows
**Config Status** **Running** within a minute, and its **Permissions**, **Storage**, **Capacity
and Usage** and **VM Service** cards are still empty. The row of tabs above them reads
**Summary**, **Monitor**, **Configure**, **Permissions**, **Zones**, **Compute**, **Storage**,
**Network**, **Resources**.

![The Summary page of a new namespace: Config Status Running, and empty Permissions, Storage and VM Service cards](img/namespace/07-summary-new.jpg)

**If not:** **New Namespace** is greyed out or missing — your user may not create namespaces, or
no Supervisor is running (step 1). An error about the name — a namespace of that name exists, or
the name has a character that is not allowed.

## 4. Give your user a role

Without this only vCenter administrators can use the namespace with `kubectl`.

1. On the namespace's **Summary** page, in the **Permissions** card, click **Add Permissions**.
   (The **Permissions** tab holds the same list.) <!-- unverified -->
2. Choose the **Identity source** (`vsphere.local` for a user made in vCenter itself), search
   for your SSO user and select it. <!-- unverified -->
3. Choose the **Role**: **Can edit** is enough for everything in these guides; **Owner** may
   also delete the namespace with `kubectl`. Click **OK**. <!-- unverified -->

   ![The Add Permissions window: identity source, the user and the role Can edit](img/namespace/08-add-permissions.jpg)

**Expect:** the **Permissions** card counts one user under **Can edit** (or **Owner**).

**If not:** the search finds no user — the identity source is not the one your user is in.

## 5. Add a storage policy

1. In the **Storage** card click **Add Storage**. (The **Storage** tab holds the same list.)
   <!-- unverified -->
2. Tick the policy you chose in step 2 and click **OK**. <!-- unverified -->

   ![The Select Storage Policies window with one policy ticked](img/namespace/09-add-storage.jpg)

**Expect:** the **Storage** card shows the policy's name. The namespace now offers a storage
class of that name, in lower case and with `-` in place of spaces.

## 6. Add the VM classes

1. In the **VM Service** card click **Add VM Class**. (The **Compute** tab holds the same list.)
   <!-- unverified -->
2. Tick the classes you chose in step 2 and click **OK**. <!-- unverified -->

   ![The Add VM Class window with best-effort-small and best-effort-medium ticked](img/namespace/10-add-vm-class.jpg)

**Expect:** the **VM Service** card counts the classes you ticked under **Associated VM
Classes**. <!-- unverified -->

The same card offers **Add Content Library**. A guest cluster does not need one in the
namespace: its Kubernetes releases come from the Supervisor's own content library
([Find the Kubernetes releases](CLUSTER-manual.md#find-the-kubernetes-releases)). A namespace
created without one by the scripted guide built clusters on the lab.

## 7. Set limits and check the status

1. Leave the **Capacity and Usage** card without limits, or click **Edit Limits** and set limits
   that leave room for one control-plane node and two or three worker nodes: at least 8 CPUs,
   24 GB of memory and 150 GB of storage. <!-- unverified -->
2. Look at the **Status** card.

   ![The Summary page of the finished namespace: Config Status Running, one user, one storage policy, two VM classes](img/namespace/11-summary-running.jpg)

**Expect:** **Config Status** **Running**, one user in **Permissions**, one policy in
**Storage**, your classes in **VM Service**.

**If not:** a status other than **Running** after some minutes — the card's message says why.

## 8. Set the name and check the namespace

Open the env file and set `VKS_NAMESPACE` to the namespace's name.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it.

If you were logged in to the Supervisor before the namespace existed, or before you gave your
user its role, run the main guide's
[Delete the Supervisor login](README.md#delete-the-supervisor-login) block and
[log in again](README.md#log-in-to-the-supervisor): a login does not see a namespace that was
granted after it.

Then run both blocks of
[Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have). They prove that the
namespace can hold a guest cluster: its VM classes, its storage class, the Kubernetes releases
and the cluster classes.

## 9. Remove the namespace (optional)

**Deleting a vSphere Namespace destroys everything in it**: every guest cluster with its
virtual machines and disks, every ArgoCD instance, every secret, with no way back. Delete only
a namespace you created yourself, and only when it holds nothing you want to keep.

First list what is left in it:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io
```

**Expect:** `No resources found in <your namespace> namespace.`

**If not:** a cluster is listed — delete it first, the way it was made
([with scripts](CLUSTER-auto.md#delete-the-cluster) or
[by hand](CLUSTER-manual.md#8-delete-the-cluster-optional)). `Forbidden` or `NotFound` — check
`VKS_NAMESPACE`: you are about to delete a namespace you cannot read.

Then, in the vSphere Client:

1. From the menu (☰) choose **Supervisor Management**, then the **Namespaces** tab.
2. Find the namespace's row and read its **Description**: it must be the text you typed in
   step 3. If it is not, or the column is empty, this is not the namespace you created: stop.
   <!-- unverified -->
3. Select the row and click **Remove**. <!-- unverified -->

   ![The Namespaces tab with one namespace selected and the Remove button](img/namespace/12-remove.jpg)

4. Read the name in the confirmation window, then confirm. <!-- unverified -->

   ![The confirmation window that names the namespace to remove](img/namespace/13-remove-confirm.jpg)

**Expect:** the namespace's status changes to **Removing** and, within a minute or two, its row
is gone from the list. <!-- unverified -->

**If not:** the row stays in **Removing** for more than 15 minutes — something in the namespace
does not end. Do not create a namespace of the same name meanwhile.

The scripted guide's delete blocks refuse a namespace made by hand, because it does not carry
their marker: that is intended.

## Fix common problems

| symptom | fix |
|---|---|
| **New Namespace** is missing or greyed out | Your user may not create namespaces, or the Supervisor is not **Running** (step 1). |
| `kubectl get ns` answers `Forbidden` for the new namespace | Your SSO user has no role in it (step 4), or the role was given after you logged in: delete the Supervisor login and log in again (step 8). |
| The check prints nothing under `VM classes:` | No VM class is assigned (step 6). |
| The check prints nothing under `Storage classes:` | No storage policy is assigned (step 5). |
| A cluster is refused with a message about the VM class or the storage class | The namespace does not have that class: add it (steps 5 and 6). |

## Next

Go on with [Use or create a guest cluster](CLUSTER.md).
