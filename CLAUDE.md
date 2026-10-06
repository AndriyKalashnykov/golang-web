# CLAUDE.md

**Resume point: [HANDOFF.md](HANDOFF.md)** — where the work stopped and what is next.

## Project Overview

HTTP web server with Prometheus metrics written in Go. Serves a simple "Hello, World" page with Kubernetes downward API environment variables, a `/healthz` health check, and `/metrics` endpoint for Prometheus scraping.

## Tech Stack

- **Language**: Go — pinned in THREE places that must agree (`go.mod`,
  `Dockerfile`, `.mise.toml`); `make check-toolchain-alignment` enforces it
- **Framework**: `net/http` (standard library) + `prometheus/client_golang`
- **Container**: Docker multi-arch (`linux/amd64`, `linux/arm64`)
- **Toolchain**: [mise](https://mise.jdx.dev/) — every tool version lives in
  `.mise.toml`; `make deps` installs them. Works on Linux and macOS.
- **Local Kubernetes**: KinD + cloud-provider-kind (host-side LoadBalancer
  controller; no in-cluster MetalLB DaemonSet)
- **CI/CD**: GitHub Actions
- **Dependency Management**: Go modules, Renovate

## Build & Development

Local settings: `cp .env.example .env` and uncomment what you change (`?=` lines, so
command line > shell > `.env` > default). act is told to ignore `.env`.

```bash
make deps           # Install the pinned toolchain via mise (.mise.toml)
make build          # Build the Go binary
make test           # Run tests with coverage
make static-check   # All quality + security checks (check-env, check-toolchain-alignment, lint-ci, lint, sec, vulncheck, secrets, trivy-fs, trivy-config, diagrams-check, scripts-test)
make check-env      # .env.example documents every setting the Makefile and Go code read
make format         # Auto-format Go source files
make ci             # Full local CI pipeline (deps, deps-verify, format, deps-prune-check, static-check, coverage-check, build)
make ci-run         # Run GitHub Actions workflow locally via act (jobs in the Docker engine's arch; ACT_ARCH overrides)
make run            # Run locally on port 8080
make image-build    # Build Docker image
make e2e            # Run e2e tests (KinD + cloud-provider-kind + curl checks)
make kind-delete    # Clean up KinD cluster (prunes this cluster's sidecars only)
make release        # Create and push a new semver tag
make version        # Print current version tag
```

## CI/CD

### Workflows

| Workflow | File | Triggers | Purpose |
|----------|------|----------|---------|
| CI | `ci.yml` | push to main, tags `v*`, PRs (paths-ignore for docs/images), `workflow_call` | Lint, test, build; on tags the image is pushed by digest, signed, verified, then tagged |
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual, `workflow_call` | Delete old workflow runs, stale caches, and ORPHANED untagged images (`.github/scripts/ghcr-prune-untagged.sh` keeps released images and signatures) |

### CI Jobs

- **static-check**: All quality + security checks (`make static-check`, list above) on ubuntu-latest
- **build**: Build (`make build`) after static-check passes
- **test**: Test with coverage threshold (`make coverage-check`) after static-check passes (parallel with build)
- **docker** (tags only, after build + test): Trivy image scan and smoke test, then push the multi-arch image BY DIGEST, `cosign sign` it, `cosign verify` it, and only then attach the release tags (`--dry-run` first confirms the tagged digest equals the signed one). `flavor: latest=auto`, so a prerelease tag does not move `latest`.

## Project Structure

- `main.go` -- Application entry point and HTTP handlers
- `go.mod` / `go.sum` -- Go module definition and checksums
- `Makefile` -- Build automation and CI targets
- `.golangci.yml` -- golangci-lint v2 configuration (linters, formatters, gocritic)
- `Dockerfile` -- Multi-stage Docker build (with `.dockerignore`)
- `k8s/golang-web.yaml` -- Kubernetes deployment manifest (with security context)
- `k8s/kind-config.yaml` -- KinD cluster configuration
- `.mise.toml` -- **tool version single source of truth** (Renovate-tracked)
- `.env.example` -- every setting, commented (`make check-env` keeps it complete); `.env` is gitignored
- `.github/scripts/` -- `check-env.sh` and `ghcr-prune-untagged.sh`, each with a `_test.sh` run by `make scripts-test`
- `.github/workflows/` -- CI and cleanup. The two Claude workflows are
  present but `.disabled` (see the Upgrade Backlog for why and how to restore)
- `.github/CODEOWNERS` -- Workflow file protection (requires owner review)
- `.trivyignore` -- Trivy suppression rules for K8s manifest findings
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Upgrade Backlog

- [x] **The app's LoadBalancer address reached from the Mac, 2026-10-05** (vks guide, step 9's
      first block). It was the one Expect of that day's macOS lab walk that had not matched:
      the address is a private lab IP and had no tunnel. The guide was run again on the Mac
      with podman, steps 1 to 8; the lab assigned `192.168.101.148`; the owner opened a sixth
      tunnel to it, and the block printed the URL, then `Hello, World` from the pod deployed
      in step 8. Step 10 ran and the scaffolding was removed. To repeat it: the lab assigns
      the address at deploy time (`.144`, `.146` and `.148` that day), so its tunnel can only
      be opened after step 8. The tunnel commands are in `vks/HANDOFF.md`.
