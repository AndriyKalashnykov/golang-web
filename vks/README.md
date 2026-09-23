# Build `golang-web` locally, push it to Harbor, deploy it to a VKS guest cluster

Build the container image on your own machine (macOS or Linux), push it to your Harbor registry,
and deploy `k8s/golang-web.yaml` to a named VKS guest cluster. About 15 minutes.

**Before you start, get these from your platform administrator:**

- the Harbor DNS name, and a project you may push to
- a Harbor credential (a robot account is created in step 6 if you have the admin password)
- the Supervisor API endpoint, your vSphere Namespace, and the guest cluster name
- network access to all of the above — if they are not reachable from your machine, ask for a
  jump host or a tunnel before going further

**Shell:** everything works in both `bash` and `zsh` (macOS defaults to `zsh`, most Linux
distributions to `bash`). Run `echo $0` if you are unsure which you have.

---

## 1. Set the variables

Everything below derives from these. Put them in a file so a second terminal — and tomorrow's
session — is one `source` away, and the credentials stay out of your shell history:

```sh
mkdir -p ~/.config/vks-golang-web
umask 077
cat > ~/.vks-golang-web.env <<'EOF'
# --- ask your platform administrator for these ------------------------------
export HARBOR_FQDN="harbor.example.test"         # Harbor's DNS name
export HARBOR_PROJECT="apps"                     # the Harbor PROJECT the image lands in
export SUPERVISOR_ENDPOINT="10.0.0.10"           # Supervisor API endpoint (IP or FQDN)
export VCENTER_FQDN="vcsa.example.test"          # vCenter — serves the CA the Supervisor uses
export VKS_CLUSTER="my-guest-cluster"            # the guest cluster NAME
export VKS_NAMESPACE="my-namespace"              # the vSphere Namespace holding it
export SSO_USERNAME="administrator@vsphere.local"

# --- credentials -------------------------------------------------------------
export VCF_CLI_VSPHERE_PASSWORD="<your vCenter SSO password>"
export HARBOR_ADMIN_PASSWORD="<Harbor admin password>"   # only to CREATE a robot in step 6
# Step 6 replaces these two with the robot's name and secret. Keep the SINGLE quotes: a robot
# name contains `$` (robot$apps+...), and double quotes would silently expand it away.
export REGISTRY_USERNAME='admin'
export REGISTRY_TOKEN="$HARBOR_ADMIN_PASSWORD"   # step 6: the robot secret, in single quotes

# --- paths; no need to change these -----------------------------------------
export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

# Every kubectl from step 8b on talks to the GUEST cluster. Setting it here means each
# snippet below is self-contained; before 8b creates the file, nothing reads it.
export KUBECONFIG="$GUEST_KUBECONFIG"

# Writes a curl -K config holding the Harbor admin credential. It is a FUNCTION so that
# sourcing this file gives it to every shell -- step 6 and step 11 both need it.
# curl's -K file is parsed, so the password is escaped: backslash first, then quote.
harbor_cfg() {
  local e="$HARBOR_ADMIN_PASSWORD"
  e="${e//\\/\\\\}"; e="${e//\"/\\\"}"
  CFG="$(mktemp)"; ( umask 077; printf 'user = "admin:%s"\n' "$e" > "$CFG" )
}
EOF

source ~/.vks-golang-web.env
```

Edit the file with your values, then `source` it again. **Every new terminal needs that one
line** — nothing else in this guide re-exports anything.

```sh
source ~/.vks-golang-web.env
```

---

## 2. Install the tools

| tool | why |
|---|---|
| `podman` (or `docker`) | build and push the image |
| `kubectl` | talk to the guest cluster |
| `vcf` | the VCF CLI — authenticates to the Supervisor |
| `git`, `make` | check out and drive the repo |
| `mise` | pins the build toolchain — `make deps` installs it if absent |
| `jq` | reading Harbor and kubectl JSON (steps 7, 8, 9) |

### Pick a container engine

Either works. **podman** is the path this guide was proven on; **docker** is equally fine.

**macOS — podman**

```sh
brew install podman
podman machine init && podman machine start
```

**macOS — docker.** The CLI alone cannot build or push; it needs a Linux VM behind it.
`brew install docker` installs only the client. Run the engine in a VM with Colima:

```sh
brew install colima docker docker-buildx
colima start
docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}'
```

