# Build `golang-web`, push it to Harbor, deploy it to a VKS guest cluster

This guide builds the `golang-web` container image on your machine, uploads it to your company's
Harbor registry, and runs it on a Kubernetes cluster managed by VMware vSphere (a *VKS guest
cluster*). It has 10 steps. Steps 1–4 are one-time setup; step 10 is optional clean-up.

Run every block in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each block
is followed by **Expect:** — what you should see — and, where it can go wrong, **If not:** — what
to do. A block that starts with `source ~/.vks-golang-web.env` is safe to run again.

## Terms

| term | meaning |
|---|---|
| Harbor | your company's private registry for container images |
| Harbor project | a folder in Harbor that holds images and has its own permissions; *private* (Harbor's default) or *public* |
| robot account | a Harbor login for scripts, limited to one project, that expires |
| CA certificate | the file your tools use to confirm they talk to the real server; company servers use a private CA your machine does not trust yet |
| fingerprint | a short hash of a certificate, used to compare it with your administrator's copy |
| vCenter CA | the certificate authority built into vCenter; it issued the Supervisor's certificate |
| Supervisor | the vSphere control plane you log in to, to reach your cluster |
| vSphere Namespace | your team's area on the Supervisor (not the Kubernetes namespace in step 8) |
| guest cluster | the Kubernetes cluster your app runs on |
| kubeconfig | the file `kubectl` reads to find a cluster and log in |
| context | a saved login inside a kubeconfig or the `vcf` tool |
| digest | an image's unique `sha256:…` ID; unlike a tag, it can never point to another image |
| pull secret | your Harbor login, stored in the cluster, so it can download images from a private project |

## Before you start

Get from your platform administrator:

- the Harbor DNS name, a project you may push to, and a robot account or the Harbor admin password
- the Supervisor endpoint, the vCenter DNS name, the vSphere Namespace and the guest cluster name
- an SSO user (your vCenter login) with the **Edit** role on that vSphere Namespace, and its password
- the SHA-256 fingerprints of the vCenter CA and of Harbor's CA certificate (you compare them in
  steps 2 and 3)
- confirmation that the guest cluster trusts Harbor's CA certificate (without it the cluster
  cannot download your image)
- network access from this machine to all of the above, and internet access to your package
  repositories, github.com, docker.io, gcr.io and dl.k8s.io

## 1. Set the variables

This block creates two files in your home directory, which every later step reads:

- `~/.vks-golang-web.env` — your settings and passwords, readable only by you. If it already
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
  if ! curl -fsIL --retry 3 -o /dev/null "https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"; then
    m="${v#v}"; m="${m%.*}"
    v="$(curl -fsSL --retry 3 "https://dl.k8s.io/release/stable-${m}.txt")" \
      || { echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)" >&2; return 1; }
    echo "note: no upstream kubectl ${1%%+*}; using ${v}, the newest of that minor" >&2
  fi
  u="https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"
  t="$(mktemp -d)" || return 1
  if curl -fsSL --retry 3 -o "$t/kubectl" "$u" \
     && h="$(curl -fsSL --retry 3 "${u}.sha256")" && [ -n "$h" ] \
     && [ "$( (sha256sum "$t/kubectl" 2>/dev/null || shasum -a 256 "$t/kubectl") | awk '{print $1}')" = "$h" ] \
     && sudo install -d /usr/local/bin && sudo install -m 0755 "$t/kubectl" /usr/local/bin/kubectl; then
    rm -rf "$t"; /usr/local/bin/kubectl version --client
    [ "$(command -v kubectl)" = /usr/local/bin/kubectl ] \
      || echo "WARNING: 'kubectl' on your PATH is $(command -v kubectl), not /usr/local/bin/kubectl" >&2
  else
    rm -rf "$t"; echo "kubectl_install: cannot reach dl.k8s.io, or the checksum did not match (${u}) — kubectl NOT changed" >&2; return 1
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
"${EDITOR:-vi}" ~/.vks-golang-web.env
```

Load the settings into this terminal. Do this in every new terminal; the blocks below also do it.

```sh
source ~/.vks-golang-web.env
```

**Expect:** no output. **If not:** `No such file or directory` means the first block did not run.

## 2. Install the tools

You need a container engine to build and upload the image (podman or docker), `kubectl` to talk
to Kubernetes, VMware's `vcf` tool to log in to the Supervisor, and a few small helpers. Skip
anything you already have; the Check at the end of this step shows what is missing.

### macOS: Homebrew

Homebrew is the macOS package manager used below. Skip this block if `brew --version` already
works. The installer asks for your password, installs the Xcode Command Line Tools too, and can
take several minutes.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
B=/opt/homebrew/bin/brew; [ -x "$B" ] || B=/usr/local/bin/brew
grep -qs "brew shellenv" ~/.zprofile || echo "eval \"\$($B shellenv)\"" >> ~/.zprofile
eval "$($B shellenv)"
brew --version
```

