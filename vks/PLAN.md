# PLAN — `vks/` becomes one end-to-end story

Internal working document, like `vks/HANDOFF.md`: not an end-user guide. It is the plan the
owner asked for on 2026-10-10 and the prioritized backlog for the work. Replace what changes;
git keeps the history. When a phase is done its row moves to "Done" with the commit, and the
measured facts go to `vks/HANDOFF.md`.

## What the owner asked for

`vks/README.md` is the centre of one story: **deploy this app onto VCF/VKS end to end, using
what exists or creating what is missing.** The reader is a customer who copies, pastes and
adapts on their own environment while the owner watches on a shared screen.

1. Every piece has a **manual** form (copy, paste, adapt; a template filled from the reader's
   env file; a web UI only where nothing else exists) and, where it applies, an **automated**
   form (no screenshots, no web UI).
2. New chapters: **use or create a vSphere Namespace**; **use or create a guest cluster**
   (without ArgoCD, like the ArgoCD guide's step 7 does with it); **install Harbor** (manual
   and auto, like the ArgoCD pair); **add-ons** in a subfolder, Headlamp first; **Istio** as an
   option.
3. Three ways to deploy the app: the **published image and manifests** from ghcr; a **local
   build pushed to Harbor** with the manifests re-pointed; an **ArgoCD Application**.
4. The main guide reads fluently with clean optional branches; big chapters become smaller
   linked documents, in a **logical order**.
5. Everything configurable and productized; walked on **Ubuntu and macOS** against the lab.
6. Check the ArgoCD guest-cluster Application: where an end user hosts the Helm chart; and
   helm as a stated, checked, tested prerequisite.

## What research established (2026-10-10)

Three reports: the map of this repo's guides; what `nested-vsphere-lab` and `vks-airgap-cicd`
already do on this lab; the vendor documentation. Grades: MEASURED on the lab (by those repos
or today), READ in a source, INFERRED.

| Topic | Finding | Grade |
|---|---|---|
| Today's guide | Assumes Supervisor, namespace, guest cluster, Harbor, a Harbor project and CA trust all exist ("your administrator gave you"). 1,224 lines; tools and clean-up are 41% | MEASURED |
| Order | The ArgoCD guides "continue from step 7", and step 7 needs the cluster they create: circular | READ |
| Namespace by YAML | No declarative vSphere Namespace object on a plain Supervisor. `kubectl create namespace` (or a 3-line `Namespace`) works ONLY when an admin enabled Namespace Self-Service; the vendor marks self-service without CCI **deprecated**. This lab has it ON (`kubectl auth can-i create namespaces`: yes) | MEASURED + 9.0-doc |
| Namespace by API | `POST /api/vcenter/namespaces/instances` with the cluster MoRef, a storage policy ID and VM class names: 204, `RUNNING`, visible to kubectl in 2 s — on a VDS + Foundation Load Balancer Supervisor ONLY. On NSX VPC the vendor uses `createv2` with a network spec (9.1-doc). Open to a VI or Tenant administrator; the exact privilege is not verified | MEASURED (lab) + 9.1-doc |
| Guest cluster | One `cluster.x-k8s.io/v1beta2` `Cluster` (`classRef` `builtin-generic-v3.7.0` in `vmware-system-vks-public`), applied with kubectl; ready in 4–9 min. `defaultStorageClass` is required or the cluster is silently unusable. A reused name never converges | MEASURED |
| Harbor | Supervisor Service from Broadcom's portal files (`-legacy` service YAML + data-values). Manual: upload in the vSphere Client. Automated: vCenter REST (`carvel_spec`, wait for the signature, install with base64 values). ~7.5 min. Contour is NOT required (`enableNginxLoadBalancer`). kubectl cannot install a Supervisor Service | MEASURED |
| Harbor trust | A guest cluster under the same Supervisor trusts that Harbor's CA automatically (no `additionalTrustedCAs`). The CA cannot be read off the TLS handshake | MEASURED by vks-airgap-cicd; re-check in the walk |
| Headlamp | Plain `helm install` is REJECTED on VKS (pod security `restricted`), and the chart binds cluster-admin. Working settings exist (chart 0.45.0, `view` role, token login). It is also in the VKS add-on catalogue (never installed that way). Desktop Headlamp needs only a kubeconfig | MEASURED / READ |
| Istio | A VKS add-on: an `AddonInstall` on the Supervisor in the cluster's namespace (or `vcf addon install create`); the controller creates the config, and a hand-made `AddonConfig` applies nothing (re-measure on 3.7.1). istiod + CNI; NO ingress gateway by default. Vendor recommends Gateway API: a `Gateway` (class `istio`) provisions its own LoadBalancer; the app needs a ClusterIP Service + `HTTPRoute` | MEASURED / 9.0-doc |
| Helm | ArgoCD renders a chart from a git path itself: NO helm client needed for the guest-cluster Application. A client is needed only for Headlamp-by-chart (and `helm push`). No guide mentions any of this today | upstream-doc |
| Chart hosting | A reader who copies `vks/argocd/guest-cluster` must change `repoURL`, `targetRevision`, `path` AND the AppProject's `sourceRepos`; a private repo needs a repository credential. The guides cover the first two loosely | READ |
| "ArgoCD monitors Harbor" | Not native. Image Updater's CRD-based releases cannot be installed on the Supervisor (`can-i create customresourcedefinitions`: no). Its 0.x releases can run in another cluster against the ArgoCD API: untested here. Default form: set the new digest (in the Application or in git) | upstream-doc + MEASURED |
| Kustomize | `spec.source.kustomize.images` needs a `kustomization.yaml` in the path. On this app's image (tag AND digest): name alone keeps the ghcr digest, name + tag drops the digest, name + digest is right | upstream-doc + MEASURED |
| Doc checks | No automated gate reads `vks/*.md`; the walk harness is not in the repo | MEASURED |

