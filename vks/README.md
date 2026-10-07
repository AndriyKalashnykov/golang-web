# Build `golang-web`, push it to Harbor, deploy it to a VKS guest cluster

This guide builds the `golang-web` container image on your machine, pushes it to your company's
Harbor registry, and runs it on a Kubernetes cluster managed by VMware vSphere (a *VKS guest
cluster*). It has 10 steps. Steps 1–4 are one-time setup; step 10 is optional clean-up.

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Where a step
offers choices, run only the one for your setup. Each block is followed by **Expect:** — what you
should see — and, where it can go wrong, **If not:** — what to do. A block you run twice either
changes nothing or tells you what to do.

A second guide, [Install ArgoCD onto Supervisor and create a VKS guest cluster with it](ARGOCD.md),
continues from steps 1, 2 and 7 of this one. It comes in two versions: [by hand](ARGOCD-manual.md),
in the vSphere Client and the ArgoCD web page, and [with scripts](ARGOCD-auto.md).

## Learn the terms

| term | meaning |
|---|---|
| env file | `~/.vks-golang-web.env`, your settings, created in step 1 |
| image | the packaged app, ready to run in a container |
| registry | a server that stores images |
| container engine | the program that builds, stores and pushes images (podman or docker) |
| tag | an image's name, such as `v0.0.3`; it can later be moved to another image |
| push | upload an image to a registry |
| Harbor | your company's private registry for container images |
| FQDN | a server's full DNS name, e.g. `harbor.example.test` |
| Harbor project | a folder in Harbor that holds images and has its own permissions; *private* (Harbor's default) or *public* |
| robot account | a Harbor login for scripts, limited to one project, that expires |
| CA (certificate authority) certificate | the file your tools use to confirm they talk to the real server; company servers use a private CA your machine does not trust yet |
| fingerprint | a short hash of a certificate, used to compare it with your administrator's copy |
| SSO user | your vCenter login, e.g. `administrator@vsphere.local` |
| vCenter CA | the certificate authority built into vCenter; it issued the Supervisor's certificate |
| Supervisor | the vSphere control plane you log in to, to reach your cluster |
| vSphere Namespace | your team's area on the Supervisor |
| namespace | a folder inside a Kubernetes cluster; the one in step 8 is not your vSphere Namespace |
| cluster | a group of machines that runs containers under Kubernetes |
| guest cluster | the Kubernetes cluster your app runs on |
| node | a machine in the cluster |
| pod | one running copy of the app |
| LoadBalancer address | an IP address the cluster gives the app so you can reach it from your machine |
| kubeconfig | the file `kubectl` reads to find a cluster and log in |
| context | a saved login inside a kubeconfig or the `vcf` tool |
| digest | an image's unique `sha256:…` ID; unlike a tag, it always names the same image |
| pull secret | your Harbor login, stored in the cluster, so it can download images from a private project |

## Gather what you need

Get from your platform administrator:

- the Harbor DNS name, a project you may push to, and a robot account or the Harbor admin password
- the Supervisor endpoint, the vCenter DNS name, the vSphere Namespace and the guest cluster name
- an SSO user (your vCenter login) with the **Edit** role on that vSphere Namespace, and its password
- the SHA-256 fingerprints of the vCenter CA and of Harbor's CA certificate (you compare them in
  steps 2 and 3)
- confirmation that the guest cluster trusts Harbor's CA certificate (without it the cluster
  cannot download your image)
- a Broadcom support account that can download VMware vSphere Foundation 9 (step 2)
- sudo (administrator) rights on this machine
- network access from this machine to all of the above, and internet access to your package
  repositories, github.com, raw.githubusercontent.com, ghcr.io, quay.io, docker.io, gcr.io,
  proxy.golang.org, dl.k8s.io, download.docker.com and support.broadcom.com

## 1. Set the variables

This block creates two files in your home directory, which every later step reads:

- `~/.vks-golang-web.env` (the *env file*) — your settings and passwords, readable only by you. If it already
  exists, it is kept as it is.
- `~/.vks-golang-web.functions` — two helper commands used later (`harbor_cfg`,
  `kubectl_install`). It is rewritten every time, so running the block again updates them.

