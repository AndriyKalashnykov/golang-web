# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-09-30

`main` is green and the working tree is clean. No open PRs, worktrees or local branches. The two
Renovate PRs from 2026-10-01 (#213 Docker dependencies, #214 renovate) were merged by hand that
day; #213's Dockerfile was built and smoke-tested locally first, because CI builds the image only
on tags.

Since 2026-09-25 the work has been the VKS runbook (`vks/README.md`, PRs #202–#212 and #215–#218): multi-arch
push, an end-user rewrite, two newcomer reviews, and `make image-push` refusing podman < 5 on
arm64 Linux before it builds. On 2026-09-30:

| PR | What |
|---|---|
| #215, #216 | The rented Mac was replaced; both macOS paths of the runbook walked end to end on the new one (macOS 26.6.1), no difference from 26.6.2 |
| #217 | "Install kubectl" reworded; a collapsed alternative installs the kubectl the Supervisor serves when dl.k8s.io is blocked; `--connect-timeout 10` on the dl.k8s.io downloads |
| #218 | That alternative downloads with `curl -k` (owner decision; do not revert without asking) |

Its state and resume point are in [vks/HANDOFF.md](vks/HANDOFF.md) (rounds 9 and 10).

Earlier, 2026-09-25:

| PR | What |
|---|---|
| #186 | Every Makefile target runs on Linux and macOS with actionable output (verified on a fresh Ubuntu 24.04 VM and the Mac) |
| #187 | README cut to what a user needs; every code block executed on Linux and macOS |
| #188 | `trivy-fs` / `trivy-config` fail on HIGH/CRITICAL (they always exited 0 before) |
| #189 | The app reads `MESSAGE_TO` (the manifest set it; the code ignored it) |
| #190 | Image cleanup deletes only orphans (it was deleting released images' platform builds and signatures) |
| #191 | Release pushes by digest, signs, verifies, then tags; `latest=auto` |
| #192 | KinD pod stopped restarting every ~20 min: 32Mi, no CPU limit, `GOMEMLIMIT=20MiB`, looser probes |
| #193 | `.env.example` + `make check-env` gate; `.env` read with `?=` precedence |

Proven outside CI: a prerelease `v0.0.4-rc.1` signed and verified end to end (then deleted, image
and tag); the fixed pod ran 2 h with 0 restarts; `make ci-run` passes on Linux and macOS.

## Next

1. **Next release** gives the first signed `latest`; verify it with the `cosign verify` command in
   CLAUDE.md's backlog entry, then close that entry.
2. **Owner decision:** branch protection on `main` (CLAUDE.md backlog has the exact command).

The open, not-urgent items are in CLAUDE.md → Upgrade Backlog.

## Environment

- **Test machines:** the Ubuntu VM used for the Linux runs is deleted. The rented Mac was
  REPLACED on 2026-09-30: the M1 (8 GB, `51.159.120.46`) is deleted, and a new M2 with 16 GB is at
  `ssh m1@62.210.166.48`. It runs macOS 26.6.1; both macOS paths of the vks README were walked on
  it the same day (vks/HANDOFF.md, round 9). Left on it: Homebrew, podman and Colima (both
  stopped), `vcf`, native kubectl v1.36.2, passwordless sudo; no clone, env file, tunnel or
  relay. It is kept for vks-airgap-cicd. See vks/HANDOFF.md before deleting it.
- **KinD:** no cluster on this host (the `golang-web` cluster was deleted 2026-09-29). `make e2e`
  creates one when needed.
- **The nested vSphere lab** (`~/projects/nested-vsphere-lab`, used by `vks/`) is **running**. It
  was already up when this session began and this session did not start or stop it. Harbor's
  `apps` project has no `golang-web` repository and no robot; the guest cluster has no
  `golang-web` namespace. Stop it with `make -C ~/projects/nested-vsphere-lab lab-stop` when
  nothing else needs it.
- **This host:** no tunnels, test containers or test images left. podman has no Harbor login.
