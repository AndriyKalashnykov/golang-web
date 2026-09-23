.DEFAULT_GOAL := help

OWNER := andriykalashnykov
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
# ECR, Quay... Only the DEFAULT happens to be GHCR. GH_ACCESS_TOKEN / CR_PAT are
# accepted as fallbacks purely so an already-exported GitHub PAT works out of the
# box against the default registry -- they are NOT the canonical name.
# (Contrast `renovate-validate`, which keeps GH_ACCESS_TOKEN deliberately: that
# credential must be a GitHub token, so the provider belongs in its name.)
REGISTRY_USERNAME ?= $(OWNER)
REGISTRY_TOKEN    ?= $(or $(GH_ACCESS_TOKEN),$(CR_PAT))
# Exported so the RECIPE SHELL can read them as `$$VAR`. Without this the recipe would have to
# use `$(VAR)`, which is a make-time expansion -- see the comment on registry-login.
export REGISTRY_TOKEN
export REGISTRY_USERNAME
OPV := $(IMAGE_REGISTRY)/$(OWNER)/$(PROJECT):$(VERSION)
WEBPORT := 8080:8080
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
RENOVATE_VERSION    := 43.110.12
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

# === Tunables (override on the command line or via the environment) ===
APP_PORT           ?= 8080
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
KIND_IMAGE          := $(OPV)

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

# uname is used only to pick the right podman install command in `deps`.
HOST_OS := $(shell uname -s)

BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
# unique id from last git commit
MY_GITREF := $(shell git rev-parse --short HEAD)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-22s\033[0m - %s\n", $$1, $$2}'
	@echo ""
	@echo "Container engines (resolved now; run 'make engines' for what each one does):"
	@printf "\033[32m%-22s\033[0m - %s\n" "CONTAINER_ENGINE" "$(CONTAINER_ENGINE)  <- builds YOUR image; this is the one you set"
	@printf "\033[32m%-22s\033[0m - %s\n" "KIND_ENGINE" "$(KIND_ENGINE)  <- kind's own containers; not yours to change"
	@printf "\033[32m%-22s\033[0m - %s\n" "DIAGRAMS_ENGINE" "$(DIAGRAMS_ENGINE)  <- plantuml render"
	@echo ""
	@echo "  one command : make image-build CONTAINER_ENGINE=docker"
	@echo "  whole shell : export CONTAINER_ENGINE=docker"

#engines: @ Show which container engine each path uses, and how to override it
engines:
	@echo "CONTAINER_ENGINE = $(CONTAINER_ENGINE)"
	@echo "    Builds YOUR application image (image-build, image-run, e2e's build step)."
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
	@echo "DIAGRAMS_ENGINE = $(DIAGRAMS_ENGINE)"
	@echo "    Runs the plantuml container for 'make diagrams'. Prefers docker: rootless"
	@echo "    podman needs --userns=keep-id locally and still cannot write on a GitHub"
	@echo "    runner, so pinning it removes a silent no-op. Falls back to podman."
	@echo ""
	@echo "Engines found on this host:"
	@for e in podman docker; do \
		if command -v $$e >/dev/null 2>&1; then \
			echo "  $$e  $$($$e --version 2>/dev/null | head -1)"; \
		else echo "  $$e  (not installed)"; fi; \
	done

#deps: @ Install the pinned toolchain via mise (.mise.toml)
deps:
	@# mise owns every tool version. This replaces the old
	@# `command -v <tool> >/dev/null || go install ...@$(VERSION)` guards,
	@# which SHORT-CIRCUITED whenever any version of the tool was already on
	@# PATH -- so the pinned version was never actually installed and local
	@# tools silently drifted from the pins. `mise install` is idempotent and
	@# always converges on the pinned version, on Linux and macOS alike.
	@$(MAKE) --no-print-directory deps-engine
	@if ! command -v mise >/dev/null 2>&1; then \
		if [ -n "$$CI" ]; then \
			echo "Error: mise not installed in CI. Ensure jdx/mise-action runs before 'make deps'."; \
			exit 1; \
		fi; \
		echo "Installing mise (no root; installs to ~/.local/bin)..."; \
		curl -fsSL https://mise.run | sh; \
		echo ""; \
		echo "mise installed. Activate it in your shell (one-time setup):"; \
		echo "  echo 'eval \"\$$(mise activate bash)\"' >> ~/.bashrc   # or the zsh equivalent"; \
		echo "Then re-run 'make deps'."; \
		exit 0; \
	fi
	@mise install --yes

#deps-engine: @ Ensure a container engine is present (installs podman if neither is)
deps-engine:
	@# Either engine works. podman is installed when neither is present because it
	@# is rootless by default and needs no daemon; docker is equally supported and
	@# is picked up automatically if it is the one already installed.
	@if [ "$(CONTAINER_ENGINE)" != "none" ]; then \
		echo "Container engine: $(CONTAINER_ENGINE) ($$($(CONTAINER_ENGINE) --version 2>/dev/null | head -1))"; \
		$(MAKE) --no-print-directory deps-buildx; \
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
	@$(CONTAINER_ENGINE) buildx version >/dev/null 2>&1 && exit 0; \
	echo "ERROR: '$(CONTAINER_ENGINE) buildx' is not available -- 'make image-build' cannot run."; \
	if [ "$(CONTAINER_ENGINE)" = "docker" ]; then \
		case "$(HOST_OS)" in \
		  Darwin) echo "  Install buildx:  brew install docker-buildx";; \
		  Linux)  echo "  Install the plugin:  sudo apt-get install -y docker-buildx-plugin"; \
		          echo "                  or:  sudo dnf install -y docker-buildx-plugin"; \
		          echo "  Or switch engines:   make image-build CONTAINER_ENGINE=podman";; \
		esac; \
	else \
		echo "  podman provides buildx via buildah; upgrade podman (>= 4.0)."; \
	fi; \
	exit 1

