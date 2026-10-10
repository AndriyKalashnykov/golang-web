# Install the tools

This chapter installs the command-line tools these guides use, on macOS and on Debian or Ubuntu
Linux. It comes after [Set the variables](README.md#set-the-variables) of
[the main guide](README.md): several blocks read the env file and use its helper commands. You
need sudo rights on this machine for most installs, and a Broadcom support account for the VCF
CLI. At the end, the main guide's check block under
[Install the tools](README.md#install-the-tools) prints no `MISSING` line.

Install only what your path needs, and skip any tool you already have:

| tool | who needs it | part |
|---|---|---|
| Homebrew | every macOS reader | [Install Homebrew (macOS only)](#install-homebrew-macos-only) |
| `jq`, `git`, `unzip`, `curl`, `openssl`, `make` | everyone | [Install jq and the other command-line tools](#install-jq-and-the-other-command-line-tools) |
| `kubectl` | everyone | [Install kubectl](#install-kubectl) |
| `vcf` | everyone | [Install the VCF CLI and its plugins](#install-the-vcf-cli-and-its-plugins) |
| podman or docker | only [REGISTRY.md](REGISTRY.md): building the image yourself | [Install a container engine — pick one](#install-a-container-engine--pick-one) |
| `envsubst` | only [CLUSTER.md](CLUSTER.md): creating a guest cluster | [Install envsubst](#install-envsubst) |
| `helm` | only the Headlamp add-on, when you install it from its chart | [Install helm](#install-helm) |
| a clipboard program | only [HARBOR-manual.md](HARBOR-manual.md), on Linux | [Install a clipboard program (Linux only)](#install-a-clipboard-program-linux-only) |

Run the blocks by copy and paste, in `bash` or `zsh`. Each block is followed by **Expect:** —
what you should see — and, where it can go wrong, **If not:** — what to do.

## Install Homebrew (macOS only)

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

## Install jq and the other command-line tools

`jq` reads JSON; Linux also needs `git`, `make`, `unzip`, `curl` and `openssl`, which macOS
already has.

**macOS** (skip this if `jq --version` already works; macOS 26 has `jq` built in):

```sh
brew install jq
```

**Linux (Debian/Ubuntu):**

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

**Expect:** the install ends without an error; the main guide's check block confirms it.

## Install kubectl

`kubectl` is the Kubernetes command-line tool. The second block below installs the newest stable
release from the official site (dl.k8s.io). It is only a starting point: your guest cluster's
version is not known yet. The main guide's
[Get the guest cluster's kubeconfig](README.md#get-the-guest-clusters-kubeconfig) reads that
version from the cluster and replaces this kubectl only if it is more than one minor version
away (Kubernetes supports a client within one minor version of the cluster).

kubectl goes into `/usr/local/bin` (`KUBECTL_DIR` in the env file). That directory needs
administrator rights on most machines, and the install never asks for a password: if `sudo`
would ask, kubectl goes into `~/.local/bin` instead, and the block says so. To have it in
`/usr/local/bin`, give `sudo` your password first, as a block of its own (skip it if you have no
`sudo` rights on this machine):

```sh
sudo -v
```

**Expect:** a password prompt, then no output; no prompt and no output at all when `sudo` still
remembers your password or never asks for one. **If not:** `… is not in the sudoers file`, or
`a terminal is required` — you have no `sudo` here: go on, kubectl goes into `~/.local/bin`.

Now install kubectl:

```sh
source ~/.vks-golang-web.env
V="$(curl -fsSL --connect-timeout 10 https://dl.k8s.io/release/stable.txt)"
if [ -n "$V" ]; then kubectl_install "$V"; else echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)"; fi
```

**Expect:** `Client Version: v1.…` (and a `Kustomize Version` line), and no `WARNING` line. If
this machine already has a kubectl within one minor version of the newest release, the block
prints `kubectl v1.… is within one minor version of v1.…: supported, not changed` instead.

**If not:**
- `… installing into <your home>/.local/bin instead`: not an error. `sudo` would have asked for a
  password, so kubectl is in `~/.local/bin`. If a line `… was not on your PATH` follows, add the
  line it prints to `~/.zshrc` (zsh) or `~/.bashrc` (bash), so that new terminals find kubectl;
  this terminal already does.
- `WARNING: 'kubectl' on your PATH is …`: another kubectl is found first. Put the directory named
  at the end of the line first in your `PATH`, or remove the other kubectl.
- `kubectl_install: command not found`, or `No such file or directory` for the env file: do the
  main guide's [Set the variables](README.md#set-the-variables) first.
- `kubectl_install: cannot reach dl.k8s.io`: ask your administrator to allow dl.k8s.io, or use
  the alternative below.
- `kubectl_install: the checksum of the download does not match`: the download arrived damaged.
  Run the block again; if it repeats, tell your administrator. (The checksum comes from the same
  site as the download, so it catches a damaged file, not one that was replaced on purpose.)
- `kubectl_install: could not write …`: the error above that line says why (a full disk, or a home
  directory you may not write to).

<details>
<summary><b>Alternative: download kubectl from your Supervisor</b> (only if dl.k8s.io is blocked)</summary>

Run this only if the block above printed `cannot reach dl.k8s.io`. Your Supervisor offers a
kubectl download of its own, for Intel/AMD (amd64) Linux and macOS only. This block picks the one for this machine,
downloads it from the Supervisor and installs it into `/usr/local/bin`; its `sudo` asks for your
password. The download does not check the Supervisor's certificate (`curl -k`), so it needs no CA
file. On any other machine the block installs nothing and says so. This kubectl is the Supervisor's version, which can be several versions older than
your guest cluster. The main guide's
[Get the guest cluster's kubeconfig](README.md#get-the-guest-clusters-kubeconfig) still tries
to install the matching one from dl.k8s.io; if that is still blocked, it says so (after up to
about a minute and a half), this kubectl stays, and the main guide's
[Check the guest cluster](README.md#check-the-guest-cluster) prints a `version difference`
warning.

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

## Install the VCF CLI and its plugins

`vcf` is VMware's command-line tool; the main guide uses it to
[log in to the Supervisor](README.md#log-in-to-the-supervisor). The
plugins bundle adds `vcf`'s other commands (for example `vcf cluster` and `vcf package`), which
you will want for day-to-day work with VKS; these guides themselves do not use them. The block
installs them from the downloaded file, without internet access.

Download the files for your platform (`Linux_AMD64`, `Linux_ARM64`, `Darwin_ARM64` or
`Darwin_AMD64`) from Broadcom (`Darwin_AMD64` is the one for Intel Macs). Tick **"I agree to the Terms and Conditions"** — the checkbox stays
greyed out until you open both Terms links — or the download icon does nothing.

| file | where to click | direct link |
|---|---|---|
| `VCF-Consumption-CLI-<platform>-9.1.1.0100.25746586.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0100 → **VCF Consumption CLI** | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0100&os=&servicePk=547810&language=EN&groupId=545612&viewGroup=true) |
| `VCF-Consumption-CLI-PluginBundle-<platform>-9.1.1.0100.25793136.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0100 → **VCF Consumption CLI Plugins** | [VCF CLI plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0100&os=&servicePk=548172&language=EN&groupId=545621&viewGroup=true) |

- Pick the release first — until you do, the page reads "No data found". The direct link skips this.
- Take the row for your platform, not the multi-GB platform-less bundles beside it.
- Your Supervisor's home page may also offer the CLI, or answer "VCF CLI is currently unavailable
  for download". This guide uses the Broadcom download.

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
CLI_TGZ="$HOME/Downloads/VCF-Consumption-CLI-${P}-9.1.1.0100.25746586.tar.gz"
PLUGINS_TGZ="$HOME/Downloads/VCF-Consumption-CLI-PluginBundle-${P}-9.1.1.0100.25793136.tar.gz"

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
then `version: v9.1.1.0100.25746586` (or the release you downloaded), then the plugins, each
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

That is all the main guide needs. Go back to its check block under
[Install the tools](README.md#install-the-tools), unless your path needs one of the tools below.

## Install a container engine — pick one

Only for [REGISTRY.md](REGISTRY.md), where you build the image yourself. The container engine
builds the image and pushes it. Choose **one** and run only its block. Both
work; if unsure, pick podman — **except on an arm64 Linux machine** (run `uname -m`: `aarch64` means arm64): there, podman 4.x (Ubuntu
24.04 has 4.9) builds an image the cluster cannot pull, and
[Build and push](REGISTRY.md#build-and-push) refuses it. Pick docker there
(podman 5.8 also works, if you already have it).

**macOS, podman:**

```sh
brew install podman
podman machine inspect >/dev/null 2>&1 || podman machine init
podman info >/dev/null 2>&1 || podman machine start
```

**Expect:** the last lines say the machine `started successfully`, or nothing if it was already
running.

**macOS, docker** (Colima — runs the docker engine in a small VM):

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

**Linux (Debian/Ubuntu), podman:**

```sh
sudo apt-get update && sudo apt-get install -y podman
```

**Expect:** the install ends without an error; *Check the tools* below confirms it. podman 4.9 or newer
is needed (Ubuntu 24.04 has it; Debian 13 has 5.4). Debian 12 has podman 4.3, which
does not work: use docker there and on anything older.

**Linux (Debian/Ubuntu), docker.** The first line reads which of the two you have:

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

## Install envsubst

Only for [CLUSTER.md](CLUSTER.md), which has the same two blocks: if you ran them there, skip
this. `envsubst` fills the `${…}` places of a file from your settings. Skip the install if
`envsubst --version` already works.

**macOS:**

```sh
brew install gettext
```

**Expect:** Homebrew's install lines, ending without an `Error:` line.

**Linux (Debian/Ubuntu):**

```sh
sudo apt-get update && sudo apt-get install -y gettext-base
```

**Expect:** the install ends without an error (`gettext-base is already the newest version` is
fine).

## Install helm

Only for the Headlamp add-on, when you install it from its chart. Nothing else in these guides
needs a `helm` program on your machine: ArgoCD reads the guest-cluster chart from Git by itself.
Skip the install if `helm version` already works.

**macOS:**

```sh
brew install helm
```

**Expect:** Homebrew's install lines, ending without an `Error:` line.

**Linux.** This runs the Helm project's own install script, which downloads the newest release,
checks its checksum and copies `helm` into `/usr/local/bin`; its `sudo` asks for your password:

```sh
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
```

**Expect:** `Downloading https://get.helm.sh/helm-v4.…`, `Verifying checksum... Done.`, then
`helm installed into /usr/local/bin/helm`.

**If not:** a `curl:` error — this machine cannot reach raw.githubusercontent.com or get.helm.sh:
ask your administrator to allow them.

Then, on both:

```sh
helm version --short
```

**Expect:** `v4.…` (a `v3.…` you already had also works).

## Install a clipboard program (Linux only)

Only for [HARBOR-manual.md](HARBOR-manual.md), which copies a configuration file to the clipboard
so that you can paste it into the vSphere Client; that chapter has the same line, so skip this
if you ran it there. macOS has `pbcopy` built in. The line below is for a Wayland desktop, which
Ubuntu uses unless you chose otherwise. On an X11 desktop (`echo $XDG_SESSION_TYPE` prints
`x11`) write `xclip` in place of `wl-clipboard`.

```sh
sudo apt-get install -y wl-clipboard
```

**Expect:** the install ends without an error (`wl-clipboard is already the newest version` is
fine).

**If not:** `Unable to locate package` — the package list is old: run `sudo apt-get update`,
then the line again.

## Check the tools

This lists any tool that is still missing for the main guide and for
[REGISTRY.md](REGISTRY.md) together, and prints the versions of the rest.

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
kubectl's `Client Version:`, and `version: v9.…`. `MISSING: podman or docker` and `MISSING: make`
matter only when you build the image yourself.

**If not:** re-run the install block for each `MISSING` tool.

## Next

Go back to [the main guide](README.md), at the check block under
[Install the tools](README.md#install-the-tools).
