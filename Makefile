.DEFAULT_GOAL := help

OWNER := andriykalashnykov
PROJECT := golang-web
VERSION := v0.0.1
OPV := $(OWNER)/$(PROJECT):$(VERSION)
WEBPORT := 8080:8080
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
# renovate: datasource=github-releases depName=golangci/golangci-lint
GOLANGCI_VERSION    := 2.11.4
# renovate: datasource=go depName=golang.org/x/vuln/cmd/govulncheck
GOVULNCHECK_VERSION := 1.1.4
# renovate: datasource=github-releases depName=securego/gosec
GOSEC_VERSION       := 2.25.0
# renovate: datasource=github-releases depName=zricethezav/gitleaks
GITLEAKS_VERSION    := 8.30.1
# renovate: datasource=github-releases depName=rhysd/actionlint
ACTIONLINT_VERSION  := 1.7.12
# renovate: datasource=github-releases depName=nektos/act
ACT_VERSION         := 0.2.87
# renovate: datasource=github-releases depName=nvm-sh/nvm
NVM_VERSION         := 0.40.4
# NODE_VERSION tracks major only — pinned manually (Renovate cannot track major-only values)
NODE_VERSION        := 24
# renovate: datasource=github-releases depName=hadolint/hadolint
HADOLINT_VERSION    := 2.14.0
# renovate: datasource=github-releases depName=koalaman/shellcheck
SHELLCHECK_VERSION  := 0.11.0
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
KIND_VERSION        := 0.31.0
# renovate: datasource=github-releases depName=metallb/metallb
METALLB_VERSION     := 0.15.3

KIND_CLUSTER_NAME   := golang-web
KIND_IMAGE          := $(OPV)

# if not a member of the 'docker' group, add yourself: sudo usermod -aG docker $USER
DOCKERCMD := "docker"

BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
# unique id from last git commit
MY_GITREF := $(shell git rev-parse --short HEAD)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-22s\033[0m - %s\n", $$1, $$2}'

#deps: @ Check and install required dependencies
deps:
	@command -v go >/dev/null 2>&1 || { echo "Error: Go required. See https://go.dev/doc/install"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker required. See https://docs.docker.com/get-docker/"; exit 1; }
	@command -v golangci-lint >/dev/null 2>&1 || { echo "Installing golangci-lint $(GOLANGCI_VERSION)..."; \
		go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v$(GOLANGCI_VERSION); }
	@command -v govulncheck >/dev/null 2>&1 || { echo "Installing govulncheck $(GOVULNCHECK_VERSION)..."; \
		go install golang.org/x/vuln/cmd/govulncheck@v$(GOVULNCHECK_VERSION); }
	@command -v gosec >/dev/null 2>&1 || { echo "Installing gosec $(GOSEC_VERSION)..."; \
		go install github.com/securego/gosec/v2/cmd/gosec@v$(GOSEC_VERSION); }
	@command -v gitleaks >/dev/null 2>&1 || { echo "Installing gitleaks $(GITLEAKS_VERSION)..."; \
		go install github.com/zricethezav/gitleaks/v8@v$(GITLEAKS_VERSION); }
	@command -v actionlint >/dev/null 2>&1 || { echo "Installing actionlint $(ACTIONLINT_VERSION)..."; \
		go install github.com/rhysd/actionlint/cmd/actionlint@v$(ACTIONLINT_VERSION); }

#deps-act: @ Install act for local CI runs
deps-act: deps
	@command -v act >/dev/null 2>&1 || { echo "Installing act $(ACT_VERSION)..."; \
		curl -sSfL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b "$$(go env GOPATH)/bin" v$(ACT_VERSION); \
	}

#deps-shellcheck: @ Install shellcheck for shell script linting
deps-shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "Installing shellcheck $(SHELLCHECK_VERSION)..."; \
		curl -sSfL -o /tmp/shellcheck.tar.xz https://github.com/koalaman/shellcheck/releases/download/v$(SHELLCHECK_VERSION)/shellcheck-v$(SHELLCHECK_VERSION).linux.x86_64.tar.xz && \
		tar -xJf /tmp/shellcheck.tar.xz -C /tmp && \
		install -m 755 /tmp/shellcheck-v$(SHELLCHECK_VERSION)/shellcheck "$$(go env GOPATH)/bin/shellcheck" && \
		rm -rf /tmp/shellcheck-v$(SHELLCHECK_VERSION) /tmp/shellcheck.tar.xz; \
	}

#deps-hadolint: @ Install hadolint for Dockerfile linting
deps-hadolint:
	@command -v hadolint >/dev/null 2>&1 || { echo "Installing hadolint $(HADOLINT_VERSION)..."; \
		curl -sSfL -o /tmp/hadolint https://github.com/hadolint/hadolint/releases/download/v$(HADOLINT_VERSION)/hadolint-Linux-x86_64 && \
		install -m 755 /tmp/hadolint "$$(go env GOPATH)/bin/hadolint" && \
		rm -f /tmp/hadolint; \
	}

#test: @ Run tests with coverage
test: deps
	@go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	@go tool cover -func=coverage.out | sort -rnk3

#build: @ Build the Go binary
build: deps
	@CGO_ENABLED=0 go build -ldflags "-X main.Version=${VERSION} -X main.BuildTime=${BUILD_TIME}" -a -o manager main.go

#lint: @ Run static analysis
lint: deps deps-hadolint
	@golangci-lint run ./...
	@hadolint Dockerfile

#lint-ci: @ Lint GitHub Actions workflows
lint-ci: deps deps-shellcheck
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

#static-check: @ Run all quality and security checks
static-check: lint-ci lint sec vulncheck secrets
	@echo "Static check passed."

#format: @ Auto-format Go source files
format: deps
	@gofmt -l -w .

#run: @ Run the application locally
run: deps
	@go run main.go

#coverage-check: @ Verify test coverage meets threshold
coverage-check: deps
	@go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	@total=$$(go tool cover -func=coverage.out | grep total | awk '{print $$NF}' | tr -d '%'); \
	threshold=80; \
	if [ "$$(echo "$$total < $$threshold" | bc -l)" -eq 1 ]; then \
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
	@$(DOCKERCMD) image rm $(OPV) | true
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
image-push:
	@$(DOCKERCMD) push $(OPV)

#k8s-apply: @ Deploy to Kubernetes cluster
k8s-apply:
	@sed -e 's/v0.0.1/$(VERSION)/' k8s/golang-web.yaml | kubectl apply -f -

#k8s-delete: @ Delete from Kubernetes cluster
k8s-delete:
	@kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true

#deps-kind: @ Install KinD for local Kubernetes testing
deps-kind: deps
	@command -v kind >/dev/null 2>&1 || { echo "Installing kind $(KIND_VERSION)..."; \
		go install sigs.k8s.io/kind@v$(KIND_VERSION); }
	@command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl required. See https://kubernetes.io/docs/tasks/tools/"; exit 1; }

#kind-create: @ Create local KinD cluster with MetalLB
kind-create: deps-kind image-build
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "KinD cluster '$(KIND_CLUSTER_NAME)' already exists, switching context..."; \
		kubectl config use-context kind-$(KIND_CLUSTER_NAME); \
	else \
		echo "Creating KinD cluster '$(KIND_CLUSTER_NAME)'..."; \
		kind create cluster --config=k8s/kind-config.yaml --name $(KIND_CLUSTER_NAME) --wait 60s; \
	fi
	@echo "Installing MetalLB $(METALLB_VERSION)..."
	@kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v$(METALLB_VERSION)/config/manifests/metallb-native.yaml
	@echo "Waiting for MetalLB controller..."
	@kubectl rollout status deployment/controller -n metallb-system --timeout=180s
	@echo "Waiting for MetalLB speaker..."
	@kubectl rollout status daemonset/speaker -n metallb-system --timeout=180s
	@echo "Configuring MetalLB IP pool..."
	@ip_sub=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk -F. '{printf "%d.%d", $$1, $$2}'); \
	sed "s/METALLB_IP_SUB/$$ip_sub/g" k8s/metallb-config.yaml | kubectl apply -f -
	@echo "Loading image $(KIND_IMAGE) into cluster..."
	@kind load docker-image $(KIND_IMAGE) --name $(KIND_CLUSTER_NAME)
	@echo "KinD cluster ready with MetalLB."

