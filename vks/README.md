# Deploy a containerized web app onto VMware VKS

Use this guide to run a modern containerized web app on VMware vSphere Kubernetes Service (VKS).
It takes one small working example, `golang-web`, to a running service on a VKS cluster (called
a *guest cluster* in these guides). It uses what your platform already has, and its chapters
create what is missing: a vSphere Namespace, a guest cluster, a Harbor registry, ArgoCD.

**What you do.** This guide is the main line: set up this machine, log in to the Supervisor,
check your vSphere Namespace and your guest cluster, deploy the app's published image and open
it. Each larger piece is a chapter of its own. A chapter starts from a place in this guide and
leads back to it; [Where to go next](#where-to-go-next) lists them all, in the order to use
them.

**How to use it.** Every part is a block of commands. Copy it, paste it into `bash` or `zsh` on
Linux or macOS, and run the blocks in order. Where a part offers choices, run only the one for
your setup. Each block is followed by **Expect:** — what you should see — and, where it can go
wrong, **If not:** — what to do. A block you run twice either changes nothing or tells you what
to do. [TROUBLESHOOTING.md](TROUBLESHOOTING.md) lists the errors by their text.

## Learn the terms

<details>
<summary><b>The terms these guides use, each in one line</b></summary>

| term | meaning |
|---|---|
| env file | `~/.vks-golang-web.env`, your settings, created in [Set the variables](#set-the-variables) |
| image | the packaged app, ready to run in a container |
| registry | a server that stores images |
| container engine | the program that builds, stores and pushes images (podman or docker) |
| tag | an image's name, such as `v0.0.3`; it can later be moved to another image |
| push | upload an image to a registry |
| Harbor | your company's private registry for container images |
| FQDN | a server's full DNS name, e.g. `harbor.example.test` |
| Harbor project | a folder in Harbor that holds images and has its own permissions; *private* (Harbor's default) or *public* |
| robot account | a Harbor login for scripts, limited to one project, that expires |
| CA (certificate authority) certificate | the file your tools use to confirm they talk to the real server; company servers use a private CA your machine does not trust yet |
| fingerprint | a short hash of a certificate, used to compare it with your administrator's copy |
| SSO user | your vCenter login, e.g. `administrator@vsphere.local` |
| vCenter CA | the certificate authority built into vCenter; it issued the Supervisor's certificate |
| Supervisor | the vSphere control plane you log in to, to reach your cluster |
| vSphere Namespace | your team's area on the Supervisor |
| namespace | a folder inside a Kubernetes cluster; the one the app is deployed into is not your vSphere Namespace |
| cluster | a group of machines that runs containers under Kubernetes |
| guest cluster | the Kubernetes cluster your app runs on |
| node | a machine in the cluster |
| pod | one running copy of the app |
| port-forward | a connection `kubectl` opens from a port on your machine to the app, through your kubeconfig |
| LoadBalancer address | an IP address the cluster gives the app so you can reach it from your machine |
| kubeconfig | the file `kubectl` reads to find a cluster and log in |
| context | a saved login inside a kubeconfig or the `vcf` tool |
| digest | an image's unique `sha256:…` ID; unlike a tag, it always names the same image |
| pull secret | your Harbor login, stored in the cluster, so it can download images from a private project |

</details>

## Gather what you need

Ask your platform administrator for what the table lists.

| you need | used in |
|---|---|
| Supervisor endpoint, vCenter DNS name, vSphere Namespace, guest cluster name | [Set the variables](#set-the-variables) |
| an SSO user with the **Edit** role on that vSphere Namespace, and its password | [Log in to the Supervisor](#log-in-to-the-supervisor) |
| the SHA-256 fingerprint of the vCenter CA | [Download and check the vCenter CA](#download-and-check-the-vcenter-ca) |
| a Broadcom support account that can download VMware vSphere Foundation 9 | [Install the VCF CLI and its plugins](SETUP.md#install-the-vcf-cli-and-its-plugins) |
| sudo rights on this machine | [Install the tools](#install-the-tools) |

What you were not given, you can make: a vSphere Namespace with [NAMESPACE.md](NAMESPACE.md)
and a guest cluster with [CLUSTER.md](CLUSTER.md). This guide tells you when to go there. You
need a Harbor registry only when you build the image yourself ([REGISTRY.md](REGISTRY.md)).

This machine must reach all of the above, and the internet: your package repositories,
github.com, raw.githubusercontent.com, dl.k8s.io and support.broadcom.com. The guest cluster's
nodes must reach ghcr.io, where the app's published image is.

## Set the variables

This block creates two files in your home directory, which every later block reads:

- `~/.vks-golang-web.env` (the *env file*) — your settings and passwords, readable only by you. If it already
  exists, it is kept as it is.
- `~/.vks-golang-web.functions` — the helper commands used later (`harbor_cfg`,
  `kubectl_install`, and five for vCenter's API: `vc_login`, `vc_api`, `vc`, `vc_cluster_id`,
  `vc_logout`). It is rewritten every time, so running the block again updates them and never
  changes your settings.

This is the one place where the env file is created. A chapter that needs more settings adds
them to this file itself, each only if it is not there yet.

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
export HARBOR_ADMIN_PASSWORD=''                  # Harbor's admin password, only if you have it
export REGISTRY_USERNAME=''                      # REGISTRY.md fills these two
export REGISTRY_TOKEN=''

export HARBOR_CA="$HOME/.config/vks-golang-web/harbor-ca.crt"
export SUPERVISOR_CA="$HOME/.config/vks-golang-web/vmca-root.pem"
export SUPERVISOR_KUBECONFIG="$HOME/.kube/supervisor.kubeconfig"
export GUEST_KUBECONFIG="$HOME/.kube/${VKS_CLUSTER}.kubeconfig"

export VC_SESSION="$HOME/.config/vks-golang-web/vc-session"   # where vc_login keeps its vCenter session
export KUBECTL_DIR="/usr/local/bin"              # where kubectl_install puts kubectl
export KUBECTL_MATCH="minor"                     # "exact": always install the cluster's own kubectl version

export KUBECONFIG="$GUEST_KUBECONFIG"
export VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION="v9.1.1"   # keeps vcf from trying to fetch a plugin Broadcom has not published

. "$HOME/.vks-golang-web.functions"
EOF
)
chmod 600 ~/.vks-golang-web.env
grep -qs vks-golang-web.functions ~/.vks-golang-web.env \
  || printf '\n. "$HOME/.vks-golang-web.functions"\n' >> ~/.vks-golang-web.env

cat >| ~/.vks-golang-web.functions <<'EOF'
# harbor_cfg [USER PASSWORD]: writes a curl config with a Harbor login to $CFG (default: admin),
# used as `curl -K "$CFG"` so that no password is on the command line.
harbor_cfg() {
  local u p
  if [ $# -ge 1 ]; then u="$1"; p="$2"; else u=admin; p="$HARBOR_ADMIN_PASSWORD"; fi
  [ -n "$u" ] && [ -n "$p" ] || { echo "harbor_cfg: empty user or password — fill the env file (REGISTRY.md, Log in to Harbor)" >&2; return 1; }
  u="${u//\\/\\\\}"; u="${u//\"/\\\"}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
  CFG="$(mktemp)"; ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$CFG" )
}

: "${VC_SESSION:=$HOME/.config/vks-golang-web/vc-session}"

# vc_login: opens ONE vCenter API session as SSO_USERNAME and saves its token in $VC_SESSION, as a
# curl config, so neither the password nor the token is on a command line. The file is made new
# each time (an older file would keep its permissions) and must hold a token to count.
vc_login() {
  local u="$SSO_USERNAME" p="$VCF_CLI_VSPHERE_PASSWORD" cfg
  if [ -z "$p" ] || [ "${p#<}" != "$p" ]; then
    echo "vc_login: set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first" >&2; return 1
  fi
  u="${u//\\/\\\\}"; u="${u//\"/\\\"}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
  vc_logout >/dev/null
  cfg="$(mktemp)" || return 1
  mkdir -p "$(dirname "$VC_SESSION")"
  rm -f "$VC_SESSION"
  ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$cfg" )
  ( umask 077; curl -fsS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$cfg" -X POST "https://${VCENTER_FQDN}/api/session" \
      | jq -r '"header = \"vmware-api-session-id: \(.)\""' > "$VC_SESSION" )
  rm -f "$cfg"
  if [ -f "$VC_SESSION" ] && [ ! -L "$VC_SESSION" ] && [ -O "$VC_SESSION" ] \
     && grep -q '^header = "vmware-api-session-id: [0-9A-Za-z-]\{16,\}"$' "$VC_SESSION"; then echo "vCenter session opened"; else
    rm -f "$VC_SESSION"; echo "vc_login: no session (see the curl error above) — do not retry a wrong password" >&2; return 1
  fi
}

# vc_api API-PATH [curl options]: one call to https://<vCenter>/api/vcenter<API-PATH> with the
# saved session.
vc_api() {
  local p="$1"; shift
  [ -s "$VC_SESSION" ] || { echo "vc_api: no vCenter session — run vc_login" >&2; return 1; }
  curl -sS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" "$@" \
    "https://${VCENTER_FQDN}/api/vcenter${p}"
}

# vc API-PATH [curl options]: the same, for vCenter's Supervisor API (paths under
# /api/vcenter/namespace-management).
vc() {
  local p="$1"; shift
  vc_api "/namespace-management${p}" "$@"
}

# vc_cluster_id: prints the ID of the vSphere cluster the Supervisor runs on: VSPHERE_CLUSTER_ID
# when it is set, otherwise the only cluster vCenter has; nothing when there are several.
vc_cluster_id() {
  if [ -n "$VSPHERE_CLUSTER_ID" ]; then printf '%s\n' "$VSPHERE_CLUSTER_ID"; return 0; fi
  vc_api /cluster | jq -r 'if type == "array" and length == 1 then .[0].cluster else empty end'
}

# vc_logout: ends the vCenter session and deletes its file.
vc_logout() {
  [ -s "$VC_SESSION" ] || return 0
  curl -sS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" -X DELETE "https://${VCENTER_FQDN}/api/session"
  rm -f "$VC_SESSION"; echo "vCenter session closed"
}

# kubectl_install VERSION: installs upstream kubectl VERSION from dl.k8s.io into $KUBECTL_DIR
# (a "+vmware.N" suffix is dropped; if that exact patch has no upstream build, the newest patch of
# the same minor is used). It changes nothing when the kubectl you have is within one minor
# version of VERSION, unless KUBECTL_MATCH is "exact". It never asks for a password: when
# $KUBECTL_DIR needs administrator rights and sudo would ask, it installs into ~/.local/bin and
# says so. The checksum guards against a corrupt download. On any failure the existing kubectl
# is left as it was.
kubectl_install() {
  local v="${1%%+*}" m os arch u t h d="${KUBECTL_DIR:-/usr/local/bin}" s="" cur x cm sm
  case "$v" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "kubectl_install: no version ('$1') — not logged in, or the server unreachable?" >&2; return 1 ;; esac
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "kubectl_install: unsupported OS $(uname -s)" >&2; return 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "kubectl_install: unsupported CPU $(uname -m)" >&2; return 1 ;; esac
  cur="$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version: \(v[0-9][0-9.]*\).*/\1/p')"
  if [ -n "$cur" ] && [ "${KUBECTL_MATCH:-minor}" != exact ]; then
    x="${cur#v*.}"; cm="${x%%.*}"; x="${v#v*.}"; sm="${x%%.*}"
    case "${cm}${sm}" in
      *[!0-9]*) ;;
      *) if [ "${cur%%.*}" = "${v%%.*}" ] && [ "$((cm - sm))" -ge -1 ] && [ "$((cm - sm))" -le 1 ]; then
           echo "kubectl ${cur} is within one minor version of ${v}: supported, not changed (set KUBECTL_MATCH=\"exact\" in the env file to install ${v})"
           return 0
         fi ;;
    esac
  fi
  if ! curl -fsIL --connect-timeout 10 --retry 3 -o /dev/null "https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"; then
    m="${v#v}"; m="${m%.*}"
    v="$(curl -fsSL --connect-timeout 10 --retry 3 "https://dl.k8s.io/release/stable-${m}.txt")" \
      || { echo "kubectl_install: cannot reach dl.k8s.io (blocked or offline?) — kubectl NOT changed" >&2; return 1; }
    echo "note: no upstream kubectl ${1%%+*}; using ${v}, the newest of that minor" >&2
  fi
  u="https://dl.k8s.io/release/${v}/bin/${os}/${arch}/kubectl"
  t="$(mktemp -d)" || return 1
  if ! curl -fsSL --connect-timeout 10 --retry 3 -o "$t/kubectl" "$u" \
     || ! h="$(curl -fsSL --connect-timeout 10 --retry 3 "${u}.sha256")" || [ -z "$h" ]; then
    rm -rf "$t"; echo "kubectl_install: cannot reach dl.k8s.io: the download failed (${u}) — kubectl NOT changed" >&2; return 1
  fi
  if [ "$( (sha256sum "$t/kubectl" 2>/dev/null || shasum -a 256 "$t/kubectl") | awk '{print $1}')" != "$h" ]; then
    rm -rf "$t"; echo "kubectl_install: the checksum of the download does not match (${u}) — kubectl NOT changed" >&2; return 1
  fi
  if [ -d "$d" ] && [ -w "$d" ]; then s=""
  elif [ ! -e "$d" ] && mkdir -p "$d" 2>/dev/null; then s=""
  elif sudo -n true 2>/dev/null; then s=sudo
  else
    echo "kubectl_install: ${d} needs administrator rights and sudo would ask for a password: installing into ${HOME}/.local/bin instead (to use ${d}: run 'sudo -v', then this block again)" >&2
    d="${HOME}/.local/bin"; mkdir -p "$d"
  fi
  if { [ -n "$s" ] && sudo -n install -d "$d" && sudo -n install -m 0755 "$t/kubectl" "$d/kubectl"; } \
     || { [ -z "$s" ] && install -m 0755 "$t/kubectl" "$d/kubectl"; }; then
    rm -rf "$t"; "$d/kubectl" version --client
    case ":${PATH}:" in
      *":${d}:"*) ;;
      *) PATH="${d}:${PATH}"; hash -r 2>/dev/null
         echo "kubectl_install: ${d} was not on your PATH: added for this terminal only. To keep it, add the next line to ~/.zshrc (zsh) or ~/.bashrc (bash), then open a new terminal:" >&2
         echo "  export PATH=\"${d}:\$PATH\"" >&2 ;;
    esac
    hash -r 2>/dev/null
    [ "$(command -v kubectl)" = "$d/kubectl" ] \
      || echo "WARNING: 'kubectl' on your PATH is '$(command -v kubectl || echo not found)', not $d/kubectl" >&2
  else
    rm -rf "$t"; echo "kubectl_install: could not write ${d}/kubectl (see the error above) — kubectl NOT changed" >&2; return 1
  fi
}
EOF
```

**Expect:** no output the first time. If the env file already exists, bash prints
`cannot overwrite existing file` and zsh prints `file exists`: that is fine, your earlier values
are kept.

Open the env file and replace each example value with what your administrator gave you. Put
passwords in **single quotes** (a `'` inside one is written `'\''`). If you have no vSphere
Namespace or no guest cluster yet, write the names you will give them. The Harbor lines matter
only when you build the image yourself: leave them as they are until
[REGISTRY.md](REGISTRY.md) asks for them.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

In nano: Ctrl+O, then Enter, saves; Ctrl+X exits. Do not edit the file in TextEdit (macOS): it
turns `'` into curly quotes, which breaks every password.

Load the settings into this terminal. Do this in every new terminal; the blocks below also do it.

```sh
source ~/.vks-golang-web.env
```

**Expect:** no output. **If not:** `No such file or directory` means the first block did not run.

## Install the tools

This guide needs `kubectl` to talk to Kubernetes, VMware's `vcf` tool to log in to the
Supervisor, and the small helpers `curl`, `unzip`, `openssl`, `jq` and `git`.
[SETUP.md](SETUP.md) installs them on macOS and on Debian or Ubuntu, one block per tool. Skip
any tool you already have. Do these parts of it, in this order:

1. [Install Homebrew (macOS only)](SETUP.md#install-homebrew-macos-only)
2. [Install jq and the other command-line tools](SETUP.md#install-jq-and-the-other-command-line-tools)
3. [Install kubectl](SETUP.md#install-kubectl)
4. [Install the VCF CLI and its plugins](SETUP.md#install-the-vcf-cli-and-its-plugins)

SETUP.md also has the tools only some chapters need: a container engine, `envsubst`, `helm` and
a clipboard program. Each of those chapters sends you there.

Then check, here. This lists any tool this guide needs that is still missing and prints the
versions of `kubectl` and `vcf`.

```sh
for t in curl unzip openssl jq git kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
kubectl version --client
vcf version | head -1
```

**Expect:** no `MISSING` line, then kubectl's `Client Version:` (and a `Kustomize Version` line),
and `version: v9.…`.

**If not:** do the part of [SETUP.md](SETUP.md) for each `MISSING` tool.

## Check out the repo

This downloads the repo into a new `golang-web` directory here. It holds the app's Kubernetes
description (`k8s/golang-web.yaml`), which this guide deploys, the files the chapters fill in
(`vks/templates`), and the app's source code. If you already have a clone, `cd` into it instead.

```sh
git clone https://github.com/AndriyKalashnykov/golang-web.git
cd golang-web
```

**Expect:** `Cloning into 'golang-web'...`. Run everything below from this directory: in every
new terminal, `cd` back into it first.

## Download and check the vCenter CA

The Supervisor's HTTPS certificate is issued by vCenter's own CA, which your machine does not
trust yet. This block downloads that CA from vCenter and saves it as `$SUPERVISOR_CA`. The
alternative under [Log in to the Supervisor](#log-in-to-the-supervisor) uses it so `vcf` can
confirm it is talking to your real Supervisor, and the chapters that call vCenter (the
namespace, Harbor and ArgoCD chapters) use it for vCenter. The download itself cannot be
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

**Expect:** a `subject=` line naming `CA` and `vsphere`, then `sha256 Fingerprint=…`
(`SHA256 Fingerprint=` on macOS). Compare its hex digits with your administrator's, ignoring
colons and upper/lower case.

**If not:**
- **A different fingerprint:** do not continue. Check `VCENTER_FQDN` in the env file. Then send
  the fingerprint you got to your administrator and ask them to confirm it or to send you the CA
  file (if vCenter has several CAs, the block shows only the first). A company proxy that
  replaces HTTPS certificates also causes this.
- **A `curl:` error** (for example `Could not resolve host`), then `unzip`, `openssl` or (zsh)
  `no matches found` errors: the
  download failed. Check `VCENTER_FQDN` and that you can reach vCenter.

## Log in to the Supervisor

Check the password in the env file first: **five failed logins within 3 minutes lock the SSO
user for 5 minutes** (vCenter's default policy; yours may be stricter).

This login does not check the Supervisor's certificate (`--insecure-skip-tls-verify`), and `vcf`
saves that choice for every later `kubectl` call to the Supervisor. On a network you do not
control, someone between you and the Supervisor could capture your SSO password; VMware's own
documentation does not recommend the flag. To have the certificate checked, use the alternative
below instead of this block.

```sh
source ~/.vks-golang-web.env
if [ -z "$VCF_CLI_VSPHERE_PASSWORD" ] || [ "${VCF_CLI_VSPHERE_PASSWORD#<}" != "$VCF_CLI_VSPHERE_PASSWORD" ]; then
  echo "Set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first (vcf reads the password from it)"
else
  KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
    vcf context create supervisor --type k8s \
      --endpoint "https://${SUPERVISOR_ENDPOINT}" \
      --username "$SSO_USERNAME" \
      --insecure-skip-tls-verify --auth-type basic
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" config use-context supervisor
fi
```

**Expect:** `Logged in successfully`, a list of saved contexts, then `Switched to context "supervisor"`.

**If not:**
- `context "supervisor" already exists`: run the [Delete the Supervisor login](#delete-the-supervisor-login)
  block, then this one again.
- A connection error: check `SUPERVISOR_ENDPOINT`.
- A login error: check `SSO_USERNAME` and `VCF_CLI_VSPHERE_PASSWORD` (in single quotes).

<details>
<summary><b>Alternative: log in and check the Supervisor's certificate</b> (uses the vCenter CA you downloaded)</summary>

Run this INSTEAD of the block above. `vcf` checks the Supervisor's certificate against the CA you
downloaded and compared under *Download and check the vCenter CA*, and refuses to send your
password to anything else.

```sh
source ~/.vks-golang-web.env
if [ -z "$VCF_CLI_VSPHERE_PASSWORD" ] || [ "${VCF_CLI_VSPHERE_PASSWORD#<}" != "$VCF_CLI_VSPHERE_PASSWORD" ]; then
  echo "Set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first (vcf reads the password from it)"
else
  KUBECONFIG="$SUPERVISOR_KUBECONFIG" \
    vcf context create supervisor --type k8s \
      --endpoint "https://${SUPERVISOR_ENDPOINT}" \
      --username "$SSO_USERNAME" \
      --ca-certificate "$SUPERVISOR_CA" --auth-type basic
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" config use-context supervisor
fi
```

**Expect:** the same three things as above.

**If not:** a certificate error — check `SUPERVISOR_ENDPOINT` and the vCenter CA file. The three
lines under the block above apply here too.

When this login ends, renew it with this block, NOT the one under *Renew the Supervisor login*
(that one would switch this login to skipping the check, without saying so):

```sh
source ~/.vks-golang-web.env
if [ -z "$VCF_CLI_VSPHERE_PASSWORD" ] || [ "${VCF_CLI_VSPHERE_PASSWORD#<}" != "$VCF_CLI_VSPHERE_PASSWORD" ]; then
  echo "Set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first (vcf reads the password from it)"
else
  KUBECONFIG="$SUPERVISOR_KUBECONFIG" vcf context refresh supervisor --ca-certificate "$SUPERVISOR_CA"
fi
```

</details>

This guide logs in with the SSO user and a password; `--auth-type basic` asks for exactly that.
Broadcom documents the flag for a Supervisor that otherwise opens a web-page login (KB 417617);
this guide does not cover such a Supervisor. If the password login fails because your account exists only
in an external identity provider (such as Okta or Entra ID), that is out of scope: ask your
administrator for another way to get the guest cluster's kubeconfig, save it
with `source ~/.vks-golang-web.env; mkdir -p ~/.kube; cp <file> "$GUEST_KUBECONFIG"`, run
`kubectl_install "$(kubectl version -o json | jq -r .serverVersion.gitVersion)"`,
then continue at [Check the guest cluster](#check-the-guest-cluster).

### Renew the Supervisor login

Skip this the first time through. **If you logged in with the alternative (certificate
checked), do NOT run this block: use the renew block inside that alternative.** This one would
switch your login to skipping the check, without saying so.

The login lasts about 10 hours. You need this block only when a `kubectl` command to the
Supervisor answers `error: You must be logged in to the server (Unauthorized)`; while the login
is still valid it changes nothing, so there is no reason to run it before or after other blocks.
It logs in again with the password in the env file, so the lock-out rule above applies.

```sh
source ~/.vks-golang-web.env
if [ -z "$VCF_CLI_VSPHERE_PASSWORD" ] || [ "${VCF_CLI_VSPHERE_PASSWORD#<}" != "$VCF_CLI_VSPHERE_PASSWORD" ]; then
  echo "Set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first (vcf reads the password from it)"
else
  KUBECONFIG="$SUPERVISOR_KUBECONFIG" vcf context refresh supervisor --insecure-skip-tls-verify
fi
```

**Expect:** `Successful re-authentication completed for context "supervisor"`, or `Token is still
active. Skipped the token refresh for context "supervisor"` when the login had not ended. Then
run the command that answered `Unauthorized` again. If you saw `Token is still active` and the
command still answers `Unauthorized`, the login is not the cause: check that the command uses
`--kubeconfig "$SUPERVISOR_KUBECONFIG"`.

**If not:**
- `context supervisor not found`: you have no saved login; log in with the block above.
- A login error: check `SSO_USERNAME` and `VCF_CLI_VSPHERE_PASSWORD` (in single quotes).

## Check your vSphere Namespace

A guest cluster lives in a vSphere Namespace, your team's area on the Supervisor. This checks
that your SSO user can see yours:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** your vSphere Namespace, `Active`. If your guest cluster exists, go on with the next
section. If you still have to create it, first run the two blocks under
[Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have): they prove that the
namespace can hold a cluster.

**If not:**
- `NotFound`: check `VKS_NAMESPACE`. If you have no vSphere Namespace yet, get one with
  [Use or create a vSphere Namespace](NAMESPACE.md), then run this block again.
- `Forbidden`: ask your administrator for the **Edit** role on it.
- `Unauthorized` or a login prompt: the login ended or did not work. Run
  [Renew the Supervisor login](#renew-the-supervisor-login), then this check again.

## Get your guest cluster

The app runs on a guest cluster in your vSphere Namespace.

- **You have one:** `VKS_CLUSTER` in the env file is its name. Run the two blocks below.
- **You have none:** create it with [Create a guest cluster with kubectl](CLUSTER.md), or let
  ArgoCD create it ([ARGOCD.md](ARGOCD.md)). The cluster chapter saves the kubeconfig and
  checks the cluster itself, so afterwards continue at [Deploy the app](#deploy-the-app). If
  you will also install Harbor on this Supervisor, do that first ([HARBOR.md](HARBOR.md)): an
  install replaces the nodes of every cluster.

### Get the guest cluster's kubeconfig

This reads the guest cluster's kubeconfig from the Supervisor, saves it as `$GUEST_KUBECONFIG`
(the env file already points `kubectl` there), and compares your kubectl with the guest cluster's
version: kubectl must be within one minor version of the cluster it manages. Within that it
changes nothing; otherwise it installs the cluster's version, the way
[Install kubectl](SETUP.md#install-kubectl) did, without asking for a password. To always get
the cluster's exact version, set `KUBECTL_MATCH="exact"` in the env file.

```sh
source ~/.vks-golang-web.env
( umask 077
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" \
    get secret "${VKS_CLUSTER}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "${GUEST_KUBECONFIG}.new" )
if [ -s "${GUEST_KUBECONFIG}.new" ]; then
  mv "${GUEST_KUBECONFIG}.new" "$GUEST_KUBECONFIG"
else
  rm -f "${GUEST_KUBECONFIG}.new"; echo "No kubeconfig read (see the error above): ${GUEST_KUBECONFIG} is as it was"
fi
V="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')"
echo "Guest cluster: ${V:-unknown}"
kubectl_install "$V"
```

**Expect:** `Guest cluster: v1.<minor>…`, then
`kubectl v1.… is within one minor version of v1.…: supported, not changed`, or, when kubectl was
further away, `Client Version:` with the cluster's `v1.<minor>`.

**If not:** `No kubeconfig read …`, under a `kubectl` error: `secrets "<name>-kubeconfig" not
found` — check `VKS_CLUSTER`; `Forbidden` — the **Edit** role is missing; `Unauthorized` — run
[Renew the Supervisor login](#renew-the-supervisor-login). A kubeconfig you saved earlier is
kept. With none, `Guest cluster: unknown` and `kubectl_install: no version` follow: fix the cause
and run the block again. For any other `kubectl_install:` line, see the list under
[Install kubectl](SETUP.md#install-kubectl); the kubeconfig itself is saved either way.

### Check the guest cluster

This confirms that kubectl now reaches the guest cluster, and shows its version beside the
cluster's.

```sh
source ~/.vks-golang-web.env
kubectl get nodes
kubectl version -o json | jq -r '"client \(.clientVersion.gitVersion)  server \(.serverVersion.gitVersion)"'
```

**Expect:** every node `Ready`, and client and server at most one minor version apart (e.g. `v1.37.1` and `v1.36.2+vmware.2`).
From here on, kubectl talks to the guest cluster; the Supervisor is reached only with
`--kubeconfig "$SUPERVISOR_KUBECONFIG"` and through `vcf`.

**If not:** a node `NotReady` is a cluster problem: tell your administrator.

## Deploy the app

This deploys the image the project publishes at ghcr.io, as `k8s/golang-web.yaml` in your clone
names it: by tag and digest. A tag can later point to another image; a digest cannot. The image
is public, so the cluster needs no login to download it. Two other ways to deploy are chapters
of their own: an image you build yourself and push to Harbor ([REGISTRY.md](REGISTRY.md)), and
an ArgoCD Application ([ARGOCD.md](ARGOCD.md) installs ArgoCD).

### Create the app's namespace

This creates a Kubernetes namespace called `golang-web` in the guest cluster, to hold the app, and
makes it the default for the commands below. (It is not your vSphere Namespace.)

```sh
source ~/.vks-golang-web.env
kubectl create namespace golang-web --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=golang-web
```

**Expect:** `namespace/golang-web created` (or `unchanged`), then `Context "…" modified.`

### Deploy the published image

By default the app gets no address of its own. Its Service is made as type `ClusterIP`, which
only the cluster reaches, and you open the app through `kubectl port-forward`, because the
published image (version 0.0.4) exits when anyone who can reach it requests its `/shutdown`
path.

This writes `ClusterIP` in place of `LoadBalancer` in the Service of `k8s/golang-web.yaml`
(only for this command; the file is not changed), applies it, waits up to 150 seconds for the
app to start, and prints the Service's type.

```sh
source ~/.vks-golang-web.env
sed 's|^  type: LoadBalancer$|  type: ClusterIP|' k8s/golang-web.yaml | kubectl apply -f - && \
  kubectl rollout status deploy/golang-web --timeout=150s
kubectl get svc golang-web-service -o jsonpath='{"service type: "}{.spec.type}{"\n"}'
```

**Expect:** `deployment.apps/golang-web created` and `service/golang-web-service created`
(`unchanged` or `configured` when run again), then `successfully rolled out`, then
`service type: ClusterIP`.

**If not:**
- `k8s/golang-web.yaml: No such file or directory`: this terminal is not in the clone. `cd` into
  it ([Check out the repo](#check-out-the-repo)).
- The wait times out: run `kubectl describe pod -l app=golang-web`, read the `Events` at the
  bottom, and look the message up in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- `service type: LoadBalancer`: the Service line in your copy of `k8s/golang-web.yaml` differs
  from the one this block looks for. Run `git pull`, then the block again.

<details>
<summary><b>Alternative: give the app a LoadBalancer address</b> (only on a network where everyone who reaches the address may stop the app)</summary>

Run this INSTEAD of the block above, or after it to change your choice. It applies
`k8s/golang-web.yaml` as it is: the Service is of type `LoadBalancer`, and the cluster gives the
app an IP address that your machine, and everything else on that network, can reach.
**Anyone who can reach that address can stop the app** by requesting `/shutdown`; Kubernetes
starts it again each time. This warning ends with the first published image that has the
`/shutdown` path switched off.

```sh
source ~/.vks-golang-web.env
kubectl apply -f k8s/golang-web.yaml && \
  kubectl rollout status deploy/golang-web --timeout=150s
kubectl get svc golang-web-service -o jsonpath='{"service type: "}{.spec.type}{"\n"}'
```

**Expect:** the `deployment.apps/golang-web` and `service/golang-web-service` lines, then
`successfully rolled out`, then `service type: LoadBalancer`. To go back, run the block above
again: it prints `service type: ClusterIP`, and the address is given back.

</details>

Check that the running app uses exactly the published image:

```sh
source ~/.vks-golang-web.env
kubectl get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,IMAGEID:.status.containerStatuses[0].imageID'
```

**Expect:** `Running`, and `IMAGEID` ending with the `sha256:…` digest of the `image:` line in
`k8s/golang-web.yaml`. **If not:** an old pod may still be listed; wait a few seconds and run it
again.

## Reach the app

### Reach the app through a port-forward

This forwards port 8080 on your machine to the app, through your kubeconfig. It works with
either Service type. Run it in a second terminal, from inside the clone, and leave it running;
press Ctrl+C to stop it.

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

**Expect:** `Hello, World` and the pod's details. (`/` alone returns 404; that is expected.)

### Reach the app through its LoadBalancer address

Only if the Service is of type `LoadBalancer`: you ran the alternative under
[Deploy the published image](#deploy-the-published-image), or you deployed with
[REGISTRY.md](REGISTRY.md). This waits for the cluster to give the app an external IP address
(a *LoadBalancer* address), then calls the app.

```sh
source ~/.vks-golang-web.env
kubectl wait svc/golang-web-service --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=120s
export APP_IP="$(kubectl get svc golang-web-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "http://${APP_IP}:8080/myhello/"
curl -sS --max-time 10 "http://${APP_IP}:8080/myhello/"
```

**Expect:** `service/golang-web-service condition met`, the URL, then `Hello, World` and the pod's
details. (`/` alone returns 404; that is expected.)

**If not:** a timeout on the wait (no external IP: with a `ClusterIP` Service there never is
one) or on `curl` (the address is not reachable from your machine): use the port-forward above
instead.

## Clean up

Both blocks are optional. They remove the app and your Supervisor login.
[CLEANUP.md](CLEANUP.md) removes everything else these guides put on this machine and in
Harbor; if you want that too, run these two first: its last blocks delete the clone and the env
file, which the others need.

### Delete the app

This deletes the app, with everything in its namespace (the pull secret too).

```sh
source ~/.vks-golang-web.env
kubectl delete namespace golang-web --ignore-not-found=true
```

**Expect:** `namespace "golang-web" deleted` (it can take a minute).

### Delete the Supervisor login

This removes the Supervisor login `vcf` saved, and `vcf`'s log files (they hold a
copy of the login token, which stays valid until its 10 hours are over).

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

## Where to go next

The chapters, in the order to use them. Each says what it needs and where it leads back to.

1. [SETUP.md](SETUP.md): install the tools, on macOS and on Debian or Ubuntu. Comes after
   [Set the variables](#set-the-variables).
2. [NAMESPACE.md](NAMESPACE.md): use or create a vSphere Namespace. Comes after
   [Log in to the Supervisor](#log-in-to-the-supervisor), as do chapters 3, 4 and 7.
3. [HARBOR.md](HARBOR.md): use the Harbor you have, or install one on the Supervisor. If you
   install one, do it before chapter 4 where you can: an install replaces the nodes of every
   cluster.
4. [CLUSTER.md](CLUSTER.md): create a guest cluster with kubectl.
5. [Deploy the app](#deploy-the-app), on this page: run the published image on your cluster and
   reach it.
6. [REGISTRY.md](REGISTRY.md): build the image yourself, push it to Harbor and run that one.
7. [ARGOCD.md](ARGOCD.md): install ArgoCD on the Supervisor and create a guest cluster with
   it, [by hand](ARGOCD-manual.md) in the vSphere Client and the ArgoCD web page, or
   [with scripts](ARGOCD-auto.md).
8. [ARGOCD-app.md](ARGOCD-app.md): deploy the app as an ArgoCD Application.
9. [addons/README.md](addons/README.md): add-ons for the guest cluster,
   [cert-manager](addons/CERT-MANAGER.md), [Istio](addons/ISTIO.md) and [Headlamp](addons/HEADLAMP.md).
10. [CLEANUP.md](CLEANUP.md): remove what these guides created.
11. [TROUBLESHOOTING.md](TROUBLESHOOTING.md): errors by their text, with the fix for each.
