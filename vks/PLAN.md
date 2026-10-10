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

## Document map (target)

```
vks/README.md                 the spine: setup, login, namespace check, cluster, deploy door A, reach, clean up
vks/SETUP.md                  per-OS tool installs (container engine, kubectl, VCF CLI, envsubst, optional helm)
vks/NAMESPACE.md              four doors                                        new
vks/CLUSTER.md                create a guest cluster with kubectl; sizing        new
vks/HARBOR.md, HARBOR-manual.md, HARBOR-auto.md                                  new
vks/REGISTRY.md               door B: trust the CA, project, robot, build, push  <- today's steps 3, 5, 6
vks/ARGOCD.md, ARGOCD-manual.md, ARGOCD-auto.md   kept, corrected (order, env, chart hosting)
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

- **Screenshots of the vSphere Client** for the manual namespace and Harbor paths: the session
  does not type passwords into a browser, so it cannot log in to the vSphere Client. Until the
  owner logs in to it in the session's browser once, those paths ship as numbered click lists
  without pictures.
- **Mac tunnels:** each walk on the Mac needs forwards to addresses the lab assigns at install
  time (Harbor, the guest cluster API, the app, the gateway). The session reports the exact
  `ssh -N -R …` line when the addresses exist; the owner runs it.
- **Broadcom downloads** (Harbor service files): the session may click the downloads on the
  support portal and verifies the SHA-256; a login prompt there is the owner's.

## Not in scope

Air-gapped installs; VCF Automation / CCI namespaces; Argo CD Image Updater; Istio ambient
mode; a Harbor from another Supervisor (the `additionalTrustedCAs` variable) beyond one
pointer; Windows.
