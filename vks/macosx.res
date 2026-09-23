=== macOS check for vks/README.md ===
generated : 2026-09-23T04:55:08Z
macOS     : 26.6.2 (25G83)
arch      : arm64
shell     : /opt/homebrew/bin/zsh
bash      : 3.2.57(1)-release
lab vars  : set - lab probes will run

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
  podman present : /opt/homebrew/bin/podman
    daemon   : UP
    host     : linux/arm64 remote=true v6.1.2
    machine  : state=running
    machine  : rootful=false
  docker present : /opt/homebrew/bin/docker
    daemon   : DOWN - the CLI alone cannot build or push on macOS
    error    : failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
  -- which VM provider is running? --
    podman machine: NAME                     VM TYPE     CREATED         LAST UP            CPUS        MEMORY      DISK SIZE
    podman machine: podman-machine-default*  applehv     33 minutes ago  Currently running  9           2GiB        100GiB
    /var/run/docker.sock: ABSENT

--- S4  can this Mac build linux/amd64? ---
  podman buildx: buildah 1.45.1
  --platform linux/amd64 : BUILDS (offline, FROM scratch)
    resulting image: linux/amd64

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
  produced output, rc=1:
    [i] Refreshing plugin inventory cache for "172.17.0.7/vcf/vcf-cli-plugins/ga/plugin-inventory/v9-rel/plugin-inventory:latest", this will take a few seconds.
    [i] The vcf cli essential plugins have not been installed and are being installed now. The install may take a few seconds.
    
      NAME                DESCRIPTION                                                                       INSTALLED  STATUS     
      addon               Add-on lifecycle management                                                       v3.6.1     installed  
      cluster             Kubernetes cluster operations                                                     v3.6.1     installed  
      imgpkg              package, distribute, and relocate your configuration and dependent oci images as  v9.1.0     installed  
                          one oci artifact                                                                                        
      kubernetes-release  Kubernetes release operations                                                     v3.6.1     installed  
      namespaces          discover vsphere supervisor namespaces you have access to                         v9.1.0     installed  
      package             VCF Package management                                                            v3.6.1     installed  
      pais                Manage model images for Private AI Services                                       v2.1.0     installed  
      registry-secret     Registry secret management                                                        v3.6.1     installed  
      secret              Secret Store Plugin for VCF CLI                                                   v9.1.0     installed  

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
  HARBOR_FQDN=harbor.mgmt.vks.lab  VCENTER_FQDN=vksa.mgmt.vks.lab  SUPERVISOR_ENDPOINT=172.17.0.4
  P1 reach Harbor:
    /api/v2.0/health http=000
    UNREACHABLE
  P2 Harbor serves its own CA:
    bytes=0 - nothing downloaded; P3 skipped
  P4 BASELINE: does login fail BEFORE the CA is trusted?
     (expect x509 unknown authority; SUCCESS means it is already trusted.
      The password sent is the literal string x - not a credential.)
    podman: Error: get credentials: reading JSON file "/var/folders/m3/10z9t5ss4s1_fg9twzmw6n240000gq/T/probeauth.vIXReJRRy8": unmarshaling JSON at "/var/folders/m3/10z9t5ss4s1_fg9twzmw6n240000gq/T/probeauth.vIXReJRRy8": unexpected end of JSON input
  P5 vCenter CA endpoint (README step 8a):
    /certs/download.zip http=000 bytes=0
    UNREACHABLE
  P6 Supervisor kubectl download (README step 7):
    darwin-amd64 http=000 bytes=0
    darwin-arm64 http=000 bytes=0
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
vcf_cli=yes
vcf_plugin_list=listed(rc=1)
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
