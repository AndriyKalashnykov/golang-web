# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-10-19

**v0.0.5 is released and signed** (`0.0.5`, `0.0`, `0`, `latest` = `sha256:cbd47f21…565d`, amd64 +
arm64; `cosign verify` passes for the v0.0.5 identity and fails for v0.0.4). It closes `/shutdown`:
the image serves it only with `ENABLE_SHUTDOWN=true` (run on amd64 with podman and docker; arm64
compared statically, not run). `/healthz` reports the real build time. **`main` is protected**:
`static-check`, `build` and `test` are required and the branch must be up to date. A PR that
touches only files CI ignores (this file, README.md) gets no checks; merge it with
`gh pr merge <n> --squash --admin`.

- **The release path now checks the image:** the tag-only `docker` job's smoke test is
  `make image-smoke`, which fails if the image serves `/shutdown` by default (proven against the
  published 0.0.4 and 0.0.5, on both engines). It first runs on the next tag.
- **`k8s/golang-web.yaml` pins 0.0.5.** A cluster that was given 0.0.4 keeps it until the
  manifest is applied again; the README and the vks guides say so.
- **vks door A:** the owner kept ClusterIP + port-forward as the default after 0.0.5.
- **Deploy `main`, never a release tag** (owner, 2026-10-16): a tag's `k8s/` names the release
  before it. Documented in the README and `vks/ARGOCD-app.md`.
- **After every release, merge Renovate's `golang-web image` PR yourself** (owner, 2026-10-16):
  the self-image no longer automerges. Its `static-check` runs `make check-image-pin`, which
  fails unless the pin is the signed release (CLAUDE.md backlog, *Why it is not automerged*).
  Never `--admin` that PR past a red `static-check`, even one reported as infrastructure: rerun
  it until the check gives a verdict. `static-check` now needs ghcr.io and Sigstore's TUF CDN.
- **README rewritten for first-time users** (#374, #378, 2026-10-19). Prerequisites now come as
  one section per tested OS, in install order. The README also gains a tool-check block, a
  `cosign verify` block for the release in `version.txt`, and Expect text for `make build`,
  `make test` and `make run`. Four adversaries reviewed it (Docker, K8s, shell, a first-time
  walker), and their findings are fixed. Tried on this host: the tool check and the cosign
  block, in bash and zsh, and both cosign failures. The README was not walked on a clean
  machine after the rewrite. Its *Tested platforms* table still records the 2026-10-06 walks.
- **`make image-push` advice on arm64 Linux** (#377): it says podman 5 or newer, not 5.8.
  Shown with a stand-in podman and `uname`, never on a real arm64 machine. `vks/SETUP.md` and
  `vks/TROUBLESHOOTING.md` were changed to match.

## Next

0. **In progress since 2026-10-10: the `vks/` end-to-end story.** Plan, decisions and phases:
   [vks/PLAN.md](vks/PLAN.md). Start at the first phase not marked done there.
1. **Read the first CI run that lands on Ubuntu 26** (`ubuntu-latest` moves from 2026-10-19,
   rolled out over time). Every job of the 2026-10-19 runs on `main` (#376, #377, #378) still
   ran on `ubuntu-24.04`. To check a run:
   `gh run view <id> --log | grep 'Image: ubuntu'`.
2. **At the next tag:** read the `docker` job's `Smoke test` step; it is the first run of
   `make image-smoke` in CI (local runs only so far). It is also the first release signed with
   `.mise.toml`'s cosign (3.1.3, installed by mise-action; probed on a runner, never on a tag):
   the `Check the cosign on PATH` and `Verify the signature` steps must pass, or no tag is
   published. Then, on Renovate's `golang-web image` PR:
   `gh pr view <n> --json autoMergeRequest` is null while it is open (first real PR since
   automerge was turned off), and its `static-check` log shows `check-image-pin` passing for the
   new version before you merge it.
3. **Next README walk** (needs the owner's machines). These paths have never been walked:
   - the Debian fallback when `sudo` is missing (`su -c …`);
   - a bare Mac, from the Homebrew installer on;
   - the blocks pasted into macOS `/bin/bash` 3.2;
   - push steps 1 and 5;
   - the cluster's own kubeconfig file (`~/.kube/kind-golang-web.yaml`).

   Then update *Tested platforms*.

The open, not-urgent items are in CLAUDE.md → Upgrade Backlog.

## Limits on a session

- It may not start the lab or open the `ssh -N -R` tunnels to the Mac; the owner does both.
- It cannot run the Homebrew installer on the Mac: `sudo -v` there asks for the login password
  even though `m1` has passwordless sudo for commands.
- Workflow run logs from before 2026-10-02 are gone (the owner had every run but the newest
  deleted). What the release run and the Ubuntu 26 probe showed is in CLAUDE.md's backlog.

## Environment

- **This host** (checked 2026-10-07): no tunnels, KinD clusters, worktrees or golang-web test
  containers; `make e2e` creates a cluster when needed. Clean test containers need
  `--network host` here: on Docker's default network every DNS lookup took 5 s. Not from this
  repo and left alone: two `nodejswebapp-builder` containers in podman and the docker
  `multi-platform-builder` buildx container. Podman has no registry login. Local images:
  `golang-web:latest` in both engines and `v0.0.4-kind` in docker.
- **The Mac:** an M2 with 16 GB at `ssh m1@62.210.166.48`, macOS 26.6.1 (it replaced the M1 on
  2026-09-30). Checked 2026-10-07: podman machine and Colima stopped, no clone, no mise, no Lima VM. Left
  on it as of 2026-10-05: Homebrew, podman, Colima, `vcf`, kubectl v1.36.2, passwordless sudo,
  `~/.kube/config` (28 bytes, written by kind), an empty `~/.local/state`, and a `kind` network
  inside the Colima VM. It is kept for vks-airgap-cicd. See vks/HANDOFF.md before deleting it.
- **The nested vSphere lab** (`~/projects/nested-vsphere-lab`, used by `vks/`): it is the owner's
  to start and stop (`make -C ~/projects/nested-vsphere-lab lab-start` took about an hour on
  2026-10-05). Its `esxi01` VM was running when last seen (2026-10-07 03:15 UTC); the owner
  stopped and started it several times on 2026-10-06 and 07. On 2026-10-06 at 15:11 the kernel
  OOM killer killed it, because a session had filled `/tmp` (RAM on this host) with test-VM
  disks; nothing inside the lab was checked after that unclean stop. **Keep VM disks and other
  large files on real disk (for example `~/.cache`), never in the scratchpad.** After the last
  walk Harbor's `apps` project had no `golang-web` repository and no robot, and the guest
  cluster's `golang-web` namespace was deleted by step 10.
