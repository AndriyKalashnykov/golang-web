# Deploy golang-web with ArgoCD

This chapter has the ArgoCD on your Supervisor deploy `golang-web` into a guest cluster. ArgoCD
reads the app's description from the [`k8s`](../k8s) folder of a Git repository and keeps the
cluster equal to it. Which image runs is your choice, written as a name and a digest into the
ArgoCD *Application*, so you need no Git repository of your own. It was written for VMware Cloud
Foundation 9.1.1, ArgoCD Service 1.2.0 (ArgoCD 3.4.4) and VKS 3.7.

Every block uses `kubectl` only: the Application, its project and the destination are objects in
your vSphere Namespace, where ArgoCD runs. You do not need the `argocd` program or the `helm`
program for this chapter.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each block is
followed by **Expect:** — what you should see — and, where it can go wrong, **If not:** — what to
do. A block you run twice either changes nothing or tells you what to do.

The terms *Application*, *destination*, *project* and *sync* are explained in the ArgoCD guide
([ARGOCD-auto.md](ARGOCD-auto.md), *Learn the terms*).

**An app deployed here belongs to ArgoCD.** ArgoCD keeps putting back what the Application says,
so three things other chapters do by hand do not last on it:

- The main guide's *Delete the app* (`kubectl delete namespace golang-web`) is undone: ArgoCD
  creates the namespace and the app again. Delete the Application instead (*Delete the app*
  below), and do that **before** you delete the guest cluster or the ArgoCD instance.
- The Istio chapter's *Make the app's Service internal* and its option *put the app into the
  mesh* change the app with `kubectl`; ArgoCD reverts both. Choose the Service's type with
  `APP_SERVICE_TYPE` here, and make any other change in Git (*Use your own Git repository*).
- A change of the image with `kubectl` is reverted too (*Deploy another image*).

## Gather what you need

- The main guide's env file, tools and Supervisor login ([the main guide](README.md)).
- **An ArgoCD instance** in your vSphere Namespace, allowed to manage that namespace: the ArgoCD
  guide ([ARGOCD.md](ARGOCD.md)) up to and including *Let ArgoCD manage your vSphere Namespace*.
