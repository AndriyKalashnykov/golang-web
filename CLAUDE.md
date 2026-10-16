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
make static-check   # All quality + security checks (check-env, check-image-pin, check-kind-kubeconfig, check-vks-docs, check-toolchain-alignment, lint-ci, lint, sec, vulncheck, secrets, trivy-fs, trivy-config, diagrams-check, scripts-test)
make check-env      # .env.example documents every setting the Makefile and Go code read
make check-image-pin  # every k8s/ pin of the image is a release: the registry tag names the digest, and cosign verify passes for this repo's v<version> release run (needs ghcr.io and Sigstore)
make check-kind-kubeconfig  # kind-*/e2e use only KIND_KUBECONFIG (~/.kube/kind-golang-web.yaml), never the ambient kubeconfig; reads `make -n`, starts nothing
make check-vks-docs # The vks/ guides: every `sh` block parses (bash, zsh), has an Expect, sources its env file; links resolve; prints "checked N block(s) in M file(s)"
make format         # Auto-format Go source files
make ci             # Full local CI pipeline (deps, deps-verify, format, deps-prune-check, static-check, coverage-check, build)
make ci-run         # Run GitHub Actions workflow locally via act (jobs in the Docker engine's arch; ACT_ARCH overrides)
make run            # Run locally on port 8080
make image-build    # Build Docker image
make image-smoke    # Check an image starts and keeps /shutdown closed by default (IMAGE_SMOKE_REF=<image>)
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
- **docker** (tags only, after build + test): Trivy image scan and smoke test (`make image-smoke`: fails if the image serves `/shutdown` by default), then push the multi-arch image BY DIGEST, `cosign sign` it, `cosign verify` it, and only then attach the release tags (`--dry-run` first confirms the tagged digest equals the signed one). `flavor: latest=auto`, so a prerelease tag does not move `latest`.

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
- `.github/scripts/` -- `check-env.sh`, `check-image-pin.sh` (the pinned image is a signed release, behind `make check-image-pin`), `check-kind-kubeconfig.sh`, `check-vks-docs.sh` (with its allowlist `check-vks-docs.allow` and its table of guides `check-vks-docs.blocks`: a new guide under `vks/` needs one line there), `ghcr-prune-untagged.sh` and `image-smoke.sh` (the image's `/shutdown` check behind `make image-smoke`), each with a `_test.sh`, and `k8s-context-guard_test.sh` (the `k8s-apply`/`k8s-delete` context guard), all run by `make scripts-test`
- `vks/test/` -- `walk.sh`, the harness that extracts and runs the guides' blocks (the gate uses its extractor), with `walk_test.sh`; `blocks_test.sh`, which runs blocks of the guides and the main guide's helper commands offline, in bash and zsh, against stand-in `curl` and `kubectl` (what vCenter answers a user without rights, `kubectl_install`, Headlamp's restart after a name change, the blocks that install one program without ever asking for a password); `mac-route.sh`, which makes the lab's addresses answer on a Mac behind the owner's reverse tunnels (`up`, `status`, `down`, `print-tunnel`) and removes only what it created, with `mac-route_test.sh`
- `.github/workflows/` -- CI and cleanup. The two Claude workflows are
  present but `.disabled` (see the Upgrade Backlog for why and how to restore)
- `.github/CODEOWNERS` -- Workflow file protection (requires owner review)
- `.trivyignore` -- Trivy suppression rules for K8s manifest findings
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Upgrade Backlog

- [ ] **`vks/` becomes one end-to-end story (owner, 2026-10-10): the plan and its ten phases
      are in [`vks/PLAN.md`](vks/PLAN.md). Built and merged; what is left is the "Not walked"
      list in `vks/HANDOFF.md`.** Use or create a vSphere Namespace and a guest
      cluster, install Harbor (manual and auto), add-ons (Headlamp, Istio), three ways to
      deploy the app, a doc gate and a committed walk harness. Work the phases in order;
      phase 1 is the gate and the harness.
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
- [x] **README walked on eight platforms, 2026-10-06** (README, Tested platforms). One clean pass
      each, every step matching its Expect text: Debian 12 and 13 on x86_64 and Ubuntu 24.04, 26.04,
      Debian 12, 13 on arm64 (new VMs, Docker only, 51 of 51 steps each), and macOS 26.6.1 with
      podman (40 of 40) and with Docker through Colima (51 of 51). A pty harness pasted each block
      into an interactive shell (the default login zsh on macOS) and judged it by its Expect lines.
      The harness (four versions of `walk.py`) and its logs are one archive on the owner's
      workstation, `~/.cache/gw-readme-walks-2026-10-06.tar.gz`; they are not in the repo.
      Not exercised anywhere: a sudo password prompt, ghcr.io (the push ran against a registry on
      the same machine), push steps 1 and 5, `make release`, running the other-architecture image.
      Not exercised on macOS: a bare Mac (Homebrew, kubectl and both engine VMs existed), the
      Homebrew installer, a fresh `go test` (the result was cached), any section in a terminal
      without mise activated, podman building for a Docker-run KinD.
      What the walks needed that the README does not contain: Git removed from the Ubuntu arm64
      images first; subuid/subgid ranges for the Lima user before the podman pushes.
      Seen: on macOS `make e2e` publishes port 8080 on every interface, and a second LoadBalancer
      Service stays pending (the backlog entry below). On arm64, podman 5.4.2 and 5.7.0 each pushed
      a two-platform index. On Debian 13, 5.4.2's first builds failed in runc (no systemd user
      session) while a session from boot was still alive, which the test VM itself kept; a plain
      log out and back in on a normal machine is untested, so the README gives no remedy.
      One lesson for the next walk: `/tmp` on the workstation is RAM. VM disks put there filled it
      and the lab VM was OOM-killed; keep them under `~/.cache`.
      How the rows of the README's *Tested platforms* table were produced (this text stood in
      the README until 2026-10-08; the owner wants no test log in user-facing docs):
      The table's last column was cut to plain facts the same day. What it said per row and no
      longer does: Debian 13.7 x86_64 was two machines (Docker only; then podman as the default
      with Docker also installed). Ubuntu 24.04.4 arm64: `make image-push` with podman refused
      as documented. Debian 12.15 arm64: it stopped at `'podman buildx' is not available`.
      Debian 13.6 arm64: it failed twice in runc and pushed once every session of the user had
      ended. macOS 26.6.1: the Homebrew installer was not run; with Colima stopped `make e2e`
      and `make ci-run` stopped at `docker is installed but not running`.

      The Debian rows and the arm64 rows are from 2026-10-06: each is one pass on a new virtual
      machine (the arm64 ones on an Apple silicon Mac; the Ubuntu images came with Git and curl, and
      Git was removed first), at commit `29c7329`, with every step matching its Expect text. In those
      walks sudo never asked for a password. The push section ran steps 2 to 4 against a registry on
      the same machine, not ghcr.io; steps 1 and 5 were not run, and the image for the other
      architecture was pushed but not run. `make release` was not run.

      The macOS 26.6.1 row is from 2026-10-06: one pass per engine, each block pasted into the default
      login zsh, at commits `29c7329` (podman) and `5de2e22` (Docker). The Mac already had Homebrew,
      kubectl and both engines with their virtual machines created (one running at a time), so the
      install blocks were re-runs; sudo did not ask for a password, and `make test` printed Go's
      cached result. The push section ran steps 2 to 4 against a registry on the same Mac; steps 1
      and 5 and `make release` were not run, and the amd64 image was pushed but not run. Every section
      after the mise line ran in a terminal with mise activated. The macOS 26.6.2 row is an earlier
      Mac that no longer exists.
