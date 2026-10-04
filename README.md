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

## Install the prerequisites

Most tools are installed for you by `make deps`, the first command in
[Run it locally](#run-it-locally). You install only the few below yourself, because `make deps`
cannot run without them.

### Install these yourself first

| Tool | Needed for |
|------|------------|
| [GNU Make](https://www.gnu.org/software/make/) | Every command on this page, including `make deps` |
| [Git](https://git-scm.com/) | Cloning the repository |
| [curl](https://curl.se/) | `make deps` uses it to download mise. Not preinstalled on Ubuntu. |
| [Homebrew](https://brew.sh) (macOS only) | `make deps` uses it to install podman |

On Ubuntu or Debian:

```bash
sudo apt-get update
sudo apt-get install -y make git curl
```

macOS already has curl; make and Git come with Apple's command line tools. If you install
Homebrew, its installer adds these tools for you and you can skip this command:

```bash
xcode-select --install
```

Expect a dialog asking to install the tools, or
`xcode-select: note: Command line tools are already installed` if you have them.

Do not install make with Homebrew: it installs GNU Make under the name `gmake`, so `make`
would still not exist.

### What `make deps` installs for you

You do not install these. `make deps` does, into your home directory, and it is safe to run
again at any time:

| Tool | Notes |
|------|-------|
| [mise](https://mise.jdx.dev/) | Goes into `~/.local/bin`. It installs the rest of this table. |
| Go, the linters and scanners, kind | The versions pinned in [`.mise.toml`](.mise.toml) |
| [Podman](https://podman.io/) | Only when neither podman nor Docker is installed. On Ubuntu or Debian this runs `sudo apt-get` and asks for your password. To install it yourself instead, see [podman's instructions](https://podman.io/docs/installation). |

### Install these yourself only for the Kubernetes sections

`make deps` does not install these two. Skip them if you only build and run the app or its
image.

| Tool | Needed for | How to install |
|------|------------|----------------|
| Docker | The local Kubernetes cluster. KinD needs Docker, even when you build images with podman. | Linux: Docker's instructions for [Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Debian](https://docs.docker.com/engine/install/debian/) or [another distribution](https://docs.docker.com/engine/install/). macOS: the block below. |
| kubectl | The two Kubernetes sections and step 5 of the push section | Kubernetes' instructions for [Linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) or [macOS](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/) |

Docker on macOS, with [Colima](https://github.com/abiosoft/colima), which runs the Docker
engine in a small virtual machine:

```bash
brew install colima docker docker-buildx
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
colima start
docker context use colima
docker buildx version
```

Expect `Current context is now "colima"` and a last line starting `github.com/docker/buildx`.

### Start the container engine on macOS

On macOS the container engine runs in a virtual machine that must be running before any image
or cluster command. After a restart of the Mac, start it again: `podman machine start` for
podman (run `podman machine init` once before the first start), `colima start` for Docker.

### Tested platforms

| OS | Architecture | Tested with |
|----|--------------|-------------|
| Ubuntu 24.04.5 LTS | x86_64 | GNU Make 4.3, Git 2.43.0, podman 4.9.3, Docker 29.8.1 (buildx 0.37.1), kubectl 1.37.1, kind 0.33.0 |
| Ubuntu 26.04.1 LTS | x86_64 | GNU Make 4.4.1, Git 2.53.0, podman 5.7.0, Docker 29.8.1, kubectl 1.37.1, kind 0.33.0 |
| macOS 26.6.2 | arm64 (Apple Silicon) | GNU Make 3.81 and 4.4.1, Git 2.55.0, podman 6.1.2, Docker 29.8.1 via Colima 0.10.3, kubectl 1.36.2, kind 0.33.0 |
| macOS 26.6.1 | arm64 (Apple Silicon) | GNU Make 3.81, Git 2.50.1, podman 6.1.3, Docker 29.8.2 via Colima 0.10.3, kubectl 1.36.2, kind 0.33.0 |

### Choose podman or Docker

The image commands use podman when both are installed.

| You want | Do this |
|---|---|
| The default engine | Nothing |
| Docker for one command | Add `CONTAINER_ENGINE=docker` to it, as in `make engines CONTAINER_ENGINE=docker` |
| Docker for every command in this terminal | `export CONTAINER_ENGINE=docker` |
| See which engine is used | `make engines` |

## Run it locally

Needs make, git and curl; see [Install these yourself first](#install-these-yourself-first).

```bash
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
make deps
make build
make test
make run
```

| Command | What it does |
|---|---|
| `make deps` | Installs the tools listed in [What `make deps` installs for you](#what-make-deps-installs-for-you). The first run downloads them; later runs print one line. |
| `make build` | Builds the Go binary `manager`. |
| `make test` | Runs the tests with coverage. |
| `make run` | Starts the app on port 8080 and keeps running. |

Expect `make run` to end with these lines (each after a timestamp) and stay in the foreground:

```text
Starting web server on port 8080
Open http://localhost:8080/
```

Open <http://localhost:8080>; [Endpoints](#endpoints) shows the page. Press Ctrl-C to stop the
app; the `make: *** [run] Error` line it leaves is normal. If port 8080 is taken, use another:
`make run APP_PORT=9090`.

`make help` lists every target.

### Use the pinned tools at your own prompt

Optional, and only after `make deps` has run: the `make` commands find the pinned tools by
themselves. To also use them (`go`, `kind` and the rest) at your own prompt, run the line for
your shell once, then open a new terminal.

zsh (the macOS default):

```bash
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
```

bash:

```bash
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
```

Expect `go version` in the repo directory to print `go1.27.1`.

## Architecture

A statically linked Go binary in a distroless image, behind a LoadBalancer Service.

<p align="center"><img src="docs/diagrams/out/c4-container.png" alt="C4 Container diagram for golang-web" width="800"></p>

## Endpoints

| Path | Method | Purpose |
|------|--------|---------|
| `/` | GET | Main page, plain text: `Hello, World`, a request counter, and the pod's node, name, namespace, IP and service account (`empty` outside Kubernetes). Set `APP_CONTEXT` to serve it on another path. |
| `/healthz` | GET | Liveness/readiness probe — returns `{"health":"ok", "Version":…, "BuildTime":…}` (both empty under `make run`; set by `make build` and the image) |
| `/metrics` | GET | Prometheus exposition; counter key `request_count_promtotal` |
| `/shutdown` | any | Exits the process (`os.Exit(0)`). Unauthenticated: do not expose it outside a test cluster. |

The main page under `make run`:

```text
Hello, World
request 0 GET /
Host: localhost:8080
MY_NODE_NAME: empty
MY_POD_NAME: empty
MY_POD_NAMESPACE: empty
MY_POD_IP: empty
MY_POD_SERVICE_ACCOUNT: empty
```

## Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Listen port, when you run the binary or the container yourself. With `make run`, set `APP_PORT` instead; `make run` sets `PORT` from it. | `8080` |
| `APP_CONTEXT` | Path the main page is served on, for example `/myhello/` | `/` |
| `MESSAGE_TO` | Noun in the greeting (`Hello, <MESSAGE_TO>`) | `World` |

Kubernetes sets these five from the pod (the Downward API); the main page prints them:

| Variable | Description |
|----------|-------------|
| `MY_NODE_NAME` | Name of Kubernetes node |
| `MY_POD_NAME` | Name of Kubernetes pod |
| `MY_POD_NAMESPACE` | Namespace of Kubernetes pod |
| `MY_POD_IP` | Kubernetes pod IP |
| `MY_POD_SERVICE_ACCOUNT` | Service account of Kubernetes pod |

## Change settings

Optional: every setting has a default. To change a setting once, put it on the command line,
as in `make run APP_PORT=9090 MESSAGE_TO=You`. To change settings for every `make` command,
copy the example file, then uncomment and edit the lines you want in `.env`:

```bash
cp .env.example .env
```

[`.env.example`](.env.example) lists every setting with its default. When a setting is given
in more than one place, the order is: command line, then a variable exported in your terminal
(even an empty one), then `.env`, then the default.

## Run the published image

A multi-arch image (`linux/amd64`, `linux/arm64`) is published to GitHub's registry on every
release. Its tags have no `v`: `0.0.4`, `0.0`, `0` and `latest`.

Pull it and run it; with Docker, replace `podman` with `docker`:

```bash
podman pull ghcr.io/andriykalashnykov/golang-web:latest
podman run --rm -p 8080:8080 ghcr.io/andriykalashnykov/golang-web:latest
```

Expect the log line `Starting web server on port 8080`. Open <http://localhost:8080>. Press
Ctrl-C to stop it. If port 8080 is taken, change the first number, as in `-p 9090:8080`.

## Build and run the image locally

Build the image from this checkout and run it in the background:

```bash
make image-run-bg
```

Expect this last line:

```text
golang-web running: http://localhost:8080/   logs: make image-logs   stop: make image-stop
```

The image is named `ghcr.io/andriykalashnykov/golang-web:v0.0.4`. That is only a local name;
nothing is uploaded.

| Command | What it does |
|---|---|
| `make image-build` | Builds the image without running it |
| `make image-run-bg` | Builds the image and runs it in the background on port 8080 (`APP_PORT=9090` to change) |
| `make image-logs` | Follows the container's log; Ctrl-C to leave (the `make: ***` line it prints then is normal) |
| `make image-stop` | Stops the container; expect `Stopped golang-web.` |

## Test it on a local Kubernetes cluster

Needs Docker and kubectl. Stop anything that uses port 8080 first; on macOS the cluster
publishes the app there.

```bash
make e2e
```

This builds the image, creates a [KinD](https://kind.sigs.k8s.io/) cluster named `golang-web`,
points kubectl at it (context `kind-golang-web`), deploys the app into the `default` namespace
and runs five checks against it. Expect near the end (your address differs):

```text
Service reachable at http://172.18.0.4:8080/myhello/
...
=== Results: 5 passed, 0 failed ===
```

Open the printed address. The cluster keeps running until you delete it; the next section can
use it. To delete it:

```bash
make kind-delete
```

Expect `KinD cluster 'golang-web' deleted.`

## Deploy the published image to a cluster

Needs a running cluster with kubectl pointed at it. The cluster from the previous section
works. This deploys the published image `ghcr.io/andriykalashnykov/golang-web:0.0.4`, not one
you built. Use a test cluster only: the app has an unauthenticated `/shutdown` endpoint and
the manifest exposes it through a LoadBalancer Service.

Check which cluster kubectl points at:

```bash
kubectl config current-context
```

Expect the name of your test cluster (`kind-golang-web` for the local one). If it prints
`current-context is not set`, there is no cluster; create the local one with `make e2e`.

Run the rest of this section in one terminal, from the repo directory; the blocks share the
`NS` variable.

Deploy [`k8s/golang-web.yaml`](k8s/golang-web.yaml), a Deployment and a LoadBalancer Service,
into its own namespace. The manifest meets the Pod Security `restricted` level, so it also
deploys into namespaces that enforce it:

```bash
NS=golang-web-demo
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NS" -f k8s/golang-web.yaml
kubectl rollout status -n "$NS" deployment/golang-web --timeout=120s
```

Expect `deployment "golang-web" successfully rolled out`.

Open it through a port-forward. The page is served under `/myhello/` (the manifest sets
`APP_CONTEXT`); `/` returns 404.

```bash
kubectl port-forward -n "$NS" svc/golang-web-service 18080:8080 >/dev/null & PF=$!
curl -sS --retry 10 --retry-connrefused --retry-delay 1 http://localhost:18080/myhello/
kill "$PF"
```

The terminal prints a job number after the first line and, in zsh, a `terminated` line after
the last. Expect `Hello, World` and the line
`MY_POD_NAMESPACE: golang-web-demo`. One `curl: (7) Failed to connect` line before the page is
normal: the forward was still starting and curl retried.

Optional, and only where the cluster gives the Service an IP address your machine can reach:
the local cluster on Linux, or a cloud cluster that publishes an IP. Skip it on macOS with the
local cluster.

```bash
kubectl wait -n "$NS" svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s \
  && IP=$(kubectl get svc -n "$NS" golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}') \
  && curl -sS --retry 5 --retry-all-errors "http://$IP:8080/myhello/"
```

Expect the same page. If the first command prints `timed out waiting for the condition`, the
cluster has no LoadBalancer controller or publishes a hostname instead of an IP: run
`kubectl get svc -n "$NS" golang-web-service` and read the EXTERNAL-IP column.

Remove everything this section created. On macOS with the local cluster, skip this command and
run `make kind-delete` instead: there the cluster can publish only one LoadBalancer Service on
port 8080, so this Service never gets its address and the delete waits forever.

```bash
kubectl delete namespace "$NS"
```

Expect `namespace "golang-web-demo" deleted`.

## Push your own image to a registry

Optional. Do this only to publish your own build of the app to a container registry, for
example to deploy it to a cluster. A ready-made image is already published; see
[Run the published image](#run-the-published-image).

The image is pushed as `<registry>/<owner>/golang-web:<version>`:

| Part | What it is | Default |
|---|---|---|
| `<registry>` | The registry host. Variable: `IMAGE_REGISTRY`. | `ghcr.io` (GitHub's registry) |
| `<owner>` | Your account on that registry. On ghcr.io: your GitHub user or organization name, in lowercase. Variable: `OWNER`. | `andriykalashnykov` (the author; you cannot push there) |
| `<version>` | The contents of `version.txt`. | `v0.0.4` |

### 1. Create a token the registry accepts

For ghcr.io, create a personal access token (classic) with only the `write:packages` scope at
[github.com/settings/tokens/new?scopes=write:packages](https://github.com/settings/tokens/new?scopes=write:packages)
and copy it. Fine-grained tokens do not work with ghcr.io. For another registry, use the
password or token it issues.

### 2. Set your owner name and the token

Run this line alone, then paste the token and press Enter. Nothing is shown while you paste.

```bash
read -rs REGISTRY_TOKEN && export REGISTRY_TOKEN
```

Then set your owner name and check it. Replace `octocat` with your GitHub user or organization
name, in lowercase:

```bash
export OWNER=octocat
make help | grep Image
```

For a registry other than ghcr.io, also run `export IMAGE_REGISTRY=registry.example.com` with
your registry's host and, when your login name is not the owner name,
`export REGISTRY_USERNAME=your-login`.

Expect your owner name in the image (the version is whatever `version.txt` holds):

```text
Image (image-push target)    - ghcr.io/octocat/golang-web:v0.0.4  <- set OWNER / IMAGE_REGISTRY for your own
```

### 3. Log in

```bash
make registry-login
```

Expect `Login Succeeded`. If not: `ERROR: no credential` means `REGISTRY_TOKEN` is empty in
this shell, so repeat step 2. `denied`, `unauthorized` or `403 Forbidden` means the token was
mistyped, has expired, or is not a classic token, so repeat steps 1 and 2.

### 4. Build and push

```bash
make image-push
```

This builds the image for `linux/amd64` and `linux/arm64` and pushes both as one tag. It builds
from source; it does not push an image `make image-build` made. Expect these two lines first,
and no `Push to ... failed.` at the end:

```text
podman buildx is available.
Building ghcr.io/octocat/golang-web:v0.0.4 for linux/amd64,linux/arm64
```

(`docker buildx is available.` when the engine is Docker.)

The image then appears under **Packages** on your GitHub profile, or on the organization's
page when `OWNER` is an organization. A new ghcr.io package is private until you change its
visibility there.

If it stops:

| Message | Do this |
|---|---|
| `Push to ... failed.` | Check `OWNER` is yours (step 2), that the token has `write:packages` (step 1), and that you logged in with the same engine you push with (step 3). |
| `This Docker uses the classic image store` | Follow the printed instructions to turn on the containerd image store, or push one platform: `make image-push PUSH_PLATFORMS=linux/amd64`. |
| `podman older than 5 is refused` (arm64 Linux with podman 4.x) | Use Docker for both steps: `make registry-login CONTAINER_ENGINE=docker`, then `make image-push CONTAINER_ENGINE=docker`. Or upgrade to podman 5.8. |

### 5. Deploy the image you pushed

Optional. Needs kubectl pointed at a test cluster that can pull the image; on ghcr.io, make
the package public first. `make k8s-apply` deploys into kubectl's current context and current
namespace, and prints both before it changes anything. Run it in the same terminal, so `OWNER`
is still set:

```bash
make k8s-apply
kubectl rollout status deployment/golang-web --timeout=180s
```

Expect (your image, context and namespace differ; `configured` replaces `created` when the app
is already in that namespace, as it is in the local cluster after `make e2e`):

```text
Deploying ghcr.io/octocat/golang-web:v0.0.4 to context 'kind-golang-web', namespace 'default'.
deployment.apps/golang-web created
service/golang-web-service created
deployment "golang-web" successfully rolled out
```

If the rollout times out and `kubectl get pods` shows `ImagePullBackOff`, the cluster cannot
pull the image: check the package is public and that `OWNER` is the one you pushed with.

Reach the app with the port-forward block in
[Deploy the published image to a cluster](#deploy-the-published-image-to-a-cluster), leaving
out `-n "$NS"`. Remove the app:

```bash
make k8s-delete
```

Expect `Deleting golang-web from context ...` and two `deleted` lines.

When you are done, remove the token from this terminal with `unset REGISTRY_TOKEN`.

### Other settings for this section

`IMAGE_REGISTRY` and `OWNER` are in the table at the top of this section.

| Variable | Default | Meaning |
|---|---|---|
| `REGISTRY_USERNAME` | value of `OWNER` | Login user, when it differs from `OWNER` |
| `REGISTRY_TOKEN` | none | Token or password for the registry |
| `PUSH_PLATFORMS` | `linux/amd64,linux/arm64` | Platforms built and pushed as one tag; comma-separated, no spaces |

## Deploy to VMware VKS

To build the image, push it to Harbor and deploy it to a VKS guest cluster, follow [`vks/README.md`](vks/README.md).

## For contributors

| Command | What it does |
|---|---|
| `make ci` | Runs the whole local pipeline: format, static checks, tests with the coverage threshold, build |
| `make static-check` | Runs the linters and security scanners only |
| `make ci-run` | Runs the GitHub Actions workflow on this machine with [act](https://github.com/nektos/act) (needs Docker) |
| `make check-env` | Fails if `.env.example` misses a setting the Makefile or the Go code reads |
| `make release` | Asks for a new `vX.Y.Z` tag, writes it to `version.txt`, commits, tags and pushes. The tag starts the CI job that publishes and signs the image. |

Where versions are pinned:

| Pinned in | What |
|---|---|
| [`.mise.toml`](.mise.toml) | Go, Node and every tool mise installs |
| `Makefile` | cloud-provider-kind, PlantUML, C4-PlantUML, Renovate CLI |
| `Dockerfile` | Go builder and distroless base images (digest-pinned) |
| `version.txt` | Release version (written by `make release`) |