#kind-deploy: @ Deploy application to KinD cluster and wait for rollout
kind-deploy: kind-create
	@echo "Deploying to KinD cluster..."
	@sed -e 's/v0.0.1/$(VERSION)/' k8s/golang-web.yaml | kubectl apply -f -
	@echo "Waiting for deployment rollout..."
	@kubectl rollout status deployment/golang-web --timeout=120s
	@echo "Waiting for service external IP..."
	@for i in $$(seq 1 30); do \
		EXTERNAL_IP=$$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
		if [ -n "$$EXTERNAL_IP" ] && [ "$$EXTERNAL_IP" != "<pending>" ]; then \
			echo "Service available at http://$$EXTERNAL_IP:8080"; \
			break; \
		fi; \
		echo "  waiting for LoadBalancer IP... ($$i/30)"; \
		sleep 2; \
	done

#kind-undeploy: @ Remove application from KinD cluster
kind-undeploy:
	@kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true

#kind-delete: @ Delete KinD cluster
kind-delete:
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
ci: deps format static-check test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@act push --container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#release: @ Create and push a new tag
release: deps
	@bash -c 'read -p "New tag (current: $(CURRENTTAG)): " newtag && \
		echo "$$newtag" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" || { echo "Error: Tag must match vN.N.N"; exit 1; } && \
		echo -n "Create and push $$newtag? [y/N] " && read ans && [ "$${ans:-N}" = y ] && \
		echo $$newtag > ./version.txt && \
		git add -A && \
		git commit -a -s -m "Cut $$newtag release" && \
		git tag $$newtag && \
		git push origin $$newtag && \
		git push && \
		echo "Done."'

#version: @ Print current version (tag)
version:
	@echo $(shell git describe --tags --abbrev=0)

#renovate-bootstrap: @ Install nvm and Node.js for Renovate
renovate-bootstrap:
	@command -v node >/dev/null 2>&1 || { \
		echo "Installing nvm $(NVM_VERSION)..."; \
		curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$(NVM_VERSION)/install.sh | bash; \
		export NVM_DIR="$$HOME/.nvm"; \
		[ -s "$$NVM_DIR/nvm.sh" ] && . "$$NVM_DIR/nvm.sh"; \
		nvm install $(NODE_VERSION); \
	}

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@if [ -n "$$GH_ACCESS_TOKEN" ]; then \
		GITHUB_COM_TOKEN=$$GH_ACCESS_TOKEN npx --yes renovate --platform=local; \
	else \
		echo "Warning: GH_ACCESS_TOKEN not set, some dependency lookups may fail"; \
		npx --yes renovate --platform=local; \
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

.PHONY: help deps deps-act deps-shellcheck deps-hadolint deps-kind test build lint lint-ci sec vulncheck secrets \
	static-check format run coverage-check \
	image-build clean update \
	image-test-fg image-test-cli image-run-bg image-cli-bg \
	image-logs image-stop image-push \
	k8s-apply k8s-delete \
	kind-create kind-deploy kind-undeploy kind-delete e2e \
	ci ci-run release version \
	renovate-bootstrap renovate-validate \
	deps-prune deps-prune-check
