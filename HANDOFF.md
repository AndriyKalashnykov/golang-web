# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-10-07

`main` is green. No open PRs, worktrees or local branches.
**v0.0.4 is released and signed** (`latest` points at it), and **`main` is protected**:
`static-check`, `build` and `test` are required and the branch must be up to date. A PR that
touches only files CI ignores (this file, README.md) gets no checks; merge it with
`gh pr merge <n> --squash --admin`.

Nothing is in progress. The last work, 2026-10-06:

- **`/shutdown` is off unless `ENABLE_SHUTDOWN=true`** (#277). The published 0.0.4 image, which
  `k8s/golang-web.yaml` pins, still serves it to anyone: that closes only with the next release.
- **README:** sections run install, use, reference; Homebrew is the one macOS starting point;
  Debian 12 needs Docker (its podman 4.3 cannot build the image).
- **Tested platforms:** every section walked on eight platforms in one clean pass each; what was
  and was not exercised is in the README table, its note, and CLAUDE.md's backlog entry.
- **`vks/README.md`:** unchanged apart from the podman version sentence; its last full walk is
  2026-10-05 (details in `vks/HANDOFF.md`).
- **vks-airgap-cicd:** its KinD teardown and bring-up no longer remove or replace this project's
  LoadBalancer controller. The deliberate differences between the two projects are listed in
  CLAUDE.md.

## Next

1. **After 2026-10-19:** read the first CI run that lands on Ubuntu 26 (`ubuntu-latest` moves).
2. **At the next release:** check `/healthz` of the released image shows a build timestamp, not
   `now` (#247; it runs only on a tag, so a local build is the only proof so far).

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