Colima runs Docker Engine in a Linux VM and gives you the plain `docker` CLI. `docker-buildx` is
required — the image build uses `docker buildx build`.

With a CLI but no VM running you get this, which is **not** a permissions problem and is **not**
fixed by `sudo`:

```
dial unix /var/run/docker.sock: connect: no such file or directory
```

**Linux (Debian/Ubuntu) — podman**

```sh
sudo apt-get update && sudo apt-get install -y podman
```

**Linux (Debian/Ubuntu) — Docker Engine**, from Docker's own repository. The distribution's
`docker.io` package also works and is one line, but it lags upstream and does not ship
`docker-buildx-plugin`, which the image build needs:

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

### The rest of the tools

**macOS**

```sh
brew install jq git make
```

**Linux (Debian/Ubuntu)**

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

### kubectl — get it from the Supervisor

The Supervisor serves the binary, at the `SUPERVISOR_ENDPOINT` you set above:

```sh
source ~/.vks-golang-web.env
case "$(uname -s)/$(uname -m)" in
  Darwin/*)     PLUGIN_OS=darwin-amd64 ;;  # no arm64 build exists; runs under Rosetta 2
  Linux/x86_64) PLUGIN_OS=linux-amd64  ;;
  *) PLUGIN_OS=""; echo "no Supervisor build for $(uname -s)/$(uname -m) — use the upstream kubectl below" ;;
esac

if [ -n "$PLUGIN_OS" ]; then
  # -k: the Supervisor's certificate is signed by a CA you do not trust yet (step 8a fetches it).
  curl -fsSkO "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/${PLUGIN_OS}/vsphere-plugin.zip"
  unzip -o vsphere-plugin.zip
  sudo install ./bin/kubectl /usr/local/bin/kubectl   # bin/ also holds the deprecated kubectl-vsphere
  rm -rf ./bin ./vsphere-plugin.zip

  # Check the binary you just installed, by its full path -- `kubectl version` alone would
  # report whatever is first on PATH, so a failed sudo still prints a version and looks fine.
  /usr/local/bin/kubectl version --client
  echo "PATH kubectl: $(command -v kubectl)"   # not /usr/local/bin/kubectl? something shadows it
fi
```

> ⚠️ **Apple Silicon:** the Supervisor publishes no `darwin-arm64` build, so the binary above is
> x86_64 and runs under Rosetta 2. If it prints `bad CPU type in executable`, install Rosetta and
> re-run: `softwareupdate --install-rosetta --agree-to-license`

If the Supervisor's build is more than one minor away from your **guest cluster** — that is where
every command from section 9 runs — take a matching build from upstream instead:

```sh
export KUBECTL_VERSION="v1.36.2"           # match the guest cluster
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  KOS=darwin/arm64 ;;
  Darwin/*)      KOS=darwin/amd64 ;;
  Linux/aarch64) KOS=linux/arm64  ;;
  *)             KOS=linux/amd64  ;;
esac
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${KOS}/kubectl"
# No -o/-g: sudo already makes it root-owned, and macOS has NO group named "root"
# (measured), so `install -g root` fails there. Do not add them back.
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
```

### Which engine will be used?

**podman if it is installed, otherwise docker.** To force the other one:

```sh
export CONTAINER_ENGINE=docker          # for this shell
```

or for a single command:

```sh
source ~/.vks-golang-web.env
make image-build CONTAINER_ENGINE=docker
```

After you check out the repo (section 4), `make engines` prints the selection it made.

### Install the VCF CLI

The VCF CLI is **not** on Homebrew or apt. Both files below are **entitled** downloads — you
need a Broadcom account with a vSphere Foundation entitlement.

Written against **VCF CLI 9.1.1.0**, where `vcf version` prints `v9.1.1.0.25662425`. Versions
move: the commands here do not change, but the build number in each filename does, so match
the release your entitlement offers rather than copying the numbers below.