- **A guest cluster**, with `VKS_CLUSTER` in the env file set to its name and its kubeconfig
  saved. Either the ArgoCD guide created it (*Create a guest cluster with ArgoCD*), or you did
  without it ([CLUSTER.md](CLUSTER.md)). In both cases finish with
  [Get the cluster's kubeconfig](CLUSTER.md#get-the-clusters-kubeconfig).
- **An image.** Either the image you built and pushed to your Harbor ([REGISTRY.md](REGISTRY.md); you need its digest;
  *Choose the image* below looks it up), or the published image on `ghcr.io`, which needs no
  Harbor: the guest cluster's nodes must then reach `ghcr.io`.
- The Supervisor must reach the Git repository (`github.com` for this one): ArgoCD reads the
  `k8s` folder from there.

## Add this chapter's settings

This adds eight settings to your env file, each only if it is not there yet. Values you already
set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export ARGOCD_APP=' ~/.vks-golang-web.env || printf '%s\n' 'export ARGOCD_APP="golang-web"' >> ~/.vks-golang-web.env
  grep -qs '^export APP_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export APP_NAMESPACE="golang-web"' >> ~/.vks-golang-web.env
  grep -qs '^export APP_REPO=' ~/.vks-golang-web.env || printf '%s\n' 'export APP_REPO="https://github.com/AndriyKalashnykov/golang-web.git"' >> ~/.vks-golang-web.env
  grep -qs '^export APP_REVISION=' ~/.vks-golang-web.env || printf '%s\n' 'export APP_REVISION="main"' >> ~/.vks-golang-web.env
  grep -qs '^export APP_IMAGE=' ~/.vks-golang-web.env || printf '%s\n' 'export APP_IMAGE=""' >> ~/.vks-golang-web.env
  grep -qs '^export APP_SERVICE_TYPE=' ~/.vks-golang-web.env || printf '%s\n' 'export APP_SERVICE_TYPE="ClusterIP"' >> ~/.vks-golang-web.env
  grep -qs '^export APP_REPO_USERNAME=' ~/.vks-golang-web.env || printf '%s\n' "export APP_REPO_USERNAME=''" >> ~/.vks-golang-web.env
  grep -qs '^export APP_REPO_TOKEN=' ~/.vks-golang-web.env || printf '%s\n' "export APP_REPO_TOKEN=''" >> ~/.vks-golang-web.env
  grep -c -E '^export (ARGOCD_APP|APP_NAMESPACE|APP_REPO|APP_REVISION|APP_IMAGE|APP_SERVICE_TYPE|APP_REPO_USERNAME|APP_REPO_TOKEN)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `8`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 8 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

| setting | meaning |
|---|---|
| `ARGOCD_APP` | the name of the Application in ArgoCD |
| `APP_NAMESPACE` | the Kubernetes namespace in the guest cluster that ArgoCD creates for the app. **Use one that does not exist yet**: the blocks refuse a namespace they did not create |
| `APP_REPO`, `APP_REVISION` | the Git repository and the branch, tag or commit ArgoCD reads the `k8s` folder from |
| `APP_IMAGE` | the image to run, as `<name>@sha256:<digest>`. Empty means: the published image, exactly as the file in Git names it |
| `APP_SERVICE_TYPE` | `ClusterIP` (reach the app through `kubectl port-forward`) or `LoadBalancer` (the app gets an address of its own) |
| `APP_REPO_USERNAME`, `APP_REPO_TOKEN` | only for a private Git repository of your own (*Use your own Git repository* below) |

**Why `ClusterIP` is the default.** The published image `0.0.4` answers `/shutdown` for anyone
who can reach it, and the app then stops. With `ClusterIP` only people who hold the cluster's
kubeconfig reach the app. Set `LoadBalancer` only on a network where every machine that can
reach the address may stop the app.

**What `main` means.** With `APP_REVISION="main"` ArgoCD follows this repository: a change to
the `k8s` folder here reaches your cluster a few minutes later, without asking you. To decide that
yourself, pin a commit. This asks the repository which commit your `APP_REVISION` points to now
(it never asks for a password: a repository that needs one answers with an error):

```sh
source ~/.vks-golang-web.env
GIT_TERMINAL_PROMPT=0 git ls-remote "$APP_REPO" "$APP_REVISION"
```

**Expect:** it depends on what `APP_REVISION` is:

| `APP_REVISION` is | the block prints |
|---|---|
| a branch, such as `main` | one line: 40 letters and digits (the commit), then `refs/heads/<the branch>` |
| a tag | the same with `refs/tags/<the tag>`; a second line ending in `^{}`, when there is one, holds the commit |
| a commit (40 letters and digits) | nothing: a commit is already pinned |

Put the 40 characters into the env file as `APP_REVISION` to pin that commit.

**If not:** no output for a branch or tag name — the repository has no branch or tag of that
name. `Repository not found`, `could not read Username` or `terminal prompts disabled` — the
address is wrong, or the repository is private: your machine then needs your own Git login to
read it, and ArgoCD needs one too (*Use your own Git repository* below).

## Check ArgoCD and the guest cluster

This confirms the tools, the ArgoCD instance and your access to the guest cluster.

```sh
source ~/.vks-golang-web.env
for t in curl git jq kubectl; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd -o jsonpath='{range .items[*]}{"ArgoCD instance: "}{.metadata.name}{"  "}{.status.phase}{"\n"}{end}'
kubectl --kubeconfig "$GUEST_KUBECONFIG" get nodes
```

**Expect:** no `MISSING` line, then `ArgoCD instance: <its name>  Ready`, then the guest
cluster's nodes, each `Ready`.

**If not:**
- No `ArgoCD instance:` line: your vSphere Namespace has no ArgoCD instance. Do the ArgoCD guide
  first ([ARGOCD.md](ARGOCD.md)). `the server doesn't have a resource type "argocd"` means the
  ArgoCD Service is not installed on the Supervisor.
- `Unauthorized` on the first `kubectl` line: the Supervisor login ended; run the main guide's
  *Renew the Supervisor login* block.
- An error on the last line: the guest cluster's kubeconfig is missing, or `VKS_CLUSTER` names
  another cluster. Run *Get the cluster's kubeconfig* in [CLUSTER.md](CLUSTER.md).

## Make the guest cluster a destination

ArgoCD deploys only to clusters it was told about (its *destinations*). This block shows them,
and marks the one that is your guest cluster.

```sh
source ~/.vks-golang-web.env
DEST="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
echo "guest cluster: ${VKS_CLUSTER:-NOT SET} at ${DEST:-NO KUBECONFIG}"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq -r --arg s "$DEST" '.items[] | ((.data.server // "") | @base64d) as $u | ((.data.name // "") | @base64d) as $n | "\(if $u == $s and $s != "" then "DESTINATION" else "other" end)  \($n)  \($u)"'
```

**Expect:** `guest cluster: <your cluster> at https://<an address>:6443`, then one line per
destination ArgoCD has. The line that starts with `DESTINATION` is your guest cluster: if you
see it, skip the next block. Your vSphere Namespace is listed too, as `other`.

**If not:**
- No line starts with `DESTINATION`: the guest cluster is not a destination yet. The ArgoCD
  guide's *Add the new cluster to ArgoCD* adds a cluster that ArgoCD created; the next block
  adds any cluster, also one you created with `kubectl`.
- `NO KUBECONFIG`: run *Get the cluster's kubeconfig* in [CLUSTER.md](CLUSTER.md).

### Add a guest cluster you created with kubectl

A cluster made without ArgoCD ([CLUSTER.md](CLUSTER.md)) is unknown to ArgoCD. This block asks the ArgoCD Service
to add it: it creates a small object (a `ManagedEntity`) in your vSphere Namespace that names
the cluster, and waits until ArgoCD lists the cluster's address. The ArgoCD Service then stores
the cluster's administrator certificate for ArgoCD; that certificate has an end date (the
ArgoCD guide's *How long this login lasts* prints it).

The block changes nothing when the cluster is already a destination: adding one cluster twice
gives ArgoCD two entries for one address. With the `argocd` program you can add the cluster the
other way instead, exactly as the ArgoCD guide's *Add the new cluster to ArgoCD* does, with your
cluster's kubeconfig; do one or the other, not both.

```sh
source ~/.vks-golang-web.env
DEST="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
dest_count() {
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
    | jq -r --arg s "$DEST" '[.items[] | select(((.data.server // "") | @base64d) == $s)] | length'
}
N="$(dest_count)"
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get managedentity "$VKS_CLUSTER" --ignore-not-found -o name)" || EX=unknown
if [ -z "$VKS_CLUSTER" ] || [ -z "$DEST" ]; then
  echo "Not added: VKS_CLUSTER is empty, or the cluster's kubeconfig is not saved"
elif [ -z "$N" ] || [ "$EX" = unknown ]; then
  echo "Not added: the Supervisor did not answer (see the error above)"
elif [ "$N" -gt 0 ]; then
  echo "Already a destination: nothing to do"
elif [ "$VKS_CLUSTER" = "$VKS_NAMESPACE" ]; then
  echo "Not added: the guest cluster and the vSphere Namespace are both named '${VKS_CLUSTER}', and the ManagedEntity of that name is the namespace's own. Nothing was changed: add this cluster with the argocd program instead."
elif [ -n "$EX" ]; then
  echo "Not added: a ManagedEntity named '${VKS_CLUSTER}' exists and ArgoCD does not list the cluster. Read 'If not' below."
elif printf 'apiVersion: argocd-service.vsphere.vmware.com/v1alpha1\nkind: ManagedEntity\nmetadata:\n  name: %s\n  labels:\n    vks-golang-web/guide: argocd-app\nspec:\n  targetRef:\n    apiGroup: cluster.x-k8s.io\n    kind: Cluster\n    name: %s\n    namespace: %s\n' \
       "$VKS_CLUSTER" "$VKS_CLUSTER" "$VKS_NAMESPACE" | kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f -; then
  n=0
  until [ "$(dest_count)" = 1 ] || [ "$n" -ge 20 ]; do
    n=$((n + 1)); sleep 3
  done
  echo "ManagedEntity: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get managedentity "$VKS_CLUSTER" -o jsonpath='{.status.phase}')"
  echo "destinations at ${DEST}: $(dest_count)"
else
  echo "Not added: see the error above"
fi
```

**Expect:** `managedentity…/<your cluster> created`, then `ManagedEntity: Ready` and
`destinations at https://<an address>:6443: 1`. When the cluster was added before:
`Already a destination: nothing to do`.

**If not:**
- `ManagedEntity:` with another word than `Ready`, or `destinations at …: 0`:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe managedentity "$VKS_CLUSTER"`
  names the failed condition. `MissingRoleBinding` means ArgoCD may not manage your vSphere
  Namespace yet: do the ArgoCD guide's *Let ArgoCD manage your vSphere Namespace*, then run
  this block again. If the object is `Ready` and the count stays `0`, the address ArgoCD stored
  differs from the one in your kubeconfig: run the block before this one and compare the two.
- `Not added: the guest cluster and the vSphere Namespace are both named …`: the ArgoCD Service
  names each `ManagedEntity` after what it adds, and your vSphere Namespace already holds that
  name. Use the ArgoCD guide's *Add the new cluster to ArgoCD* with this cluster's kubeconfig:
  the `argocd` program needs no such object.
- `Not added: a ManagedEntity named … exists …`: an earlier try left it. The `describe` command
  above says what it waits for.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.

## Choose the image

**The published image, without Harbor.** Leave `APP_IMAGE` empty. ArgoCD then deploys the image
exactly as [`k8s/golang-web.yaml`](../k8s/golang-web.yaml) names it at `APP_REVISION`: from
`ghcr.io`, by tag and digest. Go on with *Create the project*.

**Your image in Harbor.** Set `APP_IMAGE` to the image's name and digest, with no tag:
`<Harbor's name>/<project>/golang-web@sha256:<digest>`. A digest names one image for ever; a
tag can be moved to another image later, and a node that already holds an older image of the
same tag starts that one. This block looks up the digest of the version you pushed and prints
the line for the env file. Run it from inside your `golang-web` clone, after
[Build and push the image](REGISTRY.md#build-and-push-the-image).

```sh
source ~/.vks-golang-web.env
if [ ! -f version.txt ]; then
  echo "Not looked up: run this block from inside your golang-web clone"
else
  harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
  DIGEST="$(curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
    "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts/$(cat version.txt)" \
    | jq -r '.digest // empty')"
  rm -f "$CFG"
  if [ -n "$DIGEST" ]; then
    echo "export APP_IMAGE=\"${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web@${DIGEST}\""
  else
    echo "NOT FOUND: read the curl error above. 404 = not pushed; 401 = wrong credentials or HARBOR_PROJECT; 403 = the robot lacks artifact read; certificate = HARBOR_CA"
  fi
fi
```

**Expect:** one line, `export APP_IMAGE="<Harbor's name>/<project>/golang-web@sha256:…"`.

**If not:** `NOT FOUND: …` explains itself; build and push the image first ([REGISTRY.md](REGISTRY.md)).

Open the env file and replace the `export APP_IMAGE=""` line with the printed line.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
blocks read the new value.

## Create the project

A project is ArgoCD's rule set for Applications. The ArgoCD guide's project (`vks-clusters`)
allows one kind of object, a guest cluster, in your vSphere Namespace: it cannot deploy an app.
This block creates a second project, `vks-apps`, that allows only what this app needs:

| rule | value |
|---|---|
| where the description may come from | one Git repository: `APP_REPO` |
| where it may be applied | one cluster (your guest cluster's address) and one namespace in it (`APP_NAMESPACE`) |
| objects for the whole cluster | one: the `Namespace` named `APP_NAMESPACE`, so ArgoCD can create it |
| objects inside the namespace | two kinds: `Deployment` and `Service`. Nothing else: no `Secret`, no role |

The third rule needs Argo CD 3.4 or later: older versions cannot limit a `Namespace` by name.
So the block reads the name back after it stored the project, and tells you to stop when ArgoCD
did not keep it.

The block refuses a project named `vks-apps` that it did not create.

```sh
source ~/.vks-golang-web.env
DEST="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps --ignore-not-found -o name)" || EX=unknown
MK="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}' 2>/dev/null)"
if [ -z "$DEST" ] || [ -z "$APP_REPO" ] || [ -z "$APP_NAMESPACE" ]; then
  echo "Not created: APP_REPO or APP_NAMESPACE is empty, or the guest cluster's kubeconfig is not saved"
elif [ "$EX" = unknown ]; then
  echo "Not created: the Supervisor did not say whether the project exists (see the error above)"
elif [ -n "$EX" ] && [ "$MK" != argocd-app ]; then
  echo "Not changed: a project named 'vks-apps' exists and this chapter did not create it"
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: vks-apps
  labels:
    vks-golang-web/guide: argocd-app
spec:
  description: Only golang-web, from one repository, into one namespace of one guest cluster
  sourceRepos:
  - "${APP_REPO}"
  destinations:
  - server: "${DEST}"
    namespace: "${APP_NAMESPACE}"
  clusterResourceWhitelist:
  - group: ""
    kind: Namespace
    name: "${APP_NAMESPACE}"
  namespaceResourceWhitelist:
  - group: apps
    kind: Deployment
  - group: ""
    kind: Service
EOF
then
  WN="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps -o jsonpath='{.spec.clusterResourceWhitelist[0].name}')"
  if [ "$WN" = "$APP_NAMESPACE" ]; then
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps -o jsonpath='{.spec.sourceRepos[0]}{"  ->  "}{.spec.destinations[0].server}{"  namespace "}{.spec.destinations[0].namespace}{"\n"}'
  else
    echo "STOP: the stored project does not limit the Namespace to '${APP_NAMESPACE}' (it holds '${WN}'). An Application in it could create ANY namespace in the guest cluster. Nothing was deleted. Do not create the Application: read 'If not' below."
  fi
else
  echo "Not created: see the error above"
fi
```

**Expect:** `appproject.argoproj.io/vks-apps created` (`unchanged` or `configured` when you run
it again), then `<the repository>  ->  https://<an address>:6443  namespace <your namespace>`.

**If not:**
- `STOP: the stored project does not limit the Namespace …`: this ArgoCD dropped the
  `Namespace`'s name from the project, which Argo CD older than 3.4 does. The project is stored
  and nothing uses it yet; *Create the Application* refuses it as it is. This prints the version
  of your instance:
  `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.version}{"\n"}{end}'`.
  This chapter needs an ArgoCD Service that brings Argo CD 3.4 or later (ArgoCD Service
  1.2.0 brings 3.4.4; it is the one [ARGOCD-manual.md](ARGOCD-manual.md) and
  [ARGOCD-auto.md](ARGOCD-auto.md) install). To take the project away again, run *Delete the
  project and the repository login* below.
- `Not changed: a project named 'vks-apps' exists …`: someone else made it. Ask them, or have
  your ArgoCD administrator allow your repository, cluster and namespace in it. This chapter
  does not change a project it did not create.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.

## Create the Application

The Application tells ArgoCD: keep what the `k8s` folder of `APP_REPO` describes applied to the
namespace `APP_NAMESPACE` of your guest cluster. It carries four choices; change any of them
in the block if you want another:

- **The image**, when `APP_IMAGE` is set: ArgoCD replaces the image name
  `ghcr.io/andriykalashnykov/golang-web` of the file in Git with your name and digest. It is
  stored in the Application, not in Git.
- **The Service type**, from `APP_SERVICE_TYPE`.
- **Automatic sync, with `prune` and `selfHeal`.** ArgoCD applies a change by itself as soon as
  it sees one, deletes from the cluster what is no longer described, and undoes a change
  somebody makes in the cluster by hand. Take the three `automated`, `prune` and `selfHeal`
  lines out to sync only when you say so (then `argocd app sync`, or **SYNC** on the ArgoCD
  page, applies a change).
- **ArgoCD creates the namespace** (`CreateNamespace=true`) and gives it two labels: the Pod
  Security level `restricted`, which the app is built for, and this chapter's mark. ArgoCD does
  not delete that namespace again; *Delete the app* below does.

The Application also carries ArgoCD's `resources-finalizer`: deleting the Application then
deletes the app from the cluster too.

The block refuses an Application of that name, and a namespace of that name in the guest
cluster, that this chapter did not create: ArgoCD would take over, change and delete what is
there. An app you deployed with the main guide lives in a namespace named `golang-web` too:
delete it first (the main guide's *Delete the app*), or set another `APP_NAMESPACE`.

```sh
source ~/.vks-golang-web.env
DEST="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o name)" || EX=unknown
MK="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}' 2>/dev/null)"
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$APP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || NS=unknown
WN="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps --ignore-not-found -o jsonpath='{.spec.clusterResourceWhitelist[0].name}' 2>/dev/null)"
M=""
for v in ARGOCD_APP APP_NAMESPACE APP_REPO APP_REVISION APP_SERVICE_TYPE; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
BAD=""
IMG=""
NAME="${APP_IMAGE%@*}"
case "$APP_SERVICE_TYPE" in
  ClusterIP|LoadBalancer) ;;
  *) BAD="APP_SERVICE_TYPE must be ClusterIP or LoadBalancer" ;;
esac
case "$APP_IMAGE" in
  '') ;;
  ?*@sha256:?*) IMG="\"ghcr.io/andriykalashnykov/golang-web=${APP_IMAGE}\"" ;;
  *) BAD="APP_IMAGE must be <name>@sha256:<digest>" ;;
esac
case "${NAME##*/}" in
  *:*) BAD="APP_IMAGE must not carry a tag: write <name>@sha256:<digest>" ;;
esac
if [ -n "$M" ]; then
  echo "Not created: no value for:$M"
elif [ -z "$DEST" ]; then
  echo "Not created: the guest cluster's kubeconfig is not saved"
elif [ -n "$BAD" ]; then
  echo "Not created: $BAD"
elif [ "$EX" = unknown ] || [ "$NS" = unknown ]; then
  echo "Not created: the Supervisor or the guest cluster did not answer (see the error above)"
elif [ -n "$EX" ] && [ "$MK" != argocd-app ]; then
  echo "Not changed: an Application named '${ARGOCD_APP}' exists and this chapter did not create it. Set another ARGOCD_APP."
elif [ -n "$NS" ] && [ "$NS" != "${APP_NAMESPACE}/argocd-app" ]; then
  echo "Not created: the namespace '${APP_NAMESPACE}' exists in the guest cluster and this chapter did not create it. Delete what is in it first, or set another APP_NAMESPACE."
elif [ "$WN" != "$APP_NAMESPACE" ]; then
  echo "Not created: the project 'vks-apps' is missing, or does not limit the Namespace to '${APP_NAMESPACE}' (it holds '${WN}'). Run 'Create the project' again and read its 'If not'."
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP}
  labels:
    vks-golang-web/guide: argocd-app
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: vks-apps
  source:
    repoURL: "${APP_REPO}"
    targetRevision: "${APP_REVISION}"
    path: k8s
    kustomize:
      images: [${IMG}]
      patches:
      - target:
          kind: Service
          name: golang-web-service
        patch: |-
          - op: replace
            path: /spec/type
            value: ${APP_SERVICE_TYPE}
  destination:
    server: "${DEST}"
    namespace: "${APP_NAMESPACE}"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        vks-golang-web/guide: argocd-app
    syncOptions:
    - CreateNamespace=true
EOF
fi
```

**Expect:** `application.argoproj.io/<your app> created`. When you run it again with the same
values: `unchanged`; with a new value: `configured`. `kubectl` prints one line before it,
`Warning: metadata.finalizers: "resources-finalizer.argocd.argoproj.io": prefer a domain-qualified
finalizer name including a path (/) …`: that is ArgoCD's own name for the finalizer, and the
warning is harmless.

**If not:**
- `Not created: no value for: …`: each name listed is empty in the env file.
- `Not created: APP_IMAGE must …`: write the image as `<name>@sha256:<digest>`. A name alone
  would keep the published image's digest under your name, and a name with a tag would start
  whatever that tag points to: this chapter takes neither.
- `Not changed: an Application named … exists …`, `Not created: the namespace … exists …`: see
  the paragraph above the block.
- `Not created: the project 'vks-apps' is missing, or does not limit the Namespace …`: run
  *Create the project* first, or again after you changed `APP_NAMESPACE`. If that block prints
  `STOP: …`, its *If not* says what to do.
- `Forbidden`: your SSO user lacks the **Edit** role on the vSphere Namespace.

An image in a private Harbor project needs the next section before the app can start. With a
public Harbor project, or the published image, go on with *Wait for the app and check its
image*.

## Create a pull secret — only for a private Harbor project

If your Harbor project is private (Harbor's default for a new project), the cluster needs a
Harbor login to download the image. Check whether the project is public, without logging in:

```sh
source ~/.vks-golang-web.env
curl -sS --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}"
```

**Expect:** `http=200` — the project is public: skip the next block. `http=401`, or any other
code except `000` — the project is private (or its visibility is unknown): run the next block.

**If not:** `http=000` with a `curl:` error means Harbor could not be reached from this machine.

ArgoCD does not create this secret: the project above allows it no `Secret`, and a password
does not belong in Git. This block stores your Harbor login (`REGISTRY_USERNAME` and
`REGISTRY_TOKEN` from the env file; a robot account is best) in the app's namespace as the
secret `harbor-creds`, makes every pod of that namespace use it, and deletes the app's pods so
that new ones start with it. The login is passed to `kubectl` on its input, never on a command
line. Run it after *Create the Application*: the namespace must exist.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$APP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || NS=unknown
EX="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" get secret harbor-creds --ignore-not-found -o name)" || EX=unknown
MK="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" get secret harbor-creds --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}' 2>/dev/null)"
if [ -z "$APP_NAMESPACE" ] || [ -z "$HARBOR_FQDN" ] || [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_TOKEN" ]; then
  echo "Not created: APP_NAMESPACE, HARBOR_FQDN, REGISTRY_USERNAME or the registry token is empty in the env file"
elif [ "$NS" = unknown ] || [ "$EX" = unknown ]; then
  echo "Not created: the guest cluster did not answer (see the error above)"
elif [ "$NS" != "${APP_NAMESPACE}/argocd-app" ]; then
  echo "Not created: the namespace '${APP_NAMESPACE}' is not there yet, or this chapter did not create it. Run 'Create the Application' first; then wait a few seconds and run this block again."
elif [ -n "$EX" ] && [ "$MK" != argocd-app ]; then
  echo "Not changed: a secret named 'harbor-creds' exists in '${APP_NAMESPACE}' and this chapter did not create it"
elif jq -n '{apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson",
             metadata: {name: "harbor-creds", labels: {"vks-golang-web/guide": "argocd-app"}},
             stringData: {".dockerconfigjson": ({auths: {(env.HARBOR_FQDN): {username: env.REGISTRY_USERNAME, password: env.REGISTRY_TOKEN,
               auth: ((env.REGISTRY_USERNAME + ":" + env.REGISTRY_TOKEN) | @base64)}}} | tojson)}}' \
     | kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" apply -f -; then
  if kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-creds"}]}'; then
    kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" delete pod -l app=golang-web --ignore-not-found
  else
    echo "The secret is stored, but the service account was NOT changed (see the error above), so no pod was deleted. Run this block again."
  fi
else
  echo "Not created: see the error above"
fi
```

**Expect:** `secret/harbor-creds created`, `serviceaccount/default patched`, then
`pod "golang-web-…" deleted` (`configured`, `patched (no change)` and the pod line again when
you run it a second time).

**If not:**
- `Not created: the namespace … is not there yet …`: ArgoCD creates the namespace a few seconds
  after *Create the Application*. If it stays missing, the next block's first line says why.
- `The secret is stored, but the service account was NOT changed …`: the second of the three
  commands failed; the line above it says why (`serviceaccounts "default" not found` in the
  first seconds of a new namespace: wait, then run the block again).
- A pod that later shows `no basic auth credentials` or `pull access denied`: the two
  `REGISTRY_` values in the env file are wrong. Fix them and run this block again.

## Wait for the app and check its image

`Synced` alone does not prove that your image runs: for a few minutes after a change ArgoCD can
still report the state of the description it read before. So this block waits (up to three
minutes) for three things together: ArgoCD reports `Synced` and `Healthy`, the Deployment in
the guest cluster names the image you asked for, and every pod of the app runs that digest.

```sh
source ~/.vks-golang-web.env
if [ -z "$ARGOCD_APP" ] || [ -z "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o name)" ]; then
  echo "No Application named '${ARGOCD_APP}', or the Supervisor did not answer: run 'Create the Application' first"
else
  n=0; OK=""
  until [ -n "$OK" ] || [ "$n" -ge 36 ]; do
    [ "$n" -eq 0 ] || sleep 5
    n=$((n + 1))
    A="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" -o jsonpath='{.status.sync.status}{"/"}{.status.health.status}' 2>/dev/null)"
    D="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" get deployment golang-web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    P="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" get pods -l app=golang-web -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null)"
    W="${APP_IMAGE:-$D}"
    W="${W##*@}"
    OTHER="$(printf '%s\n' "$P" | grep -c -v -e "${W:-no digest}\$")"
    if [ "$A" = Synced/Healthy ] && [ -n "$W" ] && [ "$OTHER" = 0 ] && { [ -z "$APP_IMAGE" ] || [ "$D" = "$APP_IMAGE" ]; }; then OK=yes; fi
  done
  echo "Application: ${A:-no answer}"
  echo "asked for:   ${APP_IMAGE:-the image the file in Git names}"
  echo "Deployment:  ${D:-none}"
  printf '%s\n' "${P:-none}" | sed 's/^/pod runs:    /'
  if [ -n "$OK" ]; then
    echo "OK: every pod runs ${W}"
  else
    echo "NOT YET after about $((n * 5)) seconds: read 'If not' below, or run this block again to keep waiting"
    kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}{.status.operationState.message}{"\n"}'
  fi