## Decisions (made by the session; the owner may overrule any)

The plan was attacked by an adversary on 2026-10-10 (verdict: sound with changes). Ten changes
came out of it; they are folded in below and marked ⚑.

D1. **Namespace chapter has four doors** ⚑, in this order: (a) you have one: a check block
    proves it can carry a cluster (`get ns`, VM classes, storage classes, releases, cluster
    classes); (b) **ask your administrator**, with a paste-able request (name, storage policy,
    VM classes, the Edit or Owner role for your user, limits) — the reader is usually an Edit
    user without vCenter rights; (c) create it with the **vCenter API** from a JSON spec filled
    from the env file after read-only lookups (cluster, storage policy, VM classes), WITH the
    reader's own user in `access_list`, and with a first block that reads the Supervisor's
    network provider: the spec is MEASURED on a VDS + Foundation Load Balancer Supervisor
    only; on NSX VPC the vendor uses the v2 call with a network spec, and the guide says so
    and stops; (d) collapsed: `kubectl apply` of a `Namespace` when self-service is on, with
    the check that says whether it is and the vendor's deprecation stated. The vSphere Client
    path is a collapsed click list (screenshots when the owner has logged in).
    **Overruled by the owner on 2026-10-10:** see D12.
D2. **Guest cluster chapter** uses ONE template, `vks/templates/cluster.yaml`, rendered with
    `envsubst` ⚑ given an explicit variable list after a guard that every variable is
    non-empty (`envsubst` joins the tools step per OS: it is installed nowhere today, and an
    unset variable renders empty without error). Parameters: name, release (looked up, written
    without `-vkr.N`), cluster class (looked up, not a default), control-plane and worker VM
    classes and counts, storage class, pod and service CIDRs with "must not overlap your
    networks". A sizing branch "if you will add Istio" ⚑. `--dry-run=server`, apply, wait on
    `Available`, then the `<cluster>-kubeconfig` Secret (kept, per `vks/HANDOFF.md`). The
    ArgoCD route renders the same object: CI compares `helm template` of the chart with the
    rendered template AND fails when the pinned chart commit in the guides lags the chart ⚑.
D3. **Harbor**: `HARBOR.md` leads with "use the one you have"; installing needs the **Manage
    Supervisor Services** privilege and Broadcom entitlement, with the same "ask your
    administrator" fallback ⚑. `HARBOR-manual.md` (vSphere Client) and `HARBOR-auto.md`
    (vCenter REST). Both carry ⚑: the seven secrets generated once into a 0600 file the reader
    keeps (resent on every upgrade; a changed `secretKey` cannot be repaired), the storage
    class fields, the registry volume size, **DNS** (an A record to Harbor's address, checked
    from the workstation and by a pull from a guest node), uninstall deletes the data, no
    upgrade chapter. Same-Supervisor CA trust is checked in the walk; a Harbor with another CA
    gets the `additionalTrustedCAs` pointer.
D4. **Add-ons** in `vks/addons/`. **Headlamp** ⚑: Desktop with the guest kubeconfig is the
    first door (nothing installed on the cluster); the chart with restricted settings and a
    view-only role is the in-cluster door (helm client here); the VKS add-on form ships only
    if a lab install proves it. **Istio** ⚑: apply the `AddonInstall`, wait for the
    `ClusterAddon`, then PATCH the controller's own `<cluster>-istio` config (a hand-made
    `AddonConfig` was measured as a silent no-op), verify from the guest; a check for the
    Gateway API CRDs and an Accepted `GatewayClass istio`; the `Gateway` in its own namespace
    labelled `baseline`, proven with `--dry-run=server`; a ClusterIP Service + `HTTPRoute`.
