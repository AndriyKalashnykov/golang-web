# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-10-05

`main` is green and the working tree is clean. No open PRs, worktrees or local branches.
**v0.0.4 is released and signed** (`latest` points at it), and **`main` is
protected**: `static-check`, `build` and `test` are required. A PR that touches only files CI
ignores (this file, README.md) gets no checks; merge it with `gh pr merge <n> --squash --admin`.

On 2026-10-03 and 04 the root README was validated as a first-time user and rewritten:

| PR | What |
|---|---|
| #247 | README rewritten and reordered; `make help` no longer prints `Makefile` as every target name when a `.env` exists; the hints the Makefile prints are paste-safe; `ci.yml` passes the build time to both image builds; diagram corrected and re-rendered |
| #250 | `vks/README.md`: the one trailing comment on a command line removed (docker install block) |
| #251 | Prerequisites moved before "Run it locally" and split: install yourself, installed by `make deps`, install yourself for the Kubernetes sections |
| #252, #253 | Per-OS install links for Docker and kubectl, the macOS Colima install block, and why macOS gets make and Git from Apple's command line tools |
| #254 | Four small findings from the second macOS walk; this file and the backlog |

On 2026-10-05 the README's prerequisites section took its install blocks from `vks/README.md`
step 2 (Homebrew, the four engine blocks, a check block) and gained a standalone kubectl install
block; "Tested platforms" gained Debian 12 and 13 and a "What ran" column. Run for it: the Linux
install blocks in clean `ubuntu:24.04`, `ubuntu:26.04`, `debian:12` and `debian:13` containers as
a non-root user with sudo (engines installed, not started), and the kubectl block on the Mac
pasted into an interactive zsh and bash 3.2 with real sudo (the Mac's kubectl 1.36.2 was put
back afterwards), as were the macOS podman, Colima and Homebrew `PATH` blocks. Those containers
need `--network host` on this workstation: on Docker's default network every DNS lookup took
5 s, which trips the block's 10 s limit. `make e2e` here gave client v1.37.1, server v1.37.0.

Later the same day, on the Mac (macOS 26.6.1), from a state with no clone and no mise: the
kubectl block with real sudo, the podman and Colima blocks, then "Run it locally" as written
(clone, `make deps`, `make build`, `make test`, `make run` with a curl) and `make e2e` (5 passed,
client v1.37.1, server v1.37.0). Under Colima, the Linux install blocks ran in clean **arm64**
`ubuntu:24.04`, `ubuntu:26.04`, `debian:12` and `debian:13` containers. The Mac was put back
afterwards: kubectl 1.36.2, both engines stopped, docker context `default`, no clone, no mise.

The Homebrew installer block needs the Mac's login password (its `sudo -v` asks for it even
though `m1` has passwordless sudo for commands), so the owner ran it in a terminal on the Mac:
`Password:`, `Press RETURN/ENTER to continue`, `==> Installation successful!`, and then the
second block printed `Homebrew 7.0.8`. More text follows that line, so both READMEs now say the
installer prints it "near its end". A session without that password cannot run the installer.

The same day the owner started the lab and the vks guide's Linux podman path was walked on it,
steps 1 to 10, and then its Linux docker path; details are in `vks/HANDOFF.md`. and then both macOS
engines from the Mac, through tunnels the owner opened (the session may not open them or
start the lab). The lab was left running.

A rule that came out of it: **in a block, nothing may follow a line that can prompt.** A shell
without bracketed paste (macOS `/bin/bash` 3.2) hands the rest of the paste to the prompt:
measured on Linux and on the Mac with a `sudo` that prompts, the password prompt swallowed the
old kubectl block's last line and only the password after the fix. That block now
cleans up inside its `if`, the two `apt-get` lines are joined with `&&`, and the Homebrew
installer is a block of its own in both READMEs.

How it was checked, so the next reader does not repeat it:

- Every block executed on Linux (Ubuntu 26.04.1), including `make e2e` and the kubectl section.
- Two walks on the Mac (macOS 26.6.1). The first ran the old README as scripts and pasted into an
  interactive zsh; the second pasted the rewritten README into an interactive zsh, top to bottom.
  It ran the text of #247, before #251 to #253 changed the prerequisites section: that section's
  new blocks (`apt-get install`, `xcode-select --install`, the Colima install) were not walked.
- The push section ran for real against the lab's Harbor: `make registry-login`,
  `make image-push` (amd64 + arm64), `make k8s-apply` to `lab-gc1`, `make k8s-delete`. The
  ghcr.io-specific lines (classic token, package private until made public) come from GitHub's
  documentation, not a run.
- Four adversary reviews (shell and make, engines and registry, Kubernetes, the diff).

**The rule that came out of it:** no comment on a command line in a fenced block. macOS's default
interactive zsh has `interactivecomments` off, so `make deps # ...` passes the comment as
arguments. Running a block as a script cannot show this; paste it into `zsh -i` on a pty.

