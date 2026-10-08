# Install ArgoCD onto Supervisor and create a VKS guest cluster with it — by hand

This guide installs the ArgoCD Supervisor Service on a vSphere Supervisor, starts an ArgoCD
*instance* in your vSphere Namespace, and uses that ArgoCD to create a Kubernetes cluster (a *VKS
guest cluster*) from a file in Git. You click through the vSphere Client and the ArgoCD web page;
where neither has a screen for a step, you run a short `kubectl` command; step 8 uses Broadcom's
`argocd` program. It has 9 steps; step 9
is optional clean-up. It was written for VMware Cloud Foundation 9.1.1, ArgoCD Service 1.2.0 and
VKS 3.7.

The same result with scripts in place of clicks is in [ARGOCD-auto.md](ARGOCD-auto.md).

It continues [the main guide](README.md) and uses its env file, its `kubectl` and its Supervisor
login. Run the command blocks by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each is
followed by **Expect:** — what you should see — and, where it can go wrong, **If not:** — what to
do. The screenshots show example names and addresses; yours differ.

## Learn the terms

The main guide's [terms](README.md#learn-the-terms) apply. New here:

| term | meaning |
|---|---|
| context | a named login inside a kubeconfig file, or inside the `argocd` program's own settings |
| token, certificate | the two kinds of login ArgoCD can hold for a destination; a certificate has an end date |
| vSphere Client | vCenter's web page, `https://<your vCenter>/ui` |
| Supervisor Service | an add-on a vCenter administrator installs on a Supervisor |
| ArgoCD Service | the Supervisor Service that lets a vSphere Namespace run ArgoCD |
| ArgoCD instance | one running ArgoCD, with its own web page and login, inside a vSphere Namespace |
| service manifest | the `.yml` file from Broadcom that describes the ArgoCD Service to vCenter |
| Application | ArgoCD's record of "keep what is in this Git folder applied to that destination" |
| destination | a place ArgoCD may apply things to: here your vSphere Namespace, later a guest cluster |
| project | an ArgoCD rule set: which Git repositories, destinations and kinds of object an Application may use |
| sync | ArgoCD applying what is in Git |
| VM class | a virtual machine size your vSphere Namespace may use |
| storage class | a kind of disk your vSphere Namespace may use |

## Gather what you need

- Steps 1, 2 and 7 of [the main guide](README.md) done on this machine. You need no container
  engine and no Harbor for this guide. Step 8 uses Broadcom's `argocd` program, which step 1
  downloads and installs (an Intel/AMD Linux machine or any Mac; on another machine use step 8's
  alternative, which needs no program).
