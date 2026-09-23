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

Everything below derives from this block — nothing is typed twice. A different environment only
changes these values.

```sh
# --- ask your platform administrator for these ------------------------------
export HARBOR_FQDN="harbor.example.test"         # Harbor's DNS name
export HARBOR_PROJECT="apps"                     # the Harbor PROJECT the image lands in
export SUPERVISOR_ENDPOINT="10.0.0.10"           # Supervisor API endpoint (IP or FQDN)
export VCENTER_FQDN="vcsa.example.test"          # vCenter — serves the CA the Supervisor uses
export VKS_CLUSTER="my-guest-cluster"            # the guest cluster NAME
export VKS_NAMESPACE="my-namespace"              # the vSphere Namespace holding it
export SSO_USERNAME="administrator@vsphere.local"

# --- yours to choose; just a place to keep the CA ----------------------------
export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
```

---

## 2. Install the tools

| tool | why |
|---|---|
| `podman` (or `docker`) | build and push the image |
| `kubectl` | talk to the guest cluster |
| `vcf` | the VCF CLI — authenticates to the Supervisor |
| `git`, `make` | check out and drive the repo |
| `jq` | only for the robot-account step |

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
  kubectl version --client
fi
```

If the Supervisor's build is more than one minor away from your **guest cluster** — that is where
every command from section 9 runs — take a matching build from upstream instead:

```sh
export KUBECTL_VERSION="v1.36.2"           # match the guest cluster
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH:-amd64}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
```

### Which engine will be used?

**podman if it is installed, otherwise docker.** To force the other one:

```sh
export CONTAINER_ENGINE=docker          # for this shell
```

or for a single command:

```sh
make image-build CONTAINER_ENGINE=docker
```

After you check out the repo (section 4), `make engines` prints the selection it made.

## Verify the installation

```sh
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
install -D -m0644 "$HARBOR_CA" "$HOME/.config/containers/certs.d/${HARBOR_FQDN}/ca.crt"
```

**Linux + docker (needs sudo; the path is root-owned):**

```sh
sudo install -D -m0644 "$HARBOR_CA" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"
sudo systemctl restart docker
```

**macOS + podman** — import the Mac's trust store into the machine VM, then restart it:

```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$HARBOR_CA"
podman machine set --import-native-ca
podman machine stop && podman machine start
```

**macOS + docker (Colima)** — the daemon does not run on your Mac, it runs in the VM, and
`dockerd` reads `certs.d` **on the machine it runs on**. So the CA goes inside the VM:

```sh
# UNTESTED — verify before relying on it.
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
colima restart
```

> ⚠️ **Restart the engine afterwards**, or the login keeps failing.

## Verify

```sh
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
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
make deps
```

`make deps` installs the pinned toolchain from `.mise.toml` — the same versions on macOS and Linux.

---

## 5. Build the image

```sh
make image-build IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

> `OWNER` may be passed on the `make` command line or exported — both work.
>
> On an arm64 host the build targets `linux/amd64` automatically, because VKS nodes are amd64
> and a native arm64 image pushes fine and then dies with `exec format error`. Override with
> `PLATFORM=linux/arm64`, or `PLATFORM=` to build natively.

## Verify the image name

```sh
make -n k8s-apply IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT" | head -1
```

```
## Sample output — note the project segment is `apps`
sed -e 's|image: .*/golang-web:.*|image: harbor.example.test/apps/golang-web:v0.0.3|' k8s/golang-web.yaml | kubectl apply -f -
```

---

## 6. Provide Harbor credentials

`export` these two — `make REGISTRY_TOKEN=...` would put the token where `ps` can read it.

### Option A — a robot account (recommended)

A robot is scoped to one project and one set of actions, so a leak cannot touch the rest of Harbor.

```sh
export REGISTRY_USERNAME='robot$apps+golang-web-push'
read -rs REGISTRY_TOKEN && export REGISTRY_TOKEN      # paste the secret; it is not echoed
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

### Option B — the Harbor admin account

```sh
export REGISTRY_USERNAME="admin"
read -rs REGISTRY_TOKEN && export REGISTRY_TOKEN
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

```
## Sample output
Login Succeeded!
```

### How to create the robot account, given the Harbor admin account

Run this once. `duration` is in days; `-1` means never expire.

```sh
read -rs HARBOR_ADMIN_PASSWORD

# curl's -K file is parsed, so the password must be escaped.
harbor_cfg() {
  local e="$HARBOR_ADMIN_PASSWORD"
  e="${e//\\/\\\\}"; e="${e//\"/\\\"}"
  CFG="$(mktemp)"; ( umask 077; printf 'user = "admin:%s"\n' "$e" > "$CFG" )
}
harbor_cfg

jq -nc --arg p "$HARBOR_PROJECT" '{name:"golang-web-push", duration:90, level:"project",
  permissions:[{kind:"project", namespace:$p,
    access:[{resource:"repository",action:"push"},{resource:"repository",action:"pull"}]}]}' \
  > /tmp/robot.json

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X POST -H 'Content-Type: application/json' \
  --data @/tmp/robot.json "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '"\(.name)\n\(.secret)"'

rm -f /tmp/robot.json
```

```
## Sample output — the FIRST line is the username, the SECOND is the secret.
## The secret is shown ONCE and cannot be retrieved again.
robot$apps+golang-web-push
<32-character secret>
```

> Delete `$CFG` when you are done — see below.

To list or delete robots (re-run `harbor_cfg` first if you opened a new shell):

```sh
curl -s --cacert "$HARBOR_CA" -K "$CFG" "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[] | "\(.id)  \(.name)"'
curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE "https://${HARBOR_FQDN}/api/v2.0/robots/ID"   # ID from the list

rm -f "$CFG"          # when you are finished with admin calls
```