| file | where to click | direct link |
|---|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-9.1.1.0.25662425.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI** | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545612&viewGroup=true) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.1.0.25665404.tar.gz` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → VMware vSphere Foundation → VMware vSphere Foundation 9 → 9.1.1.0 → **VCF Consumption CLI Plugins** | [Plugin bundle](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545621&viewGroup=true) |

The click path is the same shape for every release.

**Portal gotchas — every one of these fails silently:**

- **Clicking the path leaves the page looking EMPTY.** The *Release* list starts blank, and
  while it is blank the file table reads **"No data found"** — which looks exactly like the
  artifact not existing. Pick your release first. The two direct links above skip this.
- **Tick "I agree to the Terms and Conditions"** or the download icons do nothing. The
  checkbox stays **inert until you open both Terms links first**, and the gate is **per page**
   — ticking it on one page does not carry to the next.
- **Patch builds appear only once you open a group.** The parent page lists only the base
  release (`9.1.0.0`); a patch such as `9.1.1.0` shows up after you open the group.
- **A `release=` in the URL is ignored** — use the on-page selector.
- **Take the row carrying your platform** — `Linux_AMD64`, `Darwin_ARM64`, uppercase. The
  platform-less `-Binaries-` (294 MB), `-PluginBundle-` (1.27 GB) and `-OCI-PluginBundle-`
  (1.48 GB) rows sit beside them and are multi-platform supersets.

Install the binary, then the plugins:

```sh
source ~/.vks-golang-web.env
tar -xzf VCF-Consumption-CLI-Linux_AMD64-*.tar.gz
sudo install ./vcf /usr/local/bin/vcf

mkdir -p /tmp/vcf-plugins
tar -xzf VCF-Consumption-CLI-PluginBundle-Linux_AMD64-*.tar.gz -C /tmp/vcf-plugins
vcf plugin install all --local-source /tmp/vcf-plugins
vcf plugin list
```

> A multi-arch bundle nests its plugins under `<os>/<arch>/`. If `plugin install all` finds
> nothing, point `--local-source` at `/tmp/vcf-plugins/linux/amd64` instead.

`vcf plugin install all` is idempotent — re-running upgrades in place. It writes to
`~/.config/vcf` and `~/.local/share/vcf-cli`; do not delete those, they hold your contexts.

> **macOS:** take the `Darwin_ARM64` rows (Apple Silicon) or `Darwin_AMD64` (Intel) — both the
> CLI and the plugin bundle publish them, on the same two pages.
>
> ⚠️ `vcf plugin list` can hang for minutes. MEASURED on macOS 26.6.2: it prints
> `Refreshing plugin inventory cache for "<registry>/vcf/vcf-cli-plugins/..."` and then waits on
> a registry it cannot reach. It is a network timeout against the plugin source — not a crash,
> and not "no plugins installed". `Ctrl-C`, then install from the local bundle above, which
> needs no registry at all.

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
## Sample output — a real transcript with both engines installed; yours will differ
  podman version 4.9.3
  Docker version 29.8.1, build 4a63305
  Client Version: v1.32.9+vmware.2-fips
  Kustomize Version: v5.5.0
  version: v9.1.1.0.25662425
```

Nothing should print `MISSING`. `curl`, `unzip` and `openssl` ship with macOS and are installed
above on Linux; if one is named here, install it before going on. An engine that prints nothing
is not on your `PATH` — if neither prints, go back and install one.

---

## 3. Trust the Harbor CA

Harbor serves a certificate signed by a private CA, so your container engine must be given that
CA. Harbor publishes it, so no file transfer is needed.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
curl -sk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

```
## Sample output — confirm this with your Harbor administrator before going further
sha256 Fingerprint=A8:00:C3:62:1C:...:72:E2
```

### Install it where your engine looks

`make registry-login` and `make image-push` call `podman login` / `docker login` with **no**
`--cert-dir`, so the CA must sit where your engine already trusts it, or both fail with
`x509: certificate signed by unknown authority`.

**The right place differs per platform**, because on macOS both engines run a Linux VM and the TLS
check happens *inside* it — a certificate on the Mac filesystem is not enough on its own.

**Linux + podman (no sudo):**

```sh
source ~/.vks-golang-web.env
install -D -m0644 "$HARBOR_CA" "$HOME/.config/containers/certs.d/${HARBOR_FQDN}/ca.crt"
```

**Linux + docker (needs sudo; the path is root-owned):**

```sh
source ~/.vks-golang-web.env
sudo install -D -m0644 "$HARBOR_CA" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"
```

No daemon restart is needed — docker reads `certs.d` per request.

**macOS + podman** — import the Mac's trust store into the machine VM, then restart it:

```sh
source ~/.vks-golang-web.env
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$HARBOR_CA"
podman machine set --import-native-ca
podman machine stop && podman machine start
```