```sh
( umask 077; set -C; cat > ~/.vks-golang-web.env <<'EOF'
export HARBOR_FQDN="harbor.example.test"         # Harbor's DNS name
export HARBOR_PROJECT="apps"                     # the Harbor PROJECT the image lands in
export SUPERVISOR_ENDPOINT="10.0.0.10"           # Supervisor API endpoint (IP or FQDN)
export VCENTER_FQDN="vcsa.example.test"          # vCenter DNS name
export VKS_CLUSTER="my-guest-cluster"            # the guest cluster NAME
export VKS_NAMESPACE="my-namespace"              # the vSphere Namespace holding it
export SSO_USERNAME="administrator@vsphere.local"

export VCF_CLI_VSPHERE_PASSWORD='<your vCenter SSO password>'
export HARBOR_ADMIN_PASSWORD=''                  # steps 5 and 10 only
export REGISTRY_USERNAME=''                      # step 5 fills these two
export REGISTRY_TOKEN=''

export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

export KUBECONFIG="$GUEST_KUBECONFIG"

. "$HOME/.vks-golang-web.functions"
EOF
)
chmod 600 ~/.vks-golang-web.env
grep -qs vks-golang-web.functions ~/.vks-golang-web.env \
  || printf '\n. "$HOME/.vks-golang-web.functions"\n' >> ~/.vks-golang-web.env

cat >| ~/.vks-golang-web.functions <<'EOF'
# harbor_cfg [USER PASSWORD]: writes a curl config with a Harbor login to $CFG (default: admin),
# used as `curl -K "$CFG"` in steps 5, 6, 8 and 10 so no password is on the command line.
harbor_cfg() {
  local u p
  if [ $# -ge 1 ]; then u="$1"; p="$2"; else u=admin; p="$HARBOR_ADMIN_PASSWORD"; fi
  [ -n "$u" ] && [ -n "$p" ] || { echo "harbor_cfg: empty user or password — fill the env file (step 5)" >&2; return 1; }
  u="${u//\\/\\\\}"; u="${u//\"/\\\"}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
  CFG="$(mktemp)"; ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$CFG" )
}

# kubectl_install VERSION: installs upstream kubectl VERSION from dl.k8s.io into /usr/local/bin
# (a "+vmware.N" suffix is dropped; if that exact patch has no upstream build, the newest patch of
# the same minor is used). The checksum guards against a corrupt download. On any failure the
# existing kubectl is left as it was.
kubectl_install() {
  local v="${1%%+*}" m os arch u t h
  case "$v" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "kubectl_install: no version ('$1') — not logged in, or the server unreachable?" >&2; return 1 ;; esac
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "kubectl_install: unsupported OS $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "kubectl_install: unsupported CPU $(uname -m)" >&2; return 1 ;; esac
  if ! curl -fsIL --connect-timeout 10 --retry 3 -o /dev/null "https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"; then
    m="${v#v}"; m="${m%.*}"
    v="$(curl -fsSL --connect-timeout 10 --retry 3 "https://dl.k8s.io/release/stable-${m}.txt")" \
      || { echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)" >&2; return 1; }
    echo "note: no upstream kubectl ${1%%+*}; using ${v}, the newest of that minor" >&2
  fi
  u="https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"
  t="$(mktemp -d)" || return 1
  if curl -fsSL --connect-timeout 10 --retry 3 -o "$t/kubectl" "$u" \
     && h="$(curl -fsSL --connect-timeout 10 --retry 3 "${u}.sha256")" && [ -n "$h" ] \
     && [ "$( (sha256sum "$t/kubectl" 2>/dev/null || shasum -a 256 "$t/kubectl") | awk '{print $1}')" = "$h" ] \
     && sudo install -d /usr/local/bin && sudo install -m 0755 "$t/kubectl" /usr/local/bin/kubectl; then
    rm -rf "$t"; /usr/local/bin/kubectl version --client
    [ "$(command -v kubectl)" = /usr/local/bin/kubectl ] \
      || echo "WARNING: 'kubectl' on your PATH is '$(command -v kubectl || echo not found)', not /usr/local/bin/kubectl" >&2
  else
    rm -rf "$t"; echo "kubectl_install: cannot reach dl.k8s.io, the checksum did not match, or sudo failed (${u}) — kubectl NOT changed" >&2; return 1
  fi
}
EOF
```

**Expect:** no output the first time. If the env file already exists, bash prints
`cannot overwrite existing file` and zsh prints `file exists`: that is fine, your earlier values
are kept.

Open the env file and replace each example value with what your administrator gave you. Put
passwords in **single quotes** (a `'` inside one is written `'\''`). Leave `HARBOR_ADMIN_PASSWORD`
empty unless you have it, and leave the two `REGISTRY_*` values empty: step 5 fills them.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

In nano: Ctrl+O, then Enter, saves; Ctrl+X exits. Do not edit the file in TextEdit (macOS): it
turns `'` into curly quotes, which breaks every password.

Load the settings into this terminal. Do this in every new terminal; the blocks below also do it.

```sh
source ~/.vks-golang-web.env
```

**Expect:** no output. **If not:** `No such file or directory` means the first block did not run.

## 2. Install the tools

You need a container engine to build and push the image (podman or docker), `kubectl` to talk
to Kubernetes, VMware's `vcf` tool to log in to the Supervisor, and a few small helpers. Skip
any tool you already have; the Check at the end of this step shows what is missing. Everyone
needs the vCenter CA download below: it is not a tool, and nothing else fetches it.

### Install Homebrew (macOS only)

Homebrew is the macOS package manager used below. Skip this block if `brew --version` already
works. The installer asks for your password, installs the Xcode Command Line Tools too, and can
take several minutes.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Expect:** the installer prints `==> Installation successful!` near its end. Then, as its own
block (the installer asks questions, so nothing may be pasted after it), put `brew` on your
`PATH`:

```sh
B=/opt/homebrew/bin/brew; [ -x "$B" ] || B=/usr/local/bin/brew
grep -qs "brew shellenv" ~/.zprofile || echo "eval \"\$($B shellenv)\"" >> ~/.zprofile
eval "$($B shellenv)"
brew --version
```

**Expect:** `Homebrew 4.…` (or newer).

### Install a container engine — pick one

The container engine builds the image and pushes it. Choose **one** and run only its block. Both
work; if unsure, pick podman — **except on an arm64 Linux machine** (run `uname -m`: `aarch64` means arm64): there, podman 4.x (Ubuntu
24.04 has 4.9) builds an image the cluster cannot pull, and step 6 refuses it. Pick docker there
(podman 5.8 also works, if you already have it).

macOS, podman:

```sh
brew install podman
podman machine inspect >/dev/null 2>&1 || podman machine init
podman info >/dev/null 2>&1 || podman machine start
```

**Expect:** the last lines say the machine `started successfully`, or nothing if it was already
running.

macOS, docker (Colima — runs the docker engine in a small VM):

```sh
brew install colima docker docker-buildx
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
colima start
docker context use colima
docker info --format '{{.Name}}: {{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}'
docker buildx version
```

`docker context use colima` points the `docker` command at Colima. On a new install `colima start`
already does that; the line matters when Colima was running before and `docker` was pointed at
another engine (Docker Desktop, for example).

**Expect:** `Current context is now "colima"`, a line like
`colima: Ubuntu 24.04…/aarch64 server=29.…` (`/x86_64` on an Intel Mac), then
`github.com/docker/buildx v0.…`. If Colima was already running, `colima start` prints
`already running, ignoring`, which is fine.

**If not:** the line does not start with `colima:`, or a `Warning: DOCKER_HOST environment variable
overrides the active context` appears — a variable in your shell points `docker` at another
engine: run `unset DOCKER_HOST DOCKER_CONTEXT`, then the block again.

Linux (Debian/Ubuntu), podman:

```sh
sudo apt-get update && sudo apt-get install -y podman
```

**Expect:** the install ends without an error; the Check below confirms it. podman 4.9 is the
oldest version tested (Ubuntu 24.04 has it; Debian 13 has 5.4). Debian 12 has podman 4.3, which
does not work: use docker there and on anything older.

Linux (Debian/Ubuntu), docker. The first line reads which of the two you have:

