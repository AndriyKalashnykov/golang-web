.DEFAULT_GOAL := help

# `?=` NOT `:=` -- `:=` cannot be overridden by the environment, so `export OWNER=apps`
# was silently ignored and images were built for the default project with no error.
OWNER ?= andriykalashnykov
PROJECT := golang-web
# version.txt is the single source of truth -- `make release` writes it and
# tags from it. It was previously duplicated here as a literal and drifted
# (version.txt said v0.0.3 while this said v0.0.1).
VERSION := $(shell cat version.txt 2>/dev/null || echo v0.0.1)
# Registry must match k8s/golang-web.yaml and the CI publish target, or
# `kind load` puts the image under a name the manifest never requests and the
# pod goes ImagePullBackOff against a tag that does not exist remotely.
IMAGE_REGISTRY ?= ghcr.io
# Registry credentials are REGISTRY-neutral: this may be GHCR, Harbor, Docker Hub,
# ECR, Quay... Only the DEFAULT happens to be GHCR. REGISTRY_TOKEN is the one name
# for every registry (GH_ACCESS_TOKEN / CR_PAT fallbacks were removed: nothing used
# them, and they silently sent a GitHub PAT to whatever registry you logged in to).
REGISTRY_USERNAME ?= $(OWNER)
# Exported so the RECIPE SHELL can read them as `$$VAR`. Without this the recipe would have to
# use `$(VAR)`, which is a make-time expansion -- see the comment on registry-login.
export REGISTRY_TOKEN
export REGISTRY_USERNAME
OPV := $(IMAGE_REGISTRY)/$(OWNER)/$(PROJECT):$(VERSION)
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions ===
# Tool versions live in .mise.toml (single source of truth, Renovate-tracked
# via its native `mise` manager). `make deps` installs them all, at the pinned
# version, on Linux and macOS alike. Only versions mise cannot own stay here.
#
# cloud-provider-kind is consumed ONLY as a container-image tag (see
# kind-cloud-provider-start). Track the REGISTRY (datasource=docker), NOT
# github-releases: registry.k8s.io is fed by the k8s image-promotion pipeline,
# which lags the upstream GitHub release by hours-to-days. A github-releases
# datasource would propose a tag the moment the release is cut -- before the
# image is promoted -- so `docker run` 404s with `manifest unknown`. The docker
# datasource can only ever propose a tag that is actually published.
#
# NOTE: each `# renovate:` line must be IMMEDIATELY followed by its variable --
# the customManager matchString in renovate.json anchors on `\n` with no blank
# or comment line between. Do not insert commentary in that gap.
# renovate: datasource=docker depName=registry.k8s.io/cloud-provider-kind/cloud-controller-manager extractVersion=^v(?<version>.*)$
CLOUD_PROVIDER_KIND_VERSION := 0.11.1
# Renovate CLI, run via `npx renovate@$(RENOVATE_VERSION)`; not a mise tool.
# renovate: datasource=npm depName=renovate
RENOVATE_VERSION    := 44.106.0
# PlantUML renderer for docs/diagrams/*.puml. Runs as a container (not a mise
# tool) so no JRE is needed on the host.
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION    := 1.2026.8
# C4-PlantUML macro library, pinned in each .puml `!include`. MUST be a tagged
# release -- `master` changes upstream without warning and breaks rendering.
# renovate: datasource=github-releases depName=plantuml-stdlib/C4-PlantUML
C4_PLANTUML_VERSION := v2.14.0

# Ensure mise-managed binaries are on PATH for every recipe, regardless of
# whether the invoking shell has `mise activate` wired up (and inside the act
# runner container, where it is not).
#
# ORDER IS LOAD-BEARING: the mise shims dir must come FIRST, ahead of
# ~/.local/bin and ~/go/bin. Those hold ad-hoc `go install` / manual binaries
# from before this repo used mise, and a stale one there will shadow the
# pinned version -- which is exactly the drift `make deps` now exists to end.
# (Measured: a leftover ~/.local/bin/golangci-lint 2.11.4 built with go1.26
# shadowed the pinned 2.13.2 and failed `make lint` with "the Go language
# version (go1.26) used to build golangci-lint is lower than the targeted
# Go version".)
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)
# Run every recipe through a real shell -- REQUIRED on macOS, do not "simplify" this line.
# Apple's /usr/bin/make is GNU Make 3.81 patched by Apple: it starts a simple recipe line
# (`mise install --yes`, `go build ...`) itself via posix_spawnp, which searches make's OWN startup
# PATH and ignores the export above, so a freshly installed mise or its Go is "No such file or
# directory". Apple also treats /bin/sh, /bin/bash, /bin/dash, /bin/zsh and /usr/local/bin/ash as
# plain shells that keep that shortcut, so none of those work here; `/usr/bin/env bash` is not on
# the list, so every line goes through bash, which does see the exported PATH. Stock GNU make on
# Linux is unaffected. Measured on macOS 26.6.2 (/bin/bash and /bin/zsh fail, /usr/bin/env bash
# works); source: apple-oss-distributions/gnumake job.c (_is_posix_shell, USE_POSIX_SPAWN).
SHELL := /usr/bin/env bash

# === Tunables (override on the command line or via the environment) ===
# APP_PORT: the port on THIS machine for `run`, `image-run-bg` and `image-test-fg`.
# The app reads PORT (main.go, default 8080); the container always listens on 8080.
APP_PORT           ?= 8080
WEBPORT            := $(APP_PORT):8080
# SERVICE_PORT: the port of golang-web-service in k8s/golang-web.yaml (KinD, e2e).
SERVICE_PORT       ?= 8080
ROLLOUT_TIMEOUT    ?= 120s
LB_WAIT_TIMEOUT    ?= 120s
LB_ROUTE_RETRIES   ?= 60
LB_POLL_INTERVAL   ?= 2
CURL_MAX_TIME      ?= 3
# Go 1.27 changed how `go test --cover` counts statements. MEASURED on
# IDENTICAL source and tests (origin/main, no code change):
#     GOTOOLCHAIN=go1.26.4 -> 84.8%
#     GOTOOLCHAIN=go1.27.1 -> 78.2%
# The same three functions are uncovered under both (StartWebServer,
# handleShutdown, main); only the denominator moved. 75 preserves the same
# ~6-point headroom the old 80 gave against 84.8 -- it is a recalibration to
# the new measurement basis, NOT a relaxation after a test regression.
# See the CLAUDE.md backlog item about refactoring StartWebServer for
# testability, which is what would let this go back up.
COVERAGE_THRESHOLD ?= 75

KIND_CLUSTER_NAME   := golang-web
# The KinD path builds its OWN tag, for the KinD node's architecture (see kind-create).
# It must never reuse OPV: on an arm64 host OPV is built linux/amd64 for real clusters,
# and an amd64 image in an arm64 KinD node never passed its startup probe (measured on
# macOS/Colima: node arm64, image amd64, "connection refused" until killed; native OK).
KIND_IMAGE          := $(OPV)-kind
# act's "Medium" runner image, the one act itself offers on first run. It is a moving
# tag upstream; passing it explicitly stops act from prompting (no prompt = no EOF crash
# in a non-interactive shell).
ACT_RUNNER_IMAGE    ?= catthehacker/ubuntu:act-latest
ACT_ARCH            ?=

# === Container engine ===
# podman is preferred (rootless by default, no daemon); docker is fully supported.
# Override explicitly:  make image-build CONTAINER_ENGINE=docker
#
# Auto-detection prefers podman, then docker, then `none` so `deps` can report a
# actionable message instead of a bare "command not found" at the first build.
# `podman buildx build --load` is verified working on podman 4.9.3 (podman ships a
# buildx compatibility shim), so image-build takes the same flags on both engines.
CONTAINER_ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || { command -v docker >/dev/null 2>&1 && echo docker; } || echo none)

# Back-compat alias: earlier revisions hardcoded DOCKERCMD.
DOCKERCMD := $(CONTAINER_ENGINE)

