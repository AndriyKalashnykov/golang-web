=== macOS verification for vks/README.md ===
date            : 2026-09-23T00:00:04Z
macOS           : 26.6.2
arch            : arm64
shell           : /opt/homebrew/bin/zsh

--- P1  which engine, and is it a VM client? ---
podman present : NO
docker present : /opt/homebrew/bin/docker
  docker info:
  docker info: failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory

--- P2  can this Mac reach Harbor at all? ---
  harbor /api/v2.0/health http=%{http_code}
  UNREACHABLE (tunnel or /etc/hosts needed)

--- P3  does Harbor serve its own CA here? ---
zsh: no such file or directory: /Users/ak901864/harbor-ca-probe.crt
  bytes=0
  Could not open file or uri for loading certificate from /Users/ak901864/harbor-ca-probe.crt: No such file or directory

--- P4  does curl verify against it? (no -k) ---
  http=%{http_code}

--- P5  BASELINE: does login fail BEFORE trusting the CA? ---
  (expected: x509 unknown authority. If it SUCCEEDS, the CA is already trusted.)
  docker: time="2026-09-22T20:00:06-04:00" level=info msg="Error logging in to endpoint, trying next endpoint" endpoint="{https://harbor.example.test 0xb00abb04780}" error="Get \"https://harbor.example.test/v2/\": dial tcp: lookup harbor.example.test: no such host"
  docker: Get "https://harbor.example.test/v2/": dial tcp: lookup harbor.example.test: no such host

--- P6  VCF CLI on THIS Mac ---
  entitled archive you need: VCF-Consumption-CLI-Darwin_arm64-<version>.tar.gz
  version: v9.1.0.0.25296329
  buildDate: 2026-03-20
  sha: 987b58e
  releaseType: ga
  --- plugins (README claims the bundle is Linux-only; does it install here?) ---



^C