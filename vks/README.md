# Build `golang-web`, push it to Harbor, deploy it to a VKS guest cluster

From your platform administrator:

- the Harbor DNS name, a project you may push to, and a robot account or the Harbor admin password
- the Supervisor endpoint, the vCenter DNS name, the vSphere Namespace and the guest cluster name
- a guest cluster that already trusts Harbor's CA
- an SSO user with the **Edit** role on that namespace, and its password
- network access from this machine to all of the above, and internet access to your package
  repositories, github.com, docker.io, gcr.io and dl.k8s.io

Works in `bash` and `zsh`, on Linux and macOS.

## 1. Set the variables

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

Open the env file and fill in your values; credentials go in **single quotes** (a `'` inside one is
written `'\''`). If the block above said the file already exists, it keeps your earlier values:

```sh
"${EDITOR:-vi}" ~/.vks-golang-web.env
```

Load it — in every new terminal:

```sh
source ~/.vks-golang-web.env
```

## 2. Install the tools

### macOS: Homebrew

The Homebrew installer also installs the Xcode Command Line Tools.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
B=/opt/homebrew/bin/brew; [ -x "$B" ] || B=/usr/local/bin/brew
grep -qs "brew shellenv" ~/.zprofile || echo "eval \"\$($B shellenv)\"" >> ~/.zprofile
eval "$($B shellenv)"
brew --version
```

### Container engine — pick one

macOS, podman:

```sh
brew install podman
podman machine inspect >/dev/null 2>&1 || podman machine init
podman info >/dev/null 2>&1 || podman machine start
```

macOS, docker (Colima):

```sh
brew install colima docker docker-buildx
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
colima start
docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}'
docker buildx version
```

Linux (Debian/Ubuntu), podman:

```sh
sudo apt-get update && sudo apt-get install -y podman
```

Linux (Debian/Ubuntu), docker — on Debian replace both `ubuntu` with `debian`:

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

With both engines installed, podman is used. For docker, add it to the env file:

```sh
grep -qs CONTAINER_ENGINE ~/.vks-golang-web.env || echo 'export CONTAINER_ENGINE=docker' >> ~/.vks-golang-web.env
```

### Other tools

macOS (macOS 26 already ships `/usr/bin/jq`; this is then a no-op):

```sh
brew install jq
```

Linux (Debian/Ubuntu):

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

### vCenter CA

`vcf` and `curl` verify the Supervisor with vCenter's CA:

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

**Expect:** a `subject=` line naming `CA` and `vsphere`, and a fingerprint equal to your
administrator's — if not, stop.

### kubectl

Upstream kubectl for this machine, from dl.k8s.io. This is the current stable release; step 7
installs the versions matching your Supervisor and then your guest cluster:

```sh
source ~/.vks-golang-web.env
V="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
if [ -n "$V" ]; then kubectl_install "$V"; else echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?)"; fi
```

**Expect:** `Client Version: v1.…` and no `WARNING` line.

Upstream kubectl is not a FIPS build; if your policy requires one, use your vendor's kubectl.

### VCF CLI

Download the file for your platform (`Linux_AMD64`, `Linux_ARM64`, `Darwin_ARM64` or
`Darwin_AMD64`) from Broadcom. Tick **"I agree to the Terms and Conditions"** (it stays inert until
you open both Terms links), or the download icon does nothing.

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

The block picks this machine's file from `~/Downloads`; if you saved it elsewhere, change that folder.

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

### Check

```sh
for t in curl unzip openssl jq git make kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done

command -v podman >/dev/null 2>&1 && podman --version
command -v docker >/dev/null 2>&1 && docker --version
kubectl version --client
vcf version | head -1
```

**Expect:** no `MISSING` line, and a version for your engine, `kubectl` and `vcf`.

## 3. Trust the Harbor CA

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

**Expect:** a SHA-256 fingerprint equal to your administrator's — if not, stop.

Install it for your engine — podman, Linux and macOS:

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

macOS, docker (Colima):

```sh
source ~/.vks-golang-web.env
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
```

Check:

```sh
source ~/.vks-golang-web.env
curl -s --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health"
```

**Expect:** `http=200`.

## 4. Check out the repo

```sh
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
```

Run everything below from this directory.

## 5. Harbor credentials

Create a robot (needs `HARBOR_ADMIN_PASSWORD`; skip if you were given one). `harbor_cfg` comes from
the env file (step 1):

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

**Expect:** two lines — the robot name and its secret. The secret is shown once.

In `~/.vks-golang-web.env`, replace the two `REGISTRY_*` lines with the name and secret printed
above (single quotes):

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
export REGISTRY_TOKEN='<the 32-character secret>'
```

Or use the admin account instead:

```sh
export REGISTRY_USERNAME='admin'
export REGISTRY_TOKEN='<Harbor admin password>'
```

Log in:

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** `Login Succeeded` (podman adds `!`; docker adds a warning about unencrypted credentials).

## 6. Build and push the image

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** the image name, then a build for `linux/amd64,linux/arm64` and a push. The image is
built for both, whatever machine you are on; `PUSH_PLATFORMS=linux/amd64` limits it to one.

Check:

```sh
source ~/.vks-golang-web.env
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))  \([.references[]?.platform.architecture]|join(","))"'
rm -f "$CFG"
```

**Expect:** a digest, your version tag, and `amd64,arm64` (in either order).

## 7. Get the kubeconfigs

Log in to the Supervisor. **Five failed logins within 3 minutes lock the SSO account for
5 minutes** (vCenter's default policy; yours may be stricter).

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

If it says `context "supervisor" already exists`, run the vcf-contexts block in step 10, then
this one again.

This guide logs in with the SSO user and a password. A Supervisor that uses only an external
OIDC identity provider is out of scope: the password login fails there.

kubectl at the Supervisor's version:

```sh
source ~/.vks-golang-web.env
V="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Supervisor: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Supervisor: v1.<minor>…`, then `Client Version:` with the same `v1.<minor>`.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** your namespace, `Active`.

Guest cluster, then kubectl at its version:

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

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

**Expect:** every node `Ready`, and client and server on the same `v1.<minor>` (e.g. `v1.36.2` and `v1.36.2+vmware.2`).
From here on, kubectl matches the guest cluster; the Supervisor is used only through `vcf`.

## 8. Deploy

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

Registry pull secret:

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

Deploy the pushed digest:

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

**Expect:** `… -> sha256:…`, then `successfully rolled out`.

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

**Expect:** `IMAGEID` ends with the digest printed above.

## 9. Reach the app

```sh
source ~/.vks-golang-web.env
kubectl wait svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -sS --max-time 10 "http://${APP_IP}:8080/myhello/"
```

**Expect:** `Hello, World` and the pod's details.

The LoadBalancer address is not reachable from your machine? In a second terminal:

```sh
source ~/.vks-golang-web.env
kubectl port-forward svc/golang-web-service 8080:8080
```

Then:

```sh
curl -s http://localhost:8080/myhello/
```

`/myhello/` and `/healthz` return 200; `/` returns 404 by design.

## 10. Clean up

The deployment:

```sh
source ~/.vks-golang-web.env
kubectl delete namespace golang-web --ignore-not-found=true
```

The image and the robot in Harbor (needs `HARBOR_ADMIN_PASSWORD`):

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

The vcf contexts:

```sh
for c in $(vcf context list 2>/dev/null | awk '$1 ~ /^supervisor:/{print $1}'); do
  vcf context delete "$c" -y --skip-delete-kubeconfig-context
done
vcf context delete supervisor -y --skip-delete-kubeconfig-context
vcf context list
rm -rf ~/.config/vcf/logs
```

The Harbor CA — podman, Linux and macOS:

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

The files this guide wrote, and the clone (installed tools, base images, build cache and
kubectl's `~/.kube/cache` stay):

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
rmdir "$HOME/.config/containers/certs.d" "$HOME/.config/containers" "$HOME/.kube" 2>/dev/null
cd .. && rm -rf golang-web
```

The variables:

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
| `x509: certificate signed by unknown authority` on login or push | Run the step 3 block for **your** engine; the directory must be exactly `$HARBOR_FQDN`. |
| `x509: "harbor" certificate is not standards compliant` (macOS) | Use step 3's podman or Colima block, not the macOS Keychain. |
| `docker: unknown command: docker buildx` (macOS) | Re-run the `ln -sfn … docker-buildx` line in step 2. |
| `dial unix /var/run/docker.sock` (macOS) | `colima start` |
| `bad CPU type in executable` (macOS) | An amd64-only program (such as the Supervisor's kubectl below) needs Rosetta: `softwareupdate --install-rosetta --agree-to-license` |
| `kubectl_install: command not found` | Re-run step 1's block; it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| `kubectl_install: no version` in step 7 | The Supervisor or cluster did not answer: re-run step 7's login. |
| `kubectl_install: cannot reach dl.k8s.io` | Allow dl.k8s.io, or use the Supervisor's kubectl: amd64 only (no Linux arm64; on Apple silicon it needs Rosetta, see `bad CPU type` above) and the Supervisor's older version. In a new directory: `curl -fsS --cacert "$SUPERVISOR_CA" -O "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/linux-amd64/vsphere-plugin.zip" && unzip -oq vsphere-plugin.zip bin/kubectl && sudo install -m 0755 bin/kubectl /usr/local/bin/kubectl` (macOS: `darwin-amd64`). |
| `ImagePullBackOff` with `x509` in `kubectl describe pod` | The guest cluster does not trust Harbor's CA — ask your administrator. |
| `403` on the step 6 or 8 lookup | The robot needs `artifact` read and list; create it with step 5. |
| `unauthorized` on push | Re-run step 5's login; a robot stops working when its `duration` (days) ends. |
| Pod crash-loops or serves an old build | Deploy by digest (step 8), then check `IMAGEID`. |
| `exec format error` in the pod | The image lacks the node's architecture: push again without `PUSH_PLATFORMS`, or include the node's (`linux/amd64`). |
| Pod rejected at admission | The cluster enforces `restricted`; `k8s/golang-web.yaml` complies — keep your changes compliant. |
| `EXTERNAL-IP` stays `<pending>` | Use the port-forward in step 9. |
