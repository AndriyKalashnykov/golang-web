# Build the image yourself and deploy it from Harbor

This chapter builds the `golang-web` image on your machine, pushes it to your Harbor registry
and runs that image on your guest cluster, in place of the published one. It comes after
[Check the guest cluster](README.md#check-the-guest-cluster) of [the main guide](README.md). At
the end the app runs from your Harbor, by digest.

You need:

- the main guide's env file, its tools, its clone and the guest cluster's kubeconfig;
- a container engine, podman or docker:
  [Install a container engine — pick one](SETUP.md#install-a-container-engine--pick-one);
- a Harbor: its DNS name, a project you may push to, a robot account or the Harbor admin
  password, the SHA-256 fingerprint of its CA certificate, and confirmation that the guest
  cluster trusts that CA (without it the cluster cannot download your image).
  [HARBOR.md](HARBOR.md) says how to check it and where each value comes from, and how to
  install a Harbor when you have none;
- internet access for the build: quay.io, docker.io, gcr.io and proxy.golang.org (and
  download.docker.com to install docker).

Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside
your `golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where
it can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells
you what to do.

First open `~/.vks-golang-web.env` and set `HARBOR_FQDN` to Harbor's DNS name and
`HARBOR_PROJECT` to your project. Leave the two `REGISTRY_*` lines empty:
[Log in to Harbor](#log-in-to-harbor) fills them.

## Trust the Harbor CA

### Download and check the Harbor CA

Harbor's certificate comes from a CA your machine does not trust yet, so your container engine
refuses to push to Harbor. This part downloads Harbor's CA certificate to `$HARBOR_CA` and
installs it where your engine looks for it. As with the vCenter CA, the download cannot be
verified yet, so you compare its fingerprint with a trusted one. For a Harbor on your
Supervisor that is the one
[Print the fingerprint of Harbor's CA](HARBOR-manual.md#print-the-fingerprint-of-harbors-ca)
reads from the Supervisor; for a Harbor elsewhere, the one its administrator gives you.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_CA")"
rm -f "$HARBOR_CA"
curl -fsSk "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$HARBOR_CA"
openssl x509 -in "$HARBOR_CA" -noout -fingerprint -sha256
```

**Expect:** `sha256 Fingerprint=…` (`SHA256 Fingerprint=` on macOS). Compare its hex digits with
the trusted fingerprint, ignoring colons and upper/lower case.

**If not:**
- **A different fingerprint:** do not continue. Check `HARBOR_FQDN` in the env file: the name
  may lead to another server. A company proxy that replaces HTTPS certificates also causes
  this. For a Harbor that is not on your Supervisor, its administrator can confirm the
  fingerprint or give you the CA file (save it with `cp <file> "$HARBOR_CA"`).
- **`curl: (22) … error: 404`, then an `openssl` error (`Could not open file` or
  `unable to load certificate`):** Harbor is reachable but does not
  publish a CA (its certificate was not made by Harbor). Get the CA file from whoever issued
  Harbor's certificate, save it with `cp <file> "$HARBOR_CA"`, and run only the `openssl` line
  above to check it.
- **Any other `curl:` error, then an `openssl` error:** the download failed. Check `HARBOR_FQDN` and that you can reach Harbor.

### Install the CA for your engine

Run only the block for the engine you installed.

**podman, Linux and macOS:**

```sh
source ~/.vks-golang-web.env
mkdir -p "$HOME/.config/containers/certs.d/${HARBOR_FQDN}"
cp "$HARBOR_CA" "$HOME/.config/containers/certs.d/${HARBOR_FQDN}/ca.crt"
```

**Linux, docker:**

```sh
source ~/.vks-golang-web.env
sudo install -D -m0644 "$HARBOR_CA" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"
```

**macOS, docker (Colima).** The CA goes inside Colima's VM, so the first line starts Colima if it is
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

This checks that the CA file works, by calling Harbor with it (the engine's own trust is proven by
[Log the container engine in to Harbor](#log-the-container-engine-in-to-harbor)):

```sh
source ~/.vks-golang-web.env
curl -s --cacert "$HARBOR_CA" -o /dev/null -w 'http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health"
```

**Expect:** `http=200`. **If not:** `http=000` means curl could not connect or did not trust the
certificate: re-check the fingerprint block above and `HARBOR_FQDN`.

## Log in to Harbor

Your container engine needs a Harbor login to push the image, and the later parts of this
chapter use the same name and secret to look the image up. Use a **robot account** (option A)
or the **admin account** (option B). The make commands
below take the Harbor project as `OWNER`.

### Option A — create a robot account

This creates a robot account that can push to and read from your project only, and expires after
90 days. It needs `HARBOR_ADMIN_PASSWORD` in the env file. If you already have a robot name and
secret, skip the block and put them in the two `REGISTRY_*` lines as shown below.

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
- `ERROR CONFLICT`: a robot with this name (`robot$<your project>+golang-web-push`) already
  exists. Use its secret if you have it; otherwise
  run the [Delete the image and the robot in Harbor](CLEANUP.md#delete-the-image-and-the-robot-in-harbor)
  block — **it also deletes the `golang-web` repository** — then run this again.
- No output at all: Harbor could not be reached; re-check
  [Trust the Harbor CA](#trust-the-harbor-ca).

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

Option B stores the admin password in the cluster too, if you create the pull secret below.
Prefer option A.

### Log the container engine in to Harbor

This saves your Harbor login in the container engine, so that it can push.

```sh
source ~/.vks-golang-web.env
make registry-login IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** `Login Succeeded` (podman adds `!`; docker may first print a `WARNING!` about
unencrypted storage, which is harmless).

**If not:** `x509` — run the block for your engine under
[Install the CA for your engine](#install-the-ca-for-your-engine). `unauthorized` — check the two
`REGISTRY_*` values in the env file. `ERROR: no credential` — the `REGISTRY_*` lines are empty:
fill them (option A or B), then run this block again.

## Build and push the image

### Build and push

This builds the app into an image and pushes it to Harbor. The image holds a version for each
common CPU architecture, `amd64` and `arm64`, under one tag, so it runs on any node whatever
machine you build on. The first build takes a few minutes. If you know every node is amd64 (you
can check with `kubectl get nodes -L kubernetes.io/arch`), you may add
`PUSH_PLATFORMS=linux/amd64` to the `make` command (faster); if unsure, keep both.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
echo "$IMAGE"
make image-push IMAGE_REGISTRY="$HARBOR_FQDN" OWNER="$HARBOR_PROJECT"
```

**Expect:** the image name, `podman buildx is available.` (or `docker …`), then `Building … for
linux/amd64,linux/arm64`, the build and the push, and no `make: ***` line at the end.

**If not:** `x509` — [Trust the Harbor CA](#trust-the-harbor-ca). `unauthorized` —
[Log the container engine in to Harbor](#log-the-container-engine-in-to-harbor).
`version.txt: No such file` or `No rule to make target` — this terminal is not in the clone:
`cd` into it. A message that the engine is not installed or not running tells you the fix. A
message that the amd64 image is labelled with a variant — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) (podman on an arm64 Linux machine).

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

## Deploy from Harbor

If the published image already runs from the main guide's
[Deploy the app](README.md#deploy-the-app), these blocks replace it: the app keeps its names,
and its image becomes yours.

### Create the app's namespace

This creates a Kubernetes namespace called `golang-web` in the guest cluster, to hold the app, and
makes it the default for the commands below. (It is not your vSphere Namespace.) It is the main
guide's block: run it again here, it changes nothing when the namespace exists.

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
With option B above, that secret holds the Harbor admin password.

**If not:** `http=000` with a `curl:` error means Harbor could not be reached; fix that first
([Trust the Harbor CA](#trust-the-harbor-ca)).

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

### Deploy the image you pushed

This looks up the digest of the image you pushed, writes it into
`k8s/golang-web.yaml`'s image line (only for this command; the file is not changed), applies it,
and waits up to 150 seconds for the app to start. It deploys by digest because a tag can later
point to another image; a digest cannot.

The Service is applied as the file has it, of type `LoadBalancer`: the cluster gives the app an
IP address of its own. An image built from this repo's current source does not answer
`/shutdown` unless `ENABLE_SHUTDOWN=true` is set, and the file does not set it.

```sh
source ~/.vks-golang-web.env
export IMAGE="${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)"
harbor_cfg "$REGISTRY_USERNAME" "$REGISTRY_TOKEN"
DIGEST="$(curl -fsS --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web/artifacts/$(cat version.txt)" \
  | jq -r '.digest // empty')"
rm -f "$CFG"
echo "${IMAGE} -> ${DIGEST:-NOT FOUND — read the curl error above: 404 = not pushed (Build and push); 401 = wrong credentials or HARBOR_PROJECT; 403 = the robot lacks artifact read; certificate = HARBOR_CA (Trust the Harbor CA)}"

[ -n "$DIGEST" ] && \
  sed "s|image: .*/golang-web:.*|image: ${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web@${DIGEST}|" \
    k8s/golang-web.yaml | kubectl apply -f - && \
  kubectl rollout status deploy/golang-web --timeout=150s
```

**Expect:** `… -> sha256:…`, then `deployment.apps/golang-web` and `service/golang-web-service`
lines, then `successfully rolled out`.

**If not:** `NOT FOUND` explains itself. If the wait times out, run `kubectl describe pod -l
app=golang-web`, read the `Events` at the bottom, and look the message up in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Check that the running app uses exactly the image you pushed:

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

**Expect:** `Running`, and `IMAGEID` ending with the digest printed above. **If not:** an old pod
may still be listed; wait a few seconds and run it again.

## Next

Open the app with the main guide's
[Reach the app through its LoadBalancer address](README.md#reach-the-app-through-its-loadbalancer-address);
its [port-forward](README.md#reach-the-app-through-a-port-forward) works too.

To remove the image, the robot account, the Harbor login and Harbor's CA from Harbor and from
this machine, use [CLEANUP.md](CLEANUP.md).