```sh
D="$(. /etc/os-release && echo "$ID")"
case "$D" in
  ubuntu|debian)
    sudo apt-get update && sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/${D}/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${D} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    sudo usermod -aG docker "$USER"
    ;;
  *) echo "Not Debian or Ubuntu ($D): nothing installed. See https://docs.docker.com/engine/install/" ;;
esac
```

**Expect:** no error. Then log out and back in: until you do, `docker` needs `sudo`. After that,
`docker info` works without `sudo`.

**If not:**
- `permission denied … docker.sock` — you are still in the old session: log out fully (or restart
  the machine) and try again.
- `Not Debian or Ubuntu (…): nothing installed` (Linux Mint, Pop!_OS and other derivatives):
  this block changed nothing. Follow https://docs.docker.com/engine/install/ for your
  distribution, or use podman.

If both podman and docker are installed, the build uses podman. To use docker instead, run this
once (it adds `CONTAINER_ENGINE=docker` to the env file):

```sh
grep -qs CONTAINER_ENGINE ~/.vks-golang-web.env || echo 'export CONTAINER_ENGINE=docker' >> ~/.vks-golang-web.env
```

**Expect:** no output. If the env file already has a `CONTAINER_ENGINE` line, nothing changes:
edit that line yourself.

### Install jq and the other command-line tools

`jq` reads JSON; Linux also needs `git`, `make`, `unzip`, `curl` and `openssl`, which macOS
already has.

macOS (skip this if `jq --version` already works; macOS 26 has `jq` built in):

```sh
brew install jq
```

Linux (Debian/Ubuntu):

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

**Expect:** the install ends without an error; the Check below confirms it.

### Download and check the vCenter CA