fi
```

**Expect:** within three minutes `Application: Synced/Healthy`, your image after `asked for:`
and after `Deployment:`, one `pod runs:` line that ends with the same `sha256:…`, and
`OK: every pod runs sha256:…`.

**If not:** the last lines are `NOT YET after …` and what ArgoCD says about the Application:
- `application destination … is not permitted in project`, or `resource … is not permitted in
  project`: run *Create the project* again; it follows your settings.
- `repository not accessible`, `authentication required`: the Supervisor cannot reach
  `APP_REPO`, or the repository is private (*Use your own Git repository* below).
- `app path does not exist`, or a `kustomize build` error: `APP_REVISION` is a commit older
  than the `k8s/kustomization.yaml` file. Use a newer commit, or `main`.
- `Deployment:` shows another image than you asked for: ArgoCD has not applied the change yet.
  Run the block again. If it stays, the Application was not created by this chapter's block.
- `pod runs:` shows `none`, or an older digest, for more than three minutes: the new pod cannot
  start. `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" describe pod -l app=golang-web`
  shows why at the bottom, under `Events`. `no basic auth credentials` or `pull access denied`
  means a private Harbor project: do *Create a pull secret* above.
- `Application: OutOfSync/…` that stays: take the first line of the message; `one or more
  objects failed to apply` names the object and the reason after it.