#registry-login: @ Log in to $(IMAGE_REGISTRY) so `make image-push` can publish
registry-login:
	@# The token is passed on STDIN, never on the command line -- anything in argv is
	@# visible to any local user via `ps` / /proc/<pid>/cmdline for the life of the call.
	@# `$(REGISTRY_TOKEN)` (single $) is a MAKE-TIME expansion: make bakes the secret into the
	@# recipe TEXT it hands to `sh -c`, so it lands in that shell's argv. MEASURED: a canary token
	@# was readable in `ps -eo args` for the life of the login. `$$REGISTRY_TOKEN` defers to the
	@# SHELL, which reads it from the exported environment instead -- argv stays clean.
	@# The same applies to REGISTRY_USERNAME: a Harbor robot is named `robot$$project+name`, and
	@# make ate the `$a`, turning robot$$apps+golang-web-push into robotpps+golang-web-push.
	@tok="$$REGISTRY_TOKEN"; usr="$$REGISTRY_USERNAME"; \
	[ -n "$$usr" ] || usr='$(REGISTRY_USERNAME)'; \
	if [ -z "$$tok" ]; then \
		echo "ERROR: no credential for $(IMAGE_REGISTRY) in the environment."; \
		echo "    export REGISTRY_TOKEN=<token-or-password>"; \
		echo "    export REGISTRY_USERNAME=<user>   # optional; defaults to $(OWNER)"; \
		echo "    make registry-login"; \
		case "$(IMAGE_REGISTRY)" in \
		  ghcr.io) echo "  For ghcr.io this is a GitHub PAT with 'write:packages':"; \
		           echo "  https://github.com/settings/tokens"; \
		           echo "  (GH_ACCESS_TOKEN / CR_PAT are also accepted for convenience.)";; \
		  *)       echo "  Use whatever credential $(IMAGE_REGISTRY) issues (Harbor robot"; \
		           echo "  account, Docker Hub access token, ECR password, ...).";; \
		esac; \
		exit 1; \
	fi; \
	printf '%s' "$$tok" | $(CONTAINER_ENGINE) login $(IMAGE_REGISTRY) -u "$$usr" --password-stdin

#deps-verify: @ Verify every pinned tool is on PATH (fails with a pointer to `make deps`)
deps-verify: deps
	@missing=""; \
	for t in go golangci-lint gosec gitleaks actionlint shellcheck hadolint trivy govulncheck; do \
		command -v "$$t" >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "Error: not on PATH:$$missing"; \
		echo "Run 'make deps', and ensure mise is activated in your shell:"; \
		echo "  eval \"\$$(mise activate bash)\"   # or the zsh equivalent"; \
		exit 1; \
	fi; \
	echo "All pinned tools present."

