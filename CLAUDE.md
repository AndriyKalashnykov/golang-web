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

- [x] **Signing proven on a real tag (2026-09-25).** A prerelease `v0.0.4-rc.1` ran the new
      sign-before-tag job end to end: `cosign verify` passed, the image was multi-arch, and
      `latest` did not move. The prerelease image (7 GHCR versions) and its git tag were deleted
      afterwards.
- [ ] **`0.0.3` / `latest` is still UNSIGNED.** It was published before the fix, and a signature
      needs GitHub OIDC, so only the next release produces a signed `latest`. Verify it with:
      ```
      cosign verify ghcr.io/andriykalashnykov/golang-web:<version-without-v> \
        --certificate-identity https://github.com/AndriyKalashnykov/golang-web/.github/workflows/ci.yml@refs/tags/<vX.Y.Z> \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com
      ```
- [ ] **Cleanup workflow re-enabled 2026-09-25** (it had been `disabled_inactivity`). Its first
      real run is the next Sunday: check the "Delete orphaned untagged container images" log.
      Dry run on 2026-09-25: the only orphan is `155cab…`, and KEEP_MINIMUM=5 keeps it.
- [ ] **Liveness restarts (fixed in #192): one part of the cause is unexplained.** The old pod's
      container was charged ~4.7 MB of the binary's code pages at start; a fresh pod ~2.7 MB.
      The 32Mi limit covers the worst case (~18 MB measured-plus-arithmetic). Kill path observed:
      memory limit + first GC + 10m CPU quota -> liveness timeouts (exit 143).
- [ ] **`make ci-run` on Apple Silicon runs linux/arm64 jobs, so it does not prove amd64.**
      Colima without Rosetta runs amd64 under qemu-user, where the Go toolchain panics
      (`growslice: len out of range`). `ACT_ARCH=linux/amd64` forces amd64 where it works.
- [ ] `check-env.sh` blind spots, listed in its header: multi-line getenv calls, keys held in
      constants, syscall.Getenv, aliased os imports, third-party env readers, un-`git add`ed files.
- [x] **Renovate is running again (2026-09-22).** It had been dormant since
      2026-04-08; the Dependency Dashboard's `updatedAt` started moving again
      on 2026-09-22 and PRs #121–#123 opened the same day. No repo-side change
      caused this and none was needed — the entry is kept so the next reader
      does not re-diagnose a dormancy that has ended.
- [ ] **`main` has NO branch protection, so automerge does not engage.**
      `gh api repos/.../branches/main/protection` -> 404 and
      `gh api repos/.../rulesets` -> 0, while the repo itself has
      `allow_auto_merge: true`. With no required checks a Renovate PR reaches
      `mergeStateStatus: CLEAN` immediately, GitHub's native auto-merge never
      engages (`autoMergeRequest: null` on every PR, measured), and the merge
      waits for Renovate's own next cycle. It is also the safety gap: automerge
      is only as safe as the checks it is *required* to wait for. Fix (owner
      decision — a repo-settings mutation):
      ```
      gh api -X PUT repos/AndriyKalashnykov/golang-web/branches/main/protection \
        -F required_status_checks.strict=true \
        -f 'required_status_checks.contexts[]=static-check' \
        -f 'required_status_checks.contexts[]=build' \
        -f 'required_status_checks.contexts[]=test' \
        -F enforce_admins=false -F required_pull_request_reviews=null -F restrictions=null
      ```
      Do NOT require `docker` — it is tag-gated (`if: startsWith(github.ref,
      'refs/tags/')`), so it reports `skipping` on every PR and would block them all.
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

## `vks/` — deploying this app to a VKS guest cluster

`vks/README.md` is an end-user runbook: build locally, push to Harbor, deploy to a named VKS
guest cluster. Proven end to end by running every block verbatim: Linux with podman and docker,
and macOS (arm64) with podman and docker/Colima.

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
