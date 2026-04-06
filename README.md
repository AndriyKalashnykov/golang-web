[![CI](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/golang-web.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/golang-web/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/golang-web)

# HTTP web server with Prometheus metrics in Go

HTTP web server running by default on port 8080, intended for testing. Features Prometheus formatted metrics at `/metrics` with key `total_request_count` using [prometheus/client_golang](https://github.com/prometheus/client_golang), and a Kubernetes compatible health check at `/healthz`.

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
| [Go](https://go.dev/dl/) | 1.26+ | Language runtime and compiler |
| [Docker](https://www.docker.com/) | latest | Container image builds |
| [staticcheck](https://staticcheck.dev/) | latest | Static analysis |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | latest | Kubernetes deployment (optional) |

Install all required dependencies:

```bash
make deps
```

## Available Make Targets

Run `make help` to see all available targets.

### Build & Run

| Target | Description |
|--------|-------------|
| `make build` | Build the Go binary |
| `make run` | Run the application locally |
| `make test` | Run tests with coverage |
| `make lint` | Run static analysis |
| `make clean` | Remove Docker image |
| `make update` | Update dependency packages to latest versions |

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

### CI

| Target | Description |
|--------|-------------|
| `make ci` | Full CI pipeline: lint, test, build |
| `make ci-run` | Run GitHub Actions workflow locally via [act](https://github.com/nektos/act) |

### Utilities

| Target | Description |
|--------|-------------|
| `make release` | Create and push a new semver tag |
| `make version` | Print current version (tag) |
| `make renovate-validate` | Validate Renovate configuration |

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

## CI/CD

GitHub Actions runs on every push to `main`, tags `v*`, and pull requests.

| Job | Triggers | Steps |
|-----|----------|-------|
| **ci** | push, PR, tags | Lint, Test, Build |
| **build-oci-image** | tags only | Docker multi-arch build+push to GHCR |
| **cleanup** | Weekly (Sunday) | Delete old workflow runs (retain 7 days, keep 5 minimum) |

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled.

## References

- https://ashishb.net/tech/docker-101-a-basic-web-server-displaying-hello-world/
- https://tutorialedge.net/golang/creating-simple-web-server-with-golang/
- https://blog.gopheracademy.com/advent-2017/kubernetes-ready-service/
- https://semaphoreci.com/community/tutorials/how-to-deploy-a-go-web-application-with-docker
- https://prometheus.io/docs/tutorials/instrumenting_http_server_in_go/