The Supervisor's HTTPS certificate is issued by vCenter's own CA, which your machine does not
trust yet. This block downloads that CA from vCenter and saves it as `$SUPERVISOR_CA`; step 7 uses
it so `vcf` can confirm it is talking to your real Supervisor. The download itself cannot be
verified yet (hence `curl -k`), so you compare its fingerprint with your administrator's.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$SUPERVISOR_CA")"
T="$(mktemp -d)"
curl -fsSk --max-time 60 -o "$T/certs.zip" "https://${VCENTER_FQDN}/certs/download.zip"
unzip -oqj "$T/certs.zip" -d "$T/certs"
cat "$T"/certs/*.0 > "$SUPERVISOR_CA"
rm -rf "$T"
openssl x509 -in "$SUPERVISOR_CA" -noout -subject -fingerprint -sha256
```

**Expect:** a `subject=` line naming `CA` and `vsphere`, then `sha256 Fingerprint=…`
(`SHA256 Fingerprint=` on macOS). Compare its hex digits with your administrator's, ignoring
colons and upper/lower case.

**If not:**
- **A different fingerprint:** do not continue. Check `VCENTER_FQDN` in the env file. Then send
  the fingerprint you got to your administrator and ask them to confirm it or to send you the CA
  file (if vCenter has several CAs, the block shows only the first). A company proxy that
  replaces HTTPS certificates also causes this.
- **A `curl:` error** (for example `Could not resolve host`), then `unzip`, `openssl` or (zsh)
  `no matches found` errors: the
  download failed. Check `VCENTER_FQDN` and that you can reach vCenter.

### Install kubectl

`kubectl` is the Kubernetes command-line tool. This block installs the newest stable release from
the official site (dl.k8s.io) into `/usr/local/bin`; its `sudo` asks for your password. It is only a
starting point: your guest cluster's version is not known yet. Step 7 reads that version from the
cluster and installs the matching kubectl over this one.

```sh
source ~/.vks-golang-web.env
V="$(curl -fsSL --connect-timeout 10 https://dl.k8s.io/release/stable.txt)"
if [ -n "$V" ]; then kubectl_install "$V"; else echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)"; fi
```

**Expect:** `Client Version: v1.…` (and a `Kustomize Version` line), and no `WARNING` line.

**If not:**
- `WARNING: 'kubectl' on your PATH is …`: another kubectl is found first, or (`not found`)
  `/usr/local/bin` is not in your `PATH`. Put `/usr/local/bin` first in your `PATH`, and remove
  the other kubectl if there is one.
- `cannot reach dl.k8s.io`: if a `sudo:` line is printed above it, sudo failed: run the block
  again and enter your password. Otherwise ask your administrator to allow dl.k8s.io, or use the
  alternative below.

<details>
<summary><b>Alternative: install the kubectl your Supervisor serves</b> (only if dl.k8s.io is blocked)</summary>

Run this only if the block above printed `cannot reach dl.k8s.io`. Your Supervisor serves its own
kubectl, for Intel/AMD (amd64) Linux and macOS only. This block picks the one for this machine,
downloads it from the Supervisor and installs it into `/usr/local/bin`; its `sudo` asks for your
password. The download does not check the Supervisor's certificate (`curl -k`), so it needs no CA
file. On any other machine the block installs nothing and says so. This kubectl is the Supervisor's version, which can be several versions older than
your guest cluster. Step 7 still tries to install the matching one from dl.k8s.io; if that is
still blocked, it says so (after up to about a minute and a half), this kubectl stays, and
step 7's last check prints a `version difference` warning.

```sh
source ~/.vks-golang-web.env
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)               P=linux-amd64 ;;
  Darwin/x86_64|Darwin/arm64) P=darwin-amd64 ;;
  *)                          P= ;;
esac
if [ -n "$P" ]; then
  if T="$(mktemp -d)" \
     && curl -fsSk --connect-timeout 20 -o "$T/vsphere-plugin.zip" \
          "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/${P}/vsphere-plugin.zip" \
     && unzip -oq "$T/vsphere-plugin.zip" bin/kubectl -d "$T" \
     && chmod +x "$T/bin/kubectl" && "$T/bin/kubectl" version --client >/dev/null \
     && sudo install -d /usr/local/bin && sudo install -m 0755 "$T/bin/kubectl" /usr/local/bin/kubectl; then
    /usr/local/bin/kubectl version --client
    [ "$(command -v kubectl)" = /usr/local/bin/kubectl ] \
      || echo "WARNING: 'kubectl' on your PATH is '$(command -v kubectl || echo not found)', not /usr/local/bin/kubectl"
  else
    echo "Nothing installed: the download from https://${SUPERVISOR_ENDPOINT}, or the check of the downloaded kubectl, failed (see the error above)"
  fi
  [ -n "$T" ] && rm -rf "$T"
else
  echo "No Supervisor kubectl for $(uname -s)/$(uname -m): nothing installed. Ask your administrator to allow dl.k8s.io."
fi
```

**Expect:** `Client Version: v1.…` (and a `Kustomize Version` line), and no `WARNING` line.

**If not:**
- `No Supervisor kubectl for …: nothing installed` (Linux on arm64): the Supervisor has no kubectl
  for this machine. Ask your administrator to allow dl.k8s.io, then run the block above.
- `Nothing installed: …`: your existing kubectl, if any, is unchanged. Read the error above that
  line:
  - `Failed to connect` or `Could not resolve host`: `SUPERVISOR_ENDPOINT` in the env file is
    wrong, or this machine cannot reach the Supervisor.
  - `bad CPU type in executable` (a Mac with Apple silicon): this kubectl is an Intel program and
    needs Rosetta. Run `softwareupdate --install-rosetta --agree-to-license`, then this block
    again.
  - Anything else (for example `404`, or an `unzip` error): send the error to your administrator.
- `WARNING: 'kubectl' on your PATH is …`: as in the block above.

</details>

### Install the VCF CLI and its plugins

`vcf` is VMware's command-line tool; this guide uses it to log in to the Supervisor (step 7). The
plugins bundle adds `vcf`'s other commands (for example `vcf cluster` and `vcf package`), which
you will want for day-to-day work with VKS; this guide itself does not use them. The block
installs them from the downloaded file, without internet access.

Download the files for your platform (`Linux_AMD64`, `Linux_ARM64`, `Darwin_ARM64` or
`Darwin_AMD64`) from Broadcom (`Darwin_AMD64`, for Intel Macs, is untested here). Tick **"I agree to the Terms and Conditions"** — the checkbox stays
greyed out until you open both Terms links — or the download icon does nothing.

| file | where to click | direct link |
|---|---|---|
| `VCF-Consumption-CLI-<platform>-9.1.1.0.25662425.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI** | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545612&viewGroup=true) |
| `VCF-Consumption-CLI-PluginBundle-<platform>-9.1.1.0.25665404.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI Plugins** | [VCF CLI plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545621&viewGroup=true) |

- Pick the release first — until you do, the page reads "No data found". The direct link skips this.
- Take the row for your platform, not the multi-GB platform-less bundles beside it.
- Your Supervisor's home page may also offer the CLI, or answer "VCF CLI is currently unavailable
  for download". This guide uses the Broadcom download; the Supervisor's file is untested here.

This block finds this machine's two files in `~/Downloads`, prints their checksums and installs
them. If you saved them elsewhere, change that folder. Other platforms are not supported.

```sh
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  P=Linux_AMD64 ;;
  Linux/aarch64) P=Linux_ARM64 ;;
  Darwin/arm64)  P=Darwin_ARM64 ;;
  Darwin/x86_64) P=Darwin_AMD64 ;;
  *)             P=unsupported ;;
esac
CLI_TGZ="$HOME/Downloads/VCF-Consumption-CLI-${P}-9.1.1.0.25662425.tar.gz"
PLUGINS_TGZ="$HOME/Downloads/VCF-Consumption-CLI-PluginBundle-${P}-9.1.1.0.25665404.tar.gz"

if [ -f "$CLI_TGZ" ] && [ -f "$PLUGINS_TGZ" ]; then
  (sha256sum "$CLI_TGZ" "$PLUGINS_TGZ" 2>/dev/null || shasum -a 256 "$CLI_TGZ" "$PLUGINS_TGZ") \
    | awk '{h = $1; sub(/.*\//, ""); print "SHA-256: " h "  " $0}'
  T="$(mktemp -d)"
  tar -xzf "$CLI_TGZ" -C "$T"
  sudo install -d /usr/local/bin
  sudo install "$T"/vcf-cli-* /usr/local/bin/vcf
  mkdir "$T/plugins" && tar -xzf "$PLUGINS_TGZ" -C "$T/plugins"
  /usr/local/bin/vcf plugin install all --local-source "$T/plugins"
  rm -rf "$T"
  /usr/local/bin/vcf version | head -1
  /usr/local/bin/vcf plugin list
  [ "$(command -v vcf)" = /usr/local/bin/vcf ] \
    || echo "WARNING: 'vcf' on your PATH is '$(command -v vcf || echo not found)', not /usr/local/bin/vcf"
else
  for f in "$CLI_TGZ" "$PLUGINS_TGZ"; do
    [ -f "$f" ] || echo "Not found: $f — download it (table above) for $(uname -s)/$(uname -m)"
  done
fi
```

**Expect:** two `SHA-256:` lines, each equal to the SHA-256 value the download page shows for that
file (labelled **SHA2**),
then `version: v9.1.1.0.25662425` (or the release you downloaded), then the plugins, each
`installed`, and no `WARNING` line.

**If not:**
- `Not found: …` — the file is not in `~/Downloads`, or its name differs: download it, or change
  the folder in `CLI_TGZ`/`PLUGINS_TGZ`. `unsupported` in the path means this machine's OS or CPU
  has no VCF CLI build.
- A different checksum means a damaged or wrong download: delete the file and download it again.
  If it still differs, do not install it; tell your administrator.
- A `WARNING` line means another `vcf` is found first, or (`not found`) `/usr/local/bin` is not in
  your `PATH`: put `/usr/local/bin` first in your `PATH`, and remove the other `vcf` if there is
  one.

### Check the tools

This lists any tool that is still missing and prints the versions of the rest.

```sh
for t in curl unzip openssl jq git make kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || echo "MISSING: podman or docker"

command -v podman >/dev/null 2>&1 && podman --version
command -v docker >/dev/null 2>&1 && docker --version
kubectl version --client
vcf version | head -1
```

**Expect:** no `MISSING` line, then a version line for podman or docker (whichever you installed),
kubectl's `Client Version:`, and `version: v9.…`.

**If not:** re-run the install block for each `MISSING` tool.

## 3. Trust the Harbor CA

### Download and check the Harbor CA

Harbor's certificate comes from a CA your machine does not trust yet, so your container engine
refuses to push to Harbor. This step downloads Harbor's CA certificate to `$HARBOR_CA` and
installs it where your engine looks for it. As in step 2, the download cannot be verified yet, so
you compare its fingerprint with your administrator's.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
rm -f "$HARBOR_CA"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

**Expect:** `sha256 Fingerprint=…` (`SHA256 Fingerprint=` on macOS). Compare its hex digits with
your administrator's, ignoring colons and upper/lower case.

**If not:**
- **A different fingerprint:** do not continue. Check `HARBOR_FQDN` in the env file. Then send
  the fingerprint you got to your administrator and ask them to confirm it or to send you the CA
  file (save it with `cp <file> "$HARBOR_CA"`). A company proxy that replaces HTTPS certificates also causes
  this.
- **`curl: (22) … error: 404`, then an `openssl` error (`Could not open file` or
  `unable to load certificate`):** Harbor is reachable but does not
  publish a CA (its certificate was not made by Harbor). Ask your administrator for the CA file,
  save it with `cp <file> "$HARBOR_CA"`, and run only the `openssl` line above to check it.
- **Any other `curl:` error, then an `openssl` error:** the download failed. Check `HARBOR_FQDN` and that you can reach Harbor.

### Install the CA for your engine

Run only the block for the engine you chose in step 2.

podman, Linux and macOS:

```sh
source ~/.vks-golang-web.env
mkdir -p "$HOME/.config/containers/certs.d/${HARBOR_FQDN}"
cp "$HARBOR_CA" "$HOME/.config/containers/certs.d/${HARBOR_FQDN}/ca.crt"
```

Linux, docker:

```sh
source ~/.vks-golang-web.env
sudo install -D -m0644 "$HARBOR_CA" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"
```

macOS, docker (Colima). The CA goes inside Colima's VM, so the first line starts Colima if it is
stopped (after a restart of the Mac, for example). `</dev/null` keeps `colima ssh` from reading
the lines you pasted after it. If you ever run `colima delete`, run this again:

```sh
source ~/.vks-golang-web.env
colima status >/dev/null 2>&1 || colima start
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}" </dev/null
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
```

**Expect:** no output. On the Colima path, if Colima was stopped, its start-up lines come first and
end with `done`.

**If not:** `colima not running` (Colima path) — Colima did not start: run `colima start` by itself
and read its error.

### Check the CA file

This checks that the CA file works, by calling Harbor with it (the engine's own trust is proven by the
login in step 5):

```sh
source ~/.vks-golang-web.env
curl -s --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health"
```

**Expect:** `http=200`. **If not:** `http=000` means curl could not connect or did not trust the
certificate: re-check the fingerprint block above and `HARBOR_FQDN`.

## 4. Check out the repo

This downloads the app's source code, which step 6 builds, into a new `golang-web` directory
here. If you already have a clone, `cd` into it instead.

```sh
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
```

**Expect:** `Cloning into 'golang-web'...`. Run everything below from this directory: in every
new terminal, `cd` back into it first.

## 5. Log in to Harbor

Your container engine needs a Harbor login to push the image, and steps 6 and 8 use the same name
and secret to look the image up. Use a **robot account** (option A) or the **admin account** (option B). The make commands
below take the Harbor project as `OWNER`.

### Option A — create a robot account

This creates a robot account that can push to and read from your project only, and expires after
90 days. It needs `HARBOR_ADMIN_PASSWORD` in the env file. Skip it if your administrator already
gave you a robot name and secret: skip the block and put them in the two `REGISTRY_*` lines as
shown below.

```sh
source ~/.vks-golang-web.env
harbor_cfg

jq -nc --arg p "$HARBOR_PROJECT" '{name:"golang-web-push", duration:90, level:"project",
  permissions:[{kind:"project", namespace:$p,
    access:[{resource:"repository",action:"push"},{resource:"repository",action:"pull"},
            {resource:"artifact",action:"read"},{resource:"artifact",action:"list"}]}]}' \
  > /tmp/robot.json

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X POST -H 'Content-Type: application/json' \
  --data @/tmp/robot.json "https://${HARBOR_FQDN}/api/v2.0/robots" \
  | jq -r 'if .errors then "ERROR \(.errors[0].code): \(.errors[0].message)" else "\(.name)\n\(.secret)" end'

rm -f /tmp/robot.json "$CFG"
```

**Expect:** two lines — the robot's name (`robot$<your project>+golang-web-push`) and its secret.
Copy the secret now: Harbor shows it only once.

**If not:**
- `harbor_cfg: empty user or password`: set `HARBOR_ADMIN_PASSWORD` in the env file.
- `ERROR UNAUTHORIZED`: `HARBOR_ADMIN_PASSWORD` is wrong.
- `ERROR CONFLICT`: a robot with this name already exists. Use its secret if you have it;
  otherwise ask your administrator to delete the robot `robot$<your project>+golang-web-push`, or
  run step 10's *Delete the image and the robot in Harbor* block — **it also deletes the
  `golang-web` repository** — then run this again.
- No output at all: Harbor could not be reached; re-check step 3.

In `~/.vks-golang-web.env`, replace the two `REGISTRY_*` lines with the name and secret printed
above, exactly as printed and in single quotes (the `$` in the name is part of it):

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
export REGISTRY_TOKEN='<the 32-character secret>'
```

### Option B — use the admin account

In `~/.vks-golang-web.env`, set:

```sh
export REGISTRY_USERNAME='admin'
export REGISTRY_TOKEN='<Harbor admin password>'
```

Option B stores the admin password in the cluster too, if you create step 8's pull secret. Prefer
option A.

### Log the container engine in to Harbor

This saves your Harbor login in the container engine, so step 6 can push.

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** `Login Succeeded` (podman adds `!`; docker may first print a `WARNING!` about
unencrypted storage, which is harmless).

**If not:** `x509` — run step 3's block for your engine. `unauthorized` — check the two
`REGISTRY_*` values in the env file. `ERROR: no credential` — the `REGISTRY_*` lines are empty:
fill them (option A or B), then run this block again.

## 6. Build and push the image

### Build and push

This builds the app into an image and pushes it to Harbor. The image holds a version for each
common CPU architecture, `amd64` and `arm64`, under one tag, so it runs on any node whatever
machine you build on. The first build takes a few minutes. If you know every node is amd64 (you
can check later with `kubectl get nodes -L kubernetes.io/arch`), you may add
`PUSH_PLATFORMS=linux/amd64` to the `make` command (faster); if unsure, keep both.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** the image name, `podman buildx is available.` (or `docker …`), then `Building … for
linux/amd64,linux/arm64`, the build and the push, and no `make: ***` line at the end.

**If not:** `x509` — step 3. `unauthorized` — step 5's login. `version.txt: No such file` or
`No rule to make target` — this terminal is not in the clone: `cd` into it (step 4). A message
that the engine is not installed or not running tells you the fix. A message that the amd64 image is labelled with a
variant — see Troubleshooting (podman on an arm64 Linux machine).

### Check that Harbor has both architectures

This asks Harbor which architectures the pushed image contains, to confirm the push sent both.

```sh
source ~/.vks-golang-web.env
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))  \([.references[]?.platform.architecture]|join(","))"'
rm -f "$CFG"
```

**Expect:** the start of the image's digest, your version tag, and `amd64,arm64` (in either order;
empty if you pushed one platform with `PUSH_PLATFORMS`).

**If not:** `404` — the image is not in `HARBOR_PROJECT`; check the project name and the push
output above. `401` — check the `REGISTRY_*` values.

## 7. Get the kubeconfigs

This logs you in to the Supervisor and fetches your guest cluster's kubeconfig, using step 2's
kubectl for the few read commands this needs. Then it installs the kubectl that matches the guest
cluster, which you use from then on (kubectl should be within one minor version of the cluster it
manages).

### Log in to the Supervisor

Check the password in the env file first: **five failed logins within 3 minutes lock the SSO
user for 5 minutes** (vCenter's default policy; yours may be stricter).

```sh
source ~/.vks-golang-web.env
if [ -z "$VCF_CLI_VSPHERE_PASSWORD" ] || [ "${VCF_CLI_VSPHERE_PASSWORD#<}" != "$VCF_CLI_VSPHERE_PASSWORD" ]; then
  echo "Set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first (vcf reads the password from it)"
else
  KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
    vcf context create supervisor --type k8s \
      --endpoint "https://${SUPERVISOR_ENDPOINT}" \
      --username "$SSO_USERNAME" \
      --ca-certificate "$SUPERVISOR_CA"
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" config use-context supervisor
fi
```

**Expect:** `Logged in successfully`, a list of saved contexts, then `Switched to context "supervisor"`.

**If not:**
- `context "supervisor" already exists`: run step 10's *Delete the Supervisor login* block, then
  this one again.
- A certificate error: check `SUPERVISOR_ENDPOINT` and step 2's vCenter CA.
- A login error: check `SSO_USERNAME` and `VCF_CLI_VSPHERE_PASSWORD` (in single quotes).

This guide logs in with the SSO user and a password. A Supervisor where you log in through a web
page (an external identity provider such as Okta or Entra ID) is out of scope: the password login
fails there. Ask your administrator for another way to get the guest cluster's kubeconfig, save it
with `source ~/.vks-golang-web.env; mkdir -p ~/.kube; cp <file> "$GUEST_KUBECONFIG"`, run
`kubectl_install "$(kubectl version -o json | jq -r .serverVersion.gitVersion)"`,
then continue at *Check the guest cluster* below.

Check that your SSO user can see your vSphere Namespace:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** your vSphere Namespace, `Active`.

**If not:** `NotFound` — check `VKS_NAMESPACE`. `Forbidden` — ask your administrator for the
**Edit** role on it. `Unauthorized` or a login prompt — the login above did not work; run it
again.

### Get the guest cluster's kubeconfig

This reads the guest cluster's kubeconfig from the Supervisor, saves it as `$GUEST_KUBECONFIG`
(the env file already points `kubectl` there), and installs the kubectl version that matches the
guest cluster.

```sh
source ~/.vks-golang-web.env
( umask 077
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "$GUEST_KUBECONFIG" )
V="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Guest cluster: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Guest cluster: v1.<minor>…`, then `Client Version:` with the same `v1.<minor>`.

**If not:** `secrets "<name>-kubeconfig" not found` — check `VKS_CLUSTER`. `Forbidden` — the
**Edit** role is missing. Either way `kubectl_install: no version` follows (the kubeconfig file is
left empty): fix the cause and run the block again.

### Check the guest cluster

This confirms that kubectl now reaches the guest cluster, and that its version matches the
cluster's.

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

**Expect:** every node `Ready`, and client and server on the same `v1.<minor>` (e.g. `v1.36.2` and `v1.36.2+vmware.2`).
From here on, kubectl talks to the guest cluster; the Supervisor is used only through `vcf`.

**If not:** a node `NotReady` is a cluster problem: tell your administrator.

## 8. Deploy

### Create the namespace

This creates a Kubernetes namespace called `golang-web` in the guest cluster, to hold the app, and
makes it the default for the commands below. (It is not your vSphere Namespace.)

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

**Expect:** `namespace/golang-web created` (or `unchanged`), then `Context "…" modified.`

### Create a pull secret — only for a private project

If your Harbor project is private (Harbor's default), the cluster needs your Harbor login to
download the image. Check whether the project is public, without logging in:

```sh
source ~/.vks-golang-web.env
curl -sS --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}"
```

**Expect:** `http=200` — the project is public: skip the next block. `http=401`, or any other
code except `000` — the project is private (or its visibility is unknown): run the next block.
With step 5 option B, that secret holds the Harbor admin password.

**If not:** `http=000` with a `curl:` error means Harbor could not be reached; fix that first
(step 3).

This stores your Harbor login in the cluster as the secret `harbor-creds`, and makes every pod in
the `golang-web` namespace use it to download from Harbor.

```sh
source ~/.vks-golang-web.env
D="$(mktemp -d)"
( umask 077
  export AUTH="$(printf '%s:%s' "$REGISTRY_USERNAME" "$REGISTRY_TOKEN" | base64 | tr -d '\n')"
  jq -nc '{auths:{(env.HARBOR_FQDN):{username:env.REGISTRY_USERNAME,
                                     password:env.REGISTRY_TOKEN, auth:env.AUTH}}}' \
    > "$D/dockercfg.json" )
kubectl create secret generic harbor-creds \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$D/dockercfg.json" --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$D"
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-creds"}]}'
```

**Expect:** `secret/harbor-creds created`, then `serviceaccount/default patched` (`configured` and
`patched (no change)` when run again).

**If not:** if a pod later shows `no basic auth credentials`, the `REGISTRY_*` values were empty or
wrong: fix them in the env file, run this block again, then
`kubectl rollout restart deploy/golang-web`.

### Deploy the app

This looks up the digest of the image you pushed in step 6, writes it into
`k8s/golang-web.yaml`'s image line (only for this command; the file is not changed), applies it,
and waits up to 150 seconds for the app to start. It deploys by digest because a tag can later
point to another image; a digest cannot.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
DIGEST="$(curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts/$(cat version.txt)" \
  | jq -r '.digest // empty')"
rm -f "$CFG"
echo "${IMAGE} -> ${DIGEST:-NOT FOUND — read the curl error above: 404 = not pushed (step 6); 401 = wrong credentials or HARBOR_PROJECT; 403 = the robot lacks artifact read; certificate = HARBOR_CA (step 3)}"

[ -n "$DIGEST" ] && \
  sed "s|image: .*/golang-web:.*|image: ${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web@${DIGEST}|" \
    k8s/golang-web.yaml | kubectl apply -f - && \
  kubectl rollout status deploy/golang-web --timeout=150s
```

**Expect:** `… -> sha256:…`, then `deployment.apps/golang-web` and `service/golang-web-service`
lines, then `successfully rolled out`.

**If not:** `NOT FOUND` explains itself. If the wait times out, run `kubectl describe pod -l
app=golang-web`, read the `Events` at the bottom, and look the message up in Troubleshooting.

Check that the running app uses exactly the image you pushed:

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

**Expect:** `Running`, and `IMAGEID` ending with the digest printed above. **If not:** an old pod
may still be listed; wait a few seconds and run it again.

## 9. Reach the app

### Reach the app through its LoadBalancer address

This waits for the cluster to give the app an external IP address (a *LoadBalancer* address), then
calls the app.

```sh
source ~/.vks-golang-web.env
kubectl wait svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -sS --max-time 10 "http://${APP_IP}:8080/myhello/"
```

**Expect:** `service/golang-web-service condition met`, the URL, then `Hello, World` and the pod's
details. (`/` alone returns 404; that is expected.)

**If not:** a timeout on the wait (no external IP) or on `curl` (the address is not reachable from
your machine): use the port-forward below instead.

### Reach the app through a port-forward (only if the address above did not work)

This forwards port 8080 on your machine to the app, through your kubeconfig. Run it in a second
terminal and leave it running; press Ctrl+C to stop it.

```sh
source ~/.vks-golang-web.env
kubectl port-forward svc/golang-web-service 8080:8080
```

**Expect:** `Forwarding from 127.0.0.1:8080 -> 8080`. **If not:** `address already in use` —
another program uses port 8080; use `8081:8080` here and `localhost:8081` below.

Then, in the first terminal:

```sh
curl -s http://localhost:8080/myhello/
```

**Expect:** `Hello, World` and the pod's details.

## 10. Clean up (optional)

This removes what this guide created. Run only the blocks you want, but in the order shown: the
last blocks delete the clone and the env file, which the others need.

### Delete the app

This deletes the app, with everything in its namespace (the pull secret too).

```sh
source ~/.vks-golang-web.env
kubectl delete namespace golang-web --ignore-not-found=true
```

**Expect:** `namespace "golang-web" deleted` (it can take a minute).

### Delete the image and the robot in Harbor

This deletes the **whole `golang-web` repository** in your
project — every tag, including any pushed by others. It needs `HARBOR_ADMIN_PASSWORD`; without it,
ask your administrator to delete the `golang-web` repository in your project and the robot
`robot$<your project>+golang-web-push`.

```sh
source ~/.vks-golang-web.env
harbor_cfg

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web" \
  -o /dev/null -w 'delete repository: http=%{http_code}\n'

PID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}" | jq -r .project_id)"
RID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" --get \
  --data-urlencode "q=Level=project,ProjectID=${PID}" --data-urlencode 'page_size=100' \
  "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[]|select(.name|test("golang-web-push"))|.id')"