# KIND_ENGINE manages KIND'S OWN containers -- the cloud-provider-kind controller
# and its kindccm sidecars -- and must match the provider kind itself uses
# (docker, since KIND_EXPERIMENTAL_PROVIDER is unset). It does NOT dictate which
# engine BUILDS the image: that stays $(CONTAINER_ENGINE), and kind-create
# bridges the two stores with `save` + `kind load image-archive` when they differ.
# The KinD path is pinned to DOCKER and is deliberately NOT $(CONTAINER_ENGINE).
# deps-kind already states the requirement (cloud-provider-kind mounts
# /var/run/docker.sock, and `kind load docker-image` reads DOCKER's image store)
# -- but it only asserted docker was INSTALLED, which passes on a box that has
# BOTH engines while every recipe still ran podman. Measured on such a box:
#   podman ps --filter name=cloud-provider-kind -> 0   docker -> 1
#   podman image exists <built tag>             -> no  docker -> yes
# so the image built by $(CONTAINER_ENGINE)=podman is invisible to `kind load`.
# Pinning the engine for this path makes the code match its own documented
# contract. Image targets stay dual-engine via $(DOCKERCMD).
KIND_ENGINE ?= docker

# uname picks the podman install command in `deps` and the start hint below.
HOST_OS := $(shell uname -s)

# $(call engine_ready,<engine>): stop with a next step unless <engine> can run containers.
# A CLI can be installed while its engine is not running (podman machine stopped, Colima
# stopped, dockerd down); `info` fails fast then (measured on macOS: 0.05 s). perl's alarm
# bounds it anyway, because macOS has no `timeout` and a wedged daemon can hang.
define engine_ready
if [ "$(1)" = none ]; then echo "No container engine found (podman or docker). Run: make deps"; exit 1; fi; \
command -v $(1) >/dev/null 2>&1 || { echo "$(1) is not installed (or not on PATH)."; \
	case "$(1)" in podman) echo "  Install it: make deps";; *) echo "  Install it: https://docs.docker.com/get-docker/";; esac; exit 1; }; \
rc=0; err=$$( (perl -e 'alarm 15; exec @ARGV or exit 127' $(1) info >/dev/null) 2>&1 ) || rc=$$?; \
if [ $$rc -ne 0 ]; then \
	case "$$err" in \
	  *[Pp]ermission?denied*) \
	    echo "$(1) is running, but this user may not use it: $$(printf '%s' "$$err" | head -1)"; \
	    echo "  Fix: sudo usermod -aG docker $$USER   then log out and back in";; \
	  *) if [ $$rc -eq 142 ]; then echo "$(1) did not answer within 15 s (it may be hung). Check: $(1) info"; else \
	    echo "$(1) is installed but not running."; \
	    case "$(HOST_OS)/$(1)" in \
	      Darwin/podman) if podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then \
	          echo "  Its VM is running but does not answer. Restart it:  podman machine stop && podman machine start"; \
	        else echo "  Start its VM:  podman machine start"; fi; \
	        (docker info >/dev/null 2>&1) && echo "  Or use Docker, which is running: add CONTAINER_ENGINE=docker to the make command";; \
	      Darwin/docker) echo "  Start it:  colima start   (or open Docker Desktop / OrbStack)";; \
	      */docker)      echo "  Start it:  sudo systemctl start docker";; \
	      *)             echo "  Check it:  $(1) info";; \
	    esac; fi;; \
	esac; \
	exit 1; \
fi
endef

# $(call port_free,<port>,<target>): stop with a next step if something already listens on <port>.
define port_free
if (exec 3<>/dev/tcp/127.0.0.1/$(1)) 2>/dev/null; then \
	echo "Port $(1) on this machine is already in use."; \
	echo "  Free it, or use another port:  make $(2) APP_PORT=9090"; \
	exit 1; fi
endef

BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
# unique id from last git commit
MY_GITREF := $(shell git rev-parse --short HEAD)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-28s\033[0m - %s\n", $$1, $$2}'
	@echo ""
	@echo "Resolved now (override any of them on the command line):"
	@printf "\033[32m%-28s\033[0m - %s\n" "CONTAINER_ENGINE" "$(CONTAINER_ENGINE)  <- builds and runs YOUR image (make engines explains)"
	@printf "\033[32m%-28s\033[0m - %s\n" "KIND_ENGINE" "$(KIND_ENGINE)  <- kind's own containers; not yours to change"
	@printf "\033[32m%-28s\033[0m - %s\n" "Image (image-push target)" "$(OPV)  <- set OWNER / IMAGE_REGISTRY for your own"
	@echo ""
	@echo "  one command : make image-build CONTAINER_ENGINE=docker"
	@echo "  whole shell : export CONTAINER_ENGINE=docker"

#engines: @ Show which container engine each path uses, and how to override it
engines:
	@echo "CONTAINER_ENGINE = $(CONTAINER_ENGINE)$(if $(filter none,$(CONTAINER_ENGINE)),  <- no engine found: run 'make deps' (installs podman))"
	@echo "    Builds and runs YOUR image (image-*, diagrams, e2e's build step)."
	@echo "    THIS is the knob you set. Auto-detected: podman if present, else docker."
	@echo "    Override:  make image-build CONTAINER_ENGINE=docker"
	@echo "               export CONTAINER_ENGINE=docker      # for the whole shell"
	@echo ""
	@echo "KIND_ENGINE = $(KIND_ENGINE)"
	@echo "    Manages KIND'S OWN containers: the cloud-provider-kind LoadBalancer"
	@echo "    controller and its kindccm sidecars. Must match the provider kind runs"
	@echo "    on (docker), because that controller mounts /var/run/docker.sock."
	@echo "    You do NOT need to set this to build with podman: when it differs from"
	@echo "    CONTAINER_ENGINE, kind-create bridges the two image stores with"
	@echo "    '<engine> save' + 'kind load image-archive'."
	@echo ""
	@echo "Engines found on this host:"
	@for e in podman docker; do \
		if command -v $$e >/dev/null 2>&1; then \
			echo "  $$e  $$($$e --version 2>/dev/null | head -1)"; \
		else echo "  $$e  (not installed)"; fi; \
	done

#deps: @ Install the pinned toolchain via mise (.mise.toml)
deps: deps-engine
	@# mise owns every tool version. This replaces the old
	@# `command -v <tool> >/dev/null || go install ...@$(VERSION)` guards,
	@# which SHORT-CIRCUITED whenever any version of the tool was already on
	@# PATH -- so the pinned version was never actually installed and local
	@# tools silently drifted from the pins. `mise install` is idempotent and
	@# always converges on the pinned version, on Linux and macOS alike.
	@if ! command -v mise >/dev/null 2>&1; then \
		if [ -n "$$CI" ]; then \
			echo "Error: mise not installed in CI. Ensure jdx/mise-action runs before 'make deps'."; \
			exit 1; \
		fi; \
		echo "Installing mise (no root; installs to ~/.local/bin)..."; \
		curl -fsSL https://mise.run | sh; \
		command -v mise >/dev/null 2>&1 || { echo "Error: mise install failed (see above)."; exit 1; }; \
		echo ""; \
		echo "mise installed. make targets find its tools themselves (this Makefile puts"; \
		echo "~/.local/share/mise/shims on PATH), so no shell setup is needed. Installing them now."; \
	fi
	@# Every target depends on deps, so install ONLY when something is missing: an
	@# up-to-date box printed ~15 lines of "already installed" before each target's
	@# own output. When a tool IS missing, mise's output is shown unfiltered.
	@# `mise ls --local --missing` exits 0 either way; its OUTPUT is the answer.
	@# If `mise ls` itself fails (a broken .mise.toml), run the install anyway so the user
	@# sees mise's real error instead of a silent success.
	@missing=$$(mise ls --local --missing 2>/dev/null | awk '{print $$1}' | tr '\n' ' ') || missing="(could not list; installing)"; \
	if [ -n "$$missing" ]; then \
		echo "Installing pinned tools: $$missing"; \
		mise install --yes; \
	fi

#deps-engine: @ Ensure a container engine is present (installs podman if neither is)
deps-engine:
	@# Either engine works. podman is installed when neither is present because it
	@# is rootless by default and needs no daemon; docker is equally supported and
	@# is picked up automatically if it is the one already installed.
	@# The engine is only NAMED here, once per top-level make (not in nested makes).
	@# Whether it is RUNNING is checked by the targets that need it (engine_ready), so
	@# a stopped podman VM no longer prints an ERROR before `make build` or `make test`.
	@if [ "$(CONTAINER_ENGINE)" != "none" ]; then \
		[ "$(MAKELEVEL)" != 0 ] || echo "Container engine: $(CONTAINER_ENGINE) ($$($(CONTAINER_ENGINE) --version 2>/dev/null | head -1))"; \
		exit 0; \
	fi; \
	echo "No container engine found (looked for podman, then docker)."; \
	echo "Installing podman. To use Docker instead, install it from"; \
	echo "https://docs.docker.com/get-docker/ and re-run 'make deps' --"; \
	echo "or force it per-invocation with 'make <target> CONTAINER_ENGINE=docker'."; \
	case "$(HOST_OS)" in \
	  Darwin) \
	    command -v brew >/dev/null 2>&1 || { echo "ERROR: Homebrew required to install podman on macOS. See https://brew.sh"; exit 1; }; \
	    brew install podman && podman machine init 2>/dev/null; podman machine start 2>/dev/null || true; \
	    echo "NOTE: on macOS podman runs in a VM. 'podman machine start' must be running before any image target."; \
	    ;; \
	  Linux) \
	    if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y podman; \
	    elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y podman; \
	    elif command -v pacman  >/dev/null 2>&1; then sudo pacman -S --noconfirm podman; \
	    elif command -v zypper  >/dev/null 2>&1; then sudo zypper install -y podman; \
	    else echo "ERROR: unsupported Linux distribution. Install podman or docker manually: https://podman.io/docs/installation"; exit 1; fi; \
	    ;; \
	  *) echo "ERROR: unsupported OS '$(HOST_OS)'. Install podman or docker manually."; exit 1;; \
	esac; \
	command -v podman >/dev/null 2>&1 || { echo "ERROR: podman install did not put podman on PATH."; exit 1; }; \
	echo "podman installed: $$(podman --version)"