- [x] **`/shutdown` closed in a published image: v0.0.5, 2026-10-15.** `main.go` registers it only
      when `ENABLE_SHUTDOWN` is exactly `true`. Run on amd64 with docker: unset, `1`, `TRUE`,
      `" true"` and 8 path variants (`/shutdown/`, `//shutdown`, `/%73hutdown`, ...) all reach the
      catch-all page and the container keeps running; `ENABLE_SHUTDOWN=true` stops it.
      `make image-smoke` passes on podman and docker.
      arm64 was compared statically (same Go, ldflags and gate strings), not run.
      `k8s/golang-web.yaml` pins 0.0.5. Images 0.0.4 and older still serve it; a cluster given one
      keeps it until the manifest is applied again. Guarded from now on by `make image-smoke`
      in the tag-only `docker` job (two containers: a control with `ENABLE_SHUTDOWN=true` must
      exit, the image's defaults must not); it first runs in CI on the next tag.
- [x] **A release tag deploys the release before it: documented "deploy `main`" (owner,
      2026-10-16).** `make release` tags the commit that bumps `version.txt`; the image exists
      only after the tag's CI run (~8 min), so `k8s/golang-web.yaml` names it in a later commit.
      Since v0.0.4, `git show <tag>:k8s/golang-web.yaml`: `v0.0.5` -> 0.0.4, `v0.0.4` -> 0.0.3
      (`v0.0.3` sits on 8fdc867, a later commit that bumps Renovate's pin, and names `v0.0.1`,
      a tag that never existed). No process change: the README
      (*Deploy the published image*, the `make release` row) and `vks/ARGOCD-app.md` (*Which image
      runs*, the `APP_REVISION` row) say deploy `main` or a commit of it, never a tag, and check the
      running image. Every documented default already reads `main`. Only `v0.0.5` has
      `k8s/kustomization.yaml`, so it is the one tag the guide's (kustomize) Application can
      deploy, and it deploys 0.0.4.
      **The window:** `main` also names the previous release until the pin commit lands. Measured:
      v0.0.4 12 min (Renovate #234); v0.0.5 3.5 h (Renovate proposed it after 3 h, the pin was
      moved by hand in #351); v0.0.3 ~5.5 months (Renovate dormant; fixed by hand in #175,
      2026-09-24). No bound; user docs quote none.
      **Maintainer action after every release (since 2026-10-16):** merge Renovate's
      `golang-web image` PR once the tag's image is published and its `static-check` is green
      (`make check-image-pin` there proves the pin is the release). It no longer merges itself, so
      the window above now lasts until that merge; for a security release do it at once, or move
      the pin by hand as #351 did.
      **Why it is not automerged:** Renovate tracks registry tags, not releases. #305 proposed a
      `0.0.5` tag on 2026-10-08, a week before the release, with automerge on; it auto-closed and
      was reopened after the release. GHCR has no version from that week now, so such a tag was
      pushed and deleted. The cause is unverified (the Mend log linked in #305 would settle it);
      a plain `make image-push` pushes `version.txt`'s value, `v0.0.4` then (with the `v`), so
      not that without a `VERSION=` override. `renovate.json`
      gives the self-image its own group with `automerge: false` (owner, 2026-10-16). That moves the
      decision to a person, and `make check-image-pin` (in `static-check`, required) now reads the
      pin: for every pin of the image in tracked `k8s/**/*.y{a,}ml` (a line naming the image that
      does not parse fails), the registry tag must still name the pinned digest (`crane digest`),
      and `cosign verify` must pass with the exact identity of this repo's release run for
      `refs/tags/v<version>`, on a push, from this repository (`--certificate-github-workflow-*`:
      ci.yml has `workflow_call`, so the identity alone would not bind the calling repository).
      Measured 2026-10-16, cosign 3.1.3 and crane 0.22.1 against ghcr.io: 0.0.5 and 0.0.4 pass;
      0.0.4's digest pinned as 0.0.5 fails on the tag; unsigned 0.0.3 fails ("no signatures
      found"); identity `andriykalashnykov/...` (lowercase) or another repository fails; 0.0.4's
      digest verified as v0.0.5 fails in cosign itself ("expected SAN value"). Sigstore's TUF CDN
      unreachable (proxy to a dead port, empty HOME) is reported as infrastructure after
      `IMAGE_PIN_TRIES`, not as a bad pin; an outage turns `static-check` red on every PR (merge
      with `--admin` after reading the message, but never the `golang-web image` PR: rerun its
      `static-check` until `check-image-pin` reaches a verdict). Not guarded: a PR that also edits the script or
      the Makefile (it runs the PR's copy); a signed digest whose tag later moves to it. Two cosign
      versions: the check uses `.mise.toml`'s, the `docker` job signs with cosign-installer's
      default (3.0.6 at v4.1.2); both verified both releases' signatures, but nothing keeps them
      aligned.
      **An age wait cannot guard it (measured 2026-10-16, renovate 44.155.3, debug lookups with the
      pin set back to 0.0.4):** ghcr.io gives Renovate no release time. With any
      `minimumReleaseAge` (1 hour tried) and the default `minimumReleaseAgeBehaviour:
      timestamp-required`, 0.0.5 stayed "pending, no releaseTimestamp" for ever; without the rule it
      was proposed. With `timestamp-optional` the wait is skipped, a no-op. The same hold had frozen
      two tool bumps under the "Tool versions" 3-day rule: cloud-provider-kind 0.12.0
      (registry.k8s.io, released 2026-10-02) and govulncheck 1.9.0 (2026-10-11); no PR had opened.
      Both age rules (majors, Tool versions) now set `timestamp-optional`, so a dep with no release
      time gets no wait; a lookup showed both bumps proceed while golangci-lint 2.15.0 and trivy
      0.76.0 (under 3 days old) are still held. `make renovate-validate` does not check that
      option's value (a misspelling passes); only a lookup proves it. The aqua guard is weaker
      than its description once was: Renovate dates a GitHub tag by the later of its tag time
      (a lightweight tag's commit date) and its Release's publish time, so a lightweight tag on an
      older commit, looked up before its Release exists, can pass the 3 days at once.
- [x] **`BuildTime` in released images (#247): proven on v0.0.5.** Its `/healthz` reports
      `"BuildTime":"2026-10-15T23:28:57.909Z"` (0.0.4 reported `"now"`).
- [ ] **macOS, local KinD cluster: a second LoadBalancer Service never gets its address.**
      cloud-provider-kind publishes Services on host port 8080 there, the e2e Service holds it,
      and deleting the second Service's namespace then waits forever on its finalizer (measured:
      killed after 5 min; `make kind-delete` clears it). The README tells macOS readers to skip
      the namespace delete. Not fixed in the Makefile.
- [ ] **One swallowed Ctrl-C on the Mac:** a Ctrl-C sent while `make run` was still starting did
      not stop it; a later one did. Seen once in the second walk, not reproduced. The 2026-10-06 walks
      sent 26 Ctrl-C to running foreground steps and each stopped on the first, but always a few
      seconds after start: a Ctrl-C during start-up, the case seen, was not sampled.
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
- [x] **`latest` is signed: v0.0.4 released 2026-10-01.** `0.0.4` (and, until v0.0.5, `0.0`, `0` and
      `latest`) is `sha256:a7df346e...69eec` (amd64 + arm64), and
      `cosign verify` passes for it and fails for a wrong tag identity. `0.0.3` stays unsigned.
      Verify any release with:
      ```
      cosign verify ghcr.io/andriykalashnykov/golang-web:<version-without-v> \
        --certificate-identity https://github.com/AndriyKalashnykov/golang-web/.github/workflows/ci.yml@refs/tags/<vX.Y.Z> \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com
      ```
      `k8s/golang-web.yaml` pinned `0.0.4@sha256:a7df346e...` (Renovate, #234) until v0.0.5.
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

One thing was a defect, not a choice, and is fixed there (2026-10-06): its KinD teardown removed
every `cloud-provider-kind` and `kindccm-*` container on the host, including this project's, and its
bring-up replaced a running controller without a word (vks-airgap-cicd #1367 and #1369). Measured
with both clusters up on Linux: this project keeps its LoadBalancer address through both.

## `vks/` — deploying this app to a VKS guest cluster

`vks/README.md` is the main line of an end-user guide: log in, check the vSphere Namespace and
the guest cluster, deploy the published image, reach it. Around it, each area has a chooser
("Use or create/install …"), a by-hand guide for the vSphere Client and a scripted one:
`NAMESPACE*.md`, `CLUSTER*.md`, `HARBOR*.md`, `ARGOCD*.md`. `REGISTRY.md` builds and pushes to
Harbor, `ARGOCD-app.md` deploys the app with ArgoCD, and `vks/addons/` holds the guest-cluster
add-ons (cert-manager, Headlamp, Istio). What was run where, and what was not, is in
`vks/HANDOFF.md`, "The files".

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