**Expect:** `Homebrew 4.…` (or newer).

### Container engine — pick one

The container engine builds the image and uploads it. Choose **one** and run only its block.
podman needs no background service; docker is the more common choice. Both work.

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
docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}'
docker buildx version
```

**Expect:** a line like `Ubuntu 24.04…/aarch64 server=29.…`, then `github.com/docker/buildx v0.…`.

Linux (Debian/Ubuntu), podman:

```sh
sudo apt-get update && sudo apt-get install -y podman
```

**Expect:** the install ends without an error; the Check below confirms it.

Linux (Debian/Ubuntu), docker. On Debian, replace `ubuntu` with `debian` in both URLs:

```sh
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

sudo usermod -aG docker "$USER"     # then LOG OUT AND BACK IN, or `docker` needs sudo
```

**Expect:** after you log out and back in, `docker info` works without `sudo`.

If both podman and docker are installed, the build uses podman. To use docker instead, run this
once (it adds `CONTAINER_ENGINE=docker` to the env file):

```sh
grep -qs CONTAINER_ENGINE ~/.vks-golang-web.env || echo 'export CONTAINER_ENGINE=docker' >> ~/.vks-golang-web.env
```

### Other tools

`jq` reads JSON; Linux also needs `git`, `make`, `unzip`, `curl` and `openssl`, which macOS
already has.

macOS (macOS 26 already ships `/usr/bin/jq`; this is then a no-op):

```sh
brew install jq
```

Linux (Debian/Ubuntu):

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

**Expect:** the install ends without an error; the Check below confirms it.

### vCenter CA

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

**Expect:** a `subject=` line naming `CA` and `vsphere`, then `sha256 Fingerprint=…` equal to the
one your administrator gave you.

**If not:**
- **A different fingerprint:** do not continue. Check `VCENTER_FQDN` in the env file. Then send
  the fingerprint you got to your administrator and ask them to confirm it or to send you the CA
  file. A company proxy that replaces HTTPS certificates also causes this.
- **A `curl:` error** (for example `Could not resolve host`), then `unzip` or `openssl` errors: the
  download failed. Check `VCENTER_FQDN` and that you can reach vCenter.

### kubectl

`kubectl` is the Kubernetes command-line tool. This installs the current release from the official
site (dl.k8s.io), for this machine. Step 7 replaces it with the versions that match your
Supervisor and then your guest cluster. `sudo` asks for your password.

```sh
source ~/.vks-golang-web.env
V="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
if [ -n "$V" ]; then kubectl_install "$V"; else echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)"; fi
```

**Expect:** `Client Version: v1.…` and no `WARNING` line.

**If not:**
- `WARNING: 'kubectl' on your PATH is …`: another kubectl is found first. Remove it, or put
  `/usr/local/bin` first in your `PATH`.
- `cannot reach dl.k8s.io`: see Troubleshooting.

Upstream kubectl is not a FIPS build; if your policy requires one, use your vendor's kubectl.

### VCF CLI

`vcf` is VMware's command-line tool. This guide uses it only to log in to the Supervisor (step 7).

Download the file for your platform (`Linux_AMD64`, `Linux_ARM64`, `Darwin_ARM64` or
`Darwin_AMD64`) from Broadcom. Tick **"I agree to the Terms and Conditions"** — the checkbox stays
greyed out until you open both Terms links — or the download icon does nothing.

| file | where to click | direct link |
|---|---|---|
| `VCF-Consumption-CLI-<platform>-9.1.1.0.25662425.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI** | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545612&viewGroup=true) |

