# Build `golang-web` locally, push it to Harbor, deploy it to a VKS guest cluster

Build the container image on your own machine (macOS or Linux), push it to your Harbor registry,
and deploy `k8s/golang-web.yaml` to a named VKS guest cluster. The first run is mostly tool
installs and downloads; later runs take a few minutes.

**Before you start, get these from your platform administrator:**

- the Harbor DNS name, a project you may push to, and either a robot account or the Harbor admin
  password (step 6 creates a robot from the admin password)
- the Supervisor API endpoint, the vCenter DNS name, your vSphere Namespace, the guest cluster
  name, and the guest cluster's **Kubernetes version** (for example `v1.36.2`)
- an SSO user and password that can read secrets in that namespace (the **Edit** role)
- network access to all of the above — if they are not reachable from your machine, ask for a
  jump host or a tunnel before going further

**And for yourself:** a Broadcom support account entitled to the VCF CLI downloads (step 2), and
internet access for the tool installs.

**Shell:** everything works in both `bash` and `zsh` (macOS defaults to `zsh`, most Linux
distributions to `bash`).

---

## 1. Set the variables

Everything below reads these from one file, so a second terminal — and tomorrow's session — is one
`source` away, and the credentials stay out of your shell history:

```sh
( umask 077; set -C; cat > ~/.vks-golang-web.env <<'EOF'
# --- from your platform administrator ----------------------------------------
export HARBOR_FQDN="harbor.example.test"         # Harbor's DNS name
export HARBOR_PROJECT="apps"                     # the Harbor PROJECT the image lands in
export SUPERVISOR_ENDPOINT="10.0.0.10"           # Supervisor API endpoint (IP or FQDN)
export VCENTER_FQDN="vcsa.example.test"          # vCenter — serves the CA the Supervisor uses
export VKS_CLUSTER="my-guest-cluster"            # the guest cluster NAME
export VKS_NAMESPACE="my-namespace"              # the vSphere Namespace holding it
export SSO_USERNAME="administrator@vsphere.local"

# --- credentials: ALWAYS in SINGLE quotes -------------------------------------
# This file is `source`d, so inside double quotes a `$` in a password or robot name is
# expanded away and you get a silently WRONG credential — for the SSO account that can mean a
# lockout. (A value that itself contains a single quote: write it as '\''.)
export VCF_CLI_VSPHERE_PASSWORD='<your vCenter SSO password>'   # vcf reads it from here: no prompt
export HARBOR_ADMIN_PASSWORD=''                  # only to create a robot in step 6; else leave empty
export REGISTRY_USERNAME=''                      # step 6 fills these two
export REGISTRY_TOKEN=''

# --- paths; no need to change these -----------------------------------------
export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

# Every kubectl from step 8b on talks to the GUEST cluster.
export KUBECONFIG="$GUEST_KUBECONFIG"

# harbor_cfg [USER PASSWORD] writes a curl -K config holding a Harbor credential (the admin by
# default) to $CFG, so the password never appears on a command line. curl parses that file, so
# backslashes and double quotes are escaped.
harbor_cfg() {
  local u p
  if [ $# -ge 1 ]; then u="$1"; p="$2"; else u=admin; p="$HARBOR_ADMIN_PASSWORD"; fi
  [ -n "$u" ] && [ -n "$p" ] || { echo "harbor_cfg: empty user or password — fill the env file (step 6)" >&2; return 1; }
  u="${u//\\/\\\\}"; u="${u//\"/\\\"}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
  CFG="$(mktemp)"; ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$CFG" )
}
EOF
)
chmod 600 ~/.vks-golang-web.env
```

If it says `cannot overwrite existing file` (bash) or `file exists` (zsh), you already have one —
edit it instead; that refusal keeps a filled-in file from being replaced by placeholders.

Now edit `~/.vks-golang-web.env` with your values, then load it:

```sh
source ~/.vks-golang-web.env
```

**Every new terminal needs that one line** — nothing else in this guide re-exports anything.

---

## 2. Install the tools