[ -n "$RID" ] && curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/robots/${RID}" -o /dev/null -w 'delete robot: http=%{http_code}\n'

rm -f "$CFG"
```

**Expect:** `delete repository: http=200` and `delete robot: http=200` (no robot line if you used
the admin account or a robot your administrator made). `http=404` means it was already gone;
`http=401` means the admin password is wrong.

### Delete the local image and the Harbor login

This logs your container engine out of Harbor and deletes the image step 6 built from this
machine. Run it from inside the clone (step 4).

```sh
source ~/.vks-golang-web.env
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
  if ! "$e" info >/dev/null 2>&1; then
    echo "$e is not running: its images (and, for podman on macOS, its Harbor login) stay. Start it and run this block again."
    continue
  fi
  [ "$e" = podman ] && podman manifest rm "localhost/golang-web-push:$(cat version.txt)" >/dev/null 2>&1
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" image prune -f >/dev/null
done
```

**Expect:** a `… login credentials for <your Harbor>` line (docker may also print `Untagged:`
lines), or nothing if they were already gone. `… is not running` names an engine you have installed
but not started (on Linux, also docker when your user may not use it yet: log out and back in
after step 2's `usermod`): start it and run the block again, or ignore it if you never used that
engine. If the block hangs, an engine is half-started: press Ctrl-C, start it fully, and run the block again.

### Delete the Supervisor login

This removes the Supervisor login `vcf` saved in step 7, and `vcf`'s log files.

```sh
for c in $(vcf context list 2>/dev/null | awk '$1 ~ /^supervisor:/{print $1}'); do
  vcf context delete "$c" -y --skip-delete-kubeconfig-context