#deps-buildx: @ Verify the engine can run `buildx build` (image-build depends on it)
deps-buildx:
	@# `image-build` runs `<engine> buildx build --load`. podman provides buildx via a
	@# built-in buildah shim, but for DOCKER on Debian/Ubuntu buildx is a SEPARATE
	@# package (`docker-buildx-plugin`) -- a plain `apt-get install docker.io` yields a
	@# docker that cannot build this image. Check it here rather than failing mid-build.
	@$(call engine_ready,$(CONTAINER_ENGINE))
	@$(CONTAINER_ENGINE) buildx version >/dev/null 2>&1 && { [ "$(MAKELEVEL)" != 0 ] || echo "$(CONTAINER_ENGINE) buildx is available."; exit 0; }; \
	echo "ERROR: '$(CONTAINER_ENGINE) buildx' is not available -- 'make image-build' cannot run."; \
	if [ "$(CONTAINER_ENGINE)" = "docker" ]; then \
		case "$(HOST_OS)" in \
		  Darwin) echo "  Install buildx, then link it where docker looks for plugins:"; \
		          echo "    brew install docker-buildx && mkdir -p ~/.docker/cli-plugins &&"; \
		          echo "    ln -sfn \"\$$(brew --prefix)/opt/docker-buildx/bin/docker-buildx\" ~/.docker/cli-plugins/docker-buildx";; \
		  Linux)  echo "  Install the plugin:  sudo apt-get install -y docker-buildx-plugin"; \
		          echo "                  or:  sudo dnf install -y docker-buildx-plugin"; \
		          echo "  Or switch engines:   make image-build CONTAINER_ENGINE=podman";; \
		esac; \
	else \
		echo "  podman provides buildx via buildah: upgrade podman to 4.0 or newer."; \
	fi; \
	exit 1

#registry-login: @ Log in to IMAGE_REGISTRY (see the footer) so `make image-push` can publish
registry-login:
	@# The token is passed on STDIN, never on the command line -- anything in argv is
	@# visible to any local user via `ps` / /proc/<pid>/cmdline for the life of the call.
	@# `$(REGISTRY_TOKEN)` (single $) is a MAKE-TIME expansion: make bakes the secret into the
	@# recipe TEXT it hands to `sh -c`, so it lands in that shell's argv. MEASURED: a canary token
	@# was readable in `ps -eo args` for the life of the login. `$$REGISTRY_TOKEN` defers to the
	@# SHELL, which reads it from the exported environment instead -- argv stays clean.
	@# The same applies to REGISTRY_USERNAME: a Harbor robot is named `robot$$project+name`, and
	@# make ate the `$a`, turning robot$$apps+golang-web-push into robotpps+golang-web-push.
	@if [ -z "$$REGISTRY_TOKEN" ]; then \
		echo "ERROR: no credential for $(IMAGE_REGISTRY) in the environment."; \
		echo "    export REGISTRY_TOKEN=<token-or-password>"; \
		echo "    export REGISTRY_USERNAME=<user>   # optional; defaults to OWNER ($(OWNER))"; \
		echo "    make registry-login"; \
		echo "  Not $(OWNER)? Set your own namespace too: make registry-login OWNER=<you>"; \
		case "$(IMAGE_REGISTRY)" in \
		  ghcr.io) echo "  For ghcr.io this is a GitHub PAT with 'write:packages':"; \
		           echo "  https://github.com/settings/tokens";; \
		  *)       echo "  Use whatever credential $(IMAGE_REGISTRY) issues (Harbor robot"; \
		           echo "  account, Docker Hub access token, ECR password, ...).";; \
		esac; \
		exit 1; \
	fi
	@$(call engine_ready,$(CONTAINER_ENGINE))
	@# REGISTRY_USERNAME is exported (default: OWNER), so the SHELL reads it -- never `$(...)`
	@# here, or a Harbor robot name like robot$$apps+x is expanded by make and by the shell.
	@printf '%s' "$$REGISTRY_TOKEN" | $(CONTAINER_ENGINE) login $(IMAGE_REGISTRY) -u "$$REGISTRY_USERNAME" --password-stdin

#deps-verify: @ Check that every tool pinned in .mise.toml is installed (installs nothing)
deps-verify:
	@# It used to depend on `deps`, so it INSTALLED everything (podman via sudo, mise, 12
	@# tools) and then reported success -- it could never fail. It also checked
	@# `command -v`, which a mise shim satisfies even when the PINNED version is missing.
	@command -v mise >/dev/null 2>&1 || { echo "mise is not installed. Run: make deps"; exit 1; }
	@# mise's own error must stay visible: with a broken .mise.toml `mise ls` fails with EMPTY
	@# output, which read as "nothing missing" and printed "All 0 ... installed" (measured).
	@all=$$(mise ls --local) || { echo "mise could not read .mise.toml (error above). Fix it, then: make deps"; exit 1; }; \
	count=$$(printf '%s\n' "$$all" | grep -c .); \
	[ "$$count" -gt 0 ] || { echo "mise lists no tools from .mise.toml; is this the repo root?"; exit 1; }; \
	missing=$$(mise ls --local --missing | awk '{print $$1}' | tr '\n' ' '); \
	if [ -n "$$missing" ]; then echo "Missing pinned tools: $$missing"; echo "Run: make deps"; exit 1; fi; \
	echo "All $$count pinned tools in .mise.toml are installed."