- A browser on a machine that reaches vCenter and the Supervisor's load-balancer addresses.
- An SSO user with the **Edit** role on your vSphere Namespace (the main guide's user).
- For steps 2 and 3 only: a vCenter user with the privileges **Manage Supervisor Services** and
  **Manage Supervisor Services on Supervisors**. If yours lacks them, ask your vCenter
  administrator to do those two steps.
- A Broadcom support account that can download **vSphere Supervisor Services** (step 1).
- The Supervisor must reach `projects.packages.broadcom.com` (it downloads ArgoCD from there)
  and `github.com` (ArgoCD reads the cluster's description from there).
- Room in your vSphere Namespace for three more virtual machines (step 7 creates them).

Your Supervisor login from the main guide lasts about 10 hours. When a `kubectl` command in this
guide answers `error: You must be logged in to the server (Unauthorized)`, run the main guide's
*Renew the Supervisor login* block (step 7), then the command again. If you logged in with the
certificate-checking alternative, use the renew block inside that alternative instead.

## 1. Download the ArgoCD files

Download two files from Broadcom: the service manifest, and the `argocd` program for this machine
(step 8 uses it). Tick **"I agree to the Terms and Conditions"** if the page shows it, or the
download icon does nothing.

| file | where to click | direct link |
|---|---|---|
| `supervisor-service-argocd-legacy-1.2.0-25642124.yml` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → search **vSphere Supervisor Services** → **ArgoCD Service** → 1.2.0 → *Installation Package Manifest (VCF 9.0 or older and disconnected/airgapped VCF 9.1)* | [ArgoCD Service 1.2.0](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.2.0&os=&servicePk=546088&language=EN) |
| `argocd-cli-linux-amd64-v3.4.4-vcf.gz` (Linux) or `argocd-cli-darwin-amd64-v3.4.4-vcf.gz` (macOS) | the same page → *ArgoCD Linux CLI* or *ArgoCD Mac CLI* | the same link |

Take both files from the same release, 1.2.0: this guide's file names and checksums are for
that release. If the page opens on a newer release, choose 1.2.0 in its release list.

Take the manifest with **legacy** in its name. The page offers a second one without it, labelled
*Internet Connected VCF 9.1 and newer*. The two differ in one line: the legacy file downloads
ArgoCD from `projects.packages.broadcom.com`, the other from a VCF Software Depot inside your
environment. Use the legacy file when the Supervisor has internet access and no Software Depot.
This guide does not cover the other file.

Print the files' checksums. If you saved them elsewhere, change the folder.

```sh
(cd ~/Downloads && for f in supervisor-service-argocd-legacy-1.2.0-25642124.yml argocd-cli-linux-amd64-v3.4.4-vcf.gz argocd-cli-darwin-amd64-v3.4.4-vcf.gz; do if [ -f "$f" ]; then sha256sum "$f" 2>/dev/null || shasum -a 256 "$f"; fi; done)
```

**Expect:** one line per file you downloaded, each starting with the value the download page
shows for that file (labelled **SHA2**):

| file | SHA-256 |
|---|---|
| `supervisor-service-argocd-legacy-1.2.0-25642124.yml` | `e4f0d0bb85bc4c63d32ab52d0e39bb40b322dcecbbc4e5f29587f8ef765eb7f1` |
| `argocd-cli-linux-amd64-v3.4.4-vcf.gz` | `f9ff2d754989107ea06d74713173b9847c08606d9c1cf863ff4fdc584f43bb0f` |
| `argocd-cli-darwin-amd64-v3.4.4-vcf.gz` | `ca2827c8087fb1b0bfb7324550f3db7f5e4ce95ba4054145994544d968ba3f1f` |

**If not:** a file's line is missing — it is not in `~/Downloads`, or its name differs.
A different checksum means a damaged or wrong download: delete the file and download it again; if
it still differs, do not use it.

### Install the argocd program

`argocd` is ArgoCD's command-line tool. This block installs Broadcom's build into
`/usr/local/bin`; its `sudo` asks for your password. Run it only after the checksum above matched.
The Mac program is built for Intel; on a Mac with Apple silicon it runs through Rosetta.

```sh
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)               P=linux-amd64 ;;
  Darwin/x86_64|Darwin/arm64) P=darwin-amd64 ;;
  *)                          P=unsupported ;;
esac
ARGOCD_GZ="$HOME/Downloads/argocd-cli-${P}-v3.4.4-vcf.gz"
if [ -x /usr/local/bin/argocd ] && ! /usr/local/bin/argocd version --client 2>/dev/null | grep -q -e -vcf; then
  echo "Not installing: /usr/local/bin/argocd is another argocd. Move it away first, or use step 8's alternative."
elif T="$(mktemp -d)" && gunzip -c "$ARGOCD_GZ" > "$T/argocd" && chmod +x "$T/argocd" \
   && "$T/argocd" version --client >/dev/null \
   && sudo install -d /usr/local/bin && sudo install -m 0755 "$T/argocd" /usr/local/bin/argocd; then
  rm -rf "$T"
  /usr/local/bin/argocd version --client | head -1
  [ "$(command -v argocd)" = /usr/local/bin/argocd ] \
    || echo "WARNING: 'argocd' on your PATH is '$(command -v argocd || echo not found)', not /usr/local/bin/argocd"
else
  [ -n "$T" ] && rm -rf "$T"
  echo "Nothing installed: see the error above"
fi
```

**Expect:** `argocd: v3.4.4+…-vcf`, and no `WARNING` line.

**If not:**
- `bad CPU type in executable` (a Mac with Apple silicon): run
  `softwareupdate --install-rosetta --agree-to-license`, then this block again.
- `No such file or directory`: the download is missing, or `unsupported` is in its name: Broadcom
  has no `argocd` program for this machine, so use step 8's alternative.
- `Not installing: …`: an `argocd` from elsewhere (for example Homebrew) is at that path. This
  guide does not replace it.
- A `WARNING` line: another `argocd` is found first, or `/usr/local/bin` is not in your `PATH`.

## 2. Register the service with vCenter

This is done once per vCenter, in the vSphere Client. If an **ArgoCD Service** card is already
on the page in the first picture, skip to step 3.

1. Open the vSphere Client. From the menu (☰, top left) choose **Supervisor Management**, then
   the **Services** tab.
2. On the **Add New Service** card click **ADD**.

   ![The Services tab of Supervisor Management, with the Add New Service card and its ADD button](img/argocd/01-services-add.jpg)

3. In the **New Service** window click **UPLOAD** and choose the manifest from step 1. The window
   then shows *YAML was uploaded successfully* and the service's details: name **ArgoCD
   Service**, ID `argocd-service.vsphere.vmware.com`, version `1.2.0-25642124`.

   ![The New Service window after the upload, showing the file name and the service details](img/argocd/02-new-service-uploaded.jpg)

4. Click **FINISH**.

**Expect:** a green line, *Service 'ArgoCD Service' is successfully registered. You can now
install the service on Supervisors.*, and a new **ArgoCD Service** card showing **Active
Versions 1** and **Supervisors 0**.

![The Services tab after registration, with the green success line and the ArgoCD Service card](img/argocd/03-registered.jpg)

**If not:** the **ADD** button is missing or the upload is refused — your user lacks **Manage
Supervisor Services**. An error naming the YAML — you chose the wrong file; do not edit the
manifest.

## 3. Install the service on your Supervisor

1. On the **ArgoCD Service** card click **ACTIONS**, then **Manage Service**.

   ![The ArgoCD Service card with its ACTIONS menu open: Manage Service, Add New Version, Manage Versions, Edit, Delete](img/argocd/16-service-actions.jpg)

2. **Configure:** leave **Install Version** at `1.2.0-25642124`, select your Supervisor in the
   list, click **NEXT**.

   ![The Manage: ArgoCD Service window, Configure step, with the Supervisor selected](img/argocd/04-install-configure.jpg)

3. **Validate:** wait for *Validation completed successfully*, with **Compatibility Check** and
   **Signature Verification** both **Pass**. Click **NEXT**.

   ![The Validate step: Compatibility Check Pass and Signature Verification Pass](img/argocd/05-install-validate.jpg)

4. **Review:** leave **YAML Service Config (optional)** empty. Click **FINISH**.

   ![The Review step with the empty YAML Service Config box](img/argocd/06-install-review.jpg)

5. Open the **Supervisors** tab, and in your Supervisor's row click **View** in the **Services**
   column. (The same page is under your Supervisor → **Configure** → **Supervisor Services** →
   **Overview**.) Wait until the **ArgoCD Service** row shows **Configured**: about a minute.
   The refresh arrow at the top of the page reloads the list.

**Expect:** **ArgoCD Service**, status **Configured**, version `1.2.0-25642124`, signature
**Trusted**.

![The Supervisor's installed services, with ArgoCD Service Configured](img/argocd/07-installed.jpg)

**If not:** a failed check in **Validate** — the message beside it says why; an error must be
fixed, a warning can be accepted. An error right after **FINISH** — wait a minute and do this
step again. A status that stays **Configuring** for more than 10 minutes, or shows an error —
most often the Supervisor cannot reach `projects.packages.broadcom.com`: tell your administrator.

## 4. Create the ArgoCD instance

The service only makes ArgoCD *available*. An instance — the ArgoCD you log in to — is one small
object in your vSphere Namespace. From here on your **Edit** role is enough, and the commands run
in a terminal on the machine where you did the main guide's steps.

First list the ArgoCD versions the service offers:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocdversion argocd-supported-versions -o jsonpath='{range .spec.versions[*]}{.version}{"  "}{.description}{"\n"}{end}'
```

**Expect:** a few lines such as `3.4.4+vmware.1-vks.1  Recommended version.`

**If not:** `the server doesn't have a resource type "argocdversion"` — step 3 has not finished.
`Unauthorized` — log in again (see *Gather what you need*).

Create the instance. If the first line of your list is not `3.4.4+vmware.1-vks.1`, replace that
version in the block with one your list marks *Recommended*.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<'EOF'
apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
kind: ArgoCD
metadata:
  name: argocd-1
spec:
  version: "3.4.4+vmware.1-vks.1"
EOF
```

**Expect:** `argocd.argocd-service.vsphere.vmware.com/argocd-1 created`.

Check it. Run this again every half minute until it shows `Ready` and an address: one to two
minutes.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd argocd-1 -o jsonpath='{.status.phase}{"  https://"}{.status.externalIP}{"\n"}'
```

**Expect:** `Ready  https://<an address>`. That address is ArgoCD's web page.

**If not:** `Forbidden` — the **Edit** role is missing. Still not `Ready` after 10 minutes —
`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe argocd argocd-1` shows
why; an empty address means the Supervisor has no free load-balancer address.

## 5. Log in to the ArgoCD web page

ArgoCD made its own certificate, so your browser will warn about it and cannot check it for you.
Check it yourself before you type the password. Print the certificate's fingerprint and the admin
password:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret argocd-secret -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

**Expect:** `sha256 Fingerprint=…` (`SHA256 Fingerprint=` on macOS), then the password on a line
of its own. Anyone who can read your screen can now log in: clear the terminal afterwards.

1. Open `https://<the address from step 4>` in your browser. It shows a warning such as *Your
   connection is not private*.
2. Open the certificate the page presents (in Chrome: **Not secure** in the address bar →
   **Certificate details**). Under **SHA-256 Fingerprints** read the **Certificate** row, not the
   **Public Key** row. Chrome shows it in lower case without colons, so compare the hex digits
   with the fingerprint printed above, ignoring colons, spaces and upper/lower case.
3. Only if they are the same: go on to the page (in Chrome: **Advanced** → **Proceed to …**) and
   log in with user name `admin` and the printed password.

**Expect:** the **Applications** page, with *No applications available to you just yet*.

**If not:** different fingerprints — something between you and ArgoCD replaces certificates (a
company proxy), or the address belongs to another server: do not type the password.
`secrets "argocd-initial-admin-secret" not found` — someone changed the admin password and
removed the first one: ask them for it.

Do not change the password under **User Info** if you also use
[ARGOCD-auto.md](ARGOCD-auto.md): its login helper reads the first password.

## 6. Let ArgoCD manage your vSphere Namespace

ArgoCD starts with no destination. This step makes your vSphere Namespace one.

**Read this first.** The first command gives ArgoCD's own account (`argocd-k8s-sa`) the **Edit**
role on your vSphere Namespace. Whoever can log in to this ArgoCD as `admin` can then, through
it, do everything Edit allows there: create and delete guest clusters and virtual machines, and
read secrets, including the kubeconfig of every guest cluster in the namespace. Share the ArgoCD
admin login only with people who may do that.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" create rolebinding argocd-k8s-sa-edit --clusterrole=edit --serviceaccount="${VKS_NAMESPACE}:argocd-k8s-sa"
```

**Expect:** `rolebinding.rbac.authorization.k8s.io/argocd-k8s-sa-edit created`. `… already exists`
on a second run is fine.

Register the namespace with ArgoCD:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<EOF
apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
kind: ManagedEntity
metadata:
  name: ${VKS_NAMESPACE}
spec:
  targetRef:
    apiGroup: ""
    kind: Namespace
    name: ${VKS_NAMESPACE}
EOF
```

**Expect:** `managedentity…/<your namespace> created`. In the ArgoCD page, **Settings** →
**Clusters** now lists your namespace, with the address
`https://kubernetes.default.svc/?context=<your namespace>`. Its status reads **Unknown** until an
Application uses it.

![ArgoCD Settings, Clusters: the vSphere Namespace as a destination](img/argocd/08-argocd-namespace.jpg)

**If not:** the list stays empty —
`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe managedentity "$VKS_NAMESPACE"`
names the failed condition (`MissingRoleBinding` means the first command failed).

Now create a project that limits what an Application may do: only this guide's Git repository,
only your vSphere Namespace, and only one kind of object — a guest cluster.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: vks-clusters
spec:
  description: Only VKS guest clusters, from one repository, into this vSphere Namespace
  sourceRepos:
  - https://github.com/AndriyKalashnykov/golang-web.git
  destinations:
  - name: ${VKS_NAMESPACE}
    namespace: ${VKS_NAMESPACE}
  namespaceResourceWhitelist:
  - group: cluster.x-k8s.io
    kind: Cluster
EOF
```

**Expect:** `appproject.argoproj.io/vks-clusters created`.

## 7. Create a guest cluster with ArgoCD

The cluster's description is a chart in this repository,
[`vks/argocd/guest-cluster`](argocd/guest-cluster). You give it four values; ArgoCD renders it
and applies the result to your vSphere Namespace, where VKS builds the cluster.

The Application below pins the chart to one commit of this repository
(`e236f5c43aa2a1c7a9cc84e7f3cbdbc7024942d6`), so a later change here cannot change your cluster.
For anything beyond trying this out, copy the `vks/argocd/guest-cluster` folder into a Git
repository of your own and use its address and commit in the Application and in step 6's
project: then only you decide what ArgoCD applies.

### Choose the cluster's values

List what you can choose from. Three commands, three lists:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr
```

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineclass
```

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get storageclass
```

**Expect:** Kubernetes releases, each with `READY` and `COMPATIBLE` columns; at least one VM
class with its CPU and memory; the Supervisor's storage classes.

Put your choices into this terminal. Keep using **this terminal** until the end of step 8.

- `NEW_CLUSTER`: a name no cluster in your namespace has. Lower-case letters, digits and `-`;
  start it with a letter; not one of the words `true`, `false`, `yes`, `no`, `on`, `off`, `null`.
- `K8S_VERSION`: the `VERSION` of a release whose `READY` and `COMPATIBLE` are both `True`,
  **without its `-vkr.N` ending**: for `v1.36.2+vmware.2-vkr.3` write `v1.36.2+vmware.2`. The
  Supervisor stores it that way; with the ending ArgoCD would report a difference forever.
- `VM_CLASS`: 2 CPUs and 4 GB is enough.
- `STORAGE_CLASS`: one your vSphere Namespace is allowed to use; your administrator knows which.

```sh
NEW_CLUSTER="my-new-cluster"
K8S_VERSION="v1.36.2+vmware.2"
VM_CLASS="best-effort-small"
STORAGE_CLASS="wcp-vmfs"
```

Check that no cluster has that name yet. ArgoCD would take over an existing cluster with the same
name, and step 9 would then delete it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get cluster "$NEW_CLUSTER"
```

**Expect:** `Error from server (NotFound): clusters.cluster.x-k8s.io "<name>" not found`.

**If not:** a line describing a cluster — choose another `NEW_CLUSTER`. `resource name may not be
empty` — the block above did not run in this terminal.

### Create the Application

This prints the Application with your values filled in:

```sh
source ~/.vks-golang-web.env
cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${NEW_CLUSTER}
spec:
  project: vks-clusters
  source:
    repoURL: https://github.com/AndriyKalashnykov/golang-web.git
    targetRevision: e236f5c43aa2a1c7a9cc84e7f3cbdbc7024942d6
    path: vks/argocd/guest-cluster
    helm:
      valuesObject:
        name: "${NEW_CLUSTER}"
        kubernetesVersion: "${K8S_VERSION}"
        vmClass: "${VM_CLASS}"
        storageClass: "${STORAGE_CLASS}"
        clusterClass: "builtin-generic-v3.7.0"
  destination:
    name: ${VKS_NAMESPACE}
    namespace: ${VKS_NAMESPACE}
EOF
```

**Expect:** 20 lines, from `apiVersion:` to the second `namespace:`, with your names in them and
no empty `""`.

1. In the ArgoCD page click **+ NEW APP**, then **EDIT AS YAML** (top right).
2. Click in the editor, select everything in it (Ctrl+A, or ⌘A on a Mac), delete it, and paste
   the 20 lines.

   ![The ArgoCD new application editor holding the 20 pasted lines](img/argocd/09-argocd-new-app-yaml.jpg)

3. Click **SAVE**: the page goes back to the form, now filled in. Leave **SYNC POLICY** at
   **Manual** and click **CREATE** (top left).

**Expect:** a tile named after your cluster, with status **Missing** and **OutOfSync**: ArgoCD
knows what to create and has not created it yet.

**If not:** `application destination … is not permitted in project` — step 6's project was not
created. `repository not accessible` — the Supervisor cannot reach GitHub. `builtin-generic-v3.7.0`
is not offered by your Supervisor — replace it in the YAML with the newest name
`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get clusterclass` lists.

### Look at what it will do, then sync

1. Click the tile, then **DIFF**. The right half lists, in green, the `Cluster` object ArgoCD
   will create, with your name, version, VM class and storage class. The left half is empty:
   nothing exists yet.

   ![The DIFF view before the first sync: nothing on the left, the new Cluster in green on the right](img/argocd/10-argocd-diff.jpg)

2. Close the view (✕, top right), click **SYNC**, then **SYNCHRONIZE**. Leave every box as it is.

   ![The SYNC panel with the SYNCHRONIZE button and the Cluster resource ticked](img/argocd/11-argocd-sync.jpg)

3. Wait. The page shows **Synced** at once and **Progressing** while VKS builds the cluster: 4
   to 7 minutes, longer on a busy system.

**Expect:** **Healthy**, **Synced** and **Sync OK**.

![The application page: Healthy, Synced, Sync OK](img/argocd/12-argocd-healthy.jpg)

The vSphere Client shows the same cluster: **Supervisor Management** → **Namespaces** → your
namespace → **Resources** → **Kubernetes service**.

![The vSphere Client listing the new cluster as Available](img/argocd/13-vsphere-cluster.jpg)

**If not:** red text in the DIFF, or a left half that is not empty, on a first sync — a cluster
with that name already exists: do not sync; delete the Application with **Non-cascading** (step
9 shows the window) and choose another name. Still **Progressing** after 30 minutes —
`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe cluster "$NEW_CLUSTER"`
shows the condition that is waiting; a VM class that is too small, or a namespace without room,
shows there.

To use the new cluster, set `VKS_CLUSTER` in `~/.vks-golang-web.env` to its name and run the main
guide's step 7 from *Get the guest cluster's kubeconfig*.

ArgoCD applies this cluster only when you click **SYNC**. To change it later, open the
Application's **DETAILS** → **PARAMETERS**, edit a value, and sync again.

## 8. Add the new cluster to ArgoCD

This makes the guest cluster a destination too, so ArgoCD can deploy applications into it. You do
it with the `argocd` program from step 1, in three short blocks. (To do it without that program,
use the alternative at the end of this step instead.)

First save the new cluster's kubeconfig to a file only you can read, and print the name of the
login inside it (its *context*). If this is a new terminal, set the name again first:
`NEW_CLUSTER="<the name from step 7>"`.

```sh
source ~/.vks-golang-web.env
( umask 077; kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret "${NEW_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' | base64 -d > "$HOME/.kube/${NEW_CLUSTER}.kubeconfig" )
kubectl --kubeconfig "$HOME/.kube/${NEW_CLUSTER}.kubeconfig" config current-context
```

**Expect:** `<cluster>-admin@<cluster>`.

**If not:** `secrets "-kubeconfig" not found` — `NEW_CLUSTER` is not set in this terminal.
`secrets "<name>-kubeconfig" not found` — the cluster from step 7 is not ready yet, or the name
is wrong.

Then check that the address still presents ArgoCD's certificate, as you did in the browser in
step 5: the `argocd` program cannot check it for you.

```sh
source ~/.vks-golang-web.env
A="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd argocd-1 -o jsonpath='{.status.externalIP}')"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret argocd-secret -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
openssl s_client -connect "${A}:443" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

**Expect:** the same `Fingerprint=…` line twice.

**If not:** two different fingerprints, or only one line — do not log in: something between you
and ArgoCD replaces certificates, or the address is not ArgoCD's.

Now log the `argocd` program in. It asks two things. First `Proceed insecurely (y/n)?`, because
it cannot check the certificate itself: answer `y` (you just checked it). Then the password: type
the `admin` password from step 5.

```sh
source ~/.vks-golang-web.env
argocd login "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd argocd-1 -o jsonpath='{.status.externalIP}')" --username admin --grpc-web
```

**Expect:** `'admin:login' logged in successfully`, then `Context '<the address>' updated`.

**If not:** `Invalid username or password` — type the password from step 5 again, carefully.
`dial tcp :443: connect: connection refused` — the address is empty: the instance is not `Ready`
(step 4), or your Supervisor login ended.

Now add the cluster. Run this only after the login above succeeded: without a login the program
still creates its account on the new cluster, and only then fails.

```sh
argocd cluster add "$(kubectl --kubeconfig "$HOME/.kube/${NEW_CLUSTER}.kubeconfig" config current-context)" --kubeconfig "$HOME/.kube/${NEW_CLUSTER}.kubeconfig" --upsert -y
argocd cluster list
```

**Expect:** four lines about `argocd-manager` on the new cluster (`created`; `already exists` or
`updated` when you run it again), then `Cluster 'https://<an address>:6443' added`, then two
destinations: your namespace, and
`<cluster>-admin@<cluster>` with **Successful** (**Unknown** for a few seconds when you run it
again). In the ArgoCD page they are under **Settings** →
**Clusters**.

**If not:** `Argo CD server address unspecified` — the login block did not succeed: run it, then
this block again. `current-context is not set`, then `context  does not exist in kubeconfig` —
the first block of this step did not run, or `NEW_CLUSTER` is not set
(`NEW_CLUSTER="<the name from step 7>"`).

### How long this login lasts

ArgoCD keeps a login for each destination. Which one it keeps depends on the kubeconfig you gave
it: this kubeconfig holds the cluster's administrator **certificate**, so that is what ArgoCD
stored, and a certificate has an end date; the block below prints it. After that date ArgoCD
can no longer deploy to the cluster or show its state, until you renew the login. What already
runs in the cluster keeps running.

This prints, for every destination, what ArgoCD holds and until when. It shows no secret.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq -r '.items[] | ((.data.config // "e30=") | try (@base64d | fromjson) catch {}) as $c
      | ($c.bearerToken // "") as $t
      | (if ($t | test("^[^.]+[.][^.]+[.][^.]+$")) then (try ($t | split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | . as $p | $p + ("===" | .[0:((4 - (($p | length) % 4)) % 4)]) | @base64d | fromjson | .exp // 0) catch 0) else 0 end) as $exp
      | [((.data.name // "") | try @base64d catch "" | if . == "" then "(no name)" else . end),
         (if $t != "" then "token" elif ($c.tlsClientConfig.certData // "") != "" then "certificate" else "other" end),
         (if $t != "" then (if $exp > 0 then ($exp | todate) else "none" end) else ($c.tlsClientConfig.certData // "none") end)] | @tsv' \
  | while IFS="$(printf '\t')" read -r name kind detail; do
      case "$kind" in
        token)       if [ "$detail" = none ]; then echo "$name: token, no end date"; else echo "$name: token, valid until $detail"; fi ;;
        certificate) echo "$name: certificate, valid until $(printf '%s' "$detail" | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)" ;;
        *)           echo "$name: no stored login" ;;
      esac
    done
```

**Expect:** one line per destination, such as `<cluster>-admin@<cluster>: certificate, valid until
Oct  8 02:07:25 2027 GMT`. Your namespace's line says `token, no end date`.

To renew: set `NEW_CLUSTER` if this is a new terminal, run the first block of this step again,
then the check and login blocks, then the block that adds the cluster, then this check again. The
date should now be later. If it is the same, the cluster has not made a newer certificate yet:
try again some weeks later, before the date shown. Keep `--upsert` in the add block: it is what
replaces the stored login. Without it, an `argocd cluster add` whose login differs from the
stored one restarted the ArgoCD server (v3.4.4) instead of printing an error.

<details>
<summary><b>Alternative: let the ArgoCD Service add the cluster</b> (a ManagedEntity)</summary>

Run this INSTEAD of the four blocks at the start of this step; it needs no `argocd` program. The ArgoCD Service adds the cluster for you; the
**Edit** role from step 6 already covers it. The service stores the same administrator
certificate, with the same end date, and keeps that copy. To renew, delete this `ManagedEntity`
(the block in step 9's alternative) and run this block again; the destination is missing in
between.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<EOF
apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
kind: ManagedEntity
metadata:
  name: ${NEW_CLUSTER}
spec:
  targetRef:
    apiGroup: cluster.x-k8s.io
    kind: Cluster
    name: ${NEW_CLUSTER}
    namespace: ${VKS_NAMESPACE}
EOF
```

**Expect:** `managedentity…/<name> created`. In the ArgoCD page, **Settings** → **Clusters** now
lists two destinations: your namespace, and `<cluster>-<namespace>` at
`https://<an address>:6443`. The new one reads **Unknown** until an Application uses it.

![ArgoCD Settings, Clusters: the namespace and the new guest cluster](img/argocd/14-argocd-clusters.jpg)

**If not:** `resource name may not be empty` — this is not the terminal where you set
`NEW_CLUSTER` in step 7: set it again and run the block again. `created`, but the cluster does
not appear under **Settings** → **Clusters** — the name is not a cluster's:
`kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe managedentity "$NEW_CLUSTER"`
says what it is waiting for; delete it with the block in step 9's alternative and correct the
name.

</details>

## 9. Clean up (optional)

Do these in order. ArgoCD must still exist while it deletes the cluster, and the service must
still exist while the instance is deleted.

### Delete the guest cluster

First remove the cluster from ArgoCD's destinations. If this is a new terminal, set the name
again first: `NEW_CLUSTER="<the name from step 7>"`.

If you added the cluster with step 8's alternative (a ManagedEntity), run this block and skip the
two after it:

<details>
<summary><b>Alternative: if you added the cluster with a ManagedEntity</b></summary>

Run this INSTEAD of the two blocks below.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete managedentity "$NEW_CLUSTER"
```

**Expect:** `managedentity… "<name>" deleted`. `resource name may not be empty` means
`NEW_CLUSTER` is not set in this terminal.

</details>

Otherwise remove it with the `argocd` program. If its login from step 8 has ended (a command
answers that you are not logged in), run step 8's check and login blocks first.

```sh
( export KUBECONFIG="$HOME/.kube/${NEW_CLUSTER:?set NEW_CLUSTER first}.kubeconfig"; argocd cluster rm "$(kubectl config current-context)" -y ) && rm -f "$HOME/.kube/${NEW_CLUSTER}.kubeconfig"
```

**Expect:** `Cluster '<cluster>-admin@<cluster>' removed`, then three lines saying the
`argocd-manager` account, its role and its binding were deleted on the new cluster.

**If not:** `Argo CD server address unspecified` — run step 8's login block, then this again.
`error: current-context is not set` — the file from step 8 is gone: save it again with step 8's
first block. `set NEW_CLUSTER first` — set it as shown above.

Then log the `argocd` program out. It asks the same certificate question as the login: answer `y`.

```sh
source ~/.vks-golang-web.env
argocd logout "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd argocd-1 -o jsonpath='{.status.externalIP}')"
```

**Expect:** `token successfully invalidated on server`, then `Logged out from '<the address>'`.

**If not:** `Nothing to logout from` — you were not logged in; nothing to do.

Then, in the ArgoCD page, open the Application, click **DELETE**, type the Application's name,
leave **Foreground** selected, and click **OK**. **Non-cascading** would remove only the
Application and leave the cluster and its virtual machines running.

![The Delete application window with the name field and the Foreground, Background and Non-cascading choices](img/argocd/15-argocd-delete.jpg)

Check that the cluster is gone before you go on. Run this again until both lines say `NotFound`:
a few minutes at most.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get cluster "$NEW_CLUSTER"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$NEW_CLUSTER"
```

**Expect:** two `Error from server (NotFound): …` lines, one for the cluster and one for the
Application.

**If not:** `resource name may not be empty` — `NEW_CLUSTER` is not set in this terminal: set it
and run the block again.

### Delete the ArgoCD instance

Skip this if the instance existed before you started this guide. It removes the project, the
destination, the role binding and the instance, then the two secrets the instance leaves behind
(a new instance would otherwise meet the old admin password).

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete appproject vks-clusters --ignore-not-found
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete managedentity "$VKS_NAMESPACE" --ignore-not-found
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete rolebinding argocd-k8s-sa-edit --ignore-not-found
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete argocd argocd-1 --ignore-not-found
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete secret argocd-initial-admin-secret argocd-redis --ignore-not-found
```

**Expect:** up to six `deleted` lines.

### Remove the ArgoCD Service

Only for the user who did steps 2 and 3, and only if those steps installed the service (not if it
was there before). First make sure no vSphere Namespace on this Supervisor still has an ArgoCD
instance: uninstalling removes them.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocd -A
```

**Expect:** `No resources found`.

**If not:** a list of instances — do not go on until their owners have deleted them. `Forbidden`
— you cannot see other namespaces: ask your vCenter administrator to check.

1. In the vSphere Client: **Supervisor Management** → **Supervisors** → **View** in your
   Supervisor's **Services** column. Select **ArgoCD Service** and click **UNINSTALL**, then
   **UNINSTALL** in the window that asks *Are you sure…*. The row shows **Removing**, then
   disappears: under a minute.
2. Only if no other Supervisor of this vCenter uses the service: open the **Services** tab, and
   on the **ArgoCD Service** card click **ACTIONS** → **Delete**. In the **Delete ArgoCD
   Service** window click **CONFIRM** under *1. Deactivate service*, then **CONFIRM** under
   *3. Delete all versions of the Service*, then **DELETE**. This removes the service from
   vCenter, for every Supervisor.

   ![The Delete ArgoCD Service window with its three steps](img/argocd/17-delete-wizard.jpg)

**Expect:** a green line, *'ArgoCD Service' successfully deleted.* The card disappears when the
page is reloaded.

### Remove the argocd program

Only if step 1 installed it. Its `sudo` asks for your password.

```sh
if /usr/local/bin/argocd version --client 2>/dev/null | grep -q -e -vcf; then sudo rm -f /usr/local/bin/argocd; fi
```

**Expect:** no output.

## Fix common problems

| symptom | fix |
|---|---|
| `error: You must be logged in to the server (Unauthorized)` | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block (step 7), then the command again. If you logged in with the certificate-checking alternative, use the renew block inside that alternative instead. |
| `error: stat …supervisor.kubeconfig: no such file or directory`, or an empty `--kubeconfig` error | The block's first line did not run, or the main guide's step 7 was never done on this machine. |
| The browser refuses the ArgoCD page with no way to go on | Some company browsers forbid pages with a certificate they cannot check. Use [ARGOCD-auto.md](ARGOCD-auto.md), which needs no browser. |
| A destination that worked for months now fails with a certificate or `Unauthorized` error | The certificate ArgoCD holds for it has ended. Step 8's *How long this login lasts* block shows the date; renew as described under it. |
| The Application shows **OutOfSync** right after a sync | `kubernetesVersion` has a `-vkr.N` ending. Open the Application's **DETAILS** → **PARAMETERS**, remove the ending, save, and sync again. |
| The DIFF of an existing cluster lists a few lines only on the left | Two settings the Supervisor added to the cluster (certificate rotation and the network add-on). ArgoCD still reports **Synced**, and a sync leaves them in place. |
| The Application stays on **Deleting** for many minutes | Normal with **Foreground**: VKS deletes the virtual machines first. |
| **UNINSTALL** is refused, or instances disappear | An ArgoCD instance still existed on the Supervisor. `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocd -A` lists them; delete each (step 9) first. |