done
vcf context delete supervisor -y --skip-delete-kubeconfig-context
vcf context list
rm -rf ~/.config/vcf/logs
```

**Expect:** the final list no longer shows `supervisor`. An error for a context that is already
gone is harmless.

### Remove the Harbor CA

Skip this if you use this Harbor for other work: those tools need the CA too. Run only the block
for your engine; each prints nothing (the Colima block starts Colima first if it is stopped, and
then prints its start-up lines). podman, Linux and macOS:

```sh
source ~/.vks-golang-web.env
rm -rf "$HOME/.config/containers/certs.d/${HARBOR_FQDN:?}"
```

Linux, docker:

```sh
source ~/.vks-golang-web.env
sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"
```

macOS, docker (Colima):

```sh
source ~/.vks-golang-web.env
colima status >/dev/null 2>&1 || colima start
colima ssh -- sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"
```

### Delete the files this guide wrote

This deletes the CA files and kubeconfigs this guide saved. Empty directories are removed;
anything else in them is kept, as are the installed tools, base images, build cache and kubectl's
`~/.kube/cache`.

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
rmdir "$HOME/.config/containers/certs.d" "$HOME/.config/containers" "$HOME/.kube" 2>/dev/null
```

**Expect:** no output.

### Delete the clone

This deletes the `golang-web` directory step 4 created, and leaves your terminal in the directory
above it. **If you used a clone you already had in step 4, do not run this: it deletes the whole
directory, including any changes you made in it.** Run it from inside the clone.