#check-toolchain-alignment: @ Verify the Go version agrees across go.mod, Dockerfile and .mise.toml
check-toolchain-alignment:
	@gomod=$$(grep -oE '^go [0-9]+\.[0-9]+(\.[0-9]+)?' go.mod | awk '{print $$2}'); \
	docker=$$(grep -oE '^FROM( --platform=[^ ]+)? (docker\.io/library/)?golang:[0-9]+\.[0-9]+(\.[0-9]+)?' Dockerfile | head -1 | sed 's/.*golang://'); \
	misev=$$(grep -oE '^go = "[0-9]+\.[0-9]+(\.[0-9]+)?"' .mise.toml | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?'); \
	if [ -z "$$gomod" ] || [ -z "$$docker" ] || [ -z "$$misev" ]; then \
		echo "ERROR: could not parse a Go version (go.mod='$$gomod' Dockerfile='$$docker' .mise.toml='$$misev')"; \
		exit 1; \
	fi; \
	if [ "$$gomod" != "$$docker" ] || [ "$$gomod" != "$$misev" ]; then \
		echo "ERROR: Go toolchain versions disagree:"; \
		echo "  go.mod       $$gomod"; \
		echo "  Dockerfile   $$docker"; \
		echo "  .mise.toml   $$misev"; \
		echo "All three must match; bump them together."; \
		exit 1; \
	fi; \
	echo "Go toolchain aligned at $$gomod (go.mod, Dockerfile, .mise.toml)."

#trivy-fs: @ Scan filesystem for vulnerabilities, secrets, and misconfigurations
trivy-fs: deps
	@trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 .

#trivy-config: @ Scan K8s manifests for security misconfigurations
trivy-config: deps
	@trivy config --severity CRITICAL,HIGH --exit-code 1 k8s/

#test: @ Run tests with coverage
test: deps
	@go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	@go tool cover -func=coverage.out | sort -rnk3

#build: @ Build the Go binary
build: deps
	@CGO_ENABLED=0 go build -ldflags "-X main.Version=${VERSION} -X main.BuildTime=${BUILD_TIME}" -a -o manager main.go

#lint: @ Run static analysis
lint: deps
	@golangci-lint run ./...
	@hadolint Dockerfile

#lint-ci: @ Lint GitHub Actions workflows
lint-ci: deps
	@actionlint && echo "GitHub Actions workflows: no issues."

#sec: @ Run security scanner
sec: deps
	@gosec ./...

#vulncheck: @ Check for known vulnerabilities in dependencies
vulncheck: deps
	@govulncheck ./...

#secrets: @ Scan for hardcoded secrets
secrets: deps
	@gitleaks detect --source . --verbose --redact

#diagrams: @ Render docs/diagrams/*.puml to PNG
# Each .puml is piped through plantuml's stdin and the PNG read from its stdout, so
# nothing is bind-mounted. That removes three measured failures of the old `-v` form:
# rootless podman could not write the mount (plantuml still exited 0), act's copied
# workdir was invisible to the host daemon, and --bind to fix that left root-owned
# files (manager, .git/index) in the checkout. Measured: the piped render is
# byte-identical to the committed PNG with docker AND podman, an invalid diagram exits
# 200 with the error on stderr, empty input exits 50 -- so the exit code is trustworthy.
# `docker.io/` is spelled out: podman on stock Ubuntu has no unqualified-search registry.
diagrams:
	@$(call engine_ready,$(CONTAINER_ENGINE))
	@mkdir -p docs/diagrams/out
	@for puml in docs/diagrams/*.puml; do \
		png="docs/diagrams/out/$$(basename "$$puml" .puml).png"; \
		$(CONTAINER_ENGINE) run --rm -i docker.io/plantuml/plantuml:$(PLANTUML_VERSION) -tpng -pipe \
			< "$$puml" > "$$png.tmp" || { rc=$$?; rm -f "$$png.tmp"; echo "ERROR: plantuml exit $$rc on $$puml (message above)."; exit 1; }; \
		[ -s "$$png.tmp" ] || { rm -f "$$png.tmp"; echo "ERROR: plantuml produced no image for $$puml."; exit 1; }; \
		mv "$$png.tmp" "$$png"; \
	done; \
	echo "Diagrams rendered to docs/diagrams/out/."

#diagrams-check: @ Verify committed diagram PNGs match their .puml sources
diagrams-check:
	@# Drift gate: re-render and diff. A committed PNG that no longer matches its
	@# source means the README is advertising a stale architecture.
	@if [ "$(CONTAINER_ENGINE)" = none ]; then echo "Skipped diagrams-check: no container engine (run make deps to install podman)."; exit 0; fi; \
	grep -q "C4-PlantUML/$(C4_PLANTUML_VERSION)/" docs/diagrams/*.puml || { \
		echo "ERROR: a .puml !include does not pin C4-PlantUML $(C4_PLANTUML_VERSION)"; \
		grep -n 'C4-PlantUML' docs/diagrams/*.puml; exit 1; }; \
	out=$$($(MAKE) --no-print-directory diagrams 2>&1) || { printf '%s\n' "$$out"; exit 1; }; \
	if ! git diff --quiet -- docs/diagrams/out/; then \
		echo "ERROR: committed diagram PNGs are stale. Run 'make diagrams' and commit the result:"; \
		git diff --stat -- docs/diagrams/out/; \
		exit 1; \
	fi; \
	echo "Diagrams up to date with their .puml sources."

#static-check: @ Run all quality and security checks
static-check: check-toolchain-alignment lint-ci lint sec vulncheck secrets trivy-fs trivy-config diagrams-check
	@echo "Static check passed."

#format: @ Auto-format Go source files
format: deps
	@golangci-lint fmt ./...
	@changed=$$(git status --porcelain -- '*.go' | wc -l | tr -d ' '); \
	echo "Go sources formatted ($$changed file(s) now differ from git)."

#run: @ Run the application locally
run: deps
	@$(call port_free,$(APP_PORT),run)
	@PORT=$(APP_PORT) go run main.go

#coverage-check: @ Verify test coverage meets threshold
coverage-check: deps
	@go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	@total=$$(go tool cover -func=coverage.out | grep total | awk '{print $$NF}' | tr -d '%'); \
	threshold=$(COVERAGE_THRESHOLD); \
	if echo "$$total $$threshold" | awk '{exit (!($$1 < $$2))}'; then \
		echo "Coverage $${total}% is below $${threshold}% threshold"; exit 1; \
	else \
		echo "Coverage $${total}% meets $${threshold}% threshold"; \
	fi

#image-build: @ Build the container image
# Kubernetes/VKS nodes are amd64. On an arm64 host a native build pushes fine and then
# dies at runtime with `exec format error`, so default to amd64 there. Override with
# `make image-build PLATFORM=linux/arm64`, or PLATFORM= to build natively.
# (The KinD targets do NOT use this default; they build for the KinD node instead.)
HOST_ARCH := $(shell uname -m)
ifneq ($(filter arm64 aarch64,$(HOST_ARCH)),)
PLATFORM ?= linux/amd64
endif
PLATFORM ?=
ifneq ($(filter arm64 aarch64,$(HOST_ARCH)),)
ifeq ($(PLATFORM),linux/amd64)
EMULATION_NOTE := echo "Note: this arm64 machine runs the linux/amd64 image under emulation (it is built for amd64 clusters). Native: add PLATFORM="
endif
endif
EMULATION_NOTE ?= true

# No `build` prerequisite: the Dockerfile compiles main.go in its own builder stage, so the host
# binary (and the mise toolchain `build: deps` installs) is not needed to build the image.
image-build: deps-buildx
	@echo MY_GITREF is $(MY_GITREF)
	@$(DOCKERCMD) buildx build --load $(if $(PLATFORM),--platform $(PLATFORM)) --build-arg MY_VERSION=$(VERSION) --build-arg MY_BUILDTIME=$(BUILD_TIME) -f Dockerfile -t $(OPV) .

#clean: @ Remove the built image and build artifacts
clean:
	@rm -f manager coverage.out
	@if [ "$(DOCKERCMD)" = none ]; then echo "Removed build artifacts (no container engine: image not checked)."; exit 0; fi; \
	if ! perl -e 'alarm 15; exec @ARGV or exit 127' $(DOCKERCMD) info >/dev/null 2>&1; then \
		echo "Removed build artifacts. $(DOCKERCMD) is not running, so image $(OPV) was not checked."; exit 0; fi; \
	if [ -n "$$($(DOCKERCMD) ps -q --filter ancestor=$(OPV))$$($(DOCKERCMD) ps -q --filter ancestor=$(KIND_IMAGE))" ]; then \
		echo "Image $(OPV) is used by a running container. Stop it first: make image-stop"; exit 1; fi; \
	removed=""; for img in $(OPV) $(KIND_IMAGE); do \
		if $(DOCKERCMD) image inspect $$img >/dev/null 2>&1; then $(DOCKERCMD) image rm $$img >/dev/null && removed="$$removed $$img"; fi; \
	done; \
	if [ -n "$$removed" ]; then echo "Removed build artifacts and image(s):$$removed"; else echo "Removed build artifacts; no image to remove."; fi

#update: @ Update dependency packages to latest versions
update: deps
	@before=$$(cat go.mod go.sum | cksum); go get -u ./... && go mod tidy || exit 1; \
	if [ "$$before" = "$$(cat go.mod go.sum | cksum)" ]; then echo "Dependencies already up to date."; \
	else echo "Dependencies updated (go.mod / go.sum changed):"; git diff --stat -- go.mod go.sum; fi

#image-test-fg: @ Run container in foreground with test overrides
image-test-fg: image-build
	@$(call port_free,$(APP_PORT),image-test-fg)
	@$(EMULATION_NOTE)
	@echo "Serving on http://localhost:$(APP_PORT)/myhello/ -- Ctrl-C to stop."
	@$(DOCKERCMD) run -it -p $(WEBPORT) \
	-e APP_CONTEXT=/myhello/ \
	-e MY_NODE_NAME=node1 \
	-e MY_POD_NAME=pod1 \
	-e MY_POD_NAMESPACE=ns1 \
	-e MY_POD_IP=podip1 \
	-e MY_POD_SERVICE_ACCOUNT=podsa1 \
	--rm $(OPV)

#image-run-bg: @ Run container in background
image-run-bg:
	@$(call engine_ready,$(DOCKERCMD))
	@if [ -n "$$($(DOCKERCMD) ps -q --filter name=^$(PROJECT)$$)" ]; then \
		echo "$(PROJECT) is already running. Logs: make image-logs   stop: make image-stop"; exit 1; fi
	@$(call port_free,$(APP_PORT),image-run-bg)
	@$(MAKE) --no-print-directory image-build
	@$(EMULATION_NOTE)
	@$(DOCKERCMD) run -d -p $(WEBPORT) --rm --name $(PROJECT) $(OPV) >/dev/null && \
	echo "$(PROJECT) running: http://localhost:$(APP_PORT)/   logs: make image-logs   stop: make image-stop"

#image-logs: @ Tail container logs
image-logs:
	@$(call engine_ready,$(DOCKERCMD))
	@[ -n "$$($(DOCKERCMD) ps -q --filter name=^$(PROJECT)$$)" ] || { echo "$(PROJECT) is not running. Start it: make image-run-bg"; exit 1; }
	@$(DOCKERCMD) logs -f $(PROJECT)

#image-stop: @ Stop background container
image-stop:
	@$(call engine_ready,$(DOCKERCMD))
	@if [ -n "$$($(DOCKERCMD) ps -q --filter name=^$(PROJECT)$$)" ]; then \
		$(DOCKERCMD) stop $(PROJECT) >/dev/null && echo "Stopped $(PROJECT)."; \
	else echo "$(PROJECT) is not running; nothing to stop."; fi

#image-push: @ Push the image to IMAGE_REGISTRY/OWNER (see the footer)
image-push: image-build
	@# A bare `push` against an unauthenticated engine fails with `denied` / `unauthorized`
	@# and no hint about what to do. Say it here instead.
	@$(CONTAINER_ENGINE) push $(OPV) || { \
		echo ""; \
		echo "Push to $(OPV) failed."; \
		echo "  Not your namespace? Push to yours:  make image-push OWNER=<you> [IMAGE_REGISTRY=<registry>]"; \
		echo "  Not logged in?  export REGISTRY_TOKEN=<credential for $(IMAGE_REGISTRY)>; make registry-login"; \
		exit 1; }

# $(call kube_target,<verb>): name the cluster and namespace a kubectl target is about to touch.
# k8s/golang-web.yaml sets no namespace, so the CONTEXT's namespace applies (default: "default").
define kube_target
ctx=$$(kubectl config current-context 2>/dev/null) || { echo "No kubectl context is set. Pick a cluster: kubectl config use-context <name>  (or: make kind-deploy)"; exit 1; }; \
ns=$$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null); \
echo "$(1) context '$$ctx', namespace '$${ns:-default}'."
endef

#k8s-apply: @ Deploy the pushed image to the CURRENT kubectl context
k8s-apply:
	@$(call kube_target,Deploying $(OPV) to); \
	sed -e 's|image: .*/$(PROJECT):.*|image: $(OPV)|' k8s/golang-web.yaml | kubectl apply -f -

#k8s-delete: @ Delete the app from the CURRENT kubectl context
k8s-delete:
	@$(call kube_target,Deleting golang-web from); \
	kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true

#deps-kind: @ Verify KinD, kubectl and a KinD-capable engine are available
deps-kind: deps
	@command -v kind >/dev/null 2>&1 || { echo "Error: kind not found. Run 'make deps' (installs via .mise.toml)."; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl required. See https://kubernetes.io/docs/tasks/tools/"; exit 1; }
	@# The KinD path specifically needs DOCKER, unlike the image targets which run on
	@# either engine. cloud-provider-kind is started with
	@#     -v /var/run/docker.sock:/var/run/docker.sock
	@# so it can watch Services and manage its Envoy sidecars; rootless podman exposes
	@# its socket at /run/user/$$(id -u)/podman/podman.sock instead. kind itself can run
	@# on podman via KIND_EXPERIMENTAL_PROVIDER=podman, but that combination is NOT
	@# verified here -- so this gate states the requirement rather than guessing.
	@command -v docker >/dev/null 2>&1 || { \
		echo "Error: the KinD targets require Docker."; \
		echo "  Image targets (image-build, image-run-bg, ...) work on podman OR docker;"; \
		echo "  the KinD path does not, because cloud-provider-kind mounts the Docker socket."; \
		echo "  Install Docker: https://docs.docker.com/get-docker/"; \
		exit 1; }
	@$(call engine_ready,$(KIND_ENGINE))

#kind-cloud-provider-start: @ Start cloud-provider-kind (supplies LoadBalancer IPs to KinD)
kind-cloud-provider-start: deps-kind
	@# cloud-provider-kind runs on the HOST (not in the cluster), watches
	@# type=LoadBalancer Services on the `kind` Docker network, and allocates
	@# IPs from that network's subnet. No in-cluster DaemonSet, no
	@# IPAddressPool/L2Advertisement YAML, and none of MetalLB's nftables
	@# fragility on recent kindest/node images. Idempotent.
	@# On macOS the engine runs in a VM, so the LoadBalancer IP (kind network, e.g.
	@# 172.18.0.4) is NOT reachable from the Mac: kind-deploy waited 319 s and failed.
	@# --enable-lb-port-mapping makes each Service port also reachable on the Mac's
	@# localhost at the SAME port number (measured: 8080 -> localhost:8080). Linux keeps
	@# the plain controller: the LB IP is routable there (measured on Ubuntu 24.04).
	@IMAGE="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v$(CLOUD_PROVIDER_KIND_VERSION)"; \
	FLAGS="$(if $(filter Darwin,$(HOST_OS)),--enable-lb-port-mapping)"; \
	if [ -n "$$($(KIND_ENGINE) ps -aq --filter name=^cloud-provider-kind$$)" ]; then \
		if [ -n "$$FLAGS" ] && ! $(KIND_ENGINE) inspect -f '{{json .Args}}' cloud-provider-kind | grep -q -- "$$FLAGS"; then \
			echo "cloud-provider-kind is already running WITHOUT $$FLAGS, which macOS needs to reach"; \
			echo "the LoadBalancer from this Mac. It is shared by every KinD cluster here: recreate"; \
			args=$$($(KIND_ENGINE) inspect -f '{{range .Args}}{{.}} {{end}}' cloud-provider-kind); \
			echo "it with its current arguments PLUS $$FLAGS (it serves other projects too):"; \
			echo "  current arguments: $${args:-none}"; \
			echo "  $(KIND_ENGINE) rm -f cloud-provider-kind && $(KIND_ENGINE) run -d --name cloud-provider-kind --restart unless-stopped \\"; \
			echo "    --network kind -v /var/run/docker.sock:/var/run/docker.sock $$IMAGE $$args$$FLAGS"; \
			exit 1; \
		fi; \
		$(KIND_ENGINE) start cloud-provider-kind >/dev/null 2>&1 || true; \
	else \
		echo "Starting cloud-provider-kind v$(CLOUD_PROVIDER_KIND_VERSION)..."; \
		$(KIND_ENGINE) run -d --name cloud-provider-kind --restart unless-stopped \
			--network kind \
			-v /var/run/docker.sock:/var/run/docker.sock \
			"$$IMAGE" $$FLAGS >/dev/null; \
	fi; \
	if [ -z "$$($(KIND_ENGINE) ps -q --filter name=^cloud-provider-kind$$)" ]; then \
		echo "ERROR: cloud-provider-kind container failed to start"; \
		$(KIND_ENGINE) logs cloud-provider-kind 2>&1 | tail -20 || true; \
		exit 1; \
	fi; \
	echo "cloud-provider-kind running."

#kind-cloud-provider-stop: @ Clean up cloud-provider-kind after this cluster is gone (kind-delete runs it)
#kind-cloud-provider-restart: @ Restart the SHARED LB controller (affects every KinD cluster on this host)
kind-cloud-provider-restart: deps-kind
	@[ -n "$$($(KIND_ENGINE) ps -aq --filter name=^cloud-provider-kind$$)" ] || { echo "cloud-provider-kind is not running. Start it: make kind-cloud-provider-start"; exit 1; }
	@others=$$(kind get clusters 2>/dev/null | grep -vx "$(KIND_CLUSTER_NAME)" | tr '\n' ' '); \
	echo "Restarting cloud-provider-kind (shared; other KinD clusters here: $${others:-none})..."
	@$(KIND_ENGINE) restart cloud-provider-kind >/dev/null && echo "Restarted."

kind-cloud-provider-stop:
	@# kind-delete runs this AFTER deleting the cluster. Called directly while the
	@# cluster exists, it would delete the sidecars that cluster's LoadBalancer still
	@# uses, so refuse instead.
	@clusters=$$(kind get clusters 2>/dev/null) || { echo "Cannot list KinD clusters (is kind/docker working?); nothing stopped."; exit 1; }; \
	if printf '%s\n' "$$clusters" | grep -qx "$(KIND_CLUSTER_NAME)"; then \
		echo "KinD cluster '$(KIND_CLUSTER_NAME)' still exists and uses cloud-provider-kind; nothing stopped."; \
		echo "  To remove the cluster and clean up after it: make kind-delete"; \
		exit 1; \
	fi
	@# cloud-provider-kind spawns a per-Service Envoy sidecar named
	@# kindccm-<hash>. These SURVIVE `kind delete cluster` and keep holding
	@# IPs in the kind Docker subnet; a later kind-create can land on an
	@# orphan's IP and inherit its stale Envoy config (pointed at pods from
	@# the previous run) -> "connection reset by peer" on the first curl.
	@#
	@# Scope the prune by the cluster LABEL that cloud-provider-kind stamps
	@# on each sidecar. A bare `--filter name=kindccm-` would also delete the
	@# sidecars of every OTHER KinD cluster on this host -- this box routinely
	@# has more than one, and a teardown must remove only what it created.
	@ORPHANS=$$($(KIND_ENGINE) ps -aq \
		--filter "label=io.x-k8s.cloud-provider-kind.cluster=$(KIND_CLUSTER_NAME)" 2>/dev/null); \
	if [ -n "$$ORPHANS" ]; then \
		echo "Removing leftover kindccm-* sidecars of '$(KIND_CLUSTER_NAME)'..."; \
		$(KIND_ENGINE) rm -f $$ORPHANS >/dev/null 2>&1 || true; \
	fi
	@# The controller is a HOST-WIDE SINGLETON shared by every KinD cluster on
	@# this machine. Only stop it once no KinD clusters remain, or tearing this
	@# one down would strip LoadBalancer support from the others.
	@clusters=$$(kind get clusters 2>/dev/null) || { echo "Cannot list KinD clusters; leaving cloud-provider-kind alone."; exit 1; }; \
	REMAINING=$$(printf '%s\n' "$$clusters" | grep -c . || true); \
	if [ "$${REMAINING:-0}" -ne 0 ]; then \
		echo "$$REMAINING other KinD cluster(s) present; leaving cloud-provider-kind running."; \
	elif [ -n "$$($(KIND_ENGINE) ps -aq --filter name=^cloud-provider-kind$$)" ]; then \
		$(KIND_ENGINE) rm -f cloud-provider-kind >/dev/null 2>&1 || true; \
		echo "No KinD clusters remain; cloud-provider-kind stopped."; \
	else \
		echo "No KinD clusters remain; cloud-provider-kind was not running."; \
	fi

# Context AND namespace: k8s/golang-web.yaml sets no namespace, so without one every call
# used the context's namespace -- MEASURED on a box where kind-golang-web carried a
# namespace that did not exist, so apply, lookups and undeploy all missed the app.
KIND_NAMESPACE ?= default
KCTX := --context kind-$(KIND_CLUSTER_NAME) --namespace $(KIND_NAMESPACE)
# The label cloud-provider-kind puts on THIS Service's sidecar (one sidecar per Service).
KIND_LB_LABEL := io.x-k8s.cloud-provider-kind.loadbalancer.name=$(KIND_CLUSTER_NAME)/$(KIND_NAMESPACE)/golang-web-service

# $(call kind_url): set URL to where THIS cluster's golang-web answers, or leave it empty.
# Candidates: the LoadBalancer IP (routable on Linux) and, where cloud-provider-kind
# publishes the Service port (macOS), that host port. A 200 is NOT proof: on macOS a
# local `make image-run-bg` on the same port answered instead of the cluster (measured),
# so the reply must name this cluster's node (MY_NODE_NAME, from the Downward API).
define kind_url
lbip=$$(kubectl $(KCTX) get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
cands=""; [ -z "$$lbip" ] || cands="http://$$lbip:$(SERVICE_PORT)"; \
sc=$$($(KIND_ENGINE) ps -q --filter label=$(KIND_LB_LABEL) | head -1); \
if [ -n "$$sc" ]; then hp=$$($(KIND_ENGINE) port "$$sc" $(SERVICE_PORT)/tcp 2>/dev/null | head -1 | sed 's/.*://'); \
  [ -z "$$hp" ] || cands="$$cands http://127.0.0.1:$$hp"; fi; \
URL=""; for u in $$cands; do \
  case "$$(curl -s --max-time $(CURL_MAX_TIME) "$$u/myhello/" 2>/dev/null)" in \
    *"MY_NODE_NAME: $(KIND_CLUSTER_NAME)-control-plane"*) URL=$$u; break;; esac; done
endef

#kind-create: @ Create local KinD cluster with cloud-provider-kind LoadBalancer support
kind-create: deps-kind
	@# Build for the KinD NODE's architecture, taken from the engine kind runs on --
	@# not PLATFORM's arm64-host default (amd64, for real clusters). Own tag: KIND_IMAGE.
	@$(call engine_ready,$(KIND_ENGINE)); \
	arch=$$($(KIND_ENGINE) info --format '{{.Architecture}}'); \
	case "$$arch" in aarch64|arm64) plat=linux/arm64;; x86_64|amd64) plat=linux/amd64;; \
	  *) echo "Unknown KinD node architecture '$$arch' ($(KIND_ENGINE) info)."; exit 1;; esac; \
	echo "Building $(KIND_IMAGE) for the KinD node ($$plat)..."; \
	$(MAKE) --no-print-directory image-build PLATFORM=$$plat OPV=$(KIND_IMAGE)
	@if kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER_NAME)"; then \
		echo "KinD cluster '$(KIND_CLUSTER_NAME)' already exists, switching context..."; \
		kubectl config use-context kind-$(KIND_CLUSTER_NAME); \
	else \
		echo "Creating KinD cluster '$(KIND_CLUSTER_NAME)'..."; \
		kind create cluster --config=k8s/kind-config.yaml --name $(KIND_CLUSTER_NAME) --wait 60s; \
	fi
	@$(MAKE) --no-print-directory kind-cloud-provider-start
	@echo "Loading image $(KIND_IMAGE) into cluster (built with $(DOCKERCMD))..."
	@# `kind load docker-image` reads the store of the engine kind is USING
	@# ($(KIND_ENGINE)). When the image was built by a DIFFERENT engine -- the
	@# normal case here, since CONTAINER_ENGINE prefers podman -- that store does
	@# not have it, and the load silently pulls/fails instead of using your build.
	@# `save` + `image-archive` bridges the two stores and is engine-neutral.
	@# Measured: a podman-built image lands in the docker-based node this way.
	@if [ "$(DOCKERCMD)" = "$(KIND_ENGINE)" ]; then \
		kind load docker-image $(KIND_IMAGE) --name $(KIND_CLUSTER_NAME); \
	else \
		archive=$$(mktemp -t kind-image-XXXXXX.tar); \
		trap 'rm -f "$$archive"' EXIT; \
		$(DOCKERCMD) save -o "$$archive" $(KIND_IMAGE); \
		kind load image-archive "$$archive" --name $(KIND_CLUSTER_NAME); \
	fi
	@echo "KinD cluster ready (LoadBalancer via cloud-provider-kind)."