**macOS + docker (Colima)** — the daemon does not run on your Mac, it runs in the VM, and
`dockerd` reads `certs.d` **on the machine it runs on**. So the CA goes inside the VM:

```sh
source ~/.vks-golang-web.env
# UNTESTED — verify before relying on it.
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
colima restart
```

> ⚠️ **On macOS, restart the engine afterwards** — the VM does not re-read trust material while
> running, so the login keeps failing until you do. Linux needs no restart.

### Verify

```sh
source ~/.vks-golang-web.env
curl -s --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health"
```

```
## Sample output
http=200
```

> This leaves a CA on your machine that survives everything else in this guide. To remove it
> later, delete the `certs.d/${HARBOR_FQDN}/` directory you just created.

## 4. Check out `golang-web` and install its dependencies

```sh
source ~/.vks-golang-web.env
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
make deps
```

**Stay in this directory for the rest of the guide.** Steps 5, 7, 9 and 11 run `make` targets and
read `k8s/golang-web.yaml` and `version.txt` by relative path; none of them will work from
anywhere else.

`make deps` installs the pinned toolchain from `.mise.toml` — the same versions on macOS and Linux.

It needs [mise](https://mise.jdx.dev), and installs it for you if it is missing (to `~/.local/bin`,
no root). **On a machine without mise it then stops and asks you to activate it and re-run** — it
exits 0, so read the output rather than assuming it finished:

```sh
source ~/.vks-golang-web.env
echo 'eval "$(mise activate bash)"' >> ~/.bashrc   # or the zsh equivalent
exec $SHELL -l
make deps                                          # re-run it
```

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

> `OWNER` may be passed on the `make` command line or exported — both work.
>
> On an arm64 host the build targets `linux/amd64` automatically, because VKS nodes are amd64
> and a native arm64 image pushes fine and then dies with `exec format error`. Override with
> `PLATFORM=linux/arm64`, or `PLATFORM=` to build natively.

---

## 6. Provide Harbor credentials

`export` these two — `make REGISTRY_TOKEN=...` would put the token where `ps` can read it.

### Option A — a robot account (recommended)

A robot is scoped to one project and one set of actions, so a leak cannot touch the rest of Harbor.

**If your administrator gave you one**, skip to the login below. **If you have the Harbor admin
password**, create one now — `duration` is in days, `-1` never expires:

```sh
source ~/.vks-golang-web.env
harbor_cfg

jq -nc --arg p "$HARBOR_PROJECT" '{name:"golang-web-push", duration:90, level:"project",
  permissions:[{kind:"project", namespace:$p,
    access:[{resource:"repository",action:"push"},{resource:"repository",action:"pull"}]}]}' \
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

Put the two printed lines into `~/.vks-golang-web.env` — `REGISTRY_USERNAME` and `REGISTRY_TOKEN`
— **in single quotes**. A robot name contains `$`: written as `"robot$apps+golang-web-push"`,
the shell expands `$apps` to nothing and you log in as `robot+golang-web-push`, which Harbor
rejects.

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
export REGISTRY_TOKEN='<the 32-character secret>'
```

Then log in with it:

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

```
## Sample output
Login Succeeded!
```

### Option B — the Harbor admin account

Simpler, but the credential is unscoped — anything that leaks it owns the whole registry.

```sh
source ~/.vks-golang-web.env
export REGISTRY_USERNAME="admin"
export REGISTRY_TOKEN="$HARBOR_ADMIN_PASSWORD"
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

### Listing or deleting robots later

```sh
source ~/.vks-golang-web.env
harbor_cfg      # defined by the env file you just sourced

# A PROJECT robot is invisible to a bare /robots call — that lists SYSTEM robots only.
# It needs both the level and the project id.
PID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}" | jq -r .project_id)"
curl -s --cacert "$HARBOR_CA" -K "$CFG" --get \
  --data-urlencode "q=Level=project,ProjectID=${PID}" --data-urlencode 'page_size=100' \
  "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[] | "\(.id)  \(.name)"'

# To delete one, put its id from the list above in RID and uncomment:
# RID=11
# curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE "https://${HARBOR_FQDN}/api/v2.0/robots/${RID}"

