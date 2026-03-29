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
make lint           # Run staticcheck
make ci             # Full local CI pipeline (deps, lint, build, test)
make run            # Run locally on port 8080
make image          # Build Docker image
make release        # Create and push a new semver tag
make version        # Print current version tag
```

## CI/CD

### Workflows

| Workflow | File | Triggers | Purpose |
|----------|------|----------|---------|
| CI | `ci.yml` | push to main, tags `v*`, PRs | Lint (staticcheck), build, test, Docker image (tag-only) |
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual | Delete old workflow runs (retain 7 days, keep 5 minimum) |

### CI Jobs

- **staticcheck**: Static analysis via `dominikh/staticcheck-action`
- **tests**: `make test` on ubuntu-latest
- **builds**: `make build` on ubuntu-latest
- **build-oci-image**: Docker multi-arch build+push to GHCR (tag-gated)

## Project Structure

- `main.go` -- Application entry point and HTTP handlers
- `Makefile` -- Build automation and CI targets
- `Dockerfile` -- Multi-stage Docker build
- `golang-web.yaml` -- Kubernetes deployment manifest
- `renovate.json` -- Renovate dependency update configuration
- `version.txt` -- Current release version

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.yml` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