#kind-deploy: @ Deploy application to KinD cluster and wait for rollout + routable LB
kind-deploy: kind-create
	@# On macOS the Service port is published on this Mac's localhost. If something else
	@# already serves it, the cluster cannot publish there -- say so before deploying.
	@if [ "$(HOST_OS)" = Darwin ] && (exec 3<>/dev/tcp/127.0.0.1/$(SERVICE_PORT)) 2>/dev/null \
	   && [ -z "$$($(KIND_ENGINE) ps -q --filter label=$(KIND_LB_LABEL))" ]; then \
		case "$$(curl -s --max-time $(CURL_MAX_TIME) http://127.0.0.1:$(SERVICE_PORT)/myhello/ 2>/dev/null)" in \
		  *"MY_NODE_NAME: $(KIND_CLUSTER_NAME)-control-plane"*) ;; \
		  *) echo "Port $(SERVICE_PORT) on this Mac is already in use, and KinD publishes the Service there."; \
		     echo "  Free it first (a local golang-web? make image-stop)."; exit 1;; \
		esac; \
	fi
	@echo "Deploying $(KIND_IMAGE) to KinD cluster '$(KIND_CLUSTER_NAME)'..."
	@# imagePullPolicy: Never -- the pod must run the image kind-create loaded, never a
	@# registry copy that happens to share the tag.
	@perl -pe 's|^(\s*)image: .*/$(PROJECT):.*|$$1image: $(KIND_IMAGE)\n$$1imagePullPolicy: Never|' k8s/golang-web.yaml \
		| kubectl $(KCTX) apply -f -
	@echo "Waiting for deployment rollout..."
	@kubectl $(KCTX) rollout status deployment/golang-web --timeout=$(ROLLOUT_TIMEOUT) || { \
		echo ""; echo "Rollout did not finish. Pod state:"; \
		kubectl $(KCTX) get pods -l app=golang-web -o wide; \
		kubectl $(KCTX) get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp | tail -5; \
		exit 1; }
	@# Two-phase LoadBalancer readiness. Phase 1 waits for cloud-provider-kind
	@# to ASSIGN an IP. Phase 2 waits for the data path to be ROUTABLE: the IP
	@# appears in status.loadBalancer.ingress before the kindccm Envoy sidecar
	@# has wired its rules, so an immediate curl gets "connection reset by
	@# peer". Asserting only phase 1 makes the first e2e assertion flaky.
	@echo "Waiting for LoadBalancer IP (phase 1/2)..."
	@# cloud-provider-kind is a HOST-WIDE SINGLETON shared by every KinD cluster.
	@# Observed: deleting and recreating a cluster can leave a long-lived controller
	@# wedged -- its watch dies ("Unexpected EOF during watch stream event decoding")
	@# and it never re-establishes one, so the IP stays <pending> forever with the
	@# pod perfectly healthy. Say so, because a bare `kubectl wait` timeout points at
	@# the Service and the real cause is a container on the host.
	@kubectl $(KCTX) wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
		svc/golang-web-service --timeout=$(LB_WAIT_TIMEOUT) || { \
		echo ""; \
		if $(KIND_ENGINE) logs cloud-provider-kind 2>&1 | grep -q 'already allocated'; then \
			echo "No LoadBalancer IP: cloud-provider-kind could not publish port $(SERVICE_PORT) on this"; \
			echo "machine because something else holds it. Free that port, then: make kind-deploy"; \
			exit 1; fi; \
		echo "No LoadBalancer IP. The pod may be fine -- check the CONTROLLER:"; \
		echo "  $(KIND_ENGINE) logs --tail 20 cloud-provider-kind"; \
		echo "If its last line is a watch EOF and nothing follows, it is wedged. Restart it:"; \
		echo "  make kind-cloud-provider-restart"; \
		echo "WARNING: that controller is shared with every other KinD cluster on this"; \
		echo "host ($$(kind get clusters 2>/dev/null | tr '\n' ' ')) -- restarting it"; \
		echo "re-reconciles THEIR LoadBalancers too, which can change their IPs."; \
		exit 1; }
	@echo "Waiting for the service to answer (phase 2/2)..."
	@for i in $$(seq 1 $(LB_ROUTE_RETRIES)); do \
		$(call kind_url); \
		if [ -n "$$URL" ]; then echo "Service reachable at $$URL/myhello/"; exit 0; fi; \
		sleep $(LB_POLL_INTERVAL); \
	done; \
	echo "ERROR: golang-web in KinD did not answer after $(LB_ROUTE_RETRIES) attempts (tried: $${cands:-none -- no LoadBalancer IP})."; \
	kubectl $(KCTX) get svc golang-web-service -o wide; \
	kubectl $(KCTX) get pods -l app=golang-web; \
	exit 1