| tool | why |
|---|---|
| `podman` (or `docker`) | build and push the image |
| `kubectl` | talk to the guest cluster |
| `vcf` | the VCF CLI — authenticates to the Supervisor |
| `git`, `make` | check out and drive the repo |
| `jq`, `curl`, `unzip`, `openssl` | read Harbor and kubectl JSON, fetch certificates |

### macOS: Homebrew and the Command Line Tools first

A fresh Mac has neither, and every macOS command below uses `brew`. You also need an admin account,
for the `sudo` steps.

```sh
xcode-select --install     # Command Line Tools (git, make); a dialog opens — skip if already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
B=/opt/homebrew/bin/brew; [ -x "$B" ] || B=/usr/local/bin/brew   # Apple Silicon, else Intel
echo "eval \"\$($B shellenv)\"" >> ~/.zprofile
eval "$($B shellenv)"
brew --version
```

### Pick a container engine

Either works. **podman** is the default; **docker** is equally fine.

**macOS — podman**

```sh
brew install podman
podman machine init && podman machine start
```

**macOS — docker.** The CLI alone cannot build or push; it needs a Linux VM behind it.
`brew install docker` installs only the client. Run the engine in a VM with Colima:

```sh
brew install colima docker docker-buildx
# Homebrew's buildx is a docker plugin that docker cannot find on its own -- link it where docker looks:
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
colima start
docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}'
docker buildx version       # must print a version -- the image build uses `docker buildx build`
```

Without the link, `docker buildx` fails with `docker: unknown command: docker buildx`. With a CLI but no VM
running you get `dial unix /var/run/docker.sock: connect: no such file or directory`, which is
**not** a permissions problem and is **not** fixed by `sudo`.

**Linux (Debian/Ubuntu) — podman**

```sh
sudo apt-get update && sudo apt-get install -y podman
```

**Linux (Debian/Ubuntu) — Docker Engine**, from Docker's own repository. The distribution's
`docker.io` package does not ship `docker-buildx-plugin`, which the image build needs:

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

> Debian: replace both `ubuntu` occurrences with `debian`.

**If both are installed, podman is used.** To use docker, add `CONTAINER_ENGINE=docker` to each
`make` command, or `export CONTAINER_ENGINE=docker` in the env file.

### The rest of the tools

**macOS** — `git` and `make` come with the Command Line Tools installed above; `make` is Apple's
(GNU Make 3.81), which this repo's Makefile supports:

```sh
brew install jq
```

**Linux (Debian/Ubuntu)**

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

### kubectl

Take the build that matches your **guest cluster's** Kubernetes version — every command from
section 9 on runs against it:

```sh
source ~/.vks-golang-web.env
export KUBECTL_VERSION="v1.36.2"           # your guest cluster's version, from your administrator
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  KOS=darwin/arm64 ;;
  Darwin/*)      KOS=darwin/amd64 ;;
  Linux/aarch64) KOS=linux/arm64  ;;
  *)             KOS=linux/amd64  ;;
esac
T="$(mktemp -d)"
curl -fsSL -o "$T/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${KOS}/kubectl"
sudo install -d /usr/local/bin             # absent on a fresh Apple Silicon Mac
sudo install -m 0755 "$T/kubectl" /usr/local/bin/kubectl
rm -rf "$T"

/usr/local/bin/kubectl version --client
echo "PATH kubectl: $(command -v kubectl)"   # not /usr/local/bin/kubectl? something shadows it
```

No internet access to `dl.k8s.io`? The Supervisor serves a kubectl too, but it is usually several
minor versions behind the guest cluster (`v1.32.9` against `v1.36.2` on the lab this guide was
tested on), and it has no Apple Silicon build:

```sh
source ~/.vks-golang-web.env
case "$(uname -s)/$(uname -m)" in
  Darwin/*)     PLUGIN_OS=darwin-amd64 ;;  # runs under Rosetta 2 on Apple Silicon
  *)            PLUGIN_OS=linux-amd64  ;;
esac
T="$(mktemp -d)"
# -k: the Supervisor's certificate is signed by a CA you do not trust yet (step 8a fetches it).
curl -fsSk -o "$T/plugin.zip" "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/${PLUGIN_OS}/vsphere-plugin.zip"
unzip -oq "$T/plugin.zip" -d "$T"
sudo install -d /usr/local/bin             # absent on a fresh Apple Silicon Mac
sudo install "$T/bin/kubectl" /usr/local/bin/kubectl
rm -rf "$T"
/usr/local/bin/kubectl version --client
```