#check-toolchain-alignment: @ Verify the Go version agrees across go.mod, Dockerfile and .mise.toml
check-toolchain-alignment:
	@gomod=$$(grep -oE '^go [0-9]+\.[0-9]+(\.[0-9]+)?' go.mod | awk '{print $$2}'); \
	docker=$$(grep -oE '^FROM golang:[0-9]+\.[0-9]+(\.[0-9]+)?' Dockerfile | head -1 | sed 's/^FROM golang://'); \
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
	@trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH .

#trivy-config: @ Scan K8s manifests for security misconfigurations
trivy-config: deps
	@trivy config k8s/

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
	@actionlint

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
# How to map the invoking user into the plantuml container, per engine.
# ROOTLESS PODMAN maps `-u <uid>` to a SUBUID, not the host uid, so the container
# cannot write the host-owned bind mount -- plantuml prints "Cannot write to file"
# and STILL EXITS 0, so the render silently produces nothing. --userns=keep-id
# maps the host uid through instead. Measured with the pinned tag:
#   -u uid:gid      -> "Cannot write to file", rc=0, PNG untouched
#   --userns=keep-id-> renders, byte-identical to docker's output
# The plantuml render is pinned to DOCKER, for the same reason the KinD path is.
# Measured: docker with -u uid:gid renders byte-identically here; rootless podman
# needs --userns=keep-id locally and STILL fails on the GitHub runner -- run
# 35798784796 logged "Cannot write to file" with keep-id applied and JAVA_TOOL_OPTIONS
# picked up, because the runner's podman maps uids differently again. Docker is
# present on ubuntu-latest and on this box, so pinning removes the variability
# instead of chasing a third uid-mapping. podman stays the fallback where docker
# is absent, with the keep-id mapping that does work locally.
DIAGRAMS_ENGINE ?= $(if $(shell command -v docker 2>/dev/null),docker,$(DOCKERCMD))
PLANTUML_RUN_FLAGS := $(if $(filter podman,$(DIAGRAMS_ENGINE)),--userns=keep-id,-u "$$(id -u):$$(id -g)")

# The container user has no passwd entry, so OpenJDK resolves user.home to "?"
# and writes its fontconfig cache into the BIND MOUNT -- littering the repo with
# docs/diagrams/?/.java/fonts and docs/diagrams/.java/fonts. `-e HOME=/tmp` does
# NOT fix it: OpenJDK derives user.home from getpwuid(), not $HOME. Only
# -Duser.home redirects it.