- `pod runs:` shows the name of **another repository** before the `@`: a node that already
  holds the same image under another name reports that name. The block compares only the part
  from `sha256:` on, so this alone does not keep it at `NOT YET`. If everything else is right
  and it still says `NOT YET`, compare by hand: the `sha256:…` after `Deployment:` and the one
  after `pod runs:` must be equal, whatever stands before the `@`.

## Reach the app

With `APP_SERVICE_TYPE="ClusterIP"` the app has no address outside the cluster. This forwards
port 8080 on your machine to it, through the cluster's kubeconfig. Run it in a second terminal
and leave it running; press Ctrl+C to stop it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" port-forward svc/golang-web-service 8080:8080
```

**Expect:** `Forwarding from 127.0.0.1:8080 -> 8080`. **If not:** `address already in use` —
another program uses port 8080; use `8081:8080` here and `localhost:8081` below.

Then, in the first terminal:

```sh
curl -s http://localhost:8080/myhello/
```

**Expect:** `Hello, World` and the pod's details. (`/` alone returns 404; that is expected.)

With `APP_SERVICE_TYPE="LoadBalancer"` the app has its own address instead:
`kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$APP_NAMESPACE" get svc golang-web-service`
shows it under `EXTERNAL-IP`, and the app answers at `http://<that address>:8080/myhello/`.

