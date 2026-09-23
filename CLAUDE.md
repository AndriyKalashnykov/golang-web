# CLAUDE.md

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

```bash
make deps           # Install the pinned toolchain via mise (.mise.toml)
make build          # Build the Go binary
make test           # Run tests with coverage
make static-check   # All quality + security checks (check-toolchain-alignment, lint-ci, lint, sec, vulncheck, secrets, trivy-fs, trivy-config)
make format         # Auto-format Go source files
make ci             # Full local CI pipeline (deps, deps-verify, format, deps-prune-check, static-check, coverage-check, build)
make ci-run         # Run GitHub Actions workflow locally via act
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
| CI | `ci.yml` | push to main, tags `v*`, PRs (paths-ignore for docs/images), `workflow_call` | Lint, test, build, Docker image (tag-only) |
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual, `workflow_call` | Delete old workflow runs, stale caches, and untagged container images |

### CI Jobs

- **static-check**: All quality + security checks (`make static-check`: lint-ci, lint, sec, vulncheck, secrets, trivy-fs, trivy-config) on ubuntu-latest
- **build**: Build (`make build`) after static-check passes
- **test**: Test with coverage threshold (`make coverage-check`) after static-check passes (parallel with build)
- **build-oci-image**: Docker multi-arch build+push to GHCR (tag-gated, requires build+test to pass)

## Project Structure

- `main.go` -- Application entry point and HTTP handlers
- `go.mod` / `go.sum` -- Go module definition and checksums
- `Makefile` -- Build automation and CI targets
- `.golangci.yml` -- golangci-lint v2 configuration (linters, formatters, gocritic)
- `Dockerfile` -- Multi-stage Docker build (with `.dockerignore`)
- `k8s/golang-web.yaml` -- Kubernetes deployment manifest (with security context)
- `k8s/kind-config.yaml` -- KinD cluster configuration
- `.mise.toml` -- **tool version single source of truth** (Renovate-tracked)
- `.github/workflows/` -- CI and cleanup. The two Claude workflows are
  present but `.disabled` (see the Upgrade Backlog for why and how to restore)
- `.github/CODEOWNERS` -- Workflow file protection (requires owner review)
- `.trivyignore` -- Trivy suppression rules for K8s manifest findings
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Upgrade Backlog

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
guest cluster. Proven on Linux with podman and docker; the macOS half is verified by
`vks/macosx.sh`, which writes `vks/macosx.res`.

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
