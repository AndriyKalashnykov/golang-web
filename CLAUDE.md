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
| Claude Code | `claude.yml` | issue/PR comments, PR review, PR opens/sync/ready, issues opened/assigned, `workflow_call` | Interactive Claude agent and automated PR review |
| Claude CI Fix | `claude-ci-fix.yml` | `workflow_run` on CI completion (filtered to PR failures) | Auto-analyze and fix CI failures via Claude |

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
- `.github/workflows/` -- CI, cleanup, Claude, and Claude CI fix workflows
- `.github/CODEOWNERS` -- Workflow file protection (requires owner review)
- `.trivyignore` -- Trivy suppression rules for K8s manifest findings
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Upgrade Backlog

- [ ] **Renovate is not running** — the Mend GitHub App has not run since
      2026-04-08 (Dependency Dashboard frozen, last bot PR #104 on
      2026-04-03, zero `renovate/*` branches). Every dependency is unmanaged
      and all `renovate.json` config is inert until it is reinstalled at
      <https://github.com/apps/renovate> (check the repo's status at
      developer.mend.io). **This fix is external — it cannot be done from the
      repo.** Until then, "Renovate will handle it" is false for this repo.
      Verify recovery: the dashboard's `updatedAt` starts moving again.
- [ ] **`CLAUDE_CONFIG_TOKEN` is expired — `claude.yml` fails on every run.**
      The "Setup Claude config" step checks out the private
      `AndriyKalashnykov/claude-config` repo and gets `Bad credentials`, so
      both `claude-pr-review` and `claude-interactive` are dead. The secret
      exists but was last set 2026-04-09; the failures begin 2026-07-01,
      consistent with a 90-day PAT expiry. Confirmed pre-existing: 4 of 4
      runs of that workflow have failed since 2026-07-01, on branches
      unrelated to any current work. **External fix** — regenerate the PAT
      (needs `repo` scope to read the private config repo) and update the
      secret. Consider a longer expiry or a GitHub App token so it stops
      silently lapsing.
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

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
