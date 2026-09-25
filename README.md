[![CI](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/golang-web.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/golang-web/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/golang-web)

# HTTP web server with Prometheus metrics in Go

A Go HTTP server with Prometheus metrics, a health endpoint and Kubernetes pod identity,
packaged as a multi-arch image with a KinD end-to-end harness.

| Component | Technology |
|-----------|-----------|
| Language | Go 1.27.1 (pinned in `.mise.toml`, `go.mod`, `Dockerfile`) |
| HTTP | net/http (standard library) |
| Metrics | [prometheus/client_golang](https://github.com/prometheus/client_golang) v1.24.1 |
| Container | Built with podman or Docker; published multi-arch (linux/amd64, linux/arm64) |
| Toolchain | [mise](https://mise.jdx.dev/) (all tool versions pinned in `.mise.toml`) |
| Local Kubernetes | KinD + [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) |
| CI/CD | GitHub Actions, [Renovate](https://docs.renovatebot.com/) |

## Quick Start

```bash
make deps      # install the pinned toolchain (mise) and a container engine if none
make build     # build the Go binary
make test      # run tests with coverage
make run       # start the application on port 8080 (make run APP_PORT=9090 to change)
# Open http://localhost:8080
```

`make help` lists every target.

## Prerequisites

### Tested platforms

| OS | Architecture | Tested with |
|----|--------------|-------------|
| Ubuntu 24.04.5 LTS | x86_64 | GNU Make 4.3, Git 2.43.0, podman 4.9.3, Docker 29.8.1 (buildx 0.37.1), kubectl 1.37.1, kind 0.33.0 |
| macOS 26.6.2 | arm64 (Apple Silicon) | GNU Make 3.81 and 4.4.1, Git 2.55.0, podman 6.1.2, Docker 29.8.1 via Colima 0.10.3, kubectl 1.36.2, kind 0.33.0 |

### Install by hand

| Tool | Needed for |
|------|------------|
| [GNU Make](https://www.gnu.org/software/make/) | Every target |
| [Git](https://git-scm.com/) | Cloning, `make release` |
| [Podman](https://podman.io/) or [Docker](https://www.docker.com/) | Image targets. `make deps` installs podman if neither is present. |
| [Docker](https://docs.docker.com/get-docker/) | KinD targets and `make ci-run` (KinD and act run on Docker) |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | KinD and `k8s-*` targets |

Everything else (Go, linters, scanners, kind, act, Node) is pinned in [`.mise.toml`](.mise.toml)
and installed by `make deps`, which also installs mise into `~/.local/bin` if it is missing.
To use the pinned tools in your own shell (when `make deps` installed mise into `~/.local/bin`):

```bash
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc   # bash
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc     # zsh (macOS default)
```

### Settings

```bash
cp .env.example .env   # then uncomment and edit the settings you change
```

The Makefile reads `.env`. Your shell and the command line still win: command line
(`make run APP_PORT=9090`) > shell (even an exported empty value) > `.env` > default. `make check-env` fails if `.env.example`
misses a setting the code reads.

### Container engine

| You want | Run |
|---|---|
| The installed engine (podman if both are present) | `make image-build` |
| Docker for one command | `make image-build CONTAINER_ENGINE=docker` |
| Docker for the whole shell | `export CONTAINER_ENGINE=docker` |
| See which engine each target uses | `make engines` |

KinD always runs on Docker (`KIND_ENGINE`). `make kind-create` builds the app image with
`CONTAINER_ENGINE` and loads it into the cluster, whichever engine that is.

## Pushing an image

```bash
export REGISTRY_TOKEN=<credential>
make registry-login
make image-push OWNER=<your-namespace>
```

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE_REGISTRY` | `ghcr.io` | Target OCI registry |
| `OWNER` | `andriykalashnykov` | Namespace in the registry; the image is `IMAGE_REGISTRY/OWNER/golang-web` |
| `REGISTRY_USERNAME` | `OWNER` | Login user, where it differs from `OWNER` |
| `REGISTRY_TOKEN` | — | Registry credential (a GitHub PAT with `write:packages` for ghcr.io) |

The tag is the version in `version.txt`.

## Pinned versions

| Pinned in | What |
|---|---|
| [`.mise.toml`](.mise.toml) | Go, Node and every tool `make deps` installs |
| `Makefile` | cloud-provider-kind, PlantUML, C4-PlantUML, Renovate CLI |
| `Dockerfile` | Go builder and distroless base images (digest-pinned) |
| `version.txt` | Release version (written by `make release`) |

## Architecture

A statically linked Go binary in a distroless image, behind a LoadBalancer Service.

<p align="center"><img src="docs/diagrams/out/c4-container.png" alt="C4 Container diagram for golang-web" width="800"></p>

Source: [`docs/diagrams/c4-container.puml`](docs/diagrams/c4-container.puml); regenerate with `make diagrams`.

## Endpoints

| Path | Method | Purpose |
|------|--------|---------|
| `$APP_CONTEXT` (default `/`) | GET | Greeting page; echoes request headers and the Downward-API pod identity |
| `/healthz` | GET | Liveness/readiness probe — returns `{"health":"ok", "Version":…, "BuildTime":…}` |
| `/metrics` | GET | Prometheus exposition; counter key `request_count_promtotal` |
| `/shutdown` | any | Exits the process (`os.Exit(0)`). Unauthenticated: do not expose it outside a test cluster. |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Listen port | `8080` |
| `APP_CONTEXT` | Base context path | `/` |
| `MESSAGE_TO` | Noun in the greeting (`Hello, <MESSAGE_TO>`) | `World` |

### Kubernetes Downward API Variables

| Variable | Description |
|----------|-------------|
| `MY_NODE_NAME` | Name of Kubernetes node |
| `MY_POD_NAME` | Name of Kubernetes pod |
| `MY_POD_NAMESPACE` | Namespace of Kubernetes pod |
| `MY_POD_IP` | Kubernetes pod IP |
| `MY_POD_SERVICE_ACCOUNT` | Service account of Kubernetes pod |

## Container Image

Multi-arch (`linux/amd64`, `linux/arm64`), published to GHCR on tag builds.

```bash
podman pull ghcr.io/andriykalashnykov/golang-web:latest   # or: docker pull ...
```

## Local Kubernetes (KinD)

```bash
make e2e          # create a KinD cluster, deploy the app, run end-to-end checks
make kind-delete  # delete the cluster
```

## Deploy to Kubernetes with kubectl

[`k8s/golang-web.yaml`](k8s/golang-web.yaml) is a Deployment and a LoadBalancer Service. It passes Pod Security `restricted`.

```bash
NS=golang-web-demo
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NS" -f k8s/golang-web.yaml
kubectl rollout status -n "$NS" deployment/golang-web --timeout=120s
```

Open it. The page is served under `/myhello/` (the manifest sets `APP_CONTEXT`); `/` returns 404.

```bash
kubectl port-forward -n "$NS" svc/golang-web-service 8080:8080 >/dev/null & PF=$!
sleep 3                                # let the forward start listening
curl http://localhost:8080/myhello/    # "Hello, World" and MY_POD_NAMESPACE: golang-web-demo
curl http://localhost:8080/healthz
kill "$PF"
```

Linux only, once `EXTERNAL-IP` is assigned (on macOS the IP is not reachable from the host):

```bash
IP=$(kubectl get svc -n "$NS" golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl "http://$IP:8080/myhello/"
```

Remove everything:

```bash
kubectl delete namespace "$NS"
```

## CI/CD

| Workflow | Triggers | Jobs |
|----------|----------|------|
| [`ci.yml`](.github/workflows/ci.yml) | push to `main`, tags `v*`, pull requests | `static-check` (`make static-check`), then `build` and `test`; on tags, `docker` builds, scans and pushes the image |
| [`cleanup-runs.yml`](.github/workflows/cleanup-runs.yml) | weekly, manual | Deletes old workflow runs, caches and untagged images |

[Renovate](https://docs.renovatebot.com/) updates dependencies and automerges them.

## References

- [Docker 101: A Basic Web Server Displaying Hello World](https://ashishb.net/tech/docker-101-a-basic-web-server-displaying-hello-world/)
- [Creating a Simple Web Server with Go](https://tutorialedge.net/golang/creating-simple-web-server-with-golang/)
- [Kubernetes-Ready Service in Go](https://blog.gopheracademy.com/advent-2017/kubernetes-ready-service/)
- [How to Deploy a Go Web Application with Docker](https://semaphoreci.com/community/tutorials/how-to-deploy-a-go-web-application-with-docker)
- [Instrumenting an HTTP Server in Go — Prometheus](https://prometheus.io/docs/tutorials/instrumenting_http_server_in_go/)