diagrams:
	@# Pre-create the output dir AS THE INVOKING USER: `docker run -v` creates a
	@# missing bind-mount source as root, and the next non-root write then fails.
	@mkdir -p docs/diagrams/out
	@# The marker predates the render, so every expected PNG must end up NEWER
	@# than it. plantuml exits 0 even when it cannot write, so an exit-code check
	@# alone cannot catch a silent no-op -- and a no-op makes diagrams-check pass
	@# VACUOUSLY (nothing rewritten => nothing for `git diff` to see).
	@marker=$$(mktemp); \
	$(DIAGRAMS_ENGINE) run --rm $(PLANTUML_RUN_FLAGS) \
		-e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
		-v "$$PWD/docs/diagrams:/data" \
		plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o /data/out /data/*.puml; \
	rc=$$?; \
	if [ $$rc -ne 0 ]; then rm -f "$$marker"; echo "ERROR: plantuml exited $$rc"; exit 1; fi; \
	for puml in docs/diagrams/*.puml; do \
		png="docs/diagrams/out/$$(basename "$$puml" .puml).png"; \
		if [ ! -f "$$png" ]; then rm -f "$$marker"; echo "ERROR: $$png was not produced"; exit 1; fi; \
		if [ ! "$$png" -nt "$$marker" ]; then \
			rm -f "$$marker"; \
			echo "ERROR: $$png was NOT written by this run (engine=$(DIAGRAMS_ENGINE))."; \
			echo "  plantuml exits 0 even when it cannot write the bind mount."; \
			exit 1; \
		fi; \
	done; \
	rm -f "$$marker"; \
	echo "Diagrams rendered to docs/diagrams/out/."

#diagrams-check: @ Verify committed diagram PNGs match their .puml sources
diagrams-check:
	@# Drift gate: re-render and diff. A committed PNG that no longer matches its
	@# source means the README is advertising a stale architecture.
	@command -v $(DIAGRAMS_ENGINE) >/dev/null 2>&1 || { echo "Skipping diagrams-check: $(DIAGRAMS_ENGINE) not available."; exit 0; }
	@grep -q "C4-PlantUML/$(C4_PLANTUML_VERSION)/" docs/diagrams/*.puml || { \
		echo "ERROR: a .puml !include does not pin C4-PlantUML $(C4_PLANTUML_VERSION)"; \
		grep -n 'C4-PlantUML' docs/diagrams/*.puml; exit 1; }
	@$(MAKE) --no-print-directory diagrams >/dev/null
	@if ! git diff --quiet -- docs/diagrams/out/; then \
		echo "ERROR: committed diagram PNGs are stale. Run 'make diagrams' and commit the result:"; \
		git diff --stat -- docs/diagrams/out/; \
		exit 1; \
	fi
	@echo "Diagrams up to date with their .puml sources."

#static-check: @ Run all quality and security checks
static-check: check-toolchain-alignment lint-ci lint sec vulncheck secrets trivy-fs trivy-config diagrams-check
	@echo "Static check passed."

#format: @ Auto-format Go source files
format: deps
	@golangci-lint fmt ./...

#run: @ Run the application locally
run: deps
	@go run main.go

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

#image-build: @ Build Docker image
image-build: build
	@echo MY_GITREF is $(MY_GITREF)
	@$(DOCKERCMD) buildx build --load --build-arg MY_VERSION=$(VERSION) --build-arg MY_BUILDTIME=$(BUILD_TIME) -f Dockerfile -t $(OPV) .

#clean: @ Remove Docker image and build artifacts
clean:
	@$(DOCKERCMD) image rm $(OPV) || true
	@rm -f manager coverage.out

#update: @ Update dependency packages to latest versions
update: deps
	@go get -u ./...; go mod tidy

#image-test-fg: @ Run container in foreground with test overrides
image-test-fg: image-build
	@$(DOCKERCMD) run -it -p $(WEBPORT) \
	-e APP_CONTEXT=/myhello/ \
	-e MY_NODE_NAME=node1 \
	-e MY_POD_NAME=pod1 \
	-e MY_POD_NAMESPACE=ns1 \
	-e MY_POD_IP=podip1 \
	-e MY_POD_SERVICE_ACCOUNT=podsa1 \
	--rm $(OPV)

#image-test-cli: @ Run container with shell entrypoint
image-test-cli:
	@$(DOCKERCMD) run -it --rm --entrypoint "/bin/sh" $(OPV)

#image-run-bg: @ Run container in background
image-run-bg: image-build
	@$(DOCKERCMD) run -d -p $(WEBPORT) --rm --name $(PROJECT) $(OPV)

#image-cli-bg: @ Get shell in running background container
image-cli-bg: image-build
	@$(DOCKERCMD) exec -it $(PROJECT) /bin/sh

#image-logs: @ Tail container logs
image-logs:
	@$(DOCKERCMD) logs -f $(PROJECT)

#image-stop: @ Stop background container
image-stop:
	@$(DOCKERCMD) stop $(PROJECT)

#image-push: @ Push image to Docker Hub
image-push: image-build
	@# A bare `push` against an unauthenticated engine fails with `denied` / `unauthorized`
	@# and no hint about what to do. Say it here instead.
	@$(CONTAINER_ENGINE) push $(OPV) || { \
		echo ""; \
		echo "Push failed. If this was an auth error, log in first:"; \
		echo "    export REGISTRY_TOKEN=<credential for $(IMAGE_REGISTRY)>"; \
		echo "    make registry-login"; \
		exit 1; }

#k8s-apply: @ Deploy to Kubernetes cluster
k8s-apply:
	@sed -e 's|image: .*/$(PROJECT):.*|image: $(OPV)|' k8s/golang-web.yaml | kubectl apply -f -

#k8s-delete: @ Delete from Kubernetes cluster
k8s-delete:
	@kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true

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