## Deploy another image

To run a new image, **set the new digest**: push the new image, look up its digest (*Choose the
image*), put it into the env file as `APP_IMAGE`, then run *Create the Application* again and
*Wait for the app and check its image* after it. The first prints `configured`; the second
ends with `OK: every pod runs` and the new digest. The same two blocks apply a new
`APP_SERVICE_TYPE` or `APP_REVISION`.

Do not change the image in the cluster with `kubectl`: with `selfHeal`, ArgoCD puts back what
the Application says.

### Use your own Git repository

The other way to choose the image keeps it in Git: every change is then a commit, with an
author and a history, and ArgoCD applies it within about ten minutes of the push. It needs a
repository you can write to.

1. Fork this repository (or copy its `k8s` folder into a repository of yours; keep the folder's
   name).
2. In your copy, add the image to `k8s/kustomization.yaml`, with your own name and digest:

   ```yaml
   images:
     - name: ghcr.io/andriykalashnykov/golang-web
       newName: harbor.example.test/apps/golang-web
       digest: sha256:<the digest>
   ```

   Commit and push. Later, a new image is a new `digest:` line, committed and pushed.
3. In the env file set `APP_REPO` to your repository's address, `APP_REVISION` to its branch,
   and `APP_IMAGE=""` (the image now comes from Git).
