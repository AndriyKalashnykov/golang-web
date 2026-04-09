[![CI](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/golang-web.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/golang-web/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/golang-web)

# HTTP web server with Prometheus metrics in Go

HTTP web server running by default on port 8080, intended for testing. Features Prometheus formatted metrics at `/metrics` with key `request_count_promtotal` using [prometheus/client_golang](https://github.com/prometheus/client_golang), and a Kubernetes compatible health check at `/healthz`.

| Component | Technology |
|-----------|-----------|
| Language | Go (see `go.mod` for version) |
| HTTP | net/http (standard library) |
| Metrics | [prometheus/client_golang](https://github.com/prometheus/client_golang) v1.23+ |
| Container | Docker multi-arch (linux/amd64, linux/arm64) |
| Orchestration | Kubernetes |
| CI/CD | GitHub Actions, [Renovate](https://docs.renovatebot.com/) |
| Code Quality | golangci-lint, gosec, govulncheck, gitleaks, Trivy |

## Quick Start

```bash
make deps      # check required dependencies
make build     # build the Go binary
make test      # run tests with coverage
make run       # start the application on port 8080
# Open http://localhost:8080
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [GNU Make](https://www.gnu.org/software/make/) | 3.81+ | Build orchestration |
| [Git](https://git-scm.com/) | 2.0+ | Version control |
| [Go](https://go.dev/dl/) | See `go.mod` | Language runtime and compiler |
| [Docker](https://www.docker.com/) | latest | Container image builds |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | latest | Kubernetes deployment (optional) |
| [KinD](https://kind.sigs.k8s.io/) | 0.31.0 | Local Kubernetes testing (optional, auto-installed by `make deps-kind`) |
| [Trivy](https://trivy.dev/) | 0.69.3 | K8s manifest security scanning (auto-installed by `make deps-trivy`) |

Install all required dependencies:

```bash
make deps
```

## Available Make Targets

Run `make help` to see all available targets.

### Setup

| Target | Description |
|--------|-------------|
| `make help` | List available tasks |
| `make deps` | Check and install required dependencies |
| `make deps-act` | Install act for local CI runs |
| `make deps-hadolint` | Install hadolint for Dockerfile linting |
| `make deps-shellcheck` | Install shellcheck for shell script linting |
| `make deps-trivy` | Install Trivy for security scanning |

### Build & Run

| Target | Description |
|--------|-------------|
| `make build` | Build the Go binary |
| `make run` | Run the application locally |
| `make test` | Run tests with coverage |
| `make format` | Auto-format Go source files |
| `make clean` | Remove Docker image and build artifacts |
| `make update` | Update dependency packages to latest versions |

### Quality & Security

| Target | Description |
|--------|-------------|
| `make static-check` | Run all quality and security checks |
| `make lint` | Run static analysis |
| `make trivy-fs` | Scan filesystem for vulnerabilities, secrets, and misconfigurations |
| `make lint-ci` | Lint GitHub Actions workflows |
| `make sec` | Run security scanner |
| `make vulncheck` | Check for known vulnerabilities in dependencies |
| `make secrets` | Scan for hardcoded secrets |
| `make trivy-config` | Scan K8s manifests for security misconfigurations |
| `make coverage-check` | Verify test coverage meets threshold |

### Docker

| Target | Description |
|--------|-------------|
| `make image-build` | Build Docker image |
| `make image-test-fg` | Run container in foreground with test overrides |
| `make image-test-cli` | Run container with shell entrypoint |
| `make image-run-bg` | Run container in background |
| `make image-cli-bg` | Get shell in running background container |
| `make image-logs` | Tail container logs |
| `make image-stop` | Stop background container |
| `make image-push` | Push image to Docker Hub |

### Kubernetes

| Target | Description |
|--------|-------------|
| `make k8s-apply` | Deploy to Kubernetes cluster |
| `make k8s-delete` | Delete from Kubernetes cluster |
| `make deps-kind` | Install KinD for local Kubernetes testing |
| `make kind-create` | Create local KinD cluster with MetalLB |
| `make kind-deploy` | Deploy application to KinD cluster and wait for rollout |
| `make kind-undeploy` | Remove application from KinD cluster |
| `make kind-delete` | Delete KinD cluster |
| `make e2e` | Run end-to-end tests against KinD cluster |

### CI

| Target | Description |
|--------|-------------|
| `make ci` | Run full local CI pipeline |
| `make ci-run` | Run GitHub Actions workflow locally using [act](https://github.com/nektos/act) |

### Utilities

| Target | Description |
|--------|-------------|
| `make release` | Create and push a new tag |
| `make version` | Print current version (tag) |
| `make deps-prune` | Remove unused dependencies |
| `make deps-prune-check` | Verify no prunable dependencies (CI gate) |
| `make renovate-bootstrap` | Install nvm and Node.js for Renovate |
| `make renovate-validate` | Validate Renovate configuration |

## CI/CD

### Workflows

| Workflow | File | Triggers | Purpose |
|----------|------|----------|---------|
| CI | `ci.yml` | push to main, tags `v*`, PRs (paths-ignore for docs/images), `workflow_call` | Lint, test, build, Docker image (tag-only) |
| Cleanup | `cleanup-runs.yml` | Weekly (Sunday midnight), manual, `workflow_call` | Delete old workflow runs, stale caches, and untagged images |
| Claude Code | `claude.yml` | issue/PR comments, PR review, PR opens/sync/ready, issues opened/assigned, `workflow_call` | Interactive Claude agent and automated PR review |
| Claude CI Fix | `claude-ci-fix.yml` | CI workflow failure on PRs (via `workflow_run`) | Auto-analyze and fix CI failures via Claude |

### CI Jobs

| Job | Runs after | Steps |
|-----|------------|-------|
| **static-check** | — | Lint (CI + code + Dockerfile), security scan, vulnerability check, secrets scan, filesystem scan (Trivy), K8s manifest scan (Trivy) |
| **build** | static-check | Build Go binary |
| **test** | static-check | Test with coverage |
| **build-oci-image** | build + test (tags only) | Docker multi-arch build+push to GHCR |

### Required Secrets

| Name | Type | Used by | How to obtain |
|------|------|---------|---------------|
| `ANTHROPIC_API_KEY` | Secret | claude-interactive, claude-pr-review, claude-ci-fix | [Anthropic Console](https://console.anthropic.com/) — create an API key |
| `CLAUDE_CONFIG_TOKEN` | Secret | claude-interactive, claude-pr-review, claude-ci-fix | GitHub PAT with `repo` scope to read the private [claude-config](https://github.com/AndriyKalashnykov/claude-config) repo |

Set secrets via **Settings > Secrets and variables > Actions > New repository secret**.

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Listen port | `8080` |
| `APP_CONTEXT` | Base context path | `/` |

### Kubernetes Downward API Variables

| Variable | Description |
|----------|-------------|
| `MY_NODE_NAME` | Name of Kubernetes node |
| `MY_POD_NAME` | Name of Kubernetes pod |
| `MY_POD_NAMESPACE` | Namespace of Kubernetes pod |
| `MY_POD_IP` | Kubernetes pod IP |
| `MY_POD_SERVICE_ACCOUNT` | Service account of Kubernetes pod |

## Pulling Image from GitHub Container Registry

```bash
docker pull ghcr.io/andriykalashnykov/golang-web:latest
```

## References

- [Docker 101: A Basic Web Server Displaying Hello World](https://ashishb.net/tech/docker-101-a-basic-web-server-displaying-hello-world/)
- [Creating a Simple Web Server with Go](https://tutorialedge.net/golang/creating-simple-web-server-with-golang/)
- [Kubernetes-Ready Service in Go](https://blog.gopheracademy.com/advent-2017/kubernetes-ready-service/)
- [How to Deploy a Go Web Application with Docker](https://semaphoreci.com/community/tutorials/how-to-deploy-a-go-web-application-with-docker)
- [Instrumenting an HTTP Server in Go — Prometheus](https://prometheus.io/docs/tutorials/instrumenting_http_server_in_go/)
