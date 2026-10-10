# Headlamp: look at the guest cluster in a web page

[Headlamp](https://headlamp.dev/) shows what runs on a Kubernetes cluster: nodes, namespaces,
pods, their logs and events. This chapter is optional and comes after the main guide's *Check the
guest cluster*. You need [the main guide](../README.md)'s env file and the guest cluster's
kubeconfig (`$GUEST_KUBECONFIG`).

There are two ways to use it. Take the first that fits you:

| your situation | go to | what it puts on the cluster |
|---|---|---|
| You want to look at the cluster from your own machine | [Headlamp on your machine](#headlamp-on-your-machine) | nothing |
| Several people should open one page, with read-only rights | [Headlamp in the cluster, with helm](#headlamp-in-the-cluster-with-helm) | one namespace, one pod, a read-only account |

Run the blocks by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside your
`golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where it
can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells you
what to do.

## Add Headlamp's settings

This adds Headlamp's five settings to your env file, each only if it is not there yet. Values
you already set are kept.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export HEADLAMP_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_VERSION="0.45.0"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_CHART_VERSION=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_CHART_VERSION="0.45.0"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_NAMESPACE=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_NAMESPACE="headlamp"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_TOKEN_HOURS=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_TOKEN_HOURS="8"' >> ~/.vks-golang-web.env
  grep -qs '^export HEADLAMP_LOCAL_PORT=' ~/.vks-golang-web.env || printf '%s\n' 'export HEADLAMP_LOCAL_PORT="8081"' >> ~/.vks-golang-web.env
  grep -c -E '^export (HEADLAMP_VERSION|HEADLAMP_CHART_VERSION|HEADLAMP_NAMESPACE|HEADLAMP_TOKEN_HOURS|HEADLAMP_LOCAL_PORT)=' ~/.vks-golang-web.env
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `5`.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine. A
number above 5 means a setting is in the file twice: open the file and delete the line you do
not want (the last one wins).

| setting | meaning |
|---|---|
| `HEADLAMP_VERSION` | the desktop program's version, for the Linux download |
| `HEADLAMP_CHART_VERSION` | the helm chart's version; chart 0.45.0 installs Headlamp 0.45.0 |
| `HEADLAMP_NAMESPACE` | the namespace on the guest cluster that Headlamp runs in |
| `HEADLAMP_TOKEN_HOURS` | how long a login token is valid |
| `HEADLAMP_LOCAL_PORT` | the port on your machine the page is served on |

The newest versions are listed on [Headlamp's releases page](https://github.com/kubernetes-sigs/headlamp/releases)
(the program is `v0.45.0`, the chart `headlamp-helm-0.45.0`). To use another one, change the
setting in the env file; no block below names a version.

## Headlamp on your machine

The desktop program runs on your machine and reads the guest cluster's kubeconfig. Nothing is
installed on the cluster.

**Read this first.** `$GUEST_KUBECONFIG` is the cluster's administrator login. Headlamp opened
with it can do everything on the cluster: delete workloads, read every Secret, open a shell in a
pod. Whoever sits at your machine while it is open has those rights. For a page other people
open, or for read-only rights, use [Headlamp in the cluster, with helm](#headlamp-in-the-cluster-with-helm).

### Install the desktop program

**macOS:**

```sh
brew install --cask headlamp
```

**Expect:** Homebrew's install lines, ending with `headlamp was successfully installed!`.

**Linux (Debian/Ubuntu, Intel or AMD):** this downloads Headlamp's package and compares it with
the checksum the project publishes.

```sh
source ~/.vks-golang-web.env
D="$(mktemp -d)"
F="headlamp_${HEADLAMP_VERSION}-1_amd64.deb"
curl -fsSL --connect-timeout 10 -o "$D/checksums.txt" "https://github.com/kubernetes-sigs/headlamp/releases/download/v${HEADLAMP_VERSION}/checksums.txt"
curl -fsSL --connect-timeout 10 -o "$D/$F" "https://github.com/kubernetes-sigs/headlamp/releases/download/v${HEADLAMP_VERSION}/${F}"
if ( cd "$D" && grep " ${F}\$" checksums.txt | sha256sum -c - ); then
  mkdir -p "$HOME/Downloads"
  mv "$D/$F" "$HOME/Downloads/$F"
  echo "saved: $HOME/Downloads/$F"
else
  echo "NOT saved: the download failed or its checksum does not match (see the lines above)"
fi
rm -rf "$D"
```

**Expect:** `headlamp_<version>-1_amd64.deb: OK`, then `saved: <your home>/Downloads/headlamp_<version>-1_amd64.deb`.

**If not:** `NOT saved: …` — a `curl: (22) … 404` line above it means `HEADLAMP_VERSION` is not a
released version; `curl: (28)` or `(6)`, that this machine cannot reach github.com. A line with
`FAILED` means the file is not the one the project published: do not install it; run the block
again.

Then install the package:

```sh
source ~/.vks-golang-web.env
sudo apt-get install -y "$HOME/Downloads/headlamp_${HEADLAMP_VERSION}-1_amd64.deb"
```

**Expect:** the install ends without an `E:` line. A line starting with `N: Download is performed
unsandboxed as root` is fine.

On other Linux machines (ARM, or not Debian/Ubuntu) the project publishes an AppImage, a
`tar.gz` and a Flatpak:
[Headlamp's Linux installation page](https://headlamp.dev/docs/latest/installation/desktop/linux-installation/).
The Flatpak can read only `~/.kube/config`, not `$GUEST_KUBECONFIG`.

### Open Headlamp with the guest cluster

This starts Headlamp with the guest cluster's kubeconfig and no other.

**macOS:**

```sh
source ~/.vks-golang-web.env
if [ -s "$GUEST_KUBECONFIG" ]; then
  KUBECONFIG="$GUEST_KUBECONFIG" open -n -a Headlamp --args "$GUEST_KUBECONFIG"
else
  echo "No kubeconfig at ${GUEST_KUBECONFIG}: run the main guide's 'Get the guest cluster's kubeconfig' first"
fi
```

**Expect:** nothing is printed, and the Headlamp window opens.

**Linux:** the program runs until you close its window; the terminal is busy until then.

```sh
source ~/.vks-golang-web.env
if [ -s "$GUEST_KUBECONFIG" ]; then
  KUBECONFIG="$GUEST_KUBECONFIG" "$(command -v headlamp || echo /opt/Headlamp/headlamp)" "$GUEST_KUBECONFIG"
else
  echo "No kubeconfig at ${GUEST_KUBECONFIG}: run the main guide's 'Get the guest cluster's kubeconfig' first"
fi
```

**Expect:** the Headlamp window opens; the terminal may print the program's own log lines.

On both, the window shows one cluster, named after your guest cluster's context. Click it: the
overview shows the nodes, all `Ready`, and the namespaces. You are not asked for a token: the
kubeconfig is the login.

**If not:**
- `No kubeconfig at …`: the file is missing or empty. The main guide's *Get the guest cluster's
  kubeconfig* writes it.
- The window shows other clusters, and not yours: Headlamp was already running and kept its
  earlier list. Quit it, then run the block again.
- The cluster is listed, and opening it shows an error or never loads: this machine cannot
  reach the cluster's address. `kubectl --kubeconfig "$GUEST_KUBECONFIG" get nodes` in the
  terminal fails the same way; fix that first (main guide, *Check the guest cluster*).
- Linux, `The SUID sandbox helper binary was found, but is not configured correctly`, or no
  window at all: install the `.deb` package as above, not the AppImage or the `tar.gz`.

To remove the desktop program: `brew uninstall --cask headlamp` on macOS,
`sudo apt-get remove -y headlamp` on Linux. Nothing was put on the cluster.

## Headlamp in the cluster, with helm

This installs Headlamp on the guest cluster with the project's own helm chart, in a namespace of
its own. The page is reached through a port-forward, and you log in with a token of an account
that can only read.

Two things in the chart's defaults do not fit a VKS guest cluster, and
[`templates/headlamp-values.yaml`](templates/headlamp-values.yaml) changes both:

- A guest cluster accepts only pods that meet the Pod Security level `restricted`. The chart's
  default pod does not, and is rejected. The values file adds the security settings that level
  asks for.
- The chart gives Headlamp's account the `cluster-admin` role. The values file gives it `view`,
  Kubernetes' built-in read-only role: it lists and reads workloads in every namespace, cannot
  read Secrets, and cannot change anything.

### Check helm

`helm` is needed for this section only; nothing else in these guides uses it.

```sh
helm version --short
```

**Expect:** a version line, `v3.…` or `v4.…`.

**If not:** `command not found` — install helm: [SETUP.md](../SETUP.md#install-helm), then run
the block again.

### Create Headlamp's namespace

This creates the namespace, marked as made by this guide and set to the Pod Security level
`restricted`. It refuses a namespace of that name that it did not create.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || NS=unknown
if [ -z "$HEADLAMP_NAMESPACE" ]; then
  echo "Not created: HEADLAMP_NAMESPACE is empty"
elif [ "$NS" = unknown ]; then
  echo "Not created: the guest cluster did not answer (see the error above)"
elif [ "$NS" = "${HEADLAMP_NAMESPACE}/headlamp-guide" ]; then
  echo "namespace/${HEADLAMP_NAMESPACE} is already there, made by this guide"
elif [ -n "$NS" ]; then
  echo "Not created: a namespace '${HEADLAMP_NAMESPACE}' exists and this guide did not make it. Set HEADLAMP_NAMESPACE to another name."
else
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    vks-golang-web/created-by: headlamp-guide\n    pod-security.kubernetes.io/enforce: restricted\n' "$HEADLAMP_NAMESPACE" \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" create -f -
fi
```

**Expect:** `namespace/headlamp created`, or `namespace/headlamp is already there, made by this
guide` when you run it again.

**If not:**
- `Not created: a namespace … exists and this guide did not make it`: somebody else uses that
  name, perhaps for a Headlamp of their own. Set `HEADLAMP_NAMESPACE` in the env file to another
  name, then run the block again.
- `Not created: the guest cluster did not answer`: the line above it says why. `Unable to
  connect` — this machine cannot reach the cluster; `Unauthorized` — the kubeconfig is not this
  cluster's: get it again (main guide).

### Check the chart against the cluster

This fills the chart with the values file and asks the guest cluster to check the result without
creating anything (`--dry-run=server`). The cluster applies its Pod Security rules in this check.

```sh
source ~/.vks-golang-web.env
if [ -f vks/addons/templates/headlamp-values.yaml ]; then
  helm template headlamp headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version "$HEADLAMP_CHART_VERSION" \
    --namespace "$HEADLAMP_NAMESPACE" -f vks/addons/templates/headlamp-values.yaml \
    | kubectl --kubeconfig "$GUEST_KUBECONFIG" apply --dry-run=server -f -
else
  echo "Not checked: run this block from inside your golang-web clone"
fi
```

**Expect:** four lines that end with `created (server dry run)`: `serviceaccount/headlamp`,
`clusterrolebinding.rbac.authorization.k8s.io/headlamp-admin`, `service/headlamp` and
`deployment.apps/headlamp`; and no line that starts with `Warning: would violate PodSecurity`.
The chart names the binding `headlamp-admin` whatever role it binds; here the role is `view`.

**If not:**
- `Warning: would violate PodSecurity "restricted:latest": …`: the line names the setting that
  is missing. With this guide's values file and chart 0.45.0 there is none; a newer chart may
  have added a container. Do not install: set `HEADLAMP_CHART_VERSION` back to `0.45.0`.
- `Error: chart "headlamp" version "…" not found`: `HEADLAMP_CHART_VERSION` is not a published
  chart version.
- `namespaces "headlamp" not found`: run *Create Headlamp's namespace* first.
- `Error: … no such host` or a timeout: this machine cannot reach
  `kubernetes-sigs.github.io` and `github.com`, where the chart is published.

### Install Headlamp

This installs the chart into the namespace this guide made, and waits up to five minutes for the
pod. It refuses any other namespace.

```sh
source ~/.vks-golang-web.env
L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ "$L" != headlamp-guide ]; then
  echo "Not installed: the namespace '${HEADLAMP_NAMESPACE}' is missing, was not made by this guide, or could not be read. Run 'Create Headlamp's namespace' first."
elif [ ! -f vks/addons/templates/headlamp-values.yaml ]; then
  echo "Not installed: run this block from inside your golang-web clone"
elif helm --kubeconfig "$GUEST_KUBECONFIG" upgrade --install headlamp headlamp --repo https://kubernetes-sigs.github.io/headlamp/ --version "$HEADLAMP_CHART_VERSION" \
    --namespace "$HEADLAMP_NAMESPACE" -f vks/addons/templates/headlamp-values.yaml --wait --timeout 5m; then
  kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" get deployment headlamp
else
  echo "Not installed, or not ready in time: see the error above"
fi
```

**Expect:** `Release "headlamp" does not exist. Installing it now.` (`has been upgraded` when you
run it again), helm's summary with `STATUS: deployed`, then the deployment with `READY` `1/1`.

**If not:**
- `Not installed, or not ready in time`, under `context deadline exceeded`: the pod did not
  become ready. `kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" get events --sort-by=.lastTimestamp`
  says why. `violates PodSecurity` — the values file was not used: run the block from inside
  your clone. `ImagePullBackOff` — the cluster's nodes cannot reach `ghcr.io`. `Insufficient
  memory` — the workers are full (Headlamp asks for 128 MB).
- `ClusterRoleBinding "headlamp-admin" … exists and cannot be imported into the current
  release`: another Headlamp was installed on this cluster with the same chart. Use that one, or
  ask its owner; this guide does not replace it.

### Check that Headlamp's account can only read

This asks the cluster what Headlamp's account may do.

```sh
source ~/.vks-golang-web.env
SA="system:serviceaccount:${HEADLAMP_NAMESPACE}:headlamp"
echo "list pods everywhere: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i list pods --all-namespaces --as "$SA")"
echo "read secrets: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i get secrets --all-namespaces --as "$SA")"
echo "delete pods: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i delete pods --all-namespaces --as "$SA")"
echo "change roles: $(kubectl --kubeconfig "$GUEST_KUBECONFIG" auth can-i create clusterrolebindings --as "$SA")"
```

**Expect:** `list pods everywhere: yes`, then `read secrets: no`, `delete pods: no` and
`change roles: no`.

**If not:** a `yes` on one of the last three lines — the account has more than the `view` role.
Run `kubectl --kubeconfig "$GUEST_KUBECONFIG" get clusterrolebinding headlamp-admin -o jsonpath='{.roleRef.name}'`:
it must print `view`. `cluster-admin` there means the chart was installed without the values
file; run *Install Headlamp* again from inside your clone.

### Make a login token

**This block shows a secret.** It prints a token that logs in as Headlamp's read-only account
for `HEADLAMP_TOKEN_HOURS` hours (8 unless you changed it). It is not stored anywhere: copy it
from the terminal into Headlamp's login page, then clear the terminal. Whoever has the token can
read everything on the cluster except Secrets until it ends. Run the block again for a new one.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" create token headlamp --duration="${HEADLAMP_TOKEN_HOURS}h"
```

**Expect:** one long line of letters, digits, `.`, `-` and `_`, starting with `eyJ`.

**If not:** `serviceaccounts "headlamp" not found` — Headlamp is not installed in
`HEADLAMP_NAMESPACE`. `invalid duration` — `HEADLAMP_TOKEN_HOURS` is not a whole number.

### Open the page

This forwards a port on your machine to Headlamp, through your kubeconfig. Run it in a second
terminal and leave it running; press Ctrl+C to stop it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$GUEST_KUBECONFIG" -n "$HEADLAMP_NAMESPACE" port-forward service/headlamp "${HEADLAMP_LOCAL_PORT}:80"
```

**Expect:** `Forwarding from 127.0.0.1:8081 -> 4466`. Open `http://localhost:8081` in your
browser, paste the token into **ID token** and click **Authenticate**. The overview lists the
namespaces and workloads. Pages for things the read-only role does not cover (Secrets, nodes)
say that access is denied; that is the read-only role at work.

**If not:**
- `address already in use`: another program uses that port. Set `HEADLAMP_LOCAL_PORT` in the env
  file to a free one.
- The login page says the token is not valid: it ended, or it was copied with a line break.
  Make a new one.
- The page loads and stays empty: wait a few seconds; then check that the port-forward is still
  running.

The page is reachable only from your own machine while the port-forward runs. This chapter does
not give Headlamp an address of its own: a page that shows the whole cluster should not be
reachable by everyone who reaches the cluster's network.

### Uninstall Headlamp

This removes the helm release and then the namespace, only if this guide made the namespace.

```sh
source ~/.vks-golang-web.env
L="$(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}{"/"}{.metadata.labels.vks-golang-web/created-by}')" || L=unknown
if [ -z "$HEADLAMP_NAMESPACE" ]; then
  echo "Not removing: HEADLAMP_NAMESPACE is empty"
elif [ -z "$L" ]; then
  echo "Nothing to remove: the guest cluster has no namespace '${HEADLAMP_NAMESPACE}'"
elif [ "$L" != "${HEADLAMP_NAMESPACE}/headlamp-guide" ]; then
  echo "Not removing '${HEADLAMP_NAMESPACE}': this guide did not make that namespace, or it could not be read. Nothing was changed."
elif helm --kubeconfig "$GUEST_KUBECONFIG" --namespace "$HEADLAMP_NAMESPACE" uninstall headlamp --ignore-not-found --wait; then
  kubectl --kubeconfig "$GUEST_KUBECONFIG" delete namespace "$HEADLAMP_NAMESPACE" --ignore-not-found
  echo "left (nothing after the colon means gone): $(kubectl --kubeconfig "$GUEST_KUBECONFIG" get namespace "$HEADLAMP_NAMESPACE" --ignore-not-found -o name || echo unknown)"
else
  echo "Not removed: helm refused (see the error above), so the namespace is kept."
fi
```

**Expect:** `release "headlamp" uninstalled`, `namespace "headlamp" deleted` (it can take a
minute), then `left (nothing after the colon means gone):` with nothing after it. Tokens made
earlier stop working: their account is gone.

**If not:**
- `Not removing … this guide did not make that namespace`: the namespace does not carry this
  guide's mark. If it is yours, remove it the way it was made.
- `Not removed: helm refused`: the line above says why; `Kubernetes cluster unreachable` means
  this machine cannot reach the cluster.

## As a VKS add-on: not covered

VKS also offers Headlamp in its add-on catalogue. This chapter does not use it: installed by
itself the add-on does not start, because it needs the cert-manager add-on on the guest cluster
first (`Expected to find kind 'cert-manager.io/v1/Issuer', but did not`). Use one of the two ways
above.

## Fix common problems

| symptom | fix |
|---|---|
| The pod is rejected: `violates PodSecurity "restricted:latest"` | The chart was installed without this guide's values file. Run *Install Headlamp* from inside your clone. |
| Headlamp's page shows `Forbidden` on Secrets or nodes | The read-only role does not cover them. That is intended. |
| The token stopped working | It is valid for `HEADLAMP_TOKEN_HOURS` hours. Make a new one. |
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended. Run the main guide's *Renew the Supervisor login* block. |
| `helm: command not found` | *Check helm* says how to install it. Only this chapter needs it. |

## Next

Go back to [the add-ons overview](README.md) or to [the main guide](../README.md).