4. Run *Create the project* again (it allows the new repository), then *Create the
   Application*, then *Wait for the app and check its image*.

After a later push, run *Wait for the app and check its image* until `Deployment:` shows the
new digest: ArgoCD Service 1.2.0 looks at Git every five to seven minutes (`timeout.reconciliation` in its
`argocd-cm`), and the change follows a little later.

**A private repository** needs a login for ArgoCD. Create an access token that may only read
that repository, put the user name and the token into the env file as `APP_REPO_USERNAME` and
`APP_REPO_TOKEN` (in single quotes), and run this block. It stores them for ArgoCD as a
*repository* secret in your vSphere Namespace; the token is passed to `kubectl` on its input,
never on a command line. A public repository needs none of this.

```sh
source ~/.vks-golang-web.env
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret vks-golang-web-repo --ignore-not-found -o name)" || EX=unknown
MK="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret vks-golang-web-repo --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}' 2>/dev/null)"
if [ -z "$APP_REPO" ] || [ -z "$APP_REPO_USERNAME" ] || [ -z "$APP_REPO_TOKEN" ]; then
  echo "Not created: APP_REPO, APP_REPO_USERNAME or the repository token is empty in the env file"
elif [ "$EX" = unknown ]; then
  echo "Not created: the Supervisor did not answer (see the error above)"
elif [ -n "$EX" ] && [ "$MK" != argocd-app ]; then
  echo "Not changed: a secret named 'vks-golang-web-repo' exists and this chapter did not create it"
elif jq -n '{apiVersion: "v1", kind: "Secret",
             metadata: {name: "vks-golang-web-repo", labels: {"argocd.argoproj.io/secret-type": "repository", "vks-golang-web/guide": "argocd-app"}},
             stringData: {type: "git", url: env.APP_REPO, username: env.APP_REPO_USERNAME, password: env.APP_REPO_TOKEN}}' \
     | kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" apply -f -; then
  echo "stored for: ${APP_REPO}"
else
  echo "Not created: see the error above"
fi
```

