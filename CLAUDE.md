# CLAUDE.md

## Project Overview

HTTP web server with Prometheus metrics written in Go. Serves a simple "Hello, World" page with Kubernetes downward API environment variables, a `/healthz` health check, and `/metrics` endpoint for Prometheus scraping.

## Tech Stack

- **Language**: Go (version from `go.mod`)
- **Framework**: `net/http` (standard library) + `prometheus/client_golang`
- **Container**: Docker multi-arch (`linux/amd64`, `linux/arm64`)
- **CI/CD**: GitHub Actions
- **Dependency Management**: Go modules, Renovate

## Build & Development

```bash
make build          # Build the Go binary
make test           # Run tests with coverage
make static-check   # Run all quality + security checks (lint, sec, vulncheck, secrets)
make format         # Auto-format Go source files
make ci             # Full local CI pipeline (format, static-check, test, build)
make ci-run         # Run GitHub Actions workflow locally via act
make run            # Run locally on port 8080
make image-build    # Build Docker image
make e2e            # Run e2e tests (KinD + MetalLB + curl checks)
make kind-delete    # Clean up KinD cluster
make release        # Create and push a new semver tag
make version        # Print current version tag
```

## CI/CD

### Workflows

| Workflow | File | Triggers | Purpose |
|----------|------|----------|---------|
| CI | `ci.yml` | push to main, tags `v*`, PRs | Lint, test, build, Docker image (tag-only) |
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual | Delete old workflow runs (retain 7 days, keep 5 minimum) and untagged container images |
| Claude Code | `claude.yml` | issue/PR comments, PR opens | Interactive Claude agent and automated PR review |
| Claude CI Fix | `claude-ci-fix.yml` | CI workflow failure on PRs | Auto-analyze and fix CI failures via Claude |

### CI Jobs

- **static-check**: All quality + security checks (`make static-check`: lint, sec, vulncheck, secrets) on ubuntu-latest
- **build**: Build (`make build`) after static-check passes
- **test**: Test with coverage (`make coverage-check`) after static-check passes (parallel with build)
- **build-oci-image**: Docker multi-arch build+push to GHCR (tag-gated, requires build+test to pass)

## Project Structure

- `main.go` -- Application entry point and HTTP handlers
- `Makefile` -- Build automation and CI targets
- `Dockerfile` -- Multi-stage Docker build (with `.dockerignore`)
- `k8s/golang-web.yaml` -- Kubernetes deployment manifest (with security context)
- `k8s/kind-config.yaml` -- KinD cluster configuration
- `k8s/metallb-config.yaml` -- MetalLB IP pool template
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Upgrade Backlog

- [ ] `munnerz/goautoneg` — bus factor of 1, no releases, last commit 2019. Monitor for a maintained fork if prometheus/common drops it.
- [ ] Run `go get -u ./... && go mod tidy` periodically to keep indirect deps fresh — Renovate handles direct deps but indirect-only bumps may lag.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