rm -f "$CFG"
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
curl -s --cacert "$HARBOR_CA" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))"'
```

```
## Sample output
sha256:8059928c0e0a  v0.0.3
```

---

## 8. Get a kubeconfig for the guest cluster

Two hops: authenticate to the **Supervisor**, then read the guest cluster's kubeconfig
from the Supervisor. Neither hop needs Pinniped.

> `kubectl-vsphere` is deprecated as of vSphere 9.1.0. Do not use it.

### 8a. Supervisor kubeconfig

**First the CA** — `vcf context create` verifies against it, so it has to exist before you run it.
`SUPERVISOR_CA` is the **vCenter VMCA root**, not Harbor's. vCenter serves it:

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

**Then create the context.** `vcf context create` writes to the path in `KUBECONFIG`:

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
umask 077        # that file is a cluster-admin credential
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
  get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
  | base64 -d > "$GUEST_KUBECONFIG"

kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

```
## Sample output
  NAME                                      STATUS   ROLES           AGE   VERSION
  my-guest-cluster-node-pool-1-abcde-xxxxx  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-node-pool-1-abcde-yyyyy  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-xxxxx-zzzzz              Ready    control-plane   6d    v1.36.2+vmware.2
  client v1.37.0  server v1.36.2+vmware.2
```

If client and server are more than one minor apart, reinstall `kubectl` pinned to the server's
minor (section 2).

**Every later command in this guide uses this `KUBECONFIG`.**

> `vcf cluster kubeconfig get "$VKS_CLUSTER" -n "$VKS_NAMESPACE"` does the same job and adds the
> context to your existing kubeconfig, but it requires Pinniped on the Supervisor. If it exits 1
> with `failed to get pinniped-info from management cluster`, use the block above.

## 9. Deploy

The committed manifest points at the upstream image, so rewrite that one line to the image you
just pushed — **by digest, not by tag**. The file itself is never edited — `sed` writes to the
pipe, not to disk.

**Why the digest:** the manifest sets `imagePullPolicy: IfNotPresent`, so a node that already
holds `golang-web:<version>` from an earlier run **never pulls your push** — it starts whatever
it cached. Deleting the image from Harbor (section 11) does not clear the nodes. Measured on a
cluster that had run this guide before: the tag deployed a cached, different `v0.0.3` that
crash-looped with no logs. A digest names exactly one build, so the node must fetch it.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
# The digest Harbor holds for the tag you pushed in step 7.
DIGEST="$(curl -s --cacert "$HARBOR_CA" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts/$(cat version.txt)" \
  | jq -r '.digest // empty')"
echo "${IMAGE} -> ${DIGEST:-NOT FOUND — re-run step 7 before going on}"

kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web

[ -n "$DIGEST" ] && \
  sed "s|image: .*/golang-web:.*|image: ${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web@${DIGEST}|" \
    k8s/golang-web.yaml | kubectl apply -f - && \
  kubectl rollout status deploy/golang-web --timeout=150s
```

After a **rebuild**, re-run step 7 and this block: the new push gets a new digest, so the node
pulls it — no need to bump `version.txt`.

Confirm which image is actually running — `.items[0]` can be a terminating pod, so list them all:

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

The `IMAGEID` digest must match the one the block above printed.

> **No `imagePullSecret` is needed** for a *public* Harbor project. For a **private** one:
> ```sh
> source ~/.vks-golang-web.env
> # Not `--docker-password=...`: that puts the token in argv.
> umask 077
> export AUTH="$(printf '%s:%s' "$REGISTRY_USERNAME" "$REGISTRY_TOKEN" | base64 | tr -d '\n')"
> jq -nc '{auths:{(env.HARBOR_FQDN):{username:env.REGISTRY_USERNAME,
>                                    password:env.REGISTRY_TOKEN, auth:env.AUTH}}}' \
>   > /tmp/dockercfg.json
> unset AUTH
>
> kubectl create secret generic harbor-creds \
>   --type=kubernetes.io/dockerconfigjson \
>   --from-file=.dockerconfigjson=/tmp/dockercfg.json
> rm -f /tmp/dockercfg.json
>
> kubectl patch serviceaccount default \
>   -p '{"imagePullSecrets":[{"name":"harbor-creds"}]}'
> ```
>


---

## 10. Reach the app

```sh
source ~/.vks-golang-web.env
kubectl get pod,svc
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -s "http://${APP_IP}:8080/myhello/"
```