#kind-undeploy: @ Remove application from KinD cluster
kind-undeploy: deps-kind
	@kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER_NAME)" || { echo "No KinD cluster '$(KIND_CLUSTER_NAME)'; nothing to undeploy."; exit 0; }; \
	out=$$(kubectl $(KCTX) delete -f k8s/golang-web.yaml --ignore-not-found=true 2>&1) || { printf '%s\n' "$$out"; exit 1; }; \
	if [ -n "$$out" ]; then printf '%s\n' "$$out"; else echo "golang-web was not deployed in '$(KIND_CLUSTER_NAME)'; nothing to remove."; fi

#kind-delete: @ Delete KinD cluster, then stop cloud-provider-kind and prune its sidecars
kind-delete: deps-kind
	@# Delete the cluster FIRST: kind-cloud-provider-stop refuses while it exists, and
	@# the sidecars it prunes survive the delete (they carry the cluster label).
	@if kind get clusters 2>/dev/null | grep -qx "$(KIND_CLUSTER_NAME)"; then \
		kind delete cluster --name $(KIND_CLUSTER_NAME) >/dev/null 2>&1 || { echo "kind delete cluster --name $(KIND_CLUSTER_NAME) failed."; exit 1; }; \
		echo "KinD cluster '$(KIND_CLUSTER_NAME)' deleted."; \
	else echo "No KinD cluster '$(KIND_CLUSTER_NAME)' to delete."; fi
	@$(MAKE) --no-print-directory kind-cloud-provider-stop