**Expect:** `secret/vks-golang-web-repo created` (`configured` when you run it again), then
`stored for: <your repository>`.

**If not:** `Not created: … is empty …` — set the three values in the env file. If ArgoCD still
reports `authentication required` afterwards, the token may not read that repository, or
`APP_REPO` is not written exactly as in the Application (run *Create the Application* again).

## Delete the app

Run these in order. Each block deletes only what this chapter created, and says so when it
finds something else under the same name.

**Do this before you delete the guest cluster, remove it from ArgoCD's destinations, or delete
the ArgoCD instance.** The Application carries a finalizer: it can be deleted only by an ArgoCD
that runs and still reaches the cluster. Without one of the two it stays in `Terminating` (*If
the Application will not go away* below).

### Delete the Application

This deletes the Application; ArgoCD then deletes the app's Deployment and Service from the
guest cluster. The block waits until the Application is gone (it gives up after five minutes).

```sh
source ~/.vks-golang-web.env
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o name)" || EX=unknown
MK="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}' 2>/dev/null)"
if [ -z "$ARGOCD_APP" ]; then
  echo "Not deleting: ARGOCD_APP is empty"
elif [ "$EX" = unknown ]; then
  echo "Not deleting: the Supervisor did not answer (see the error above)"
elif [ -z "$EX" ]; then
  echo "No Application named '${ARGOCD_APP}': nothing to delete"
elif [ "$MK" != argocd-app ]; then
  echo "Not deleting '${ARGOCD_APP}': this chapter did not create that Application"
elif kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete applications.argoproj.io "$ARGOCD_APP" --wait=false; then
  n=0; LEFT=unknown
  until [ -z "$LEFT" ] || [ "$n" -ge 60 ]; do
    [ "$n" -eq 0 ] || sleep 5
    n=$((n + 1))
    LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o name || echo unknown)"
  done
  echo "left (nothing after the colon means gone): ${LEFT}"
else
  echo "Not deleted: the Supervisor refused (see the error above), so nothing is waited for"
fi
```

**Expect:** `application.argoproj.io "<your app>" deleted`, and within a minute
`left (nothing after the colon means gone):` with nothing after it.

**If not:**
- `Not deleting '…': this chapter did not create that Application`: it lacks this chapter's
  mark (the label `vks-golang-web/guide`). Delete it the way it was made.
- A name, or `unknown`, after the colon: ArgoCD is still deleting the app from the guest
  cluster: run the block again. If the name stays for more than a few minutes, see *If the
  Application will not go away* below.

#### If the Application will not go away

An Application that stays after *Delete the Application* waits for ArgoCD to delete the app
from the guest cluster, and ArgoCD cannot do it. There are two cases:

| case | how to tell |
|---|---|
| the guest cluster was deleted, or is no longer one of ArgoCD's destinations | the block under *Make the guest cluster a destination* shows no `DESTINATION` line, or `NO KUBECONFIG` |
| the ArgoCD instance was deleted | `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd` lists none |

If the cluster still exists, first put back what is missing (add the cluster again; create the
instance again with the ArgoCD guide) and run *Delete the Application* again: ArgoCD then
removes the app properly. If the cluster is gone for good, there is nothing left to remove in
it. This takes the finalizer off, and the Application goes without ArgoCD doing anything; it
refuses an Application this chapter did not create.

```sh
source ~/.vks-golang-web.env
MK="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/guide}{"/"}{.metadata.deletionTimestamp}')" || MK=unknown
case "${ARGOCD_APP:+set}/$MK" in
  /*)                echo "Not changed: ARGOCD_APP is empty" ;;
  set/unknown)       echo "Not changed: the Supervisor did not answer (see the error above)" ;;
  set/)              echo "No Application named '${ARGOCD_APP}': nothing to do" ;;
  set/argocd-app/)   echo "Not changed: '${ARGOCD_APP}' is not being deleted. Run 'Delete the Application' first." ;;
  set/argocd-app/?*) kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" patch applications.argoproj.io "$ARGOCD_APP" --type merge -p '{"metadata":{"finalizers":null}}' ;;
  *)                 echo "Not changed: this chapter did not create the Application '${ARGOCD_APP}'" ;;
esac
```

**Expect:** `application.argoproj.io/<your app> patched`; the Application is gone a moment
later. What the app left in a guest cluster that still exists (its Deployment, its Service, the
namespace) is then yours to delete: *Delete the namespace* below does it.

**If not:** `Not changed: '…' is not being deleted …` — the Application was never deleted: this
block is only for one that hangs after *Delete the Application*.

### Delete the namespace

ArgoCD created the app's namespace and does not delete it. This deletes it, with the pull
secret in it. The block refuses while the Application exists (ArgoCD would create the namespace
again) and refuses a namespace this chapter did not create.

```sh
source ~/.vks-golang-web.env
EX="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io "$ARGOCD_APP" --ignore-not-found -o name)" || EX=unknown
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$APP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || NS=unknown
if [ -z "$ARGOCD_APP" ] || [ -z "$APP_NAMESPACE" ]; then
  echo "Not deleting: ARGOCD_APP or APP_NAMESPACE is empty"
elif [ "$EX" = unknown ] || [ "$NS" = unknown ]; then
  echo "Not deleting: the Supervisor or the guest cluster did not answer (see the error above)"
elif [ -n "$EX" ]; then
  echo "Not deleting: the Application '${ARGOCD_APP}' still exists. Run 'Delete the Application' first."
elif [ -z "$NS" ]; then
  echo "No namespace named '${APP_NAMESPACE}': nothing to delete"
elif [ "$NS" != "${APP_NAMESPACE}/argocd-app" ]; then
  echo "Not deleting '${APP_NAMESPACE}': this chapter did not create that namespace"
else
  kubectl --kubeconfig "$GUEST_KUBECONFIG" delete namespace "$APP_NAMESPACE"
fi
```

