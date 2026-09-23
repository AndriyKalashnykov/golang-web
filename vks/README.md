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

Boxed notes marked ⚠️ are the steps that fail quietly if skipped — they are worth reading.

---

## 1. Download and install the utils

| tool | why |
|---|---|
| `podman` (or `docker`) | build and push the image |
| `kubectl` | talk to the guest cluster |
| `vcf` | the VCF CLI — authenticates to the Supervisor |
| `git`, `make` | check out and drive the repo |
| `jq` | only for the robot-account step |

**macOS**

```sh
brew install podman kubectl jq git make
podman machine init && podman machine start
```

⚠️ **On macOS a container CLI cannot build or push on its own — it needs a Linux VM behind it.**
`brew install docker` installs **only the client** — verified in the formula itself, which
builds from `github.com/docker/cli` (not moby/moby, the engine) and compiles exactly one
binary, `cmd/docker`. There is no `dockerd` in it. With no VM running you get:

```
dial unix /var/run/docker.sock: connect: no such file or directory
```

which is not a permissions problem and is not fixed by `sudo`. Pick a VM provider and start it:

| provider | start it with |
|---|---|
| **podman** (the path this guide was proven on) | `podman machine init && podman machine start` |
| Colima | `brew install colima docker && colima start` |
| Docker Desktop / OrbStack / Rancher Desktop | launch the app |

Confirm before going further — this must print a server section, not a socket error:

```sh
podman info --format '{{.Host.Arch}} remote={{.Host.ServiceIsRemote}}' 2>/dev/null \
  || docker info --format '{{.ServerVersion}}'
```

**Linux (Debian/Ubuntu)**

```sh
sudo apt-get update && sudo apt-get install -y podman kubectl jq git make
```

### Install the VCF CLI

The VCF CLI is **not** on Homebrew or apt. Both files below are **entitled** downloads — you
need a Broadcom account with a vSphere Foundation entitlement. Versions move; match yours to
what your entitlement offers.

| file | from |
|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-<version>.tar.gz` | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540529) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-<version>.tar.gz` | [Plugin bundle](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540672) |

**Portal gotchas — every one of these fails silently:**

- **Each link opens a page that looks EMPTY until you pick a release.** The *Release* list
  starts blank, and while it is blank the file table reads **"No data found"** — which looks
  exactly like the artifact not existing. Pick your release first, then the files appear.
- **Tick "I agree to the Terms and Conditions"** or the download icons do nothing. The
  checkbox stays **inert until you open both Terms links first**, and the gate is **per page**
   — ticking it on one page does not carry to the next.
- **Patch builds appear only once you open a group.** The parent page lists `9.1.0.0` alone.
- **A `release=` in the URL is ignored** — use the on-page selector.
- **Take only the `Linux_AMD64` rows** (uppercase). The un-suffixed `-Binaries-`,
  `-PluginBundle-` and `-OCI-` archives are multi-platform supersets.

Install the binary, then the plugins:

```sh
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

> **macOS:** the `Darwin_*` CLI archive works — measured on macOS 26.6.2 / Apple Silicon,
> `vcf version` reports `v9.1.0.0.25296329`, `releaseType: ga`. The **plugin bundle** is
> documented Linux-only; ask your platform administrator for the matching plugin path.
>
> ⚠️ **`vcf plugin list` HANGS when no plugins are installed** (measured on that Mac — it had
> to be interrupted). It appears to block on registry discovery. If it does not return within
> ~30 s, it is not going to; `Ctrl-C` and install the bundle first.

## Verify the installation

```sh
podman version && kubectl version --client && vcf version && echo "toolchain OK"
```

```
## Sample output (versions will differ)
  Client Version: v1.36.2
  version: v9.1.1.0.25662425
  releaseType: ga
  toolchain OK
```

---

## 2. Set the variables

Everything below derives from this block — nothing is typed twice. A different environment only
changes these values.

```sh
# --- ask your platform administrator for these six values --------------------
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

> The `-k` on that one call is a trust-on-first-use bootstrap: you cannot verify a CA with a CA
> you do not yet have. Every command after this verifies against it properly.

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

**macOS + docker** — which file to write depends on **where the daemon runs**, and on macOS it
never runs on your Mac:

| your setup | where the CA goes |
|---|---|
| Docker Desktop / OrbStack | the Mac's Keychain (below), then restart the app |
| Colima, Rancher Desktop, or any `docker` CLI over a VM | **inside the VM**, at `/etc/docker/certs.d/<registry>/ca.crt` |

```sh
# Docker Desktop / OrbStack:
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$HARBOR_CA"

# Colima (UNTESTED here — verify before relying on it; the mechanism is that dockerd
# reads certs.d on the machine it runs on, which is the Lima VM, not your Mac):
colima ssh -- sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
colima ssh -- sudo tee "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt" < "$HARBOR_CA" >/dev/null
colima restart
```

> ⚠️ **`/etc/docker/certs.d` ON YOUR MAC does nothing** — no daemon reads it there. It is the right
> path only *inside* the VM. Likewise `~/.config/containers/certs.d` is not a documented macOS
> location for podman; use `podman machine set --import-native-ca` above.
>
> ⚠️ **Restart the engine after this.** No engine re-reads trust material while running, so the
> login keeps failing until you do.

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

> ⚠️ **Pass `OWNER` on the `make` command line, never with `export`.** The Makefile sets it with
> `:=`, which the environment cannot override — so `export OWNER=apps` is silently ignored and
> your image is built for the *default* project instead. There is no error. Always confirm with
> the check below before pushing.

> ⚠️ **On Apple Silicon**, add `--platform linux/amd64`. VKS nodes are `amd64`; an arm64 image
> builds and pushes fine, then fails at runtime with `exec format error`.

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

The Makefile reads `REGISTRY_USERNAME` and `REGISTRY_TOKEN`, and passes the token on **stdin** —
never on the command line, where any local user could read it from `ps`.

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

# curl's -K file is PARSED, not read literally: a bare " truncates the password and a
# backslash is swallowed. Escape backslash FIRST, then the quote.
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

> The admin password is written to a `curl -K` config under `umask 077`, so it never appears in
> `ps` output or your shell history. **Delete it when you are done** — see below.

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

`vcf context create` writes to the path in `KUBECONFIG`, so set it on the command:

```sh
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"

VCF_CLI_VSPHERE_PASSWORD='<your-sso-password>' \
KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
  vcf context create supervisor --type k8s \
    --endpoint "https://${SUPERVISOR_ENDPOINT}" \
    --username "$SSO_USERNAME" \
    --ca-certificate "$SUPERVISOR_CA"
```

`SUPERVISOR_CA` is the **vCenter VMCA root**, not Harbor's CA. vCenter serves it:

```sh
getent hosts "$VCENTER_FQDN" || echo "your machine cannot resolve $VCENTER_FQDN — fix DNS first"

mkdir -p "$(dirname "$SUPERVISOR_CA")"
curl -fsSk --max-time 60 -o /tmp/certs.zip "https://${VCENTER_FQDN}/certs/download.zip"
unzip -o -j /tmp/certs.zip -d /tmp/vccerts
cat /tmp/vccerts/*.0 > "$SUPERVISOR_CA"
openssl x509 -in "$SUPERVISOR_CA" -noout -subject -enddate
```

```
## Sample output
  subject=CN = CA, DC = vsphere, DC = local, C = US, ST = California, O = vcsa.example.test, OU = VMware Engineering
  notAfter=Sep 11 18:13:40 2036 GMT
```

> `-f` and `-S` are load-bearing. With plain `-s`, a DNS failure or an HTTP error writes a
> **0-byte** `/tmp/certs.zip` and says nothing — `unzip` then fails with a message that points
> at the zip instead of at DNS.

⚠️ `curl -sk` skips verification **to fetch the trust anchor itself** — unavoidable, but it
means you must confirm the fingerprint out of band before trusting it:

```sh
openssl x509 -in "$SUPERVISOR_CA" -noout -fingerprint -sha256
```

Compare that with the fingerprint your platform administrator gives you. If you cannot, ask them
for the file directly — do **not** reach for `--insecure-skip-tls-verify` on a shared cluster.

> ⚠️ Passing the password in the environment as above keeps it out of `ps` output. Omit
> `VCF_CLI_VSPHERE_PASSWORD` entirely and the CLI prompts for it instead, which is safer on a
> shared machine. **vCenter SSO locks the account after repeated failures — type it carefully.**

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

### 8c. Optional: `vcf cluster kubeconfig get`

The VCF CLI can build the guest kubeconfig for you, which is more convenient because it also
adds the context to your existing `KUBECONFIG`:

```sh
vcf cluster kubeconfig get "$VKS_CLUSTER" -n "$VKS_NAMESPACE"
kubectl config use-context "$VKS_CLUSTER"
kubectl get nodes
```

> ⚠️ **This requires Pinniped and fails on many Supervisors.** It builds a *Pinniped-backed*
> kubeconfig, so it reads the `pinniped-info` ConfigMap from the Supervisor's `kube-public`
> namespace. If that ConfigMap is absent the command exits **1** with:
>
> ```
> Error: failed to get pinniped-info from management cluster
> ```
>
> Pinniped being *deployed* is not sufficient — the ConfigMap must exist. Check with:
>
> ```sh
> kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n kube-public get cm pinniped-info
> ```
>
> Nothing you can do from your machine fixes this; ask your platform administrator. **Use 8b
> instead** — it needs no Pinniped and works on every Supervisor.

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

> **No `imagePullSecret` is needed** when the Harbor project is *public* — the cluster pulls
> anonymously and already trusts the Harbor CA. Verified: `Successfully pulled image
> "harbor.example.test/apps/golang-web:v0.0.3" in 1.129s`. For a **private** project, create one:
> ```sh
> # NOT `kubectl create secret docker-registry --docker-password=...` — that puts the token in
> # argv, where any user on the machine can read it from `ps` for the life of the command.
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
> `jq` reads the values from the **environment** (`env.X`), not from `--arg`, because `--arg`
> is argv too. `printf` is a shell builtin, so it forks no process that could expose the token.

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

**`exec format error` in the pod** — an arm64 image on amd64 nodes. Rebuild with
`--platform linux/amd64`.

**Pod rejected at admission** — the guest cluster enforces the `restricted` Pod Security Standard
cluster-wide. `k8s/golang-web.yaml` already complies (`runAsNonRoot`, `seccompProfile:
RuntimeDefault`, `readOnlyRootFilesystem`, `capabilities: drop: ["ALL"]`). A pod of your own needs
the same, or label the namespace to a lower level.

**`EXTERNAL-IP` stays `<pending>`** — the cluster has no LoadBalancer provider, or none is free.
Reach the app with `kubectl port-forward svc/golang-web-service 8080:8080` instead.

**`unauthorized` on push** — the login expired or was never made. Re-run step 6; a robot's
`duration` is in days and it stops working silently when it lapses.