#e2e: @ Run end-to-end tests against KinD cluster
e2e: kind-deploy
	@echo "=== E2E Tests ==="
	@$(call kind_url); \
	[ -n "$$URL" ] || { echo "golang-web in KinD is not reachable (tried: $${cands:-none}). Run: make kind-deploy"; exit 1; }; \
	BASE_URL="$$URL"; \
	PASS=0; FAIL=0; \
	echo "Base URL: $$BASE_URL"; \
	echo ""; \
	echo "--- Test 1: GET /myhello/ returns 200 and Hello ---"; \
	RESP=$$(curl -sf "$$BASE_URL/myhello/"); \
	if echo "$$RESP" | grep -q "Hello, World"; then \
		echo "  PASS: Got 'Hello, World'"; PASS=$$((PASS+1)); \
	else \
		echo "  FAIL: Expected 'Hello, World', got: $$RESP"; FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	echo "--- Test 2: GET /healthz returns 200 and health ok ---"; \
	RESP=$$(curl -sf "$$BASE_URL/healthz"); \
	if echo "$$RESP" | grep -q '"health":"ok"'; then \
		echo "  PASS: Health check ok"; PASS=$$((PASS+1)); \
	else \
		echo "  FAIL: Health check failed: $$RESP"; FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	echo "--- Test 3: GET /metrics returns Prometheus metrics ---"; \
	RESP=$$(curl -sf "$$BASE_URL/metrics"); \
	if echo "$$RESP" | grep -q "request_count_promtotal"; then \
		echo "  PASS: Prometheus metrics present"; PASS=$$((PASS+1)); \
	else \
		echo "  FAIL: Prometheus metrics missing"; FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	echo "--- Test 4: Kubernetes Downward API env vars populated ---"; \
	RESP=$$(curl -sf "$$BASE_URL/myhello/"); \
	if echo "$$RESP" | grep -q "MY_POD_NAME:" && ! echo "$$RESP" | grep -q "MY_POD_NAME: empty"; then \
		echo "  PASS: Downward API vars populated"; PASS=$$((PASS+1)); \
	else \
		echo "  FAIL: Downward API vars not populated: $$RESP"; FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	echo "--- Test 5: Request counter increments ---"; \
	curl -sf "$$BASE_URL/myhello/" >/dev/null; \
	RESP=$$(curl -sf "$$BASE_URL/myhello/"); \
	REQ_NUM=$$(echo "$$RESP" | grep "^request" | awk '{print $$2}'); \
	if [ "$$REQ_NUM" -gt 0 ] 2>/dev/null; then \
		echo "  PASS: Request counter at $$REQ_NUM"; PASS=$$((PASS+1)); \
	else \
		echo "  FAIL: Request counter not incrementing"; FAIL=$$((FAIL+1)); \
	fi; \
	echo ""; \
	echo "=== Results: $$PASS passed, $$FAIL failed ==="; \
	if [ $$FAIL -gt 0 ]; then exit 1; fi