- [x] **README validated as a first-time user, 2026-10-04** (#247, #250 to #253). The rule to
      keep: **no comment on a command line in a fenced block.** macOS's default interactive zsh
      has `interactivecomments` off, so the comment is passed as arguments (`make deps # ...`
      ran nothing; `read -rs TOKEN && export TOKEN # ...` read the token and did not export it).
      A walk that runs each block as a script cannot see it: paste into `zsh -i` on a pty.
      The second rule (2026-10-05): **in a block, nothing may follow a line that can prompt.**
      A shell without bracketed paste (macOS `/bin/bash` 3.2) hands the rest of the paste to
      the prompt: a `sudo` password prompt swallowed the old kubectl block's last line. So that
      block cleans up inside its `if`, the two `apt-get` lines are joined with `&&`, and the
      Homebrew installer is a block of its own in both READMEs.
- [ ] **Debian 12's podman 4.3.1 cannot build or push the image (measured 2026-10-06).** It has
      `podman buildx build` but no `podman buildx version`, which `deps-buildx` probes, so every
      image target stops there; the README and the hint now say podman 4.9 or newer. Letting the
      probe pass would not be enough: rootless podman there defaults to the `vfs` storage driver
      (a build ran out of space until `storage.conf` selected overlay), and its buildah 1.28.2
      does not set `BUILDPLATFORM`, so the two-platform build fails at `go mod download` with
      `Exec format error`. 4.4 to 4.8 are unmeasured. Use Docker on Debian 12.
- [x] **README walked on fresh Debian and arm64 Linux VMs, 2026-10-06** (Tested platforms).
      **Re-walked the same day as single clean passes at `29c7329`: 51 of 51 steps on each of the
      six VMs.** The first x86 walks had been pieced together from several passes after the
      session's own VM disks filled `/tmp` (RAM on this host) and the lab VM was OOM-killed; the
      re-walk kept its disks under `~/.cache`. Logs: `~/.cache/gw-x86-walk`, `~/.cache/gw-arm64-walk2`.
      Docker only, as the README prescribes for every section: Debian 12 and 13 on x86_64 (KVM),
      Ubuntu 24.04 and 26.04 and Debian 12 and 13 on arm64 (Lima VMs on the Mac, deleted after).
      A pty harness pasted each block and judged it by its Expect lines; it and its logs were in
      the session scratchpad and are NOT in the repo. Not exercised: sudo password prompts,
      ghcr.io (the push used a registry in the VM), push steps 1 and 5, `make release`. On arm64,
      podman 5.4.2 and 5.7.0 each pushed a two-platform index once. On Debian 13, 5.4.2's first
      build failed in runc (no user D-Bus socket) until the user's systemd session was
      restarted; Lima keeps a session open, so a real log out and back in could not be tried.
      Untested: Debian 13 with podman only, where the README asks for no re-login between the
      podman block and the first build.
      Steps outside the README that the walks needed: Git removed from the Ubuntu arm64 images
      first; subuid/subgid ranges added for the Lima user before the podman pushes; on Debian 12
      x86_64, `rm -rf ~/.cache/act` after a full host disk left act's cached jdx-mise-action
      clone corrupt (`invalid git object`).
- [ ] **`/shutdown` is gated in the source, not in any published image (2026-10-06).** `main.go`
      registers it only when `ENABLE_SHUTDOWN` is exactly `true`, and logs
      `shutdown endpoint: enabled|disabled` at start. The 0.0.4 image (`latest`) still serves it
      to anyone, and `k8s/golang-web.yaml` pins 0.0.4 behind a LoadBalancer Service. The exposure
      closes only with the next release and Renovate's bump of that pin; when to release is the
      owner's decision. Until then the README warns in both sections that run the published image.
- [ ] **`BuildTime` in released images (#247) is unproven until the next tag.** The 0.0.4 image's
      `/healthz` reports `"BuildTime":"now"`: `ci.yml` passed `MY_VERSION` but not
      `MY_BUILDTIME`. Both image builds now pass the metadata step's `created` timestamp. A local
      build with the argument returns it; the workflow path runs only on a tag.
- [ ] **macOS, local KinD cluster: a second LoadBalancer Service never gets its address.**
      cloud-provider-kind publishes Services on host port 8080 there, the e2e Service holds it,
      and deleting the second Service's namespace then waits forever on its finalizer (measured:
      killed after 5 min; `make kind-delete` clears it). The README tells macOS readers to skip
      the namespace delete. Not fixed in the Makefile.
- [ ] **One swallowed Ctrl-C on the Mac:** a Ctrl-C sent while `make run` was still starting did
      not stop it; a later one did. Seen once in the second walk, not reproduced.
- [x] **vks: settled 2026-09-29** (measured; details in `vks/HANDOFF.md`, "Settled"):
      - podman 5.8.7 on arm64 Linux builds a correct amd64+arm64 image, so the README offers it
        beside docker. podman 4.9 (Ubuntu 24.04's apt) mislabels; 5.4.2 and 5.7.0 each pushed
        correctly once on 2026-10-06; other 5.0–5.7 untested.
      - The 9.1.1 Linux_ARM64 plugin bundle exists (SHA-256 matches the portal); the README's
        install block, run as written on arm64, installed every plugin.
      - Step 10's clean-up with the podman engine unreachable prints its message, and the
        podman login stays, as the message says.
      - Gatekeeper: the installed `vcf` keeps Safari's quarantine flag but is "Notarized
        Developer ID" (VMware), so it runs without a block. Checked over SSH; Terminal.app is
        inferred to behave the same.
      - The Supervisor's CLI download: its nginx template proxies to the Fleet Depot Service
        (placed in VCF Operations per KB 449965) when that is set up, and otherwise returns a
        hard-coded 503. Documented in the README; the working download path is untested.
      - Lab Harbor: GC with untagged deletion freed 4.0 GB (99% to 60% full).

- [x] **Signing proven on a real tag (2026-09-25).** A prerelease `v0.0.4-rc.1` ran the new
      sign-before-tag job end to end: `cosign verify` passed, the image was multi-arch, and
      `latest` did not move. The prerelease image (7 GHCR versions) and its git tag were deleted
      afterwards.
- [x] **`latest` is signed: v0.0.4 released 2026-10-01.** `0.0.4`, `0.0`,
      `0` and `latest` all point at `sha256:a7df346e...69eec` (amd64 + arm64), and
      `cosign verify` passes for it and fails for a wrong tag identity. `0.0.3` stays unsigned.
      Verify any release with:
      ```
      cosign verify ghcr.io/andriykalashnykov/golang-web:<version-without-v> \
        --certificate-identity https://github.com/AndriyKalashnykov/golang-web/.github/workflows/ci.yml@refs/tags/<vX.Y.Z> \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com
      ```
      `k8s/golang-web.yaml` pins `0.0.4@sha256:a7df346e...` (Renovate, #234).
- [x] **Cleanup workflow re-enabled 2026-09-25** (it had been `disabled_inactivity`). Its first
      real run, 2026-09-27, logged "7 versions; 1 orphaned images, keeping the
      newest 1": nothing deleted, as the dry run predicted.
- [ ] **Liveness restarts (fixed in #192): one part of the cause is unexplained.** The old pod's
      container was charged ~4.7 MB of the binary's code pages at start; a fresh pod ~2.7 MB.
      The 32Mi limit covers the worst case (~18 MB measured-plus-arithmetic). Kill path observed:
      memory limit + first GC + 10m CPU quota -> liveness timeouts (exit 143).
- [ ] **`make ci-run` on Apple Silicon runs linux/arm64 jobs, so it does not prove amd64.**
      Colima without Rosetta runs amd64 under qemu-user, where the Go toolchain panics
      (`growslice: len out of range`). `ACT_ARCH=linux/amd64` forces amd64 where it works.
- [x] **`static-check` failed intermittently in CI on `engine_ready`'s 15 s limit: fixed 2026-10-01.**
      `diagrams-check` printed `podman did not answer within 15 s (it may be hung)` in 2 of 8
      runs that evening. podman was slow, not hung: its first `podman info` on a fresh runner
      also looks up package versions with `dpkg-query` on a cold disk. Measured, 20 fresh
      runners each, as the first podman call inside `make static-check`: `info` 4.8-13.7 s,
      `ps -q` 2.4-8.4 s; on a bare runner `info` reached 22.7 s. The fix: the check runs
      `ps -q` and its limit is 60 s. Not proven: how long `ps -q` can take on a bad evening
      (podman's first-run storage check is still paid), which is why the limit was raised too.
- [ ] **`ubuntu-latest` moves to Ubuntu 26 from 2026-10-19** (notice on every CI run;
      actions/runner-images#14748). All four CI jobs and the cleanup jobs use `ubuntu-latest`,
      so the runner's preinstalled tools change under them without a commit here. What depends
      on the runner rather than on `.mise.toml`: podman (4.9.3 today; `static-check` runs
      diagrams through it, and the `engine_ready` timings in the Makefile were measured on it),
      docker/buildx in the tag-only `docker` job, and perl.
      **Probed 2026-10-01 on a throwaway branch (deleted, and its run with it):** all four
      jobs ran on `ubuntu-24.04` and `ubuntu-26.04` side by side and passed on both. The
      `docker` job ran up to the push (build, Trivy scan, smoke test, a multi-arch build
      without push, cosign install). Not run on Ubuntu 26: the push, `cosign sign`/`verify`
      and the tagging, which need a real tag. Ubuntu 26.04.1 ships podman 5.7.0 (24.04:
      4.9.3), Docker 29.4.2 (28.0.4), perl 5.40.1 (5.38.2), buildx 0.37.1 on both.
      Still open until the label really moves: read the first `ubuntu-latest` run on
      Ubuntu 26. To hold the old image, use `runs-on: ubuntu-24.04`. To move early,
      `runs-on: ubuntu-26.04` fails `make lint-ci` today: actionlint 1.7.12 does not know
      that label.
- [x] **mise binary pinned in CI (2026-10-01):** `MISE_VERSION` in `ci.yml`'s `env:`, passed to
      all three `jdx/mise-action` steps. Without it, mise-action v5 picked the newest mise at
      least 24 h old on each run and reinstalled over the cached one with the warning
      `Existing mise failed integrity verification`. Renovate bumps the pin through the second
      custom manager in `renovate.json` ("Tool versions" group, 3-day wait). Its built-in
      github-actions manager also sees the `version:` inputs and skips them (`invalid-value`,
      because they are `${{ env.MISE_VERSION }}`); that is expected and harmless.
      "Cache Go modules" runs BEFORE the mise step in every job: on a mise cache miss, mise
      compiles govulncheck into `~/go/pkg/mod`, and restoring the module cache after that
      failed with `tar ... Cannot open: File exists`. Proven with a forced mise cache miss
      in the probe run above: no warning on either image.
- [ ] `check-env.sh` blind spots, listed in its header: multi-line getenv calls, keys held in
      constants, syscall.Getenv, aliased os imports, third-party env readers, un-`git add`ed files.
- [x] **Renovate is running again (2026-09-22).** It had been dormant since
      2026-04-08; the Dependency Dashboard's `updatedAt` started moving again
      on 2026-09-22 and PRs #121–#123 opened the same day. No repo-side change
      caused this and none was needed — the entry is kept so the next reader
      does not re-diagnose a dormancy that has ended.
- [x] **`main` is protected since 2026-10-01:** `static-check`, `build` and `test` are
      required and the branch must be up to date (`strict`). Admins are not held to it
      (`enforce_admins: false`), so `make release` still pushes its version commit straight
      to `main` (GitHub prints "Bypassed rule violations"; seen on v0.0.4). Before this, no
      check was required and GitHub's auto-merge never engaged on Renovate PRs.
      The cost: a PR that changes only files CI ignores (root `*.md` except CLAUDE.md,
      `docs/**`, images) starts no CI run, so its required checks never report. Merge such
      a PR with `gh pr merge <n> --squash --admin`.
      `docker` is NOT required: it is tag-gated and reports `skipping` on every PR.
      Seen working 2026-10-02: Renovate's #234 (the `k8s/golang-web.yaml` bump to 0.0.4)
      merged itself 1 min 47 s after it opened, once its three checks had passed.
      To change it (`gh api -F a.b=c` does not build nested JSON; send a body):
      ```
      echo '{"required_status_checks":{"strict":true,"contexts":["static-check","build","test"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}' \
        | gh api -X PUT repos/AndriyKalashnykov/golang-web/branches/main/protection --input -
      ```
- [ ] **Claude workflows are DISABLED** (`claude.yml.disabled`,
      `claude-ci-fix.yml.disabled`). GitHub only loads
      `.github/workflows/*.yml`, so the suffix stops them running while
      keeping them in the repo. They were failing on every run since
      2026-07-01: the "Setup Claude config" step checks out the private
      `AndriyKalashnykov/claude-config` repo with `CLAUDE_CONFIG_TOKEN`,
      which has expired (`Bad credentials`; secret last set 2026-04-09,
      ~90 days before the failures began).
      To bring them back: regenerate the secret FIRST, then rename back.
      ```
      gh secret set CLAUDE_CONFIG_TOKEN --repo AndriyKalashnykov/golang-web
      git mv .github/workflows/claude.yml.disabled .github/workflows/claude.yml
      git mv .github/workflows/claude-ci-fix.yml.disabled .github/workflows/claude-ci-fix.yml
      ```
      The token needs read access to the private config repo (fine-grained
      PAT with Contents:Read, or classic PAT with `repo`). Prefer a long
      expiry or a GitHub App token -- a 90-day PAT is what lapsed silently.
- [ ] After Renovate is revived, expect a large first batch (automerge +
      `prConcurrentLimit: 50`). Consider lowering the limit for the first run.
- [ ] `munnerz/goautoneg` — bus factor of 1, no releases, last commit 2019.
      Transitive via `prometheus/common`; nothing actionable here. Monitor for
      a maintained fork if prometheus/common drops it.
- [ ] `linters.default: all` in `.golangci.yml` means every golangci-lint
      bump can auto-enable new linters and fail unchanged code. This already
      happened once: 2.13 renamed `exhaustruct` to `exhaustruct_v5`,
      re-enabling a linter the project had opted out of. Consider an explicit
      `enable:` list, or budget a triage pass per bump.
- [ ] **Coverage threshold recalibrated 80 -> 75, not earned back.** Go 1.27
      changed statement counting: identical source and tests measure 84.8% on
      go1.26.4 and 78.2% on go1.27.1. The same three functions are uncovered
      under both — `StartWebServer` (blocks in `ListenAndServe`),
      `handleShutdown` (calls `os.Exit(0)`) and `main`. Covering them needs a
      testability refactor (extract an `*http.Server` constructor; make the
      exit path injectable), which was deliberately out of scope for an
      upgrade PR. Doing that refactor is what lets the threshold go back up.
- [ ] mise `go:`-backend tools are COMPILED at install time and bind to the
      Go toolchain active then. After a Go bump, reinstall them
      (`mise uninstall`/`mise install`) or they fail with "application built
      with go1.<old>". Only `govulncheck` is affected today.

## Deliberate differences from vks-airgap-cicd

Owner decisions of 2026-10-06, after a three-way comparison of this README, `vks/README.md` and
`~/projects/vks-airgap-cicd`. Do not "fix" these as inconsistencies:

- **GNU Make on macOS:** all three guides start a Mac from Homebrew. vks-airgap-cicd also needs
  GNU Make 3.82 or newer, so it uses Homebrew's `gmake`; that stays. This Makefile runs on the
  make 3.81 that Homebrew's installer adds with Apple's command line tools, so it does not ask
  for `brew install make`. The standalone `xcode-select --install` route was removed from the
  README so that Homebrew is the one macOS path.
- **Docker on Linux:** this README adds Docker's apt repository (`docker-ce`); vks-airgap-cicd
  installs the distro's `docker.io` because it never adds a third-party repo to a jump box.
- **KinD LoadBalancers on macOS:** here cloud-provider-kind maps the Service port to the Mac's
  localhost; vks-airgap-cicd routes the LoadBalancer addresses with a root daemon
  (docker-mac-net-connect) because it needs every address reachable.
- **Default engine on a Docker-only machine:** here Docker is used; vks-airgap-cicd's `make deps`
  installs podman anyway, by its engine policy.

One thing was a defect, not a choice: vks-airgap-cicd's KinD teardown removed every
`cloud-provider-kind` and `kindccm-*` container on the host, including this project's. Its fix
is tracked in that repo.

## `vks/` — deploying this app to a VKS guest cluster

`vks/README.md` is an end-user runbook: build locally, push to Harbor, deploy to a named VKS
guest cluster. Proven end to end by running every block verbatim: Linux with podman and docker,
Linux arm64 with docker, and macOS (arm64) with podman and docker/Colima.

**Read `vks/HANDOFF.md` before changing anything under `vks/`** — it holds the resume point,
what is already measured, and the traps that have already been paid for.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
