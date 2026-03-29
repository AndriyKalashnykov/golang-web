.DEFAULT_GOAL := help

OWNER := andriykalashnykov
PROJECT := golang-web
VERSION := v0.0.1
OPV := $(OWNER)/$(PROJECT):$(VERSION)
WEBPORT := 8080:8080
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")
NVM_VERSION := 0.40.4

# you may need to change to "sudo docker" if not a member of 'docker' group
DOCKERCMD := "docker"

BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
# unique id from last git commit
MY_GITREF := $(shell git rev-parse --short HEAD)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-20s\033[0m - %s\n", $$1, $$2}'

#deps: @ Check required dependencies
deps:
	@command -v go >/dev/null 2>&1 || { echo "Error: Go required. See https://go.dev/doc/install"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker required. See https://docs.docker.com/get-docker/"; exit 1; }

#test: @ Run tests with coverage
test: deps
	@go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	@go tool cover -func=coverage.out | sort -rnk3

#build: @ Build the Go binary
build: deps
	@CGO_ENABLED=0 go build -ldflags "-X main.Version=${VERSION} -X main.BuildTime=${BUILD_TIME}" -a -o manager main.go

#lint: @ Run static analysis
lint: deps
	@command -v staticcheck >/dev/null 2>&1 || { echo "Error: staticcheck required. Run: go install honnef.co/go/tools/cmd/staticcheck@latest"; exit 1; }
	@staticcheck ./...

#run: @ Run the application locally
run: deps
	@go run main.go

#image: @ Build Docker image
image: deps
	@echo MY_GITREF is $(MY_GITREF)
	@$(DOCKERCMD) buildx build --load --build-arg MY_VERSION=$(VERSION) --build-arg MY_BUILDTIME=$(BUILD_TIME) -f Dockerfile -t $(OPV) .

#clean: @ Remove Docker image
clean:
	@$(DOCKERCMD) image rm $(OPV) | true

#update: @ Update dependency packages to latest versions
update:
	@go get -u ./...; go mod tidy

#image-test-fg: @ Run container in foreground with test overrides
image-test-fg: image
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
image-run-bg: image
	@$(DOCKERCMD) run -d -p $(WEBPORT) --rm --name $(PROJECT) $(OPV)

#image-cli-bg: @ Get shell in running background container
image-cli-bg: image
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
	@sed -e 's/v0.0.1/$(VERSION)/' golang-web.yaml | kubectl apply -f -

#k8s-delete: @ Delete from Kubernetes cluster
k8s-delete:
	@kubectl delete -f golang-web.yaml

#ci: @ Run full local CI pipeline
ci: deps lint build test
	@echo "Local CI pipeline passed."

#release: @ Create and push a new tag
release:
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

.PHONY: help deps test build lint run image clean update \
	image-test-fg image-test-cli image-run-bg image-cli-bg \
	image-logs image-stop image-push \
	k8s-apply k8s-delete \
	ci release version \
	renovate-bootstrap renovate-validate

#renovate-bootstrap: @ Install nvm and npm for Renovate
renovate-bootstrap:
	@command -v node >/dev/null 2>&1 || { \
		echo "Installing nvm $(NVM_VERSION)..."; \
		curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$(NVM_VERSION)/install.sh | bash; \
		export NVM_DIR="$$HOME/.nvm"; \
		[ -s "$$NVM_DIR/nvm.sh" ] && . "$$NVM_DIR/nvm.sh"; \
		nvm install --lts; \
	}

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@npx --yes renovate --platform=local