> If it prints `bad CPU type in executable` on a Mac, install Rosetta and re-run:
> `softwareupdate --install-rosetta --agree-to-license`

### Install the VCF CLI

The VCF CLI is **not** on Homebrew or apt. Both files below are **entitled** downloads — you
need a Broadcom account with a vSphere Foundation entitlement. This guide was tested with
**9.1.1.0** (`vcf version` prints `v9.1.1.0.25662425`); take the release your entitlement offers.

| file | where to click | direct link |
|---|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-9.1.1.0.25662425.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI** | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545612&viewGroup=true) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.1.0.25665404.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI Plugins** | [Plugin bundle](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545621&viewGroup=true) |

**Portal gotchas:**

- **The page looks EMPTY until you pick a release** — the file table reads "No data found". The
  direct links above skip this.
- **Tick "I agree to the Terms and Conditions"** or the download icons do nothing. The checkbox
  stays inert until you open both Terms links, and it has to be ticked on each page.
- **Take the row for your platform** — `Linux_AMD64`, or `Darwin_ARM64` / `Darwin_AMD64` on a Mac
  — not the platform-less multi-GB bundles beside it.

Install both, from the directory holding the downloads. Put the **exact** file names in the first
two lines — a wildcard breaks as soon as a second version sits beside them:

```sh
source ~/.vks-golang-web.env
CLI_TGZ="VCF-Consumption-CLI-Linux_AMD64-9.1.1.0.25662425.tar.gz"
PLUGINS_TGZ="VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.1.0.25665404.tar.gz"

T="$(mktemp -d)"
tar -xzf "$CLI_TGZ" -C "$T"
sudo install -d /usr/local/bin                  # absent on a fresh Apple Silicon Mac
sudo install "$T"/vcf-cli-* /usr/local/bin/vcf    # the binary is named vcf-cli-<os>_<arch>
mkdir "$T/plugins" && tar -xzf "$PLUGINS_TGZ" -C "$T/plugins"
vcf plugin install all --local-source "$T/plugins"
rm -rf "$T"
vcf version | head -1
```

`vcf plugin install all` copies the plugins into `~/.local/share/vcf-cli` and writes
`~/.config/vcf`; do not delete those, they hold your contexts.

> ⚠️ `vcf plugin list` can wait for minutes, printing `Refreshing plugin inventory cache for …` —
> it is trying to reach a plugin registry your machine cannot reach. That is a network timeout,
> not a failure. `Ctrl-C` it; the plugins installed above need no registry.

### Verify the installation

```sh
source ~/.vks-golang-web.env
for t in curl unzip openssl jq git make kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done

command -v podman >/dev/null 2>&1 && podman --version
command -v docker >/dev/null 2>&1 && docker --version
kubectl version --client
vcf version | head -1
```

```
## Sample output — both engines installed; yours will differ
  podman version 5.7.0
  Docker version 29.8.1, build 4a63305
  Client Version: v1.36.2
  Kustomize Version: v5.8.1
  version: v9.1.1.0.25662425
```

Nothing should print `MISSING`. An engine that prints nothing is not installed — if neither prints,
go back and install one.

---

## 3. Trust the Harbor CA

Harbor serves a certificate signed by a private CA, so your container engine must be given that
CA. Harbor publishes it, so no file transfer is needed:

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

```
## Sample output — confirm this with your Harbor administrator before going further
sha256 Fingerprint=A8:00:C3:62:1C:...:72:E2
```

### Install it where your engine looks

Run the **one** block for your engine.

**podman — Linux and macOS (no sudo):**