#kind-cloud-provider-start: @ Start cloud-provider-kind (supplies LoadBalancer IPs to KinD)
kind-cloud-provider-start: deps-kind
	@# cloud-provider-kind runs on the HOST (not in the cluster), watches
	@# type=LoadBalancer Services on the `kind` Docker network, and allocates
	@# IPs from that network's subnet. No in-cluster DaemonSet, no
	@# IPAddressPool/L2Advertisement YAML, and none of MetalLB's nftables
	@# fragility on recent kindest/node images. Idempotent.
	@IMAGE="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v$(CLOUD_PROVIDER_KIND_VERSION)"; \
	if [ -n "$$($(KIND_ENGINE) ps -aq --filter name=^cloud-provider-kind$$)" ]; then \
		$(KIND_ENGINE) start cloud-provider-kind >/dev/null 2>&1 || true; \
	else \
		echo "Starting cloud-provider-kind v$(CLOUD_PROVIDER_KIND_VERSION)..."; \
		$(KIND_ENGINE) run -d --name cloud-provider-kind --restart unless-stopped \
			--network kind \
			-v /var/run/docker.sock:/var/run/docker.sock \
			"$$IMAGE" >/dev/null; \
	fi; \
	if [ -z "$$($(KIND_ENGINE) ps -q --filter name=^cloud-provider-kind$$)" ]; then \
		echo "ERROR: cloud-provider-kind container failed to start"; \
		$(KIND_ENGINE) logs cloud-provider-kind 2>&1 | tail -20 || true; \
		exit 1; \
	fi; \
	echo "cloud-provider-kind running."

#kind-cloud-provider-stop: @ Prune this cluster's kindccm-* sidecars (and the controller if unused)
#kind-cloud-provider-restart: @ Restart the SHARED LB controller (affects every KinD cluster on this host)
kind-cloud-provider-restart:
	@echo "Restarting cloud-provider-kind. Other KinD clusters on this host:"
	@kind get clusters 2>/dev/null | grep -v "^$(KIND_CLUSTER_NAME)$$" | sed 's/^/  /' || true
	@$(KIND_ENGINE) restart cloud-provider-kind >/dev/null && echo "Restarted."

kind-cloud-provider-stop:
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
		echo "Removing kindccm-* sidecars for cluster '$(KIND_CLUSTER_NAME)'..."; \
		$(KIND_ENGINE) rm -f $$ORPHANS >/dev/null 2>&1 || true; \
	fi
	@# The controller is a HOST-WIDE SINGLETON shared by every KinD cluster on
	@# this machine. Only stop it once no KinD clusters remain, or tearing this
	@# one down would strip LoadBalancer support from the others.
	@REMAINING=$$(kind get clusters 2>/dev/null | grep -v "^$(KIND_CLUSTER_NAME)$$" | grep -c . || true); \
	if [ "$${REMAINING:-0}" -eq 0 ]; then \
		$(KIND_ENGINE) rm -f cloud-provider-kind >/dev/null 2>&1 || true; \
		echo "No KinD clusters remain; cloud-provider-kind stopped."; \
	else \
		echo "$$REMAINING other KinD cluster(s) present; leaving cloud-provider-kind running."; \
	fi

#kind-create: @ Create local KinD cluster with cloud-provider-kind LoadBalancer support
kind-create: deps-kind image-build
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
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
	@echo "Deploying to KinD cluster..."
	@sed -e 's|image: .*/$(PROJECT):.*|image: $(OPV)|' k8s/golang-web.yaml | kubectl apply -f -
	@echo "Waiting for deployment rollout..."
	@kubectl rollout status deployment/golang-web --timeout=$(ROLLOUT_TIMEOUT)
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
	@kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
		svc/golang-web-service --timeout=$(LB_WAIT_TIMEOUT) || { \
		echo ""; \
		echo "No LoadBalancer IP. The pod may be fine -- check the CONTROLLER:"; \
		echo "  $(KIND_ENGINE) logs --tail 20 cloud-provider-kind"; \
		echo "If its last line is a watch EOF and nothing follows, it is wedged. Restart it:"; \
		echo "  make kind-cloud-provider-restart"; \
		echo "WARNING: that controller is shared with every other KinD cluster on this"; \
		echo "host ($$(kind get clusters 2>/dev/null | tr '\n' ' ')) -- restarting it"; \
		echo "re-reconciles THEIR LoadBalancers too, which can change their IPs."; \
		exit 1; }
	@EXTERNAL_IP=$$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
	echo "Waiting for LoadBalancer route (phase 2/2) at $$EXTERNAL_IP..."; \
	for i in $$(seq 1 $(LB_ROUTE_RETRIES)); do \
		CODE=$$(curl -s -o /dev/null -w '%{http_code}' --max-time $(CURL_MAX_TIME) "http://$$EXTERNAL_IP:$(APP_PORT)/healthz" 2>/dev/null || echo 000); \
		if [ "$$CODE" = "200" ]; then \
			echo "Service routable at http://$$EXTERNAL_IP:$(APP_PORT)"; \
			exit 0; \
		fi; \
		sleep $(LB_POLL_INTERVAL); \
	done; \
	echo "ERROR: LoadBalancer $$EXTERNAL_IP not routable after $(LB_ROUTE_RETRIES) attempts"; \
	kubectl get svc golang-web-service -o wide; \
	kubectl get pods -l app=golang-web; \
	exit 1

