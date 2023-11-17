OWNER := andriykalashnykov
PROJECT := golang-web
VERSION := v0.0.1
OPV := $(OWNER)/$(PROJECT):$(VERSION)
WEBPORT := 8080:8080
CURRENTTAG:=$(shell git describe --tags --abbrev=0)
NEWTAG ?= $(shell bash -c 'read -p "Please provide a new tag (currnet tag - ${CURRENTTAG}): " newtag; echo $$newtag')

# you may need to change to "sudo docker" if not a member of 'docker' group
DOCKERCMD := "docker"

BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
# unique id from last git commit
MY_GITREF := $(shell git rev-parse --short HEAD)

## display test coverage
test:
	go test --cover -parallel=1 -v -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | sort -rnk3

build:
	CGO_ENABLED=0 go build -ldflags "-X main.Version=${MY_VERSION} -X main.BuildTime=${MY_BUILDTIME}" -a -o manager main.go

## builds docker image
docker-build:
	echo MY_GITREF is $(MY_GITREF)
	$(DOCKERCMD) build --build-arg MY_VERSION=$(VERSION) --build-arg MY_BUILDTIME=$(BUILD_TIME) -f Dockerfile -t $(OPV) .

## cleans docker image
clean:
	$(DOCKERCMD) image rm $(OPV) | true

## update dependency packages to latest versions
update:
	@go get -u ./...; go mod tidy

## runs container in foreground, testing a couple of override values
docker-test-fg: docker-build
	$(DOCKERCMD) run -it -p $(WEBPORT) \
	-e APP_CONTEXT=/myhello/ \
	-e MY_NODE_NAME=node1 \
	-e MY_POD_NAME=pod1 \
	-e MY_POD_NAMESPACE=ns1 \
	-e MY_POD_IP=podip1 \
	-e MY_POD_SERVICE_ACCOUNT=podsa1 \
	--rm $(OPV)

## runs container in foreground, override entrypoint to use use shell
docker-test-cli:
	$(DOCKERCMD) run -it --rm --entrypoint "/bin/sh" $(OPV)

## run container in background
docker-run-bg: docker-build
	$(DOCKERCMD) run -d -p $(WEBPORT) --rm --name $(PROJECT) $(OPV)

## get into console of container running in background
docker-cli-bg: docker-build
	$(DOCKERCMD) exec -it $(PROJECT) /bin/sh

## tails $(DOCKERCMD)logs
docker-logs:
	$(DOCKERCMD) logs -f $(PROJECT)

## stops container running in background
docker-stop:
	$(DOCKERCMD) stop $(PROJECT)


## pushes to $(DOCKERCMD)hub
docker-push:
	$(DOCKERCMD) push $(OPV)

## pushes to kubernetes cluster
k8s-apply:
	sed -e 's/v0.0.1/$(VERSION)/' golang-web.yaml | kubectl apply -f -

k8s-delete:
	kubectl delete -f golang-web.yaml

#release: @ Create and push a new tag
release:
	$(eval NT=$(NEWTAG))
	@echo -n "Are you sure to create and push ${NT} tag? [y/N] " && read ans && [ $${ans:-N} = y ]
	@echo ${NT} > ./version.txt
	@git add -A
	@git commit -a -s -m "Cut ${NT} release"
	@git tag ${NT}
	@git push origin ${NT}
	@git push
	@echo "Done."

#version: @ Print current version(tag)
version:
	@echo $(shell git describe --tags --abbrev=0)