Since 2026-09-25 the work has been the VKS runbook (`vks/README.md`, PRs #202–#212 and #215–#218): multi-arch
push, an end-user rewrite, two newcomer reviews, and `make image-push` refusing podman < 5 on
arm64 Linux before it builds. On 2026-09-30:

| PR | What |
|---|---|
| #215, #216 | The rented Mac was replaced; both macOS paths of the runbook walked end to end on the new one (macOS 26.6.1), no difference from 26.6.2 |
| #217 | "Install kubectl" reworded; a collapsed alternative installs the kubectl the Supervisor serves when dl.k8s.io is blocked; `--connect-timeout 10` on the dl.k8s.io downloads |
| #218 | That alternative downloads with `curl -k` (owner decision; do not revert without asking) |

Its state and resume point are in [vks/HANDOFF.md](vks/HANDOFF.md) (rounds 9 to 12). Round 11
(#222, 2026-10-01) made the Colima blocks start Colima and select its docker context; round 12
walked the macOS Colima path end to end on the merged text.

Also on 2026-10-01:

| PR | What |
|---|---|
| #228 | CI's `static-check` failed 2 of 8 runs with `podman did not answer within 15 s`. Cause: the first `podman info` on a fresh runner is slow (package lookups on a cold disk), not hung. The engine check now runs `ps -q` with a 60 s limit. Measurements are in the Makefile comment and the CLAUDE.md backlog entry |
| #223, #225, #227 | Renovate merged these itself: renovate v44.117.0, and `jdx/mise-action` v4 to v5 (a major bump) with a digest update. CI on `main` passed after each. The v5 change was reviewed afterwards: it works, but with no `version:` it reinstalled mise on every job with an "integrity verification" warning |
| #230 | `MISE_VERSION` in `ci.yml` pins the mise binary for all three `jdx/mise-action` steps, and Renovate bumps it ("Tool versions" group). CLAUDE.md's backlog also records that `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19 |
| #232 | "Cache Go modules" runs before the mise step, which removes a `tar` restore warning on a mise cache miss. A throwaway probe ran all four CI jobs on `ubuntu-24.04` and `ubuntu-26.04`; both passed (CLAUDE.md backlog has the details) |
| release | v0.0.4, cut with `make release`. Signed, verified, amd64 + arm64 |
| settings | Branch protection on `main` (not a commit; CLAUDE.md backlog has the command) |
| Actions | On 2026-10-02 the owner had every workflow run deleted except the newest, so run logs from before that date are gone (the release run, the Ubuntu 26 probe). What they showed is written in CLAUDE.md's backlog |
| #234 | Renovate bumped `k8s/golang-web.yaml` to the 0.0.4 image and merged it itself once the required checks passed: the first auto-merge under the protection |

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

1. **First:** reach the app's LoadBalancer address from the Mac (vks guide, step 9). The steps
   are the top item of CLAUDE.md's Upgrade Backlog; it needs the owner to open two tunnels.
2. **After 2026-10-19:** read the first CI run that lands on Ubuntu 26 (`ubuntu-latest` moves).
3. **At the next release:** check `/healthz` of the released image shows a build timestamp, not
   `now` (#247; it runs only on a tag, so a local build is the only proof so far).

The open, not-urgent items are in CLAUDE.md → Upgrade Backlog.

## Environment

- **Test machines:** the Ubuntu VM used for the Linux runs is deleted. The rented Mac was
  REPLACED on 2026-09-30: the M1 (8 GB, `51.159.120.46`) is deleted, and a new M2 with 16 GB is at
  `ssh m1@62.210.166.48`. It runs macOS 26.6.1; both macOS paths of the vks README were walked on
  it the same day (vks/HANDOFF.md, round 9). Left on it: Homebrew, podman and Colima (both
  stopped), `vcf`, native kubectl v1.36.2, passwordless sudo; no clone, env file, tunnel or
  relay. It is kept for vks-airgap-cicd. See vks/HANDOFF.md before deleting it.
- **KinD:** no cluster on this host (the last one was created and deleted on 2026-10-04).
  `make e2e` creates one when needed.
- **The nested vSphere lab** (`~/projects/nested-vsphere-lab`, used by `vks/`) is **stopped**:
  this session started it on 2026-10-03 for the push test and stopped it on 2026-10-04
  (`lab stopped`, `esxi01` shut off). Start it with `make -C ~/projects/nested-vsphere-lab
  lab-start` (about 23 minutes). Harbor's `apps` project has no `golang-web` repository and no
  robot; the guest cluster has no `golang-web` namespace. `make guest-login` there rewrote
  `kubeconfig-guest` with a fresh token.
- **The Mac** was left as found after both walks: podman machine and Colima stopped, no clone, no
  mise, no Go caches, no registry login. Left by the walks: `~/.kube/config` (28 bytes, written
  by kind), an empty `~/.local/state`, and a `kind` network inside the Colima VM.
- **This host** (checked 2026-10-04): no tunnels, KinD clusters, golang-web test containers or
  worktrees. Not from this repo and left alone: podman's Harbor login as `robot$vks-cicd` (it
  belongs to vks-airgap-cicd), two `nodejswebapp-builder` containers from 2026-09-05, and the
  docker `multi-platform-builder` buildx container. `ghcr.io/andriykalashnykov/golang-web:latest`
  in both engines is now the 0.0.4 image (re-pulled 2026-10-03).