**Expect:** `namespace "<your namespace>" deleted` (it can take a minute).

**If not:** `Not deleting '…': this chapter did not create that namespace` — the namespace
lacks this chapter's mark. Nothing was changed.

### Delete the project and the repository login

This deletes the project `vks-apps` and, if you created it, the repository secret. The block
refuses while an Application still uses the project.

```sh
source ~/.vks-golang-web.env
USED="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get applications.argoproj.io -o json | jq -e -r '[.items[] | select(.spec.project == "vks-apps") | .metadata.name] | join(" ")')" || USED=unknown
PM="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get appprojects.argoproj.io vks-apps --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || PM=unknown
SM="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret vks-golang-web-repo --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || SM=unknown
if [ "$USED" = unknown ] || [ "$PM" = unknown ] || [ "$SM" = unknown ]; then
  echo "Not deleting: the Supervisor did not answer (see the error above)"
elif [ -n "$USED" ]; then
  echo "Not deleting: the project 'vks-apps' is still used by: ${USED}"
else
  case "$PM" in
    '') echo "No project named 'vks-apps': nothing to delete" ;;
    vks-apps/argocd-app) kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete appprojects.argoproj.io vks-apps ;;
    *) echo "Not deleting 'vks-apps': this chapter did not create that project" ;;
  esac
  case "$SM" in
    '') echo "No repository login: nothing to delete" ;;
    vks-golang-web-repo/argocd-app) kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete secret vks-golang-web-repo ;;
    *) echo "Not deleting 'vks-golang-web-repo': this chapter did not create that secret" ;;
  esac
fi
```

**Expect:** `appproject.argoproj.io "vks-apps" deleted`, then
`No repository login: nothing to delete` (or `secret "vks-golang-web-repo" deleted`).

**If not:** `Not deleting: the project 'vks-apps' is still used by: …` — delete those
Applications first, or keep the project.

### Remove the guest cluster from ArgoCD's destinations

Only if *Add a guest cluster you created with kubectl* above added it, and no other Application
deploys to that cluster. The block refuses a `ManagedEntity` this chapter did not create. A
cluster the ArgoCD guide added is removed by that guide's clean-up.

```sh
source ~/.vks-golang-web.env
ME="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get managedentity "$VKS_CLUSTER" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/guide}')" || ME=unknown
if [ -z "$VKS_CLUSTER" ]; then
  echo "Not removing: VKS_CLUSTER is empty"
elif [ "$ME" = unknown ]; then
  echo "Not removing: the Supervisor did not answer (see the error above)"
elif [ -z "$ME" ]; then
  echo "No ManagedEntity named '${VKS_CLUSTER}': nothing to remove"
elif [ "$ME" != "${VKS_CLUSTER}/argocd-app" ]; then
  echo "Not removing '${VKS_CLUSTER}': this chapter did not add that cluster"
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" delete managedentity "$VKS_CLUSTER"
fi
```

**Expect:** `managedentity… "<your cluster>" deleted`, or one of the `No …` and `Not removing …`
lines when this chapter did not add the cluster.

The eight settings stay in the env file; they do nothing by themselves.

## Not covered: ArgoCD following Harbor by itself

ArgoCD does not watch a registry. It deploys a new image when the Application, or Git, names a
new digest: that is the update this chapter describes, and it leaves a record of who chose which
image.

A separate program, Argo CD Image Updater, can watch a registry and change the Application for
you. This chapter does not cover it. Its current releases are installed with their own custom
resource definitions, and a Supervisor does not let a namespace user create those
(`kubectl auth can-i create customresourcedefinitions` answers `no` there). Running it in the
guest cluster instead, talking to the Supervisor's ArgoCD from outside, is not covered either.

## Fix common problems

| symptom | fix |
|---|---|
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block. |
| `the server doesn't have a resource type "applications"` | Your vSphere Namespace has no ArgoCD instance, or the ArgoCD Service is not installed: do the ArgoCD guide first. |
| Every block prints `Not created: the guest cluster's kubeconfig is not saved` | `VKS_CLUSTER` is not the cluster's name, or its kubeconfig was never read: *Get the cluster's kubeconfig* in [CLUSTER.md](CLUSTER.md). |
| `Application: Synced/Healthy`, but `pod runs:` shows an older digest | A new pod is still starting. Run *Wait for the app and check its image* again. |
| `Application: Unknown/…` with `repository not accessible` | The Supervisor cannot reach `APP_REPO`. A private repository needs *Use your own Git repository*'s login block. |
| `resource :Namespace is not permitted in project vks-apps` | `APP_NAMESPACE` changed after the project was created. Run *Create the project* again. |
| The app's pod shows `ImagePullBackOff` | With your own image: the Harbor project is private and has no pull secret (*Create a pull secret*), or the digest is not in that project. With the published image: the nodes cannot reach `ghcr.io`. |
| You changed the Deployment with `kubectl` and the change is gone | `selfHeal` put back what the Application says. Change the Application (*Deploy another image*). |
| A destination that worked for months fails with a certificate error | The certificate ArgoCD holds for the cluster has ended: the ArgoCD guide's *How long this login lasts*. |
| You deleted the app's namespace, and it is back | ArgoCD created it again. Delete the Application (*Delete the app*), then the namespace. |
| The Istio chapter's change to the Service, or its mesh option, is gone | `selfHeal` reverted it. Set `APP_SERVICE_TYPE`, or make the change in Git (*Use your own Git repository*). |
| The Application stays in `Terminating` | The guest cluster or the ArgoCD instance was deleted first: *If the Application will not go away*. |
| `STOP: the stored project does not limit the Namespace …` | The ArgoCD is older than 3.4: *Create the project*, *If not*. |
