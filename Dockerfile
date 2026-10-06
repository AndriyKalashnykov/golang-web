# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#
# builder image
# https://hub.docker.com/_/golang/tags
# --platform=$BUILDPLATFORM: the Go toolchain runs NATIVELY on the build machine and cross-compiles
# to $TARGETARCH (CGO off, GOARCH set below). Without it an arm64 Mac building linux/amd64 runs the
# whole Go toolchain under emulation -- and under Colima's QEMU the Go runtime crashes in
# `go mod download` ("marked free object in span"; measured on macOS 26.6.2). The final stage
# runs no commands, so nothing is emulated at all.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27.1@sha256:23fe8075c2e428136326703a2c63203f0c57595d8400eedbe06a29cab53055e8 AS builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY main.go main.go

# accept override of value from --build-args
ARG MY_VERSION=v0.0.1
ENV MY_VERSION=$MY_VERSION

# accept override of value from --build-args
ARG MY_BUILDTIME=now
ENV MY_BUILDTIME=$MY_BUILDTIME

# Build
# GOARCH=${TARGETARCH} selects the architecture of the OUTPUT binary -- the platform the image is for.
# It must stay TARGETARCH: this stage runs on $BUILDPLATFORM (see FROM above), so BUILDARCH or an
# omitted GOARCH would compile for the BUILD machine and ship the wrong binary in a cross-build
# (e.g. an arm64 binary in the amd64 image an Apple Silicon Mac builds for VKS -> exec format error).
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -ldflags "-X main.Version=${MY_VERSION} -X main.BuildTime=${MY_BUILDTIME}" -a -o manager main.go

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
