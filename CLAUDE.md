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
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual | Delete old workflow runs (retain 7 days, keep 5 minimum) |

### CI Jobs

- **static-check**: All quality + security checks (`make static-check`: lint, sec, vulncheck, secrets) on ubuntu-latest
- **build**: Build (`make build`) after static-check passes
- **test**: Test with coverage (`make test`) after static-check passes (parallel with build)
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

Items not immediately actionable — review on next upgrade cycle:

- [ ] **`golang/protobuf` deprecated transitive dep** — `github.com/golang/protobuf v1.5.0` (in go.sum, not go.mod) is deprecated in favor of `google.golang.org/protobuf`. Not directly actionable; will be removed when `prometheus/client_golang` drops it. Monitor upstream.
- [ ] **Deep transitive dep updates** — `golang.org/x/net` v0.48→v0.52, `golang.org/x/oauth2` v0.34→v0.36, `golang.org/x/sync` v0.17→v0.20, `golang.org/x/text` v0.32→v0.35, `klauspost/compress` v1.18.0→v1.18.5 are in go.sum but not go.mod. Not directly upgradeable; will update when `prometheus/client_golang` or `prometheus/common` release new versions pulling them.
- [ ] **NODE_VERSION := 24** — Node.js v26 becomes LTS in October 2026. Bump `NODE_VERSION` in Makefile when v26 LTS is released.
- [ ] **Dockerfile builder digest** — `golang:1.26.1` digest may drift over time (tag is mutable for security patches). Renovate handles this via the `dockerfile` manager; verify Renovate PRs are not blocked.
- [ ] **Distroless variant** — Currently `gcr.io/distroless/static:nonroot` (PR #107 changes to `static-debian12:nonroot` for explicit OS tracking). If `static-debian12` is merged, monitor Debian 12 EOL (expected ~2028).

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.yml` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
