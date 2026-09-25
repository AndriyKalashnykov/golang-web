# HANDOFF — where golang-web stands

Resume point for work on this repo. Durable facts and the backlog are in [CLAUDE.md](CLAUDE.md);
the VKS runbook has its own [vks/HANDOFF.md](vks/HANDOFF.md). Keep this file short: replace its
content when the state changes, do not append history (git has it).

## State — 2026-09-25

`main` is green; no open PRs, branches or worktrees. Everything below is merged.

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

1. **Next Sunday:** read the first real run of the re-enabled Cleanup workflow ("Delete orphaned
   untagged container images"). Expected: nothing deleted (one orphan, KEEP_MINIMUM=5).
2. **Next release** gives the first signed `latest`; verify it with the `cosign verify` command in
   CLAUDE.md's backlog entry, then close that entry.
3. **Owner decision:** branch protection on `main` (CLAUDE.md backlog has the exact command).

The open, not-urgent items are in CLAUDE.md → Upgrade Backlog.

## Environment

- **Test machines:** the Ubuntu VM used for the Linux runs is deleted. The rented Mac
  (`ssh m1@51.159.120.46`) is KEPT for vks-airgap-cicd: podman machine and Colima stopped, no
  clones or harness files left in `~`. See vks/HANDOFF.md before deleting it.
- **This host's KinD cluster `golang-web`** runs the #192 manifest.