```sh
if [ -f version.txt ] && [ "${PWD##*/}" = golang-web ]; then cd .. && rm -rf golang-web; else echo "Not in the golang-web clone: remove it yourself"; fi
```

**Expect:** no output (or `Not in the golang-web clone: remove it yourself` if you ran it
elsewhere).

### Delete the env file and the variables

In any other terminal where you loaded the env file, run the `unset` lines too, or
close it.

```sh
rm -f ~/.vks-golang-web.env ~/.vks-golang-web.functions
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP CONTAINER_ENGINE
unset -f harbor_cfg kubectl_install 2>/dev/null || true
```

**Expect:** no output.

## Fix common problems

| symptom | fix |
|---|---|
| Fingerprint differs from your administrator's (step 2 or 3) | Do not continue. Check `VCENTER_FQDN` or `HARBOR_FQDN`; send the fingerprint you got to your administrator and ask them to confirm it or send the CA file. A company proxy replacing HTTPS certificates also causes this. |
| `x509: certificate signed by unknown authority` on login or push | Run the step 3 block for **your** engine; the directory must be exactly `$HARBOR_FQDN`. On macOS with Colima, `docker context show` must also print `colima`; if it does not, run `docker context use colima`. |
| `x509: "harbor" certificate is not standards compliant` (macOS) | If you added the CA to the macOS Keychain instead of step 3: use step 3's podman or Colima block. |
| `docker: unknown command: docker buildx` (macOS) | Re-run the `ln -sfn … docker-buildx` line in step 2. |
| `dial unix /var/run/docker.sock` (macOS) | `colima start`. If it prints `already running`, `docker` is pointed at another engine: `docker context use colima`. |
| `bad CPU type in executable` (macOS) | An Intel-only program (such as the Supervisor's kubectl, from step 2's alternative under *Install kubectl*) needs Rosetta: `softwareupdate --install-rosetta --agree-to-license` |
| `vcf plugin list` pauses on `Refreshing plugin inventory cache` | Wait: it stops by itself after about 30 s (it cannot reach VMware's plugin server). The installed plugins do not need that server. |
| Every `vcf` command first prints `The vcf cli essential plugins have not been installed …` and `Failed to install plugin 'telemetry:v9.0.2'` | Harmless: the command still runs. It happens on a machine that had another `vcf` before; a fresh install by step 2 does not print it. To silence it, run `export VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION=v9.1.1` (add the line to `~/.zshrc` or `~/.bashrc` to keep it). The setting was found by testing VCF CLI 9.1.1; Broadcom does not document it. |
| `kubectl_install: command not found` | Re-run step 1's block; it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| `kubectl_install: no version` in step 7 | The guest cluster did not answer: check the kubeconfig block's output, and re-run step 7's login. |
| `kubectl_install: cannot reach dl.k8s.io` | If a `sudo:` line is printed above it, sudo failed: run the block again and enter your password. Otherwise ask your administrator to allow dl.k8s.io (the real fix). Until then, run step 2's *Alternative: install the kubectl your Supervisor serves* block (under *Install kubectl*): Intel/AMD machines only, and the Supervisor's older version. |
| `ImagePullBackOff` with `x509` in `kubectl describe pod` | The guest cluster does not trust Harbor's CA. Ask your administrator to add Harbor's CA certificate (your `$HARBOR_CA` file) to the trusted CAs of the guest cluster `$VKS_CLUSTER`. |
| `ImagePullBackOff` with `pull access denied` or `no basic auth credentials` in `kubectl describe pod` | The project is private: run step 8's pull-secret block, then `kubectl rollout restart deploy/golang-web` (running pods keep their old pull settings). |
| `403` on the step 6 or 8 lookup | The robot needs `artifact` read and list; create it with step 5. |
| `unauthorized` on push | Re-run step 5's login. A robot stops working when its `duration` (days) ends: then create a new one with step 5 option A (`ERROR CONFLICT` there says how). |
| Pod crash-loops | `kubectl logs deploy/golang-web --previous`, and send the output to the app's owner. |
| `blob upload invalid` on push | Harbor's storage is full: ask your administrator to run garbage collection or add space, then push again. |
| `labelled the amd64 image variant 'v8'`, or `labelling the amd64 image with a variant`, in step 6 | podman older than 5 on an arm64 Linux machine: push with docker (`CONTAINER_ENGINE=docker` in the env file), or podman 5.8 (measured correct). Only if every node is arm64: `PUSH_PLATFORMS=linux/arm64`. |
| `'podman buildx' is not available`, in step 6 | podman older than 4.9 (Debian 12 has 4.3): push with docker (`CONTAINER_ENGINE=docker` in the env file). |
| `exec format error` in the pod | The image lacks the node's architecture: push again without `PUSH_PLATFORMS`, or include the node's (`linux/amd64`). |
| Pod rejected at admission | The cluster enforces the `restricted` security policy, and `k8s/golang-web.yaml` complies. If you changed the file, keep it compliant; if not, send the message from `kubectl get events` to your administrator. |
