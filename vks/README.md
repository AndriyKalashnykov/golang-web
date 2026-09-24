# Build `golang-web`, push it to Harbor, deploy it to a VKS guest cluster

From your platform administrator:

- the Harbor DNS name, a project you may push to, and a robot account or the Harbor admin password
- the Supervisor endpoint, the vCenter DNS name, the vSphere Namespace, the guest cluster name and
  its Kubernetes version
- an SSO user with the **Edit** role on that namespace, and its password
- network access from this machine to all of the above

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
export HARBOR_ADMIN_PASSWORD=''                  # only to create a robot in step 6
export REGISTRY_USERNAME=''                      # step 6 fills these two
export REGISTRY_TOKEN=''

export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

export KUBECONFIG="$GUEST_KUBECONFIG"

# harbor_cfg [USER PASSWORD]: writes a curl config with a Harbor login to $CFG (default: admin),
# used as `curl -K "$CFG"` in steps 6, 7, 9 and 11 so no password is on the command line.
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

Fill in `~/.vks-golang-web.env`; credentials go in **single quotes**. If the block says the file
already exists, edit that file instead. Then load it — in every new terminal:

```sh
source ~/.vks-golang-web.env
```

## 2. Install the tools

### macOS: Homebrew

```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
B=/opt/homebrew/bin/brew; [ -x "$B" ] || B=/usr/local/bin/brew
echo "eval \"\$($B shellenv)\"" >> ~/.zprofile
eval "$($B shellenv)"
brew --version
```

### Container engine — pick one

macOS, podman:

```sh
brew install podman
podman machine init && podman machine start
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

With both engines installed, podman is used. For docker, add `export CONTAINER_ENGINE=docker` to
`~/.vks-golang-web.env`.

### Other tools

macOS:

```sh
brew install jq
```

Linux (Debian/Ubuntu):

```sh
sudo apt-get install -y jq git make unzip curl openssl
```

### kubectl

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
sudo install -d /usr/local/bin
sudo install -m 0755 "$T/kubectl" /usr/local/bin/kubectl
rm -rf "$T"

/usr/local/bin/kubectl version --client
echo "PATH kubectl: $(command -v kubectl)"
```

**Expect:** your version, then `PATH kubectl: /usr/local/bin/kubectl`.

No access to `dl.k8s.io`: use the Supervisor's kubectl instead (older, amd64 only):

```sh
source ~/.vks-golang-web.env
case "$(uname -s)/$(uname -m)" in
  Darwin/*)     PLUGIN_OS=darwin-amd64 ;;
  *)            PLUGIN_OS=linux-amd64  ;;
esac
T="$(mktemp -d)"
curl -fsSk -o "$T/plugin.zip" "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/${PLUGIN_OS}/vsphere-plugin.zip"
unzip -oq "$T/plugin.zip" -d "$T"
sudo install -d /usr/local/bin
sudo install "$T/bin/kubectl" /usr/local/bin/kubectl
rm -rf "$T"
/usr/local/bin/kubectl version --client
```

### VCF CLI

Download both files for your platform (`Linux_AMD64`, `Darwin_ARM64` or `Darwin_AMD64`) from
Broadcom. Tick **"I agree to the Terms and Conditions"** on each page, or the download icons do
nothing.

| file | link |
|---|---|
| `VCF-Consumption-CLI-<platform>-9.1.1.0.25662425.tar.gz` | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545612&viewGroup=true) |
| `VCF-Consumption-CLI-PluginBundle-<platform>-9.1.1.0.25665404.tar.gz` | [VCF CLI plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.1.0&os=&servicePk=545804&language=EN&groupId=545621&viewGroup=true) |

In the directory holding them, set the two exact file names, then run:

```sh
source ~/.vks-golang-web.env
CLI_TGZ="VCF-Consumption-CLI-Linux_AMD64-9.1.1.0.25662425.tar.gz"
PLUGINS_TGZ="VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.1.0.25665404.tar.gz"

T="$(mktemp -d)"
tar -xzf "$CLI_TGZ" -C "$T"
sudo install -d /usr/local/bin
sudo install "$T"/vcf-cli-* /usr/local/bin/vcf
mkdir "$T/plugins" && tar -xzf "$PLUGINS_TGZ" -C "$T/plugins"
vcf plugin install all --local-source "$T/plugins"
rm -rf "$T"
vcf version | head -1
```

**Expect:** `version: v9.1.1.0.25662425` (or the release you downloaded).

### Check

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

**Expect:** no `MISSING` line, and a version for your engine, `kubectl` and `vcf`.

## 3. Trust the Harbor CA

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