D5. **Deploy has three doors.** A. published image: by default with a ClusterIP Service and a
    port-forward ⚑, because the pinned 0.0.4 image serves `/shutdown` to anyone; the
    LoadBalancer form is a stated choice with that warning (it goes away with the next
    release: owner's call). B. build, push to Harbor, deploy by digest. C. ArgoCD Application
    on `k8s/` through a `kustomization.yaml`: the image override is **name + digest** ⚑
    (MEASURED with kustomize: name alone keeps the ghcr digest; name + tag drops the digest
    and brings back the stale-tag failure), stored in the Application by default so no fork is
    needed, with "your own fork and a commit" as the GitOps variant; a SECOND AppProject for
    the guest-cluster destination (today's project allows only `Cluster` objects); who creates
    the namespace and the pull secret is stated. No tag or digest literal goes into
    `kustomization.yaml` (Renovate does not track it).
D6. **Add-ons change other chapters only through stated branches** (as before).
D7. **`vks/README.md` keeps the spine** ⚑ (about 500 lines, one file a shared screen can
    follow): setup → Supervisor login → namespace check → cluster check or create → deploy
    door A → reach → clean up. Only real branches become their own files: `NAMESPACE.md`,
    `CLUSTER.md`, the Harbor trio, `REGISTRY.md` (door B), the ArgoCD files, `addons/`,
    `CLEANUP.md`, `TROUBLESHOOTING.md`, `SETUP.md` (the per-OS tool installs).
D8. **One env-file contract** ⚑ with a migration: the file is written with `set -C` and never
    overwritten, so each chapter opens with an idempotent "add what is missing" block
    (`grep -qs … || printf … >>`); a one-time block imports `~/.vks-argocd.env` and tells the
    reader to delete it. ONE name for the cluster (`VKS_CLUSTER`) whichever door creates it.
    Every block that runs before a cluster exists names `--kubeconfig "$SUPERVISOR_KUBECONFIG"`.
D9. **The gate and the walk harness land first**, against today's files ⚑. The gate checks:
    every `sh` block parses in bash and zsh; no comment on a command line; nothing after a
    line that can prompt; shellcheck on extracted blocks; a block that uses a variable sources
    the env file, and every variable is in the contract; every block has an **Expect**;
    relative links and anchors resolve; no step-number reference crosses files; `<details>`
    balance; templates render with zero empty substitutions from the example env; no secret
    on a command line; chart = template. It prints "checked N blocks in M files" and its RED
    is proven by a planted bad block.
D10. **Helm**: the ArgoCD guides say no helm client is needed there and name what a reader
    changes when they host the chart (repo, revision, path, project sources, the repository
    credential). Helm becomes an OPTIONAL tool in `SETUP.md`, installed and checked per OS,
    needed only for Headlamp by chart.
D11. **"ArgoCD monitoring Harbor"** ⚑: the default update is "set the new digest" (in the
    Application, or a commit in the reader's fork). Argo CD Image Updater is MEASURED on the
    lab in phase 9 (run in the guest cluster against the ArgoCD API); it ships as an optional
    chapter only if it works there, otherwise the guide says why not.

D12. **Four areas, one shape** (owner, 2026-10-10; it replaces D1's four doors and the
    request letters). The reader is taken to be a vCenter administrator, or to sit beside one.
    Namespace, guest cluster, Harbor and ArgoCD each have a chooser page titled "Use or
    create/install X" (`X.md`): one sentence on the rights each path needs, three choices (use
    what you have, with a check block; by hand; with scripts), and ONE collapsed "If you are
    not a vCenter administrator" with three lines. `X-manual.md` is the vSphere Client with a
    screenshot per window, and shows where the client keeps each value; `X-auto.md` is command
    blocks only, and prints each value. No request letter is a section anywhere. `ARGOCD.md`
    lists what ArgoCD is for, in order: install, create a guest cluster, deploy the app; the
    vSphere Namespace is created first and not by ArgoCD.

## Document map (target)

```
vks/README.md                 the spine: setup, login, namespace check, cluster, deploy door A, reach, clean up
vks/SETUP.md                  per-OS tool installs (container engine, kubectl, VCF CLI, envsubst, optional helm)
vks/NAMESPACE.md, NAMESPACE-manual.md, NAMESPACE-auto.md   chooser + check; vSphere Client; vCenter API and self-service
vks/CLUSTER.md, CLUSTER-manual.md, CLUSTER-auto.md         chooser + kubeconfig and check; vSphere Client; kubectl and the template
vks/HARBOR.md, HARBOR-manual.md, HARBOR-auto.md            chooser + check; vSphere Client; vCenter API
vks/REGISTRY.md               door B: trust the CA, project, robot, build, push  <- today's steps 3, 5, 6
vks/ARGOCD.md, ARGOCD-manual.md, ARGOCD-auto.md            chooser + check + what ArgoCD is for; by hand; with scripts
vks/ARGOCD-app.md             door C                                             new
vks/addons/README.md, HEADLAMP.md, ISTIO.md                                      new
vks/CLEANUP.md, vks/TROUBLESHOOTING.md                                           <- step 10, "Fix common problems"
vks/templates/                namespace-spec.json, cluster.yaml, istio-addoninstall.yaml, gateway.yaml, headlamp-values.yaml
k8s/kustomization.yaml, k8s/overlays/{clusterip,istio}/
vks/test/                     the walk harness; .github/scripts/check-vks-docs.sh is the gate
```

## Phases — prioritized

Each phase: idea review where it embeds a design decision → build → one diff review → the
gate → walk → merge. Builds run in parallel; walks share ONE lab and run one after another (a
golden restore takes about 3 minutes and destroys what another walk is using, so it is
scheduled). **Ubuntu: every phase is walked in full. macOS** ⚑: per phase, the blocks parse in
zsh and bash 3.2 and every workstation-only block and everything the two fixed tunnels reach
(vCenter, Supervisor) is run; the parts that need an install-time address (guest API, app,
gateway, a new Harbor) get ONE full Mac walk in the last phase, when the owner opens those
tunnels.

| # | Phase | Done when |
|---|---|---|
| 0 | This plan, attacked and stored | merged |
| 1 | Gate + walk harness against today's files | gate green in CI, RED proven, denominator printed; one Ubuntu walk through the harness |
| 2 | Step-number references → section-title links, in place ⚑ (156 of them; a split would break them and no link checker sees them) | gate green; one Ubuntu walk |
| 3 | Env contract + migration; the split (block-CONTENT hash before = after); spine README; ArgoCD guides re-pointed and the circular order removed | hash equal; gate green; Ubuntu walk of the spine on a lab that has a cluster |
| 4 | `NAMESPACE.md` + `templates/namespace-spec.json` | on the bare lab: check, create by API, create by kubectl, delete; Ubuntu and macOS in full (fixed tunnels reach it) |
| 5 | `CLUSTER.md` + template + `envsubst` + chart-equality and pin check | a cluster from the template in a phase-4 namespace reaches `Available`, nodes Ready |
| 6 | `k8s/kustomization.yaml`, overlays; deploy door A; reach; clean up | door A serves `/myhello/` on the phase-5 cluster |
| 7 | Harbor chooser, `REGISTRY.md` + door B; `HARBOR-auto.md`; then `HARBOR-manual.md` | Harbor installed on the bare lab by the auto guide, DNS and CA checked, a guest node pulls from it; door B serves |
| 8 | `ARGOCD-app.md` (door C) + chart-hosting section + second AppProject | the Application deploys from ghcr and from Harbor by digest; an Application from a COPY of the chart in another repo syncs |
| 9 | Add-ons: Headlamp (Desktop, chart), Istio (install, gateway namespace, route); the Image Updater measurement | Headlamp serves view-only under `restricted`; the app answers through the gateway; the main flow is unchanged without add-ons |
| 10 | Full walk from a BARE lab on Ubuntu and on the Mac, every door; tested-platforms record; final adversary over the whole | one clean pass per OS |

## Phase state

Phases 0 and 1 are not tracked here. For phases 4 and 5 the chapters, the two templates and
`check-vks-templates.sh` are on the branch `docs/vks-namespace-cluster`. For phase 7 the three
Harbor chapters are on the branch `docs/vks-harbor`. Phases 2, 3 and 6 (the main guide's part)
were built together on 2026-10-10 and are recorded under the table: text only, **no lab walk**.

| # | Walked on the lab (VCF 9.1.1, VKS 3.7.2; Linux, bash and zsh) | Not walked |
|---|---|---|
| 4 | The check blocks; the namespace by the vCenter API (settings, session, network type, the two lists, fill, create, the stops); the namespace by self-service (`kubectl create namespace`). After the vCenter helpers moved into the main guide's step 1: the step 1 block, the namespace settings block, the open-session block and `vc_logout` | macOS and bash 3.2; the vSphere Client click list (not clicked); a Supervisor on NSX; an SSO user with only the Edit role (the first two NAMESPACE blocks are that reader's whole path, and they have never run as such a user) |
| 5 | Lookups, fill, server dry run, create, the wait, the machines, the cluster check, delete. After the helper move: the cluster settings block, the machines block under *Install Harbor before you create clusters*, and the kubeconfig block twice with a kubectl within one minor version (no change) | macOS and bash 3.2; `kubectl_install`'s install branches on a real machine (`KUBECTL_DIR`, `sudo -n`, the `~/.local/bin` fallback, the three failure messages: run only against stand-in `curl`, `sudo` and `kubectl` programs); the two re-used-name stops on a lab |
| 7 | Harbor Supervisor Service 2.15.2+vmware.1-vks.1. `HARBOR-auto.md`, one block per fresh login shell: the download check, the secrets file (7 values), the storage class list, the configuration file, the vCenter session, the manifest check, register (201, `ACTIVATED`, signature `TRUSTED`), install (201 on attempt 1, `CONFIGURED`), the address and `http=200`, the DNS check with both verdicts, the CA fingerprint, the three main-guide parts, the admin login, the project (201), the pull check from a guest cluster (`OK`), uninstall (204), remove the service (three 204). `HARBOR-manual.md`: every click and window in the vSphere Client; its ten screenshots are from that run. Seen in the walk: installing AND uninstalling Harbor replaces every node of every guest cluster on the Supervisor; a second install has a new address and a new CA. Run on the lab after the first review, in bash and zsh: the settings block (`settings: 6 of 6`, `admin password line: 1 of 1`), the secrets file's count line (one `awk`), the pull check's guard for a missing kubeconfig | macOS; a user without the Manage Supervisor Services privilege; a Supervisor on NSX; Contour in place of the nginx load balancer; a second install with other data values. NOT run anywhere: the two clipboard install lines of the manual guide (`sudo apt-get install -y wl-clipboard`, `sudo dnf install -y wl-clipboard`), the `xclip` form, and the block that empties the clipboard (`pbcopy`, `wl-copy --clear`, `xclip`): the walk met the clipboard block's `No clipboard program here` line on a Wayland desktop with neither program, and the paste was done from an editor |
| 8 | `ARGOCD-app.md` on ArgoCD Service 1.2.0 (Argo CD 3.4.4), each block as written: the settings (`8`); the destination list before and after the add; *Add a guest cluster you created with kubectl* (`ManagedEntity: Ready`, `destinations at …: 1`; the stored address equals the kubeconfig's); *Create the project*; *Create the Application* refused while the directly deployed app's namespace existed, then `created` (with kubectl's finalizer-name warning); the wait with `APP_IMAGE` empty (`Synced/Healthy`, the ghcr digest in the Deployment and in the pod, `OK`); port-forward and `curl` (`Hello, World`). Then with a two-architecture image pushed to Harbor: the digest lookup, the public/private check (`http=401`), the Application `configured`, the pull secret block (secret, service account, two pods deleted), and the wait: asked-for, Deployment and pod all showed the same index digest, `OK`. `CreateNamespace=true` worked through the cluster the service added, with the `Namespace` limited by name in the project | The four delete blocks and *If the Application will not go away*; the own-fork variant with the repository login; the pin block with a branch, a tag and a commit against a private repository; everything changed after the walk (list below); an Application from a COPY of the chart in another repository (phase 8's third "done when"); a `LoadBalancer` Service through the Application; an ArgoCD older than 3.4; a user with only the Edit role; macOS |

Changed after those walks, and run only against stand-in `curl`, `kubectl` and `sleep` programs,
in bash and zsh (not on a lab):

- the namespace's `description` marker in `templates/namespace-spec.json`, and the delete by the
  vCenter API that refuses a namespace without it. That vCenter stores `description` and
  returns it on a read is not measured;
- the `kubectl delete namespace` block refusing a namespace without the self-service annotation;
- the create and delete calls gating their waits on the answer (namespace create and delete,
  cluster delete), with the vCenter session closed on every path;
- the cluster create block refusing a cluster it did not create (no
  `kubectl.kubernetes.io/last-applied-configuration` annotation) or one with ArgoCD's mark, and
  the cluster delete refusing one with ArgoCD's mark. A cluster somebody else made with
  `kubectl apply` carries the same annotation and is NOT refused;
- the two re-used-name stops: both fired against a stand-in `kubectl` (a
  `VirtualMachineService` of the name before the dry run; a cluster address that differs from
  its load balancer's during the wait). Neither has fired on a lab;
- both kubeconfig blocks keeping an earlier kubeconfig when the read fails; `vc_login` replacing
  an older session file and checking the new one's content; the main guide's clean-up block.

Run on the lab after that round, in bash and zsh: a namespace created with the marker (vCenter
stores `description` and returns it on a read: measured); the API delete refusing a namespace
without the marker and one that still holds a cluster, and deleting the marked one (HTTP 204,
then 404); the `kubectl` delete of a self-service namespace; the cluster create block run again
on its own cluster; the kubeconfig block. Still only against stand-ins: the refused-call paths
(403), the cluster delete, the re-used-name stops, the main guide's clean-up block.

Not done from phase 5's "done when": the check that the chart commit pinned in the ArgoCD guides
is not older than the chart. `check-vks-templates.sh` (chart = template, and the namespace
marker in step with NAMESPACE.md) runs in `make static-check`, and so in CI, where it fails if
`helm` or `yq` is missing.

`SETUP.md` now has the optional tools, and the clipboard tool the manual Harbor chapter wants on
Linux (`wl-clipboard` on Wayland, `xclip` on X11) is there as well as in the two lines inside
that chapter's install step. **Open:** those lines, and the clipboard path on Linux
as a whole (copy with `wl-copy`, paste into the vSphere Client, empty it), have not been run.

Phase 7, changed after those runs (second review) and run ONLY against stand-in `curl`,
`kubectl`, `sleep` and `wl-copy` programs, in bash and zsh, not on a lab:

- the record `~/.config/vks-golang-web/harbor-none-before`: step 1's check block writes it when
  the Supervisor has no Harbor (vCenter's name and the Supervisor's endpoint), never when one
  exists, and never twice; the install block adds the Supervisor's ID when vCenter accepts the
  install; the uninstall block refuses without that ID and takes it out again when Harbor is
  gone; the remove-service block refuses without the record; the delete-files block removes it.
  A Harbor installed with the earlier copy of the chapters has no record and is refused: it is
  uninstalled in the vSphere Client. The manual chapter cannot record an install, so its check
  block proves only what step 1 saw;
- the uninstall and remove-service blocks gating their waits and their next call on vCenter's
  answer, the login-failed message, and the refusal while Harbor is installed on another
  Supervisor. That the service list's `state` reads `ACTIVATED` before and something else after a
  deactivation, that a deleted version answers 404, and that a Supervisor without Harbor answers
  404 on the per-Supervisor read are the stand-in's assumptions: only the 404 after an uninstall
  was seen on the lab (the old block waited for it);
- the install block: another version already installed is detected and not waited for; its two
  temporary files are made beside the configuration file under `umask 077` and removed on every
  path (a SIGINT to the block's process group was sent in the test; an interactive Ctrl+C in a
  terminal was not);
- the configuration-file block refusing an empty or example `HARBOR_FQDN` and a data values file
  whose SHA-256 is not step 2's. The accepting path ran only on a copy of the block with the
  expected checksum replaced by a stand-in file's, because Broadcom's file is not in the repo;
- the delete-files block refusing while a Harbor namespace exists; `--kubeconfig
  "$GUEST_KUBECONFIG"` on the pull check; `wl-copy --type text/plain`.

**Open for phase 7:** every REST body and answer shape in `HARBOR-auto.md` rests on ONE lab walk
(VCF 9.1.1). The **Delete Harbor** window was captured only while Harbor was still installed:
what it shows after an uninstall (an empty list under section 2, and what section 3 offers) is
described from the walk's clicks, not from a picture. A Supervisor on NSX was not run.

From phase 7's "done when": `REGISTRY.md` (door B) is written from the old main guide's
registry, build and deploy blocks (see phases 2, 3 and 6 above); door B has not been walked
against a Harbor installed by these chapters.

### The four areas in one shape (D12) — built 2026-10-10, not walked

A move plus new text. Of the 253 `sh` blocks before, all 253 are byte-identical after (SHA-256
of each block's content): 226 in the same file, 27 in another (13 from `NAMESPACE.md` to
`NAMESPACE-auto.md`, 14 from `CLUSTER.md` to `CLUSTER-auto.md`). The two namespace check blocks
stayed in `NAMESPACE.md`; the kubeconfig block, the cluster check and the machines block under
*Install Harbor before you create clusters* stayed in `CLUSTER.md`, so the links to those
anchors hold. The walks recorded for phases 4 and 5 stand for those blocks as blocks.

| new | what | walked |
|---|---|---|
| `NAMESPACE-manual.md` | every click, and 13 image lines under `img/namespace/` | steps 1 to 7 and step 9 (remove) clicked by the owner in the lab's client (9.1.1) on 2026-10-10 and the text corrected to it; screenshots 01 to 13 are from that walk; the two check blocks then passed for the namespace made by hand (both VM classes, `wcp-vmfs` and `wcp-vmfs-latebinding`, 13 releases, 7 cluster classes). NOT seen: the content of `download.zip` in step 1, which carries an HTML comment `unverified` |
| `CLUSTER-manual.md` | 12 image lines under `img/cluster/` (01, 03, 05 to 14; there is no 02 and no 04) | clicked by the owner in the lab's client (9.1.1) on 2026-10-10, start to delete: the **Resources** cards, the five steps of the create page, FINISH, the row `Not Available`, **Available** after about five and a half minutes (1 control-plane node, 1 worker: the page's defaults; `defaultStorageClass: wcp-vmfs` in the spec, so the field works but is EMPTY unless chosen), the row's menu, the delete window. Not clicked, marked `unverified`: a node pool row's ⋮ menu, and **Download Kubeconfig File** (what it saves). The **Network** section was not opened |
| `CLUSTER.md`, *Use the cluster you have* | one block: lists the namespace's guest clusters | no |
| `NAMESPACE-manual.md`, step 9 | the same block, before a delete by hand | no |
| `CLUSTER-manual.md`, step 8 | one block: are the cluster and its address gone | no |
| `ARGOCD.md`, *Use the ArgoCD you have* | one block: service installed, instance in the namespace, first admin password present | no |
| `HARBOR.md`, *Use the Harbor you have* | one block: Harbor namespace on the Supervisor; `curl -sk` to `/api/v2.0/ping` | no |

The gate fails with one `the image file does not exist` line per picture that is not in the
tree yet (13 for the namespace guide, 12 for the cluster guide). With stand-in files it ends at
0 errors.
**Open:** whether an Edit user without vCenter rights can open the namespace in the vSphere Client; the
echo text `CLUSTER.md, Install envsubst` in five blocks (kept byte for byte; `CLUSTER.md` links
the section, which is in `CLUSTER-auto.md` and `SETUP.md`).

### Phases 2, 3 and 6 — built 2026-10-10, not walked

**Phase 2.** `README.md` had 76 references by step number on 68 lines; `README.md`, `SETUP.md`,
`REGISTRY.md`, `CLEANUP.md` and `TROUBLESHOOTING.md` now have none: each is a link to the
section by its title. The references INTO the main guide from the ArgoCD chapters (16, one of
them inside a block's `echo` text) are links by title too, and the Harbor, namespace and cluster
chapters' links follow the sections that moved. What is left by number is each ArgoCD and Harbor
guide naming its OWN steps (`ARGOCD-auto.md` 34 lines, `ARGOCD-manual.md` 41, `ARGOCD.md` 1,
`HARBOR-auto.md` 54, `HARBOR-manual.md` 51): those guides keep numbered steps. The gate has no
step-reference check; the counts are from `grep -cE '[Ss]teps? [0-9]+'`.

**Phase 3.** The split is a move. Of the 55 blocks of the old `README.md`, 53 are byte-identical
in their new place (SHA-256 of each block's content, extracted with `walk.sh`, before against
after): 18 in `README.md`, 14 in `SETUP.md`, 13 in `REGISTRY.md`, 8 in `CLEANUP.md` (two of
them are in two files: see below). So the walks in `vks/HANDOFF.md` stand for those blocks as blocks.
They do **not** stand for the new ORDER: the Supervisor login, the namespace check and the
kubeconfig now come before anything about Harbor, and nobody has run the files in that order.

| changed or new | what | walked |
|---|---|---|
| `README.md`, the first block (the two heredocs) | comment and message text only: three comments and `harbor_cfg`'s message named step numbers | no |
| `REGISTRY.md`, *Deploy the image you pushed* | the `NOT FOUND` message named two step numbers; now two section titles | no |
| `ARGOCD-auto.md`, step 1's check block | one `echo` text: `(main guide, step 2)` is now the section's title | no |
| `README.md`, the check block under *Install the tools* | NEW: the old *Check the tools* block without `make` and without the container engine (that block is in `SETUP.md`, unchanged) | no |
| `SETUP.md`, *Install helm* (three blocks) | NEW. The Linux line ran once on a Linux amd64 host with `USE_SUDO=false` and a scratch `HELM_INSTALL_DIR` (Helm v4.3.0, checksum verified); the `sudo` path, `brew install helm` and `helm version --short` as printed did not run | no |
| `SETUP.md`, *Install envsubst* and *Install a clipboard program* | copies of the blocks in `CLUSTER.md` and `HARBOR-manual.md`, byte-identical; walked or not as recorded for those chapters | as there |
| `README.md` and `REGISTRY.md` both hold *Create the app's namespace* and the pod check | two old blocks, each in two places, byte-identical | as before |

The env contract (D8): the main guide's first block is still the one definition; `SETUP.md`,
`REGISTRY.md` and `CLEANUP.md` add no setting. **Not done from phase 3:** the one-time block
that imports `~/.vks-argocd.env`, and the ArgoCD guides' own order (both belong to the ArgoCD
chapters). `README.md` is 744 lines, not 500: its first block alone is 163, and D8 keeps it
there.

**Phase 6 (door A).** `README.md`, *Deploy the published image*: NEW block, the published image
with the Service written as `ClusterIP` by `sed` on the way to `kubectl apply`, then the
Service's type printed; NEW collapsed alternative that applies the file as it is
(`LoadBalancer`), with the `/shutdown` warning. Checked on a workstation only: the `sed` changes
exactly one line of `k8s/golang-web.yaml`, and the `jsonpath` prints `service type: ClusterIP`
(`kubectl patch --local`). **Not run on a lab:** both blocks, the change from one Service type
to the other and back on a live Service, a pull of the ghcr image by a guest node, and the reach
blocks after a `ClusterIP` deploy (the port-forward blocks themselves are old and unchanged).
Not built: `k8s/overlays/`; door A does not use `k8s/kustomization.yaml`.

Phase 8, run offline only (no lab), in bash and zsh:

- `kustomize build k8s` and `kubectl kustomize k8s` give the same two objects as
  `k8s/golang-web.yaml` (kustomize 5.8.2, and the 5.8.1 inside kubectl 1.37.1). The three image
  overrides were measured again and D5 holds: name alone keeps the ghcr tag and digest under the
  new name, name + tag drops the digest, name + digest gives `<name>@sha256:…`;
- the `Application` and `AppProject` the blocks send were captured from a stand-in `kubectl` and
  checked against the CRD schemas of upstream ArgoCD v3.4.4 with unknown fields refused (a
  misspelt field fails). The VCF build's own CRDs were not read. The `ManagedEntity` has no
  schema offline: it is the ArgoCD guides' object plus one label;
- the same `Application` was rendered the way ArgoCD's repo-server does it (`kustomize edit set
  image`, the patch appended to `kustomization.yaml`, `kustomize build`): the Harbor digest and
  `type: ClusterIP` come out, and the result is valid for Kubernetes 1.36;
- every refusal and the digest check, against stand-in `kubectl`, `curl` and `sleep` programs:
  an empty name, an object without this chapter's label (Application, project, namespace, pull
  secret, repository secret, `ManagedEntity`), a Supervisor or guest cluster that does not
  answer, a refused call (nothing is waited for), `Synced/Healthy` with the old image in the
  Deployment or in a pod (not accepted), and no token on any command line.

Phase 8, changed AFTER the lab walk and run only against stand-in `kubectl`, `curl`, `git` and
`sleep` programs, in bash 5.3, zsh 5.9 and bash 3.2 (171 checks each; six planted defects made 18
of them fail), not on a lab:

- the pin block asks for `APP_REVISION` (it asked for `main` whatever was set) with
  `GIT_TERMINAL_PROMPT=0`. Against GitHub, from a workstation: a branch prints one
  `refs/heads/…` line, a commit prints nothing, a repository that does not exist or is private
  answers with an error and no prompt;
- *Create the project* reads `clusterResourceWhitelist[0].name` back and prints `STOP: …` when
  it is not `APP_NAMESPACE`; *Create the Application* refuses a project that is missing or does
  not hold that name. That an ArgoCD older than 3.4 drops the field (and does not refuse the
  object) is NOT measured: the lab has 3.4.4, where the field is kept;
- a guest cluster named like the vSphere Namespace is refused by the add block;
- the pull secret block deletes no pod when the service account patch failed;
- the new block under *If the Application will not go away* (it takes the finalizer off only
  from an Application of this chapter that is already being deleted);
- the removal order: `CLEANUP.md`'s table, one sentence at the top of step 9 of both ArgoCD
  guides, and the chapter's own warning.

What phase 8 takes from a source and has NOT measured: that ArgoCD leaves the namespace behind
when the Application is deleted, and that an Application whose cluster or ArgoCD instance is gone
stays until its finalizer is taken off (both read in upstream's documentation); that the ArgoCD
Service's instance reads a repository secret `kubectl` creates in its vSphere Namespace; that an
Edit user may create that secret, the project and the `ManagedEntity`; what
`kubectl get argocd -o jsonpath='{.spec.version}'` prints for an instance (the chapter gives it
as the way to read the version). The project needing the `Namespace` for `CreateNamespace=true`
was read in v3.4.4's `sync_context.go` and `controller/sync.go`; the walk only shows that it
works WITH the entry.

**Open (D11), for phase 9:** Argo CD Image Updater is not measured. What is known is unchanged:
its CRD-based releases cannot be installed on the Supervisor
(`kubectl auth can-i create customresourcedefinitions`: no, measured on the lab), and running it
in the guest cluster against the Supervisor's ArgoCD API has not been tried. `ARGOCD-app.md`
therefore says "not covered" and claims nothing about it; the update it describes is "set the
new digest".

### Phase 9 (add-ons): three chapters; installs and checks walked, removals and options not

`vks/addons/README.md`, `CERT-MANAGER.md`, `ISTIO.md` and `HEADLAMP.md`, with three files under
`vks/addons/templates/` (`addoninstall.yaml`, shared by the three add-ons; `istio-gateway.yaml`;
`headlamp-values.yaml`, for the helm chart). The document map above names `vks/templates/` for
them, which is not where they are. Owner, 2026-10-10: add-ons are first class; every chapter
leads with the VKS add-on and gives other ways after it.

Walked on the lab (2026-10-10; VCF 9.1.1, VKS 3.7.2, guest v1.36.2; Linux, bash and zsh), every
block as written:

- `ISTIO.md`, end to end, in its first-round text: release list; install (taken up in 10 s);
  size patch (worked in after 5 s); Ready after 45 s; `istiod` 1 of 1 at 1Gi, `istio-cni-node`
  3 of 3, 3 webhooks; Gateway API there, `GatewayClass istio` accepted; gateway programmed in
  10 s; the label dry run printing the `restricted` violation (`seccompProfile`); the app
  through the gateway; the mesh option and its undo; remove; uninstall (no `istio-system`, 0
  Istio object types).
- `CERT-MANAGER.md`, on a cluster that already had the add-on under this guide's names:
  settings (`4`); the check (`a VKS add-on, Ready=True`); the release list (seven); fill and dry
  run; install (`unchanged`, `15 s: Ready=True`); the guest check (three deployments 1/1, three
  CRDs); *Remove cert-manager* with Headlamp installed (the refusal).
- `HEADLAMP.md`, add-on way, likewise already installed: settings (`11`); the cert-manager
  check; fill; install (`unchanged`, `15 s: Ready=True`); *What the add-on put on the cluster*
  (LoadBalancer on 443, `cluster-admin`, `privileged`); the read-only account (created; yes /
  no / no / no, no kubectl warning); the token block; *Open the page* (HTTP 200, the same
  fingerprint from the Secret `headlamp-tls-cert` and from the address).
- `HEADLAMP.md`, helm way: all of it in the first round; *Create Headlamp's namespace* again
  with the add-on installed (the refusal).
- By hand, outside the chapters: the Headlamp add-on without cert-manager stays `Ready=False`
  (`Expected to find kind 'cert-manager.io/v1/Issuer', but did not`); cert-manager from nothing
  was Ready after 30 s, Headlamp after it in 20 s.

NOT walked on a lab (stand-in `kubectl`, `helm`, `curl`, `sleep` only: 149 cases, each in bash
and zsh):

- the three remove blocks in their third-round form. Each now reads the `AddonInstall` AND the
  `ClusterAddon` first; with both absent it cleans up (Headlamp: the read-only binding on the
  guest and two files; the others: one file), also on a later run after a wait that timed out;
  with only the `ClusterAddon` left it says VKS is still removing it. The stand-in cases run
  that sequence (timed out, still going, gone). On a lab: none of the three has deleted
  anything, and whether a `ClusterAddon` outlives its `AddonInstall` for a visible time is not
  known;
- `CERT-MANAGER.md`: an install from nothing through the chapter's own blocks; the remove once
  Headlamp is gone (does it pass the `Certificate` guard); the "what is left" block (the chapter
  expects no namespace and 0 object types);
- `HEADLAMP.md`, add-on way: an install from nothing through the blocks; the install's refusal
  on a cluster without cert-manager and on a cluster with the helm Headlamp; logging in to the
  page in a browser with the read-only token (the warning's wording, the field and button
  names, and that Headlamp accepts another account's token); the remove, and that VKS deletes
  the namespace with the read-only account in it;
- `HEADLAMP.md`, *Change the add-on's settings (optional)*, both blocks: **never run.** The two
  settings are read from the add-on's schema. Unknown: whether a new `hostname` re-issues the
  certificate and how long that takes; whether the Secret has `ca.crt`; what `gatewayApi.enabled`
  creates beyond the schema's defaults and whether the `LoadBalancer` Service stays;
- `ISTIO.md`: the changed uninstall block; the Service block as changed after the walk (it
  notes the earlier type in an annotation); nothing about an app that ArgoCD deployed (the
  chapter's two sentences on `selfHeal` are from ARGOCD-app.md's text, not from a run);
- `HEADLAMP.md`, desktop: macOS `open -n -a Headlamp --args`, the `.deb` on Ubuntu.

Not built from phase 9: the Image Updater measurement (D11). `check-vks-templates.sh` does not
read `vks/addons/templates/`; that each template's variables equal the guides' `envsubst` lists
was checked by hand.

## Gate: known gaps

What `make check-vks-docs` and `vks/test/walk.sh` do not cover after the review of 2026-10-10.
None blocks a phase; each is a place where a green gate says nothing.

- **HTML links:** `<img src="…">` and `<a href="…">` targets are not resolved; only markdown
  `[text](target)` and `![alt](target)` are.
- **Step-number references:** no check. A reference by number that crosses files would pass.
- **HTML comments:** not read. `README.md`, *Where to go next*, has two that name a chapter to
  link once it exists.
- **Emoji in a heading:** the anchor the gate computes for such a heading may differ from
  GitHub's. The guides have none today.
- **`walk.sh remote`, dry run:** it does not check that local paths (`--env-file`,
  `--workdir`) exist on the far side before the real run.
- **`walk.sh container`:** an `--env-file` path with a space breaks the mount list (`$mounts`
  is built unquoted).
- **bash 3.2 and BSD awk:** neither script has run under them. The owner runs the harness on
  the Mac; that run is the proof.
- **zsh in CI:** the CI job has no zsh, so `zsh -n` runs only locally (`vks/HANDOFF.md`, "The
  doc gate").

## Risks to a customer walk (from the review)

1. **Rights:** the reader lacks vCenter rights for a namespace, **Manage Supervisor Services**
   or the Broadcom entitlement. Every create door has an "ask your administrator" twin.
2. **Environment differences:** an NSX VPC or Avi Supervisor, no DNS record for Harbor, a
   Harbor CA the guest does not trust, no Supervisor egress to GitHub for ArgoCD. Each is a
   check block before the step that would fail.
3. **Silent no-ops and sizing:** an empty substitution, a hand-made `AddonConfig`, a wrong
   digest from kustomize, istiod Pending on small workers, a gateway pod refused by pod
   security. Each gets a guard or a verify-from-the-guest step.

## Open with the owner (defaults are in force until overruled)

- **Door A's exposure:** default is ClusterIP + port-forward until a release without the open
  `/shutdown` exists. A new release would let door A use the LoadBalancer.
- **Helm:** read as "installed, checked and tested where it is needed (Headlamp)", not as a
  prerequisite for everyone.
- **Image Updater:** measured in phase 9, shipped only if it works.
- **Hub size:** the spine stays in `README.md` (about 500 lines), not a 300-line index.

## Needs the owner (work continues around these)

- **Screenshots of the vSphere Client** for `NAMESPACE-manual.md` (13, `img/namespace/`) and
  `CLUSTER-manual.md` (12, `img/cluster/`): the session does not type passwords into a browser,
  so it cannot log in to the vSphere Client. The image lines are in the guides; the files are
  not, and the click steps marked `unverified` are to be walked when they are taken.
- **Mac tunnels:** each walk on the Mac needs forwards to addresses the lab assigns at install
  time (Harbor, the guest cluster API, the app, the gateway). The session reports the exact
  `ssh -N -R …` line when the addresses exist; the owner runs it.
- **Broadcom downloads** (Harbor service files): the session may click the downloads on the
  support portal and verifies the SHA-256; a login prompt there is the owner's.

## Not in scope

Air-gapped installs; VCF Automation / CCI namespaces; Argo CD Image Updater; Istio ambient
mode; a Harbor from another Supervisor (the `additionalTrustedCAs` variable) beyond one
pointer; Windows.
