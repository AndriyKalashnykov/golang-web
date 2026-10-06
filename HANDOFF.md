# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-10-06

`main` is green. No open PRs, worktrees or local branches.
**v0.0.4 is released and signed** (`latest` points at it), and **`main` is protected**:
`static-check`, `build` and `test` are required. A PR that touches only files CI ignores (this
file, README.md) gets no checks; merge it with `gh pr merge <n> --squash --admin`.

Nothing is in progress. The last work, 2026-10-03 to 05, validated both READMEs as a first-time
user:

- **Root README:** every block run on Linux (Ubuntu 26.04.1) and pasted into an interactive zsh
  on the Mac (macOS 26.6.1) from a state with no clone and no mise, `make e2e` included. The
  Linux install blocks ran in clean `ubuntu:24.04`, `ubuntu:26.04`, `debian:12` and `debian:13`
  containers, amd64 here and arm64 under Colima. The push section ran against the lab's Harbor.
  On 2026-10-06 every section was also walked, Docker only, on fresh Debian 12 and 13 x86_64
  VMs and on Ubuntu 24.04, 26.04 and Debian 12, 13 arm64 VMs; see the README's Tested platforms
  and the two 2026-10-06 entries in CLAUDE.md's backlog.
- **`vks/README.md`:** steps 1 to 10 walked on the lab with Linux podman, Linux docker, and
  both macOS engines, including the app's LoadBalancer address reached from the Mac. Details
  are in `vks/HANDOFF.md`.
- **Not run:** the ghcr.io-specific lines of the push section (classic token, package private
  until made public) come from GitHub's documentation.

The two rules for fenced blocks that came out of it are in CLAUDE.md's backlog entry for the
README validation.

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

- **This host** (checked 2026-10-06): no tunnels, KinD clusters, worktrees or golang-web test
  containers; `make e2e` creates a cluster when needed. Clean test containers need
  `--network host` here: on Docker's default network every DNS lookup took 5 s. Not from this
  repo and left alone: two `nodejswebapp-builder` containers in podman and the docker
  `multi-platform-builder` buildx container. Podman has no registry login. Local images:
  `golang-web:latest` in both engines and `v0.0.4-kind` in docker.
- **The Mac:** an M2 with 16 GB at `ssh m1@62.210.166.48`, macOS 26.6.1 (it replaced the M1 on
  2026-09-30). Checked 2026-10-06: podman machine and Colima stopped, no clone, no mise. Left
  on it as of 2026-10-05: Homebrew, podman, Colima, `vcf`, kubectl v1.36.2, passwordless sudo,
  `~/.kube/config` (28 bytes, written by kind), an empty `~/.local/state`, and a `kind` network
  inside the Colima VM. It is kept for vks-airgap-cicd. See vks/HANDOFF.md before deleting it.
- **The nested vSphere lab** (`~/projects/nested-vsphere-lab`, used by `vks/`): the owner
  started it on 2026-10-05 and it is his to stop (`make -C ~/projects/nested-vsphere-lab
  lab-stop`; `lab-start` took about an hour that day). Its `esxi01` VM is **shut off
  since 2026-10-06 15:11**: the kernel OOM killer killed it. A session had put about 76 GB of
  test-VM disks in its scratchpad, and `/tmp` on this host is tmpfs (RAM). It was not shut down
  cleanly, so expect the lab to need checking after the next `lab-start`. Keep large files off
  `/tmp` here. After the last walk Harbor's `apps` project had no
  `golang-web` repository and no robot, and the guest cluster's `golang-web` namespace was
  deleted by step 10.
