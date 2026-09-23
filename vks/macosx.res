=== macOS check for vks/README.md ===
generated : 2026-09-23T03:58:07Z
macOS     : 26.6.2 (25G83)
arch      : arm64
shell     : /opt/homebrew/bin/zsh
bash      : 3.2.57(1)-release
lab vars  : UNSET - lab probes will report SKIPPED

--- S1  base tools README assumes macOS ships ---
  curl     OK   /usr/bin/curl
  unzip    OK   /usr/bin/unzip
  openssl  OK   /opt/homebrew/bin/openssl
  tar      OK   /usr/bin/tar
  git      OK   /usr/bin/git
  make     OK   /usr/bin/make
  mise     /Users/ak901864/.local/bin/mise

--- S2  Rosetta 2 ---
  Rosetta 2 : PRESENT - an x86_64 binary runs here

--- S3  container engine, and is it a VM client? ---
  podman present : NO
  docker present : /opt/homebrew/bin/docker
    daemon   : DOWN - the CLI alone cannot build or push on macOS
    error    : Client: Docker Engine - Community
./macosx.sh: line 88: 46931 Terminated: 15          ( sleep "$_s"; kill -TERM "$_p" 2> /dev/null; sleep 3; kill -KILL "$_p" 2> /dev/null ) > /dev/null 2>&1
  -- which VM provider is running? --
    /var/run/docker.sock: ABSENT
    VERDICT: no working engine - brew install docker gives the CLIENT only.

--- S4  can this Mac build linux/amd64? ---
  SKIPPED - no engine with a live daemon

--- S5  VCF CLI on this Mac ---
  entitled archives for this Mac:
    VCF-Consumption-CLI-Darwin_ARM64-<version>.tar.gz
    VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-<version>.tar.gz
  version: v9.1.0.0.25296329
  buildDate: 2026-03-20
  sha: 987b58e
  releaseType: ga
  -- plugins: does the Darwin bundle actually install here? --
  (README says this HANGS on a Mac with no plugins installed; capped at 25s.)
  produced output, rc=143:
    [i] Refreshing plugin inventory cache for "172.17.0.7/vcf/vcf-cli-plugins/ga/plugin-inventory/v9-rel/plugin-inventory:latest", this will take a few seconds.

--- S6  BSD userland vs the commands README actually runs ---
  base64 -d            : OK
  install -D           : NOT supported (BSD) - README rightly keeps it Linux-only
  sed image rewrite    : OK
  -- macOS trust-path prerequisites --
  security(1)          : present
  /usr/local/bin on PATH: yes

--- S7  lab-dependent probes ---
  SKIPPED - lab endpoints not set. To include them:
    export HARBOR_FQDN=... VCENTER_FQDN=... SUPERVISOR_ENDPOINT=...
    ./macosx.sh
  Unset is the EXPECTED state on a Mac with no lab. Everything above still measured.

=== SUMMARY (machine-readable) ===
arch=arm64
macos=26.6.2
rosetta2=yes
engine=none
daemon_up=no
vm_provider=none
engine_remote=unknown
buildx=no
vcf_cli=yes
vcf_plugin_list=listed(rc=143)
base64_flag=-d ok
install_D=no
sed_rewrite=ok
security_cmd=yes
import_native_ca=unknown
usr_local_bin=yes
lab_probes=skipped
=== end ===