```sh
source ~/.vks-golang-web.env
mkdir -p "$HOME/.config/containers/certs.d/${HARBOR_FQDN}"
cp "$HARBOR_CA" "$HOME/.config/containers/certs.d/${HARBOR_FQDN}/ca.crt"
```

On macOS this one directory covers both halves: `podman login` checks the certificate on the Mac,
and `podman push` checks it inside the machine VM, and both read it from here — no VM restart.

> ⚠️ **macOS: do not put the Harbor CA in the Keychain instead.** Harbor's default certificate is
> valid for 10 years, and macOS rejects any server certificate under a private CA that is valid for
> more than 825 days — trusted CA or not — with `x509: "harbor" certificate is not standards
> compliant`. podman's own CA directory is not subject to that check. (Measured with podman 6.1.2
> on macOS 26.6.2.)

**Linux + docker (needs sudo; the path is root-owned):**

```sh
source ~/.vks-golang-web.env
sudo install -D -m0644 "$HARBOR_CA" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"
```

No daemon restart is needed — docker reads `certs.d` per request.

**macOS + docker (Colima)** — `dockerd` runs in the VM and reads `certs.d` there:

```sh
source ~/.vks-golang-web.env
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
colima restart
```

### Verify

This proves the CA file is right. Whether your **engine** trusts it is proven by the login in
step 6 — an `x509: certificate signed by unknown authority` there means the block above did not
take.

```sh
source ~/.vks-golang-web.env
curl -s --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health"
```

```
## Sample output
http=200
```

---

## 4. Check out `golang-web` and install its dependencies

```sh
source ~/.vks-golang-web.env
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
make deps
```

**Stay in this directory for the rest of the guide** — later steps read `k8s/golang-web.yaml` and
`version.txt` by relative path.