- Pick the release first — until you do, the page reads "No data found". The direct link skips this.
- Take the row for your platform, not the multi-GB platform-less bundles beside it.
- The **VCF Consumption CLI Plugins** bundle is not needed: every `vcf` command in this guide is
  built in.
- On VCF with VCF Operations, your Supervisor's home page (`https://<SUPERVISOR_ENDPOINT>/`) also
  offers the CLI without a Broadcom login. Where it shows "VCF Consumption CLI is currently
  unavailable for download", use the portal. If you took it from the Supervisor, set `CLI_TGZ`
  below to that file (not tested here: this guide's lab Supervisor serves no CLI).

This block finds this machine's file in `~/Downloads`, prints its checksum and installs it. If you
saved the file elsewhere, change that folder. Other platforms are not supported.

```sh
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  P=Linux_AMD64 ;;
  Linux/aarch64) P=Linux_ARM64 ;;
  Darwin/arm64)  P=Darwin_ARM64 ;;
  Darwin/x86_64) P=Darwin_AMD64 ;;
  *)             P=unsupported ;;
esac
CLI_TGZ="$HOME/Downloads/VCF-Consumption-CLI-${P}-9.1.1.0.25662425.tar.gz"

if [ -f "$CLI_TGZ" ]; then
  (sha256sum "$CLI_TGZ" 2>/dev/null || shasum -a 256 "$CLI_TGZ") | awk '{print "SHA-256: " $1}'
  T="$(mktemp -d)"
  tar -xzf "$CLI_TGZ" -C "$T"
  sudo install -d /usr/local/bin
  sudo install "$T"/vcf-cli-* /usr/local/bin/vcf
  rm -rf "$T"
  vcf version | head -1
else
  echo "Not found: $CLI_TGZ — download it (table above) for $(uname -s)/$(uname -m)"
fi
```

**Expect:** a `SHA-256:` equal to the **SHA2** the download page shows for your file, then
`version: v9.1.1.0.25662425` (or the release you downloaded).

**If not:** a different checksum means a damaged or wrong download: delete the file and download
it again. If it still differs, do not install it; tell your administrator.

### Check

This lists any tool that is still missing and prints the versions of the rest.

```sh
for t in curl unzip openssl jq git make kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done

command -v podman >/dev/null 2>&1 && podman --version
command -v docker >/dev/null 2>&1 && docker --version
kubectl version --client
vcf version | head -1
```

**Expect:** no `MISSING` line, then a version line for podman or docker (whichever you installed),
kubectl's `Client Version:`, and `version: v9.…`.

**If not:** re-run the install block for each `MISSING` tool.

## 3. Trust the Harbor CA

Harbor's certificate comes from a CA your machine does not trust yet, so your container engine
refuses to upload to Harbor. This step downloads Harbor's CA certificate to `$HARBOR_CA` and
installs it where your engine looks for it. As in step 2, the download cannot be verified yet, so
you compare its fingerprint with your administrator's.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

**Expect:** `sha256 Fingerprint=…` equal to the one your administrator gave you.

**If not:**
- **A different fingerprint:** do not continue. Check `HARBOR_FQDN` in the env file. Then send
  the fingerprint you got to your administrator and ask them to confirm it or to send you the CA
  file (save it as `$HARBOR_CA`). A company proxy that replaces HTTPS certificates also causes
  this.
- **A `curl:` error, then `Could not read certificate`** (or `unable to load certificate`): the
  download failed. Check `HARBOR_FQDN` and that you can reach Harbor.

Install it for your engine — run only the block for the engine you chose in step 2.

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

macOS, docker (Colima). If you ever run `colima delete`, run this again:

```sh
source ~/.vks-golang-web.env
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
```

**Expect:** no output.

Check that the CA file works, by calling Harbor with it (the engine's own trust is proven by the
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

**Expect:** `Cloning into 'golang-web'...`. Run everything below from this directory.

## 5. Harbor credentials

Your container engine needs a Harbor login to upload the image, and step 8 uses it to find the
image. Use a **robot account** (option A) or the **admin account** (option B). The make commands
below take the Harbor project as `OWNER`.

### Option A — a robot account

Skip the first block if your administrator gave you a robot name and secret.

This creates a robot account that can push to and read from your project only, and expires after
90 days. It needs `HARBOR_ADMIN_PASSWORD` in the env file.

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
  otherwise delete it (step 10, the Harbor block) and run this again.
- No output at all: Harbor could not be reached; re-check step 3.

In `~/.vks-golang-web.env`, replace the two `REGISTRY_*` lines with the name and secret printed
above, exactly as printed and in single quotes (the `$` in the name is part of it):

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
export REGISTRY_TOKEN='<the 32-character secret>'
```

### Option B — the admin account

In `~/.vks-golang-web.env`, set:

```sh
export REGISTRY_USERNAME='admin'
export REGISTRY_TOKEN='<Harbor admin password>'
```

### Log in

This saves your Harbor login in the container engine, so step 6 can upload.

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** `Login Succeeded` (podman adds `!`; docker adds a warning about unencrypted credentials).

**If not:** `x509` — run step 3's block for your engine. `unauthorized` — check the two
`REGISTRY_*` values in the env file.

## 6. Build and push the image

This builds the app into a container image and uploads (*pushes*) it to Harbor. The image holds a
build for each common CPU type, `amd64` and `arm64`, under one name, so it runs on any node
whatever machine you build on. The first build takes a few minutes.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** the image name, then `Building … for linux/amd64,linux/arm64`, the build and the upload,
and no `make: ***` line at the end. To build only one type (faster, if all your nodes are amd64),
add `PUSH_PLATFORMS=linux/amd64`.

**If not:** `x509` — step 3. `unauthorized` — step 5's login. A message that the engine is not
installed or not running tells you the fix.

Check that Harbor received both builds:

```sh
source ~/.vks-golang-web.env
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))  \([.references[]?.platform.architecture]|join(","))"'
rm -f "$CFG"
```

**Expect:** the start of the image's digest, your version tag, and `amd64,arm64` (in either order).

**If not:** `404` — the image is not in `HARBOR_PROJECT`; check the project name and step 6's
output. `401` — check the `REGISTRY_*` values.

## 7. Get the kubeconfigs

This logs you in to the Supervisor and fetches the kubeconfig for your guest cluster. On the way it
installs the kubectl version that matches each one, because kubectl should be within one minor
version of the cluster it talks to.

### Log in to the Supervisor

Check the password in the env file first: **five failed logins within 3 minutes lock the SSO
account for 5 minutes** (vCenter's default policy; yours may be stricter).

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
- `context "supervisor" already exists`: run the vcf-contexts block in step 10, then this one again.
- A certificate error: check `SUPERVISOR_ENDPOINT` and step 2's vCenter CA.
- A login error: check `SSO_USERNAME` and `VCF_CLI_VSPHERE_PASSWORD` (in single quotes).

This guide logs in with the SSO user and a password. A Supervisor that uses only an external
OIDC identity provider is out of scope: the password login fails there. Ask your administrator
for another way to get the guest cluster's kubeconfig, save it as `$GUEST_KUBECONFIG`, and
continue at the `kubectl get nodes` block below.

### kubectl for the Supervisor

This installs the kubectl version that matches the Supervisor, for the next command. It is
temporary: the guest cluster's version replaces it below.

```sh
source ~/.vks-golang-web.env
V="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Supervisor: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Supervisor: v1.<minor>…`, then `Client Version:` with the same `v1.<minor>`.