```
## Sample output
NAME                              READY   STATUS    RESTARTS   AGE
pod/golang-web-7f4b97d4dd-8bwtm   1/1     Running   0          20s

NAME                         TYPE           CLUSTER-IP      EXTERNAL-IP       PORT(S)          AGE
service/golang-web-service   LoadBalancer   172.21.64.186   192.168.101.138   8080:30463/TCP   20s

http://192.168.101.138:8080/myhello/
Hello, World
request 0 GET /myhello/
Host: 192.168.101.138:8080
MY_NODE_NAME: lab-gc1-np1-mjdnz-z8zw4-gmk9v
MY_POD_NAME: golang-web-7f4b97d4dd-8bwtm
MY_POD_NAMESPACE: golang-web
MY_POD_IP: 172.20.2.8
MY_POD_SERVICE_ACCOUNT: default
```

**In a browser:** open the URL that `echo` printed. This only works if your machine can route to
the cluster's LoadBalancer range — on a laptop outside the lab network it usually cannot, in which
case use the port-forward below.

### If the LoadBalancer address is not reachable from your machine

`kubectl port-forward` tunnels through the API server, so it works wherever `kubectl` works —
no routing to the LB range needed. It stays in the foreground, so run it in its own terminal.

**A new terminal has none of your exports** — `source` the env file there first. Then:

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

To forward a specific pod instead of the Service:

```sh
source ~/.vks-golang-web.env
kubectl port-forward "$(kubectl get pod -l app=golang-web -o name | head -1)" 8080:8080
```

### Which paths respond

Measured on a running deployment:

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

**The deployment:**

```sh
source ~/.vks-golang-web.env
kubectl delete -f k8s/golang-web.yaml --ignore-not-found=true
kubectl delete namespace golang-web --ignore-not-found=true
```

**The image in Harbor**, and the robot account if you made one:

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

**The local images and the registry login:**

```sh
source ~/.vks-golang-web.env
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" rmi -f "ghcr.io/andriykalashnykov/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
done
```

**The vcf context** (it lives in `~/.config/vcf/`, outside everything else here):

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

**The Harbor CA you installed for your engine** — this one survives everything else:

```sh
source ~/.vks-golang-web.env
rm -rf "$HOME/.config/containers/certs.d/${HARBOR_FQDN}"        # Linux + podman
sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN}"                # Linux + docker
# macOS + podman: sudo security delete-certificate -c "Harbor CA" /Library/Keychains/System.keychain
```

**The files this guide wrote:**

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
rm -rf ~/golang-web                    # wherever you cloned it
```

**Finally the variables themselves.** `rm` removes the file; `unset` clears the shell you are in
(a new terminal never had them):

```sh
rm -f ~/.vks-golang-web.env
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP
```

If you kept the credentials in your shell history, clear that too — `history -c` for the current
shell, and edit `~/.bash_history` or `~/.zsh_history` for earlier ones.

---

## Troubleshooting

**`x509: certificate signed by unknown authority` on push** — the CA is missing or wrong. Re-run
the step-3 verify, and check you used the block for YOUR platform — the paths differ between
Linux and macOS, and on macOS the engine must be restarted afterwards. `--cert-dir` is a
podman/skopeo flag; docker ignores it.

**Image pushed to the wrong project** — `OWNER` did not hold what you expected. `echo "$IMAGE"`
in step 5 prints the full tag before you build; check the project segment there.

**The pod crash-loops, or serves an OLD build, right after deploy** — it was deployed by tag, and
the node started an image it had cached from an earlier run. Use the section 9 block, which
deploys by digest, and check that the `IMAGEID` it prints matches.

**`exec format error` in the pod** — an arm64 image on amd64 nodes. The build targets amd64
automatically on an arm64 host, so this means `PLATFORM` was overridden or the image predates
that. Rebuild with `make image-build PLATFORM=linux/amd64` and push again.

**Pod rejected at admission** — the guest cluster enforces the `restricted` Pod Security Standard
cluster-wide. `k8s/golang-web.yaml` already complies (`runAsNonRoot`, `seccompProfile:
RuntimeDefault`, `readOnlyRootFilesystem`, `capabilities: drop: ["ALL"]`). A pod of your own needs
the same, or label the namespace to a lower level.

**`EXTERNAL-IP` stays `<pending>`** — the cluster has no LoadBalancer provider, or none is free.
Reach the app with `kubectl port-forward svc/golang-web-service 8080:8080` instead.

**`unauthorized` on push** — the login expired or was never made. Re-run step 6; a robot's
`duration` is in days and it stops working silently when it lapses.