#kind-undeploy: @ Remove application from KinD cluster
kind-undeploy:
	@kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true

#kind-delete: @ Delete KinD cluster, stop cloud-provider-kind, prune kindccm-* sidecars
kind-delete: kind-cloud-provider-stop
	@kind delete cluster --name $(KIND_CLUSTER_NAME) 2>/dev/null || true
	@echo "KinD cluster '$(KIND_CLUSTER_NAME)' deleted."

#e2e: @ Run end-to-end tests against KinD cluster
e2e: kind-deploy
	@echo "=== E2E Tests ==="
	@EXTERNAL_IP=$$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
	BASE_URL="http://$$EXTERNAL_IP:8080"; \
	PASS=0; FAIL=0; \
	echo "Base URL: $$BASE_URL"; \
	echo ""; \
	echo "--- Test 1: GET / returns 200 and Hello ---"; \
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

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps
	@docker container prune -f 2>/dev/null || true
	@act push --container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#release: @ Create and push a new tag
release: deps
	@bash -c 'read -p "New tag (current: $(CURRENTTAG)): " newtag && \
		echo "$$newtag" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" || { echo "Error: Tag must match vN.N.N"; exit 1; } && \
		if git rev-parse -q --verify "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists locally. Pick a new version or delete it: git tag -d $$newtag"; exit 1; fi && \
		if git ls-remote --exit-code --tags origin "refs/tags/$$newtag" >/dev/null 2>&1; then echo "ERROR: tag $$newtag already exists on origin. Pick a new version."; exit 1; fi && \
		echo -n "Create and push $$newtag? [y/N] " && read ans && [ "$${ans:-N}" = y ] && \
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

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@if [ -n "$$GH_ACCESS_TOKEN" ]; then \
		GITHUB_COM_TOKEN=$$GH_ACCESS_TOKEN npx --yes renovate@$(RENOVATE_VERSION) --platform=local; \
	else \
		echo "Warning: GH_ACCESS_TOKEN not set, some dependency lookups may fail"; \
		npx --yes renovate@$(RENOVATE_VERSION) --platform=local; \
	fi

#deps-prune: @ Remove unused dependencies
deps-prune: deps
	@echo "--- Go: running go mod tidy ---"
	@go mod tidy

#deps-prune-check: @ Verify no prunable dependencies (CI gate)
deps-prune-check: deps
	@go mod tidy; \
	if ! git diff --exit-code go.mod go.sum >/dev/null 2>&1; then \
		echo "Error: go.mod/go.sum not tidy. Run 'go mod tidy'."; \
		git checkout go.mod go.sum; \
		exit 1; \
	fi; \
	echo "No prunable dependencies found."

.PHONY: help engines deps deps-engine deps-buildx registry-login deps-verify deps-kind check-toolchain-alignment \
	diagrams diagrams-check \
	test build lint lint-ci sec vulncheck secrets \
	trivy-fs trivy-config static-check format run coverage-check \
	image-build clean update \
	image-test-fg image-test-cli image-run-bg image-cli-bg \
	image-logs image-stop image-push \
	k8s-apply k8s-delete \
	kind-cloud-provider-start kind-cloud-provider-stop kind-cloud-provider-restart \
	kind-create kind-deploy kind-undeploy kind-delete e2e \
	ci ci-run release version \
	renovate-bootstrap renovate-validate \
	deps-prune deps-prune-check
