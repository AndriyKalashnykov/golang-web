=== macOS check for vks/README.md ===
generated : 2026-09-23T19:23:58Z
macOS     : 26.6.2 (25G83)
arch      : arm64
shell     : /bin/zsh
bash      : 3.2.57(1)-release
lab vars  : set - lab probes will run

--- S1  base tools README assumes macOS ships ---
  curl     OK   /usr/bin/curl
  unzip    OK   /usr/bin/unzip
  openssl  OK   /usr/bin/openssl
  tar      OK   /usr/bin/tar
  git      OK   /opt/homebrew/bin/git
  make     OK   /usr/bin/make
  mise     absent (make deps installs it)

--- S2  Rosetta 2 ---
  Rosetta 2 : PRESENT - an x86_64 binary runs here

--- S3  container engine, and is it a VM client? ---
  podman present : /opt/homebrew/bin/podman
    daemon   : UP
    host     : linux/arm64 remote=true v6.1.2
    machine  : state=running
    machine  : rootful=false
  docker present : NO
  -- which VM provider is running? --
    podman machine: NAME                     VM TYPE     CREATED        LAST UP            CPUS        MEMORY      DISK SIZE
    podman machine: podman-machine-default*  applehv     7 minutes ago  Currently running  4           2GiB        100GiB
    /var/run/docker.sock: ABSENT

--- S4  can this Mac build linux/amd64? ---
  podman buildx: buildah 1.45.1
  --platform linux/amd64 : BUILDS (offline, FROM scratch)
    resulting image: linux/amd64

--- S5  VCF CLI on this Mac ---
  entitled archives for this Mac:
    VCF-Consumption-CLI-Darwin_ARM64-<version>.tar.gz
    VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-<version>.tar.gz
  vcf: NOT INSTALLED - note whether the portal archive installs cleanly

--- S6  BSD userland vs the commands README actually runs ---
  base64 -d            : OK
  install -D           : NOT supported (BSD) - README rightly keeps it Linux-only
  sed image rewrite    : OK
  -- macOS trust-path prerequisites --
  security(1)          : present
  --import-native-ca   : supported by this podman
  podman machine ssh   : available (VM-side trust is reachable)
  group "root"         : NOT FOUND - `install -g root` would fail here
  /usr/local/bin on PATH: yes

--- S7  lab-dependent probes ---
  HARBOR_FQDN=harbor.env1.lab.test:8443  VCENTER_FQDN=vcsa.env1.lab.test  SUPERVISOR_ENDPOINT=192.168.101.128
  P1 reach Harbor:
    /api/v2.0/health http=200  (reached)
  P2 Harbor serves its own CA:
    bytes=1159
    subject= /CN=Harbor CA
    SHA256 Fingerprint=A8:00:C3:62:1C:31:33:93:6B:55:0D:5A:77:B0:88:2D:A5:DA:9C:E5:F2:5A:F1:80:73:20:65:60:BA:AA:72:E2
  P3 curl verifies against it (no -k):
    http=200  (reached)
  P4 BASELINE: does login fail BEFORE the CA is trusted?
     (expect x509 unknown authority; SUCCESS means it is already trusted.
      The password sent is the literal string x - not a credential.)
    podman: Error: logging into "harbor.env1.lab.test:8443": invalid username/password
  P5 vCenter CA endpoint (README step 8a):
    /certs/download.zip 000 0  (DNS: name does not resolve)
  P6 Supervisor kubectl download (README step 7):
    darwin-amd64  000 0  (resolves, but NO ROUTE or connection refused)
    darwin-arm64  000 0  (resolves, but NO ROUTE or connection refused)
    (README pins darwin-amd64 because darwin-arm64 404s. If arm64 is 200 here, fix the README.)

=== SUMMARY (machine-readable) ===
arch=arm64
macos=26.6.2
rosetta2=yes
engine=podman
daemon_up=yes
vm_provider=podman-machine
engine_remote=true
buildx=yes
vcf_cli=no
vcf_plugin_list=unknown
base64_flag=-d ok
install_D=no
sed_rewrite=ok
security_cmd=yes
import_native_ca=yes
podman_machine=exists
machine_state=running
machine_rootful=false
xarch_build=ok
usr_local_bin=yes
lab_probes=ran
=== end ===