**If not:** `Supervisor: unknown` and `kubectl_install: no version` — the login above did not
work; run it again.

Check that your SSO user can see your vSphere Namespace:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** your namespace, `Active`.

**If not:** `NotFound` — check `VKS_NAMESPACE`. `Forbidden` — ask your administrator for the
**Edit** role on it.

### Guest cluster

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
**Edit** role is missing.

Check the guest cluster:

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

**Expect:** every node `Ready`, and client and server on the same `v1.<minor>` (e.g. `v1.36.2` and `v1.36.2+vmware.2`).
From here on, kubectl talks to the guest cluster; the Supervisor is used only through `vcf`.

**If not:** a node `NotReady` is a cluster problem: tell your administrator.

## 8. Deploy

### Namespace

This creates a Kubernetes namespace called `golang-web` in the guest cluster, to hold the app, and
makes it the default for the commands below. (It is not your vSphere Namespace.)

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

**Expect:** `namespace/golang-web created` (or `unchanged`), then `Context "…" modified.`

### Pull secret — only for a private project

If your Harbor project is private (Harbor's default), the cluster needs your Harbor login to
download the image. Check whether the project is public, without logging in:

```sh
source ~/.vks-golang-web.env
curl -sS --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}"
```

**Expect:** `http=200` — the project is public: skip the next block. `http=401` — the project is
private: run it.

**If not:** `http=000` with a `curl:` error means Harbor could not be reached; fix that first
(step 3).

This stores your Harbor login in the cluster as the secret `harbor-creds`, and tells the namespace's
default service account to use it, so every pod in `golang-web` can download from Harbor.

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

**Expect:** `secret/harbor-creds created`, then `serviceaccount/default patched`.

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

**Expect:** `Running`, and `IMAGEID` ending with the digest printed above.

## 9. Reach the app

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
details. `/myhello/` and `/healthz` return 200; `/` returns 404 by design.

**If not:** a timeout on the wait (no external IP) or on `curl` (the address is not reachable from
your machine): use the port-forward below instead.

### Port-forward (only if the address above did not work)

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

This removes what this guide created. Each block is independent; run only the ones you want.

The app, with everything in its namespace (the pull secret too):

```sh
source ~/.vks-golang-web.env
kubectl delete namespace golang-web --ignore-not-found=true
```

**Expect:** `namespace "golang-web" deleted` (it can take a minute).

The image and the robot in Harbor. This deletes the **whole `golang-web` repository** in your
project — every tag, including any pushed by others. It needs `HARBOR_ADMIN_PASSWORD`; without it,
ask your administrator to delete them.

```sh
source ~/.vks-golang-web.env
harbor_cfg

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web" \
  -o /dev/null -w 'repository deleted: http=%{http_code}\n'

PID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}" | jq -r .project_id)"
RID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" --get \
  --data-urlencode "q=Level=project,ProjectID=${PID}" --data-urlencode 'page_size=100' \
  "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[]|select(.name|test("golang-web-push"))|.id')"
[ -n "$RID" ] && curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/robots/${RID}" -o /dev/null -w 'robot deleted: http=%{http_code}\n'

rm -f "$CFG"
```

**Expect:** `repository deleted: http=200` and `robot deleted: http=200`. `http=404` means it was
already gone; `http=401` means the admin password is wrong.

The local image and the registry login:

```sh
source ~/.vks-golang-web.env
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  [ "$e" = podman ] && podman manifest rm "localhost/golang-web-push:$(cat version.txt)" >/dev/null 2>&1
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
  "$e" image prune -f >/dev/null
done
```

**Expect:** `Untagged:`/`Deleted:` lines and `Removed login credentials`, or nothing if they were
already gone.

The Supervisor login `vcf` saved in step 7:

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

The Harbor CA — run only the block for your engine. podman, Linux and macOS:

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
colima ssh -- sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"
```

The files this guide wrote, and the clone. Run it from inside the clone (step 4). Empty
directories are removed; anything else in them is kept, as are the installed tools, base images,
build cache and kubectl's `~/.kube/cache`.

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
rmdir "$HOME/.config/containers/certs.d" "$HOME/.config/containers" "$HOME/.kube" 2>/dev/null
if [ -f version.txt ] && [ "${PWD##*/}" = golang-web ]; then cd .. && rm -rf golang-web; else echo "Not in the golang-web clone: remove it yourself"; fi
```

The variables. In any other terminal where you loaded the env file, run the `unset` lines too, or
close it.

```sh
rm -f ~/.vks-golang-web.env ~/.vks-golang-web.functions
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP CONTAINER_ENGINE
unset -f harbor_cfg kubectl_install 2>/dev/null || true
```

## Troubleshooting

| symptom | fix |
|---|---|
| Fingerprint differs from your administrator's (step 2 or 3) | Do not continue. Check `VCENTER_FQDN` or `HARBOR_FQDN`; send the fingerprint you got to your administrator and ask them to confirm it or send the CA file. A company proxy replacing HTTPS certificates also causes this. |
| `x509: certificate signed by unknown authority` on login or push | Run the step 3 block for **your** engine; the directory must be exactly `$HARBOR_FQDN`. |
| `x509: "harbor" certificate is not standards compliant` (macOS) | Use step 3's podman or Colima block, not the macOS Keychain. |
| `docker: unknown command: docker buildx` (macOS) | Re-run the `ln -sfn … docker-buildx` line in step 2. |
| `dial unix /var/run/docker.sock` (macOS) | `colima start` |
| `bad CPU type in executable` (macOS) | An amd64-only program (such as the Supervisor's kubectl below) needs Rosetta: `softwareupdate --install-rosetta --agree-to-license` |
| `kubectl_install: command not found` | Re-run step 1's block; it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| `kubectl_install: no version` in step 7 | The Supervisor or cluster did not answer: re-run step 7's login. |
| `kubectl_install: cannot reach dl.k8s.io` | Allow dl.k8s.io, or use the Supervisor's kubectl: amd64 only (no Linux arm64; on Apple silicon it needs Rosetta, see `bad CPU type` above) and the Supervisor's older version. In a new directory: `curl -fsS --cacert "$SUPERVISOR_CA" -O "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/linux-amd64/vsphere-plugin.zip" && unzip -oq vsphere-plugin.zip bin/kubectl && sudo install -m 0755 bin/kubectl /usr/local/bin/kubectl` (macOS: `darwin-amd64`). |
| `ImagePullBackOff` with `x509` in `kubectl describe pod` | The guest cluster does not trust Harbor's CA. Ask your administrator to add Harbor's CA certificate (your `$HARBOR_CA` file) to the trusted CAs of the guest cluster `$VKS_CLUSTER`. |
| `ImagePullBackOff` with `pull access denied` or `no basic auth credentials` in `kubectl describe pod` | The project is private: run step 8's pull-secret block, then `kubectl rollout restart deploy/golang-web` (running pods keep their old pull settings). |
| `403` on the step 6 or 8 lookup | The robot needs `artifact` read and list; create it with step 5. |
| `unauthorized` on push | Re-run step 5's login; a robot stops working when its `duration` (days) ends. |
| Pod crash-loops or serves an old build | Deploy by digest (step 8), then check `IMAGEID`. |
| `exec format error` in the pod | The image lacks the node's architecture: push again without `PUSH_PLATFORMS`, or include the node's (`linux/amd64`). |
| Pod rejected at admission | The cluster enforces the `restricted` security policy, and `k8s/golang-web.yaml` complies. If you changed the file, keep it compliant; if not, send the message from `kubectl get events` to your administrator. |
| `EXTERNAL-IP` stays `<pending>` | Use the port-forward in step 9. |