**Expect:** a SHA-256 fingerprint. Confirm it with your Harbor administrator.

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
colima restart
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
source ~/.vks-golang-web.env
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
make deps
```

Run everything below from this directory.

## 5. Build the image

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"

make image-build IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** the image name, with your Harbor and project, then a finished build.

## 6. Harbor credentials

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

Put them in `~/.vks-golang-web.env`, in single quotes:

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

**Expect:** `Login Succeeded`.

## 7. Push the image

```sh
source ~/.vks-golang-web.env
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

Check:

```sh
source ~/.vks-golang-web.env
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts" \
  | jq -r '.[] | "\(.digest[0:19])  \([.tags[]?.name]|join(","))"'
rm -f "$CFG"
```

**Expect:** a digest and your version tag.

## 8. Get the kubeconfigs

Supervisor CA:

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$SUPERVISOR_CA")"
VCTMP="$(mktemp -d)"
curl -fsSk --max-time 60 -o "$VCTMP/certs.zip" "https://${VCENTER_FQDN}/certs/download.zip"
unzip -oqj "$VCTMP/certs.zip" -d "$VCTMP/certs"
cat "$VCTMP"/certs/*.0 > "$SUPERVISOR_CA"
rm -rf "$VCTMP"

[ -s "$SUPERVISOR_CA" ] || echo "FAILED: $SUPERVISOR_CA is empty — the fetch above did not work"
openssl x509 -in "$SUPERVISOR_CA" -noout -subject -fingerprint -sha256
```

**Expect:** `subject=CN = CA, DC = vsphere, …` and a fingerprint.

Log in to the Supervisor. **Three failed logins lock the SSO account.**

```sh
source ~/.vks-golang-web.env
KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
  vcf context create supervisor --type k8s \
    --endpoint "https://${SUPERVISOR_ENDPOINT}" \
    --username "$SSO_USERNAME" \
    --ca-certificate "$SUPERVISOR_CA"

kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" config use-context supervisor
```

If it says `context "supervisor" already exists`, run the vcf-contexts block in step 11, then
this one again.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** your namespace, `Active`.

Guest cluster:

```sh
source ~/.vks-golang-web.env
( umask 077
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "$GUEST_KUBECONFIG" )

kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

**Expect:** every node `Ready`, and client and server at most one minor version apart.

## 9. Deploy

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

Private Harbor project only:

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
  --from-file=.dockerconfigjson="$D/dockercfg.json"
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
echo "${IMAGE} -> ${DIGEST:-NOT FOUND — read the curl error above: 404 = not pushed (step 7); 401 = wrong credentials or HARBOR_PROJECT; 403 = the robot lacks artifact read; certificate = HARBOR_CA (step 3)}"

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

## 10. Reach the app

```sh
source ~/.vks-golang-web.env
kubectl wait svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -s "http://${APP_IP}:8080/myhello/"
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

## 11. Clean up

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
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
done
```

The vcf contexts:

```sh
source ~/.vks-golang-web.env
for c in $(vcf context list 2>/dev/null | awk '$1 ~ /^supervisor:/{print $1}'); do
  vcf context delete "$c" -y --skip-delete-kubeconfig-context
done
vcf context delete supervisor -y --skip-delete-kubeconfig-context
vcf context list          # confirm none remain
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

The files this guide wrote (then delete the `golang-web` clone):

```sh
source ~/.vks-golang-web.env
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
```

The variables:

```sh
rm -f ~/.vks-golang-web.env
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP
unset -f harbor_cfg 2>/dev/null || true
```

## Troubleshooting

| symptom | fix |
|---|---|
| `x509: certificate signed by unknown authority` on login or push | Run the step 3 block for **your** engine; the directory must be exactly `$HARBOR_FQDN`. |
| `x509: "harbor" certificate is not standards compliant` (macOS) | Use step 3's podman or Colima block, not the macOS Keychain. |
| `docker: unknown command: docker buildx` (macOS) | Re-run the `ln -sfn … docker-buildx` line in step 2. |
| `dial unix /var/run/docker.sock` (macOS) | `colima start` |
| `bad CPU type in executable` (macOS) | `softwareupdate --install-rosetta --agree-to-license` |
| `vcf plugin list` hangs on `Refreshing plugin inventory cache` | `Ctrl-C`; the installed plugins need no registry. |
| `403` on the step 7 or 9 lookup | The robot needs `artifact` read and list; create it with step 6. |
| `unauthorized` on push | Re-run step 6's login; a robot stops working when its `duration` (days) ends. |
| Pod crash-loops or serves an old build | Deploy by digest (step 9), then check `IMAGEID`. |
| `exec format error` in the pod | `make image-build PLATFORM=linux/amd64`, then push again. |
| Pod rejected at admission | The cluster enforces `restricted`; `k8s/golang-web.yaml` complies — keep your changes compliant. |
| `EXTERNAL-IP` stays `<pending>` | Use the port-forward in step 10. |