#ci: @ Run full local CI pipeline
ci: deps deps-verify format deps-prune-check static-check coverage-check build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act (needs a running Docker)
ci-run: deps
	@# No `docker container prune -f` any more: MEASURED, it deleted an unrelated stopped
	@# container belonging to someone else. act removes its own stale job containers, and
	@# --rm removes them after a failure too (a failed job's container was left running).
	@command -v docker >/dev/null 2>&1 || { echo "ci-run needs Docker: act runs each job in a Docker container. Install it: https://docs.docker.com/get-docker/"; exit 1; }
	@$(call engine_ready,docker)
	@# --container-daemon-socket: act bind-mounts the Docker socket into each job container.
	@# By default it uses the CLIENT's socket path; with Colima that is ~/.colima/docker.sock,
	@# which the daemon (inside Colima's VM) cannot mount -- "mkdir ...docker.sock: operation
	@# not supported" (measured). /var/run/docker.sock is the daemon's own socket on Linux,
	@# Colima and Docker Desktop alike.
	@# Job containers run in the Docker engine's own architecture unless ACT_ARCH is set.
	@# MEASURED on an Apple-silicon Mac with Colima (no Rosetta): linux/amd64 runs under
	@# qemu-user, the Go toolchain panics ("growslice: len out of range") while mise installs
	@# govulncheck, and the workflow's mise step fails; linux/arm64 passes all jobs.
	@plat='$(ACT_ARCH)'; \
	if [ -z "$$plat" ]; then \
	  arch=$$(docker info --format '{{.Architecture}}') || { echo "docker info failed (output above); start Docker and retry."; exit 1; }; \
	  case "$$arch" in aarch64|arm64) plat=linux/arm64;; x86_64|amd64) plat=linux/amd64;; \
	    *) echo "Docker engine architecture '$$arch' has no act runner mapping here. Set one: make ci-run ACT_ARCH=linux/<arch>"; exit 1;; esac; \
	fi; \
	echo "Running the CI workflow with act in $$plat job containers..."; \
	[ "$$plat" = linux/amd64 ] || echo "Note: GitHub runs this workflow on linux/amd64; this $$plat run does not prove amd64."; \
	act push --container-architecture "$$plat" --rm \
		--container-daemon-socket unix:///var/run/docker.sock \
		-P ubuntu-latest=$(ACT_RUNNER_IMAGE)

#release: @ Create and push a new tag
release:
	@# Only git is needed here (no `deps`: it printed tool noise right before the prompt).
	@bash -c 'read -r -p "New tag (current: $(CURRENTTAG)): " newtag || { echo "Aborted: no tag entered."; exit 1; }; \
		echo "$$newtag" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" || { echo "Error: Tag must match vN.N.N"; exit 1; }; \
		if git rev-parse -q --verify "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists locally. Pick a new version or delete it: git tag -d $$newtag"; exit 1; fi; \
		if git ls-remote --exit-code --tags origin "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists on origin. Pick a new version."; exit 1; fi; \
		read -r -p "Create and push $$newtag? [y/N] " ans || ans=N; \
		case "$$ans" in y|Y|yes|YES) ;; *) echo "Aborted: nothing tagged or pushed."; exit 0;; esac; \
		echo $$newtag > ./version.txt && \
		git add version.txt && \
		git commit -s -m "Cut $$newtag release" && \
		git tag $$newtag && \
		git push origin $$newtag && \
		git push && \
		echo "Done."'

#version: @ Print current version (tag)
version:
	@echo $(shell git describe --tags --abbrev=0)

#renovate-bootstrap: @ Verify Node (installed via mise) is available for `npx renovate`
renovate-bootstrap: deps
	@# Node is pinned in .mise.toml and installed by `make deps`. This
	@# replaces the previous nvm bootstrap, which sourced ~/.nvm/nvm.sh
	@# inside the recipe shell and pinned Node in a second place.
	@command -v node >/dev/null 2>&1 || { \
		echo "Error: node not found. Run 'make deps' to install it via mise (.mise.toml)."; \
		exit 1; \
	}
	@echo "node $$(node --version) is available for npx."

#renovate-validate: @ Validate the Renovate configuration (renovate.json)
renovate-validate: renovate-bootstrap
	@# renovate-config-validator checks the config itself: no GitHub token, ~1 s, and a
	@# broken option exits 1 naming it. The previous full `--platform=local` run did
	@# dependency LOOKUPS instead, hit the GitHub rate limit without a token, took 24 s,
	@# and never said whether the config was valid.
	@npx --yes --package=renovate@$(RENOVATE_VERSION) -- renovate-config-validator

#deps-prune: @ Remove unused dependencies
deps-prune: deps
	@before=$$(cat go.mod go.sum | cksum); go mod tidy || exit 1; \
	if [ "$$before" = "$$(cat go.mod go.sum | cksum)" ]; then echo "Nothing to prune: go.mod / go.sum already tidy."; \
	else echo "Pruned (go mod tidy changed go.mod / go.sum):"; git diff --stat -- go.mod go.sum; fi

#deps-prune-check: @ Verify no prunable dependencies (CI gate)
deps-prune-check: deps
	@# Compare against a SNAPSHOT of the working files, never against git: the old
	@# `git diff` + `git checkout go.mod go.sum` threw away uncommitted go.mod edits
	@# (MEASURED: an added line was gone after the check).
	@tmp=$$(mktemp -d) && cp go.mod go.sum "$$tmp"/ || { echo "Could not snapshot go.mod/go.sum; not running go mod tidy."; exit 1; }; \
	go mod tidy || { cp "$$tmp"/go.mod "$$tmp"/go.sum .; rm -rf "$$tmp"; exit 1; }; \
	if cmp -s go.mod "$$tmp"/go.mod && cmp -s go.sum "$$tmp"/go.sum; then \
		rm -rf "$$tmp"; echo "No prunable dependencies found."; \
	else \
		cp "$$tmp"/go.mod "$$tmp"/go.sum . || { echo "RESTORE FAILED: your originals are in $$tmp"; exit 1; }; rm -rf "$$tmp"; \
		echo "go.mod / go.sum are not tidy (left exactly as they were). Fix: make deps-prune"; \
		exit 1; \
	fi

.PHONY: help engines deps deps-engine deps-buildx registry-login deps-verify deps-kind check-toolchain-alignment \
	diagrams diagrams-check \
	test build lint lint-ci sec vulncheck secrets \
	trivy-fs trivy-config static-check format run coverage-check \
	image-build clean update \
	image-test-fg image-run-bg \
	image-logs image-stop image-push \
	k8s-apply k8s-delete \
	kind-cloud-provider-start kind-cloud-provider-stop kind-cloud-provider-restart \
	kind-create kind-deploy kind-undeploy kind-delete e2e \
	ci ci-run release version \
	renovate-bootstrap renovate-validate \
	deps-prune deps-prune-check