`make deps` installs [mise](https://mise.jdx.dev) if it is missing (to `~/.local/bin`, no root),
then the pinned toolchain from `.mise.toml`. The `make` targets find those tools on their own —
**no shell setup is needed**.

---

## 5. Build the image

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"

make image-build IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

```
## Sample output — check the project segment is yours, not the upstream default
  harbor.example.test/apps/golang-web:v0.0.3
```

> On an arm64 host the build targets `linux/amd64` automatically, because VKS nodes are amd64 and
> a native arm64 image pushes fine and then dies with `exec format error`.

---

## 6. Provide Harbor credentials

Keep the credential in the env file — `make REGISTRY_TOKEN=...` on the command line would put the
token where `ps` can read it.

### Option A — a robot account (recommended)

A robot is scoped to one project and one set of actions, so a leak cannot touch the rest of Harbor.
**If your administrator gave you one**, skip to "put it in the env file" below (for a *private*
project it also needs `artifact` read and list — steps 7 and 9 look up what you pushed).

**If you have the Harbor admin password**, create one — `duration` is in days, `-1` never expires:

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

```
## Sample output — the FIRST line is the username, the SECOND is the secret.
## The secret is shown ONCE and cannot be retrieved again. Copy it now.
robot$apps+golang-web-push
<32-character secret>
```

**Put it in the env file**, in **single quotes** — a robot name contains `$`, and inside double
quotes `robot$apps+golang-web-push` becomes `robot+golang-web-push`, which Harbor rejects:

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
export REGISTRY_TOKEN='<the 32-character secret>'
```

### Option B — the Harbor admin account

Simpler, but the credential is unscoped — anything that leaks it owns the whole registry. Put
these in the env file instead:

```sh
export REGISTRY_USERNAME='admin'
export REGISTRY_TOKEN='<Harbor admin password>'
```

### Log in

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

```
## Sample output (docker prints "Login Succeeded" and a warning that the credential is
## stored unencrypted in ~/.docker/config.json)
Login Succeeded!
```

---

## 7. Push the image

```sh
source ~/.vks-golang-web.env
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

### Verify it landed

```sh
source ~/.vks-golang-web.env
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))"'
rm -f "$CFG"
```

```
## Sample output — no output at all means nothing was pushed
sha256:8059928c0e0a  v0.0.3
```

---

## 8. Get a kubeconfig for the guest cluster

Two hops: authenticate to the **Supervisor**, then read the guest cluster's kubeconfig from the
Supervisor. Neither hop needs Pinniped. (`kubectl-vsphere` is deprecated as of vSphere 9.1.0 — do
not use it.)

### 8a. Supervisor kubeconfig

**First the CA** — `vcf context create` verifies against it. `SUPERVISOR_CA` is the **vCenter VMCA
root**, not Harbor's. vCenter serves it:

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$SUPERVISOR_CA")"
# mktemp -d, not a fixed path: unzip MERGES into an existing directory.
VCTMP="$(mktemp -d)"
curl -fsSk --max-time 60 -o "$VCTMP/certs.zip" "https://${VCENTER_FQDN}/certs/download.zip"
unzip -oqj "$VCTMP/certs.zip" -d "$VCTMP/certs"
cat "$VCTMP"/certs/*.0 > "$SUPERVISOR_CA"
rm -rf "$VCTMP"

[ -s "$SUPERVISOR_CA" ] || echo "FAILED: $SUPERVISOR_CA is empty — the fetch above did not work"
openssl x509 -in "$SUPERVISOR_CA" -noout -subject -fingerprint -sha256
```

```
## Sample output
  subject=CN = CA, DC = vsphere, DC = local, C = US, ST = California, O = vcsa.example.test, OU = VMware Engineering
  sha256 Fingerprint=7A:A5:12:54:4F:38:...
```

That fetch skipped TLS verification — you had no CA yet. If your administrator can give you the
expected fingerprint, compare it with the one printed above.

**Then create the context.** `vcf` reads the password from `VCF_CLI_VSPHERE_PASSWORD`, so there is
no prompt — if it prompts, the env file was not `source`d. **Three failed logins lock the SSO
account.**

```sh
source ~/.vks-golang-web.env
KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
  vcf context create supervisor --type k8s \
    --endpoint "https://${SUPERVISOR_ENDPOINT}" \
    --username "$SSO_USERNAME" \
    --ca-certificate "$SUPERVISOR_CA"

# vcf writes the context but does NOT make it current; without this every kubectl
# below falls back to localhost:8080.
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" config use-context supervisor
```

If it says `context "supervisor" already exists` — left over from an earlier run — clear it with the
vcf-contexts block in section 11, then run this again.

Check it worked:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

```
## Sample output
  NAME           STATUS   AGE
  my-namespace   Active   6d
```

### 8b. Guest cluster kubeconfig

The Supervisor stores each guest cluster's admin kubeconfig in a secret named
`<cluster>-kubeconfig` in the cluster's namespace:

```sh
source ~/.vks-golang-web.env
( umask 077        # that file is a cluster-admin credential
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "$GUEST_KUBECONFIG" )

kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

```
## Sample output
  NAME                                      STATUS   ROLES           AGE   VERSION
  my-guest-cluster-node-pool-1-abcde-xxxxx  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-node-pool-1-abcde-yyyyy  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-xxxxx-zzzzz              Ready    control-plane   6d    v1.36.2+vmware.2
  client v1.36.2  server v1.36.2+vmware.2
```

- `Error from server (Forbidden)` reading the secret — your SSO user lacks the **Edit** role on the
  namespace; ask your administrator.
- `kubectl get nodes` hangs or times out — the guest cluster's API address is not reachable from
  your machine; ask for a jump host or tunnel.
- client and server more than one minor apart — reinstall `kubectl` at the server's version
  (section 2).

**Every later command in this guide uses this `KUBECONFIG`.**

---

## 9. Deploy

Create the namespace:

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

**Private Harbor project only** — give the namespace a pull secret *before* deploying, so the pods
can pull. Skip this for a public project.

```sh
source ~/.vks-golang-web.env
# Not `--docker-password=...`: that puts the token in argv.
D="$(mktemp -d)"
( umask 077
  export AUTH="$(printf '%s:%s' "$REGISTRY_USERNAME" "$REGISTRY_TOKEN" | base64 | tr -d '\n')"
  jq -nc '{auths:{(env.HARBOR_FQDN):{username:env.REGISTRY_USERNAME,
                                     password:env.REGISTRY_TOKEN, auth:env.AUTH}}}' \
    > "$D/dockercfg.json" )
kubectl create secret generic harbor-creds \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$D/dockercfg.json"
rm -rf "$D"
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-creds"}]}'
```

Then deploy — **by digest, not by tag**. The manifest sets `imagePullPolicy: IfNotPresent`, so a
node that already holds `golang-web:<version>` from an earlier run starts that cached copy instead
of your push; a digest names exactly one build, so the node must fetch it. The committed manifest
is never edited — `sed` rewrites the image line on its way to `kubectl`:

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
DIGEST="$(curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts/$(cat version.txt)" \
  | jq -r '.digest // empty')"
rm -f "$CFG"
echo "${IMAGE} -> ${DIGEST:-NOT FOUND — read the curl error above: 404 = not pushed (step 7); 401 = wrong credentials or HARBOR_PROJECT; 403 = the robot lacks artifact read; certificate = HARBOR_CA (step 3)}"

[ -n "$DIGEST" ] && \
  sed "s|image: .*/golang-web:.*|image: ${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web@${DIGEST}|" \
    k8s/golang-web.yaml | kubectl apply -f - && \
  kubectl rollout status deploy/golang-web --timeout=150s
```

After a **rebuild**, re-run steps 7 and 9: the new push gets a new digest, so the node pulls it.

Confirm the running image is the digest printed above — list every pod, since one can be
terminating:

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

```
## Sample output
NAME                          PHASE     IMAGEID
golang-web-5bf684c548-p6m56   Running   harbor.example.test/apps/golang-web@sha256:213908c99f1c...
```

---

## 10. Reach the app

```sh
source ~/.vks-golang-web.env
kubectl wait svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -s "http://${APP_IP}:8080/myhello/"
```

```
## Sample output
service/golang-web-service condition met
http://10.0.0.20:8080/myhello/
Hello, World
request 0 GET /myhello/
Host: 10.0.0.20:8080
MY_NODE_NAME: my-guest-cluster-node-pool-1-abcde-xxxxx
MY_POD_NAME: golang-web-5bf684c548-p6m56
MY_POD_NAMESPACE: golang-web
MY_POD_IP: 172.20.2.6
MY_POD_SERVICE_ACCOUNT: default
```

**In a browser:** open the URL that `echo` printed. This only works if your machine can route to
the cluster's LoadBalancer range — on a laptop outside the lab network it usually cannot, in which
case use the port-forward below.

### If the LoadBalancer address is not reachable from your machine

`kubectl port-forward` tunnels through the API server, so it works wherever `kubectl` works. It
stays in the foreground, so run it in its own terminal (`source` the env file there first):

```sh
source ~/.vks-golang-web.env
kubectl port-forward svc/golang-web-service 8080:8080
```

```
## Sample output — it stays in the foreground until you Ctrl-C
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

Then browse to **<http://localhost:8080/myhello/>**, or from another terminal:

```sh
curl -s http://localhost:8080/myhello/
```

### Which paths respond

| path | |
|---|---|
| `/myhello/` | **200** — the app; the manifest sets `APP_CONTEXT=/myhello/` |
| `/myhello` | 307 redirect to `/myhello/` — a browser follows it, `curl` needs `-L` |
| `/healthz` | 200 |
| `/` | **404 by design** — do not read this as a broken deployment |

---

## 11. Clean up

Everything this guide created, in the order that works. Each step is independent — skip any you
want to keep.

**The deployment** (deleting the namespace removes everything in it):

```sh
source ~/.vks-golang-web.env
kubectl delete namespace golang-web --ignore-not-found=true
```

**The image in Harbor**, and the robot account if you made one. This needs the Harbor admin
password; without it, ask your administrator:

```sh
source ~/.vks-golang-web.env
harbor_cfg

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web" \
  -o /dev/null -w 'repository deleted: http=%{http_code}\n'

# A PROJECT robot is invisible to a bare /robots call; it needs the level and the project id.
PID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}" | jq -r .project_id)"
RID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" --get \
  --data-urlencode "q=Level=project,ProjectID=${PID}" --data-urlencode 'page_size=100' \
  "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[]|select(.name|test("golang-web-push"))|.id')"
[ -n "$RID" ] && curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/robots/${RID}" -o /dev/null -w 'robot deleted: http=%{http_code}\n'

rm -f "$CFG"
```

**The local image and the registry login:**

```sh
source ~/.vks-golang-web.env
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
done
```

**The vcf contexts** (they live in `~/.config/vcf/`, outside everything else here):

```sh
source ~/.vks-golang-web.env
# `vcf context create` also makes one context PER vSphere Namespace you can see, named
# `supervisor:<namespace>`. Deleting `supervisor` does NOT remove them.
# --skip-delete-kubeconfig-context: without it the delete FAILS once the kubeconfig file
# below has been removed, making this step order-dependent.
for c in $(vcf context list 2>/dev/null | awk '$1 ~ /^supervisor:/{print $1}'); do
  vcf context delete "$c" -y --skip-delete-kubeconfig-context
done
vcf context delete supervisor -y --skip-delete-kubeconfig-context
vcf context list          # confirm none remain
```

**The Harbor CA you installed for your engine** — run the **one** line for your platform and engine:

```sh
source ~/.vks-golang-web.env
rm -rf "$HOME/.config/containers/certs.d/${HARBOR_FQDN:?}"        # podman, Linux and macOS
# sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"              # Linux + docker
# colima ssh -- sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"   # macOS + docker (Colima)
```

**The files this guide wrote**, then the clone — `cd ..` out of `golang-web` and delete the
directory you cloned in step 4:

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
```

**Finally the variables themselves.** `rm` removes the file; `unset` clears the shell you are in:

```sh
rm -f ~/.vks-golang-web.env
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP
unset -f harbor_cfg 2>/dev/null || true
```

**Optional** — the tools this guide installed: `/usr/local/bin/kubectl`, `/usr/local/bin/vcf`,
`~/.config/vcf`, `~/.local/share/vcf-cli`, and mise (`~/.local/bin/mise`, `~/.local/share/mise`).

---

## Troubleshooting

**`x509: certificate signed by unknown authority` on login or push** — the CA is not where your
engine looks. Check that you ran the step 3 block for YOUR engine, and that the directory name is
exactly `$HARBOR_FQDN` (including `:port` if your registry address has one).

**`x509: "harbor" certificate is not standards compliant` on a Mac** — macOS itself rejected the
certificate: Harbor's default one is valid for 10 years, over macOS's 825-day limit. Use podman's
CA directory from step 3, not the Keychain.

**Image pushed to the wrong project** — `OWNER` did not hold what you expected. `echo "$IMAGE"` in
step 5 prints the full tag before you build; check the project segment there.

**The pod crash-loops, or serves an OLD build, right after deploy** — it was deployed by tag, and
the node started an image it had cached from an earlier run. Use the step 9 block, which deploys
by digest, then check that the `IMAGEID` from the `kubectl get pods` check below it matches the
digest that block printed.

**`exec format error` in the pod** — an arm64 image on amd64 nodes. The build targets amd64
automatically on an arm64 host, so this means `PLATFORM` was overridden or the image predates
that. Rebuild with `make image-build PLATFORM=linux/amd64` and push again.

**Pod rejected at admission** — the guest cluster enforces the `restricted` Pod Security Standard
cluster-wide. `k8s/golang-web.yaml` already complies (`runAsNonRoot`, `seccompProfile:
RuntimeDefault`, `readOnlyRootFilesystem`, `capabilities: drop: ["ALL"]`). A pod of your own needs
the same, or label the namespace to a lower level.

**`EXTERNAL-IP` stays `<pending>`** — the cluster has no LoadBalancer provider, or none is free.
The `kubectl wait` in step 10 times out; reach the app with
`kubectl port-forward svc/golang-web-service 8080:8080` instead.

**`unauthorized` on push** — the login expired or was never made. Re-run step 6; a robot's
`duration` is in days and it stops working silently when it lapses.