---

## 7. Push the image

```sh
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

## Verify it landed

```sh
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
mkdir -p "$(dirname "$SUPERVISOR_CA")"
# A fresh directory every time: unzip MERGES, so a stale one would add a foreign CA.
VCTMP="$(mktemp -d)"
curl -fsSk --max-time 60 -o "$VCTMP/certs.zip" "https://${VCENTER_FQDN}/certs/download.zip"
unzip -oqj "$VCTMP/certs.zip" -d "$VCTMP/certs"
cat "$VCTMP"/certs/*.0 > "$SUPERVISOR_CA"
rm -rf "$VCTMP"

[ -s "$SUPERVISOR_CA" ] || echo "FAILED: $SUPERVISOR_CA is empty — the fetch above did not work"
awk '/BEGIN CERT/{n++} END{print n+0" certificate(s)"}' "$SUPERVISOR_CA"
openssl x509 -in "$SUPERVISOR_CA" -noout -subject -fingerprint -sha256
```

```
## Sample output
  1 certificate(s)
  subject=CN = CA, DC = vsphere, DC = local, C = US, ST = California, O = vcsa.example.test, OU = VMware Engineering
  sha256 Fingerprint=7A:A5:12:54:4F:38:...
```

That fetch skipped TLS verification — you had no CA yet. If your administrator can give you the
expected fingerprint, compare it with the one printed above.

**Then create the context.** `vcf context create` writes to the path in `KUBECONFIG`:

```sh
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"

read -rsp 'vCenter SSO password: ' VCF_CLI_VSPHERE_PASSWORD; echo
export VCF_CLI_VSPHERE_PASSWORD

KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
  vcf context create supervisor --type k8s \
    --endpoint "https://${SUPERVISOR_ENDPOINT}" \
    --username "$SSO_USERNAME" \
    --ca-certificate "$SUPERVISOR_CA"

unset VCF_CLI_VSPHERE_PASSWORD
```

> ⚠️ **vCenter SSO locks the account after repeated failures.** Type it carefully.

Check it worked:

```sh
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
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

umask 077
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
  get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
  | base64 -d > "$GUEST_KUBECONFIG"

export KUBECONFIG="$GUEST_KUBECONFIG"
kubectl get nodes
```

```
## Sample output
  NAME                                      STATUS   ROLES           AGE   VERSION
  my-guest-cluster-node-pool-1-abcde-xxxxx  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-node-pool-1-abcde-yyyyy  Ready    <none>          6d    v1.36.2+vmware.2
  my-guest-cluster-xxxxx-zzzzz              Ready    control-plane   6d    v1.36.2+vmware.2
```

`umask 077` matters — that file is a cluster-admin credential.

Now you can check the version skew that section 2 mentioned — `kubectl` is supported within one
minor of the server:

```sh
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)   server \(.serverVersion.gitVersion)"'
```

If they are more than one minor apart, reinstall `kubectl` from upstream pinned to the server's
minor (section 2).

### 8c. Optional: `vcf cluster kubeconfig get`

The VCF CLI can build the guest kubeconfig for you, which is more convenient because it also
adds the context to your existing `KUBECONFIG`:

```sh
vcf cluster kubeconfig get "$VKS_CLUSTER" -n "$VKS_NAMESPACE"
kubectl config use-context "$VKS_CLUSTER"
kubectl get nodes
```

> ⚠️ If this exits 1 with `failed to get pinniped-info from management cluster`, your Supervisor
> has no Pinniped ConfigMap. You cannot fix that from your machine — **use 8b**.

The two kubeconfigs differ in how they authenticate: 8b is a CAPI-minted cluster-admin
certificate, 8c is an OIDC token brokered by Pinniped that honours your SSO identity and its
RBAC. On a shared cluster prefer 8c where it is available; 8b is the reliable fallback.

Every later command in this guide uses this `KUBECONFIG`.

## 9. Deploy

`make k8s-apply` rewrites the `image:` line in `k8s/golang-web.yaml` to the image you just pushed,
then applies it — so the manifest itself never needs editing.

```sh
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web

make k8s-apply IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
kubectl rollout status deploy/golang-web --timeout=150s
```

> **No `imagePullSecret` is needed** for a *public* Harbor project. For a **private** one:
> ```sh
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

## 10. Verify

```sh
kubectl get pod,svc
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl -s "http://${APP_IP}:8080/myhello/"
```

```
## Sample output
pod/golang-web-6b99d48b78-4d65g   1/1   Running   0   11s
service/golang-web-service   LoadBalancer   10.96.140.12     203.0.113.40   8080:30605/TCP

Hello, World
request 0 GET /myhello/
MY_POD_NAME: golang-web-6b99d48b78-4d65g
MY_POD_NAMESPACE: golang-web
```

The path is `/myhello/` because the manifest sets `APP_CONTEXT=/myhello/`. Any other path returns
404 by design.

---

## 11. Clean up

```sh
make k8s-delete
kubectl delete namespace golang-web
```

---

## Troubleshooting

**`x509: certificate signed by unknown authority` on push** — the CA is missing or wrong. Re-run
the step-3 verify, and check you used the block for YOUR platform — the paths differ between
Linux and macOS, and on macOS the engine must be restarted afterwards. `--cert-dir` is a
podman/skopeo flag; docker ignores it.

**Image pushed to the wrong project** — you used `export OWNER=...`. It has no effect; `OWNER` is
a `:=` assignment. Use `make OWNER=...`. Confirm with the step-5 verify before pushing.

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
