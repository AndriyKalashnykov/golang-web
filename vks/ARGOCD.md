# Install ArgoCD on your Supervisor and create a VKS guest cluster with it

This guide installs the ArgoCD Supervisor Service on a vSphere Supervisor, starts an ArgoCD
*instance* in your vSphere Namespace, and uses that ArgoCD to create a Kubernetes cluster (a *VKS
guest cluster*) from a file in Git. It has 9 steps; step 9 is optional clean-up. It was written
for VMware Cloud Foundation 9.1.1, ArgoCD Service 1.2.0 and VKS 3.7.

It continues [the main guide](README.md) and uses its env file, its tools and its Supervisor
login. Run the blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each
block is followed by **Expect:** — what you should see — and, where it can go wrong, **If not:**
— what to do. A block you run twice either changes nothing or tells you what to do.

## Learn the terms

The main guide's [terms](README.md#learn-the-terms) apply. New here:

| term | meaning |
|---|---|
| Supervisor Service | an add-on a vCenter administrator installs on a Supervisor |
| ArgoCD Service | the Supervisor Service that lets a vSphere Namespace run ArgoCD |
| ArgoCD instance | one running ArgoCD, with its own web page and login, inside a vSphere Namespace |
| service manifest | the `.yml` file from Broadcom that describes the ArgoCD Service to vCenter |
| Application | ArgoCD's record of "keep what is in this Git folder applied to that destination" |
| destination | a place ArgoCD may apply things to: here your vSphere Namespace, later a guest cluster |
| project | an ArgoCD rule set: which Git repositories, destinations and kinds of object an Application may use |
| sync | ArgoCD applying what is in Git |
| chart | a Helm template; here one file that describes a guest cluster, with four values you set |
| VM class | a virtual machine size your vSphere Namespace may use |
| storage class | a kind of disk your vSphere Namespace may use |

## Gather what you need

- Steps 1, 2 and 7 of [the main guide](README.md) done on this machine (step 1 below checks it).
  You need no container engine and no Harbor for this guide.
- An SSO user with the **Edit** role on your vSphere Namespace (the main guide's user).
- For step 4 only: an SSO user with the vCenter privilege **Manage Supervisor Services**. If
  yours lacks it, ask your vCenter administrator to do step 4; its second half shows the clicks.
- A Broadcom support account that can download **vSphere Supervisor Services** (step 2).
- The Supervisor must reach `projects.packages.broadcom.com` (it downloads ArgoCD from there)
  and `github.com` (ArgoCD reads the cluster's description from there).
- Room in your vSphere Namespace for three more virtual machines (step 7 creates them).
- An Intel/AMD Linux machine, or a Mac. Broadcom publishes no `argocd` program for arm64 Linux.

## 1. Check the main guide's steps

This confirms the tools, the vCenter CA file and the Supervisor login from the main guide.

```sh
source ~/.vks-golang-web.env
for t in curl openssl jq kubectl vcf; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
[ -s "$SUPERVISOR_CA" ] || echo "MISSING: the vCenter CA file (main guide, step 2)"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
```

**Expect:** no `MISSING` line, then your vSphere Namespace, `Active`.

**If not:** do the main guide's step for each `MISSING` line. `Unauthorized`, or a kubeconfig
that is not found: run the main guide's step 7, *Log in to the Supervisor* (a login lasts about
10 hours).

Create this guide's two files. `~/.vks-argocd.env` holds its settings and is kept if it already
exists; `~/.vks-argocd.functions` holds five helper commands and is rewritten every time.

```sh
( umask 077; set -C; cat > ~/.vks-argocd.env <<'EOF'
export ARGOCD_MANIFEST="$HOME/Downloads/supervisor-service-argocd-legacy-1.2.0-25642124.yml"
export ARGOCD_NAME="argocd-1"                    # the NAME of your ArgoCD instance
export NEW_CLUSTER="my-new-cluster"              # the NAME of the guest cluster step 7 creates
export K8S_VERSION=""                            # step 7 fills these three
export VM_CLASS=""
export STORAGE_CLASS=""
export CLUSTER_CLASS="builtin-generic-v3.7.0"

export CLUSTER_REPO="https://github.com/AndriyKalashnykov/golang-web.git"
export CLUSTER_REVISION="e236f5c43aa2a1c7a9cc84e7f3cbdbc7024942d6"

export VC_SESSION="$HOME/.config/vks-golang-web/vc-session"

. "$HOME/.vks-golang-web.env"
. "$HOME/.vks-argocd.functions"
EOF
)
chmod 600 ~/.vks-argocd.env

cat >| ~/.vks-argocd.functions <<'EOF'
# sk ARGS: kubectl on the Supervisor, in your vSphere Namespace.
sk() { kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" "$@"; }

# vc_login: opens ONE vCenter API session as SSO_USERNAME and saves its token in $VC_SESSION, as a
# curl config, so neither the password nor the token is on a command line.
vc_login() {
  local u="$SSO_USERNAME" p="$VCF_CLI_VSPHERE_PASSWORD" cfg
  if [ -z "$p" ] || [ "${p#<}" != "$p" ]; then
    echo "vc_login: set VCF_CLI_VSPHERE_PASSWORD in ~/.vks-golang-web.env first" >&2; return 1
  fi
  u="${u//\\/\\\\}"; u="${u//\"/\\\"}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
  vc_logout
  cfg="$(mktemp)" || return 1
  mkdir -p "$(dirname "$VC_SESSION")"
  ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$cfg" )
  ( umask 077; curl -fsS --cacert "$SUPERVISOR_CA" -K "$cfg" -X POST "https://${VCENTER_FQDN}/api/session" \
      | jq -r '"header = \"vmware-api-session-id: \(.)\""' > "$VC_SESSION" )
  rm -f "$cfg"
  if [ -s "$VC_SESSION" ]; then echo "vCenter session opened"; else
    rm -f "$VC_SESSION"; echo "vc_login: no session (see the curl error above) — do not retry a wrong password" >&2; return 1
  fi
}

# vc API-PATH [curl options]: one call to vCenter's Supervisor API with the saved session.
vc() {
  local p="$1"; shift
  [ -s "$VC_SESSION" ] || { echo "vc: no vCenter session — run vc_login" >&2; return 1; }
  curl -sS --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" "$@" \
    "https://${VCENTER_FQDN}/api/vcenter/namespace-management${p}"
}

# vc_logout: ends the vCenter session and deletes its file.
vc_logout() {
  [ -s "$VC_SESSION" ] || return 0
  curl -sS --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" -X DELETE "https://${VCENTER_FQDN}/api/session"
  rm -f "$VC_SESSION"; echo "vCenter session closed"
}

# argocd_session: logs this terminal's `argocd` in to your instance as admin. It reads the
# address, the admin password and ArgoCD's certificate from the Supervisor, sends the password
# only to a server that holds that certificate's key, and sets ARGOCD_SERVER / ARGOCD_AUTH_TOKEN /
# ARGOCD_OPTS.
argocd_session() {
  local ip crt pin body tok
  unset ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_OPTS
  ip="$(sk get argocd "$ARGOCD_NAME" -o jsonpath='{.status.externalIP}' 2>/dev/null)"
  [ -n "$ip" ] || { echo "argocd_session: instance '$ARGOCD_NAME' has no address yet (step 5), or the Supervisor login ended" >&2; return 1; }
  crt="$(sk get secret argocd-secret -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  [ -n "$crt" ] || { echo "argocd_session: cannot read ArgoCD's certificate from the Supervisor" >&2; return 1; }
  pin="$(printf '%s\n' "$crt" | openssl x509 -noout -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
  body="$(mktemp)" || return 1
  ( umask 077; P="$(sk get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
      jq -n '{username: "admin", password: env.P}' > "$body" )
  tok="$(curl -sSk --pinnedpubkey "sha256//${pin}" -H 'Content-Type: application/json' --data-binary "@${body}" \
      "https://${ip}/api/v1/session" | jq -r '.token // empty')"
  rm -f "$body"
  [ -n "$tok" ] || { echo "argocd_session: no login — a 'curl: (90)' line above means ${ip} does not hold ArgoCD's key; otherwise ArgoCD refused the password" >&2; return 1; }
  export ARGOCD_SERVER="$ip" ARGOCD_AUTH_TOKEN="$tok" ARGOCD_OPTS="--insecure"
  echo "argocd: logged in to https://${ip} as admin"
}
EOF
```

**Expect:** no output the first time. If the env file already exists, bash prints
`cannot overwrite existing file` and zsh prints `file exists`: that is fine, your earlier values
are kept.

## 2. Download the ArgoCD files

Download two files from Broadcom: the service manifest and the `argocd` program for this machine.
Tick **"I agree to the Terms and Conditions"** if the page shows it, or the download icon does
nothing.

| file | where to click | direct link |
|---|---|---|
| `supervisor-service-argocd-legacy-1.2.0-25642124.yml` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → search **vSphere Supervisor Services** → **ArgoCD Service** → 1.2.0 → *Installation Package Manifest (VCF 9.0 or older and disconnected/airgapped VCF 9.1)* | [ArgoCD Service 1.2.0](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.2.0&os=&servicePk=546088&language=EN) |
| `argocd-cli-linux-amd64-v3.4.4-vcf.gz` (Linux) or `argocd-cli-darwin-amd64-v3.4.4-vcf.gz` (macOS) | the same page → *ArgoCD Linux CLI* or *ArgoCD Mac CLI* | the same link |

- Take the manifest with **legacy** in its name. The page offers a second one without it,
  labelled *Internet Connected VCF 9.1 and newer*. The two differ in one line: the legacy file
  downloads ArgoCD from `projects.packages.broadcom.com`, the other from a VCF Software Depot
  inside your environment. This guide was tested with the legacy file, on VCF 9.1.1 with internet
  access and no Software Depot. The other file is untested here.
- The page has no separate configuration file: the service needs none.
- The Mac program is built for Intel. On a Mac with Apple silicon it runs through Rosetta
  (step 3 says what to do if Rosetta is missing).

This block finds the two files in `~/Downloads` and prints their checksums. If you saved them
elsewhere, change `ARGOCD_MANIFEST` in `~/.vks-argocd.env` and the folder below.

```sh
source ~/.vks-argocd.env
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)               P=linux-amd64 ;;
  Darwin/x86_64|Darwin/arm64) P=darwin-amd64 ;;
  *)                          P=unsupported ;;
esac
ARGOCD_GZ="$HOME/Downloads/argocd-cli-${P}-v3.4.4-vcf.gz"
for f in "$ARGOCD_MANIFEST" "$ARGOCD_GZ"; do
  if [ -f "$f" ]; then
    (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | awk '{h = $1; sub(/.*\//, ""); print "SHA-256: " h "  " $0}'
  else
    echo "Not found: $f — download it (table above) for $(uname -s)/$(uname -m)"
  fi
done
```

**Expect:** two `SHA-256:` lines, each equal to the value the download page shows for that file
(labelled **SHA2**). For the files named above:

| file | SHA-256 |
|---|---|
| `supervisor-service-argocd-legacy-1.2.0-25642124.yml` | `e4f0d0bb85bc4c63d32ab52d0e39bb40b322dcecbbc4e5f29587f8ef765eb7f1` |
| `argocd-cli-linux-amd64-v3.4.4-vcf.gz` | `f9ff2d754989107ea06d74713173b9847c08606d9c1cf863ff4fdc584f43bb0f` |
| `argocd-cli-darwin-amd64-v3.4.4-vcf.gz` | `ca2827c8087fb1b0bfb7324550f3db7f5e4ce95ba4054145994544d968ba3f1f` |

**If not:** `Not found: …` — the file is not in `~/Downloads`, or its name differs. `unsupported`
in the path means Broadcom has no `argocd` program for this machine. A different checksum means a
damaged or wrong download: delete the file and download it again; if it still differs, do not
install it.

## 3. Install the argocd program

`argocd` is ArgoCD's command-line tool; Broadcom's build of it matches the ArgoCD the service
runs. This block installs it into `/usr/local/bin`; its `sudo` asks for your password. Run it only
after the checksums above matched.

```sh
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)               P=linux-amd64 ;;
  Darwin/x86_64|Darwin/arm64) P=darwin-amd64 ;;
  *)                          P=unsupported ;;
esac
ARGOCD_GZ="$HOME/Downloads/argocd-cli-${P}-v3.4.4-vcf.gz"
if [ -x /usr/local/bin/argocd ] && ! /usr/local/bin/argocd version --client 2>/dev/null | grep -q -e -vcf; then
  echo "Not installing: /usr/local/bin/argocd is another argocd. Move it away first, or keep it and skip this guide."
elif T="$(mktemp -d)" && gunzip -c "$ARGOCD_GZ" > "$T/argocd" && chmod +x "$T/argocd" \
   && "$T/argocd" version --client >/dev/null \
   && sudo install -d /usr/local/bin && sudo install -m 0755 "$T/argocd" /usr/local/bin/argocd; then
  rm -rf "$T"
  /usr/local/bin/argocd version --client | head -1
  [ "$(command -v argocd)" = /usr/local/bin/argocd ] \
    || echo "WARNING: 'argocd' on your PATH is '$(command -v argocd || echo not found)', not /usr/local/bin/argocd"
else
  [ -n "$T" ] && rm -rf "$T"
  echo "Nothing installed: see the error above"
fi
```

**Expect:** `argocd: v3.4.4+…-vcf`, and no `WARNING` line.

**If not:**
- `bad CPU type in executable` (a Mac with Apple silicon): run
  `softwareupdate --install-rosetta --agree-to-license`, then this block again.
- `No such file or directory`: step 2's download is missing.
- `Not installing: …`: an `argocd` from elsewhere (for example Homebrew on an Intel Mac) is at
  that path. This guide does not replace it.
- A `WARNING` line: another `argocd` is found first, or `/usr/local/bin` is not in your `PATH`.

## 4. Install the ArgoCD Service on the Supervisor

This is done once per Supervisor, by an SSO user with the **Manage Supervisor Services**
privilege. If ArgoCD Service is already installed there, skip to step 5 (its first block tells
you).

The blocks below use vCenter's API. Broadcom's documentation describes only the vSphere Client
for this; the API calls were measured on VCF 9.1.1. The clicks are at the end of this step.

### Open a vCenter session

Check the password in the main guide's env file first: **five failed logins within 3 minutes lock
the SSO user for 5 minutes** (vCenter's default policy).

```sh
source ~/.vks-argocd.env
vc_login
vc /supervisor-services | jq -r '.[] | "\(.supervisor_service)  \(.state)"'
```

**Expect:** `vCenter session opened`, then the Supervisor Services vCenter knows, one per line
(for example `tkg.vsphere.vmware.com  ACTIVATED`).

**If not:** a `curl:` certificate error — check `VCENTER_FQDN` and the vCenter CA file (main
guide, step 2). `401` — the user name or password is wrong: fix the env file before you try
again. A list that already shows `argocd-service.vsphere.vmware.com`: the next block skips
what is done.

### Register the service with vCenter

This sends the manifest to vCenter, which then knows the service and this version of it.

```sh
source ~/.vks-argocd.env
if vc /supervisor-services/argocd-service.vsphere.vmware.com/versions | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  echo "already registered"
else
  B="$(mktemp)"
  base64 < "$ARGOCD_MANIFEST" | tr -d '\n' | jq -Rs '{carvel_spec: {version_spec: {content: .}}}' > "$B"
  vc /supervisor-services -X POST -H 'Content-Type: application/json' --data-binary "@$B" -w 'HTTP %{http_code}\n'
  rm -f "$B"
fi
vc /supervisor-services/argocd-service.vsphere.vmware.com/versions | jq -r '.[] | "version \(.version)  \(.state)"'
```

**Expect:** `HTTP 201` (or `already registered`), then `version 1.2.0-25642124  ACTIVATED`.

**If not:** `HTTP 403` — your user lacks **Manage Supervisor Services**: ask your vCenter
administrator to do this step. `HTTP 400` with a message — send it to your administrator; do not
edit the manifest.

### Install it on your Supervisor

This installs the registered version on the Supervisor and waits until it runs (about a minute).
With more than one Supervisor in this vCenter, the block lists them and stops: put the ID of
yours in `~/.vks-argocd.env` as `export SUPERVISOR_ID="…"`, run `vc_login`, then the block again.

```sh
source ~/.vks-argocd.env
SUP="${SUPERVISOR_ID:-$(vc /supervisors/summaries | jq -r 'if (.items | length) == 1 then .items[0].supervisor else empty end')}"
if [ -z "$SUP" ]; then
  vc /supervisors/summaries | jq -r '.items[] | "\(.supervisor)  \(.info.name)"' \
    && echo "Set SUPERVISOR_ID in ~/.vks-argocd.env to one of the IDs above, run vc_login, then this block again"
else
  S="/supervisors/${SUP}/supervisor-services"
  C=200; n=0
  if [ "$(vc "$S/argocd-service.vsphere.vmware.com" -o /dev/null -w '%{http_code}')" != 200 ]; then
    C=500
    until [ "$C" != 500 ] || [ "$n" -ge 12 ]; do
      [ "$n" -eq 0 ] || sleep 10
      n=$((n + 1))
      C="$(jq -n '{supervisor_service: "argocd-service.vsphere.vmware.com", version: "1.2.0-25642124"}' \
        | vc "$S" -X POST -H 'Content-Type: application/json' --data-binary @- -o /dev/null -w '%{http_code}')"
    done
    echo "install: HTTP ${C} (attempt ${n})"
  fi
  if [ "$C" = 200 ] || [ "$C" = 201 ]; then
    n=0
    until [ "$(vc "$S/argocd-service.vsphere.vmware.com" | jq -r '.config_status // empty')" = CONFIGURED ] || [ "$n" -ge 40 ]; do
      n=$((n + 1)); sleep 15
    done
    vc "$S/argocd-service.vsphere.vmware.com" | jq -r '"\(.config_status)  \(.current_version)  \(.messages[0].details.default_message // "")"'
  fi
fi
vc_logout
```

**Expect:** `install: HTTP 201 (attempt 1)` — a higher attempt number is normal right after the
block above, while vCenter prepares the service's account; the line is not printed when the
service was already installed — then within about a minute
`CONFIGURED  1.2.0-25642124  Reason: ReconcileSucceeded. …`, then `vCenter session closed`.

**If not:** `install: HTTP 500 (attempt 12)` — vCenter was still not ready after two minutes: run
the block again (start with `vc_login`). `install: HTTP 403` — your user lacks the privilege.
A status other than `CONFIGURED` after 10 minutes: the message on that line says why.
`ReconcileFailed` with an image or download error means the Supervisor cannot reach
`projects.packages.broadcom.com`: tell your administrator.

<details>
<summary><b>Alternative: the same step in the vSphere Client</b> (Broadcom's documented way)</summary>

Not run for this guide; the steps are from Broadcom's VCF 9.1 documentation
(*Add a Supervisor Service to vCenter*, *Install a Supervisor Service on Supervisors*).

1. In the vSphere Client, open **Supervisor Management** → **Services** and pick your vCenter.
2. Drag the manifest from step 2 onto the **Add New Service** card, then **Next** → **Finish**.
3. On the new **ArgoCD Service** card: **Actions** → **Manage Service** → **Install Version**,
   select your Supervisor, **Next** through the checks, leave the YAML Service Config empty,
   **Finish**.
4. Wait until the Supervisor's **Configure** → **Supervisor Services** → **Overview** shows the
   service as **Configured**.

</details>

## 5. Create the ArgoCD instance

The service only makes ArgoCD *available*. An instance — the ArgoCD you log in to — is one
small object in your vSphere Namespace. From here on your **Edit** role is enough.

### Create the instance

This reads the first ArgoCD version the service lists (its recommended one), creates the
instance with it, and waits until it is ready (one to two minutes). If your vSphere Namespace
already has an instance, the block changes nothing and shows it: to use that one, set
`ARGOCD_NAME` in `~/.vks-argocd.env` to its name, and skip *Delete the ArgoCD instance* in
step 9.

```sh
source ~/.vks-argocd.env
V="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocdversion argocd-supported-versions -o jsonpath='{.spec.versions[0].version}')"
if [ -z "$V" ]; then
  echo "No ArgoCD version found: the ArgoCD Service is not installed on this Supervisor (step 4), or the Supervisor login ended"
elif [ -n "$(sk get argocd -o name 2>/dev/null)" ]; then
  echo "This vSphere Namespace already has an ArgoCD instance (not changed):"
  sk get argocd
else
  printf 'apiVersion: argocd-service.vsphere.vmware.com/v1alpha1\nkind: ArgoCD\nmetadata:\n  name: %s\nspec:\n  version: "%s"\n' "$ARGOCD_NAME" "$V" \
    | sk apply -f -
  n=0
  until [ "$(sk get argocd "$ARGOCD_NAME" -o jsonpath='{.status.phase}')" = Ready ] || [ "$n" -ge 40 ]; do
    n=$((n + 1)); sleep 15
  done
  sk get argocd "$ARGOCD_NAME" -o jsonpath='{.status.phase}{"  https://"}{.status.externalIP}{"\n"}'
fi
```

**Expect:** `argocd…/argocd-1 created`, then `Ready  https://<an address>`.
That address is ArgoCD's web page; your browser will warn about its certificate, which ArgoCD
made for itself.

**If not:** `Forbidden` — the **Edit** role is missing. A phase other than `Ready` after 10
minutes: `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" describe argocd "$ARGOCD_NAME"`
shows why; an empty address means the Supervisor has no free load-balancer address.

### Log in

`argocd_session` logs the `argocd` program in as `admin` for this terminal. It reads the admin
password from the Supervisor, so you never type it, and sends it only to a server that holds the
key of the certificate the Supervisor stores for ArgoCD. ArgoCD's certificate names no address,
so the `argocd` program itself cannot verify it: the `argocd` commands that follow run without
that check, and carry the login token, not the password.

```sh
source ~/.vks-argocd.env
argocd_session && argocd version --short
```

**Expect:** `argocd: logged in to https://<the address> as admin`, then two lines,
`argocd: v3.4.4+…` and `argocd-server: v3.4.4+…`.

**If not:** `curl: (90) … public key does not match` — something between you and ArgoCD replaces
certificates (a company proxy), or the address belongs to another server: do not continue.
`no address yet` — the instance is not `Ready`, or the Supervisor login ended (main guide,
step 7).

To open the web page, log in as `admin` with the password this prints (anyone who can read your
screen can then log in):

```sh
source ~/.vks-argocd.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 6. Let ArgoCD manage your vSphere Namespace

ArgoCD starts with no destination. This step makes your vSphere Namespace one, in two parts.

**Read this first.** The block gives ArgoCD's own account (`argocd-k8s-sa`) the **Edit** role on
your vSphere Namespace. Whoever can log in to this ArgoCD as `admin` can then, through it, do
everything Edit allows there: create and delete guest clusters and virtual machines, and read
secrets, including the kubeconfig of every guest cluster in the namespace. Share the ArgoCD
admin login only with people who may do that.

```sh
source ~/.vks-argocd.env
sk create rolebinding argocd-k8s-sa-edit --clusterrole=edit \
  --serviceaccount="${VKS_NAMESPACE}:argocd-k8s-sa" --dry-run=client -o yaml | sk apply -f -
printf 'apiVersion: argocd-service.vsphere.vmware.com/v1alpha1\nkind: ManagedEntity\nmetadata:\n  name: %s\nspec:\n  targetRef:\n    apiGroup: ""\n    kind: Namespace\n    name: %s\n' \
  "$VKS_NAMESPACE" "$VKS_NAMESPACE" | sk apply -f -
n=0
until [ "$(sk get managedentity "$VKS_NAMESPACE" -o jsonpath='{.status.phase}')" = Ready ] || [ "$n" -ge 20 ]; do
  n=$((n + 1)); sleep 3
done
sk get managedentity "$VKS_NAMESPACE"
```

**Expect:** two `created` (or `unchanged`/`configured`) lines, then your namespace with
`SupervisorNamespace`, `Ready` and `https://kubernetes.default.svc/?context=<your namespace>`.

**If not:** a phase other than `Ready`: `sk describe managedentity "$VKS_NAMESPACE"` names the
failed condition (`MissingRoleBinding` means the first command failed).

Now create a project that limits what an Application may do: only this guide's Git repository,
only your vSphere Namespace, and only one kind of object — a guest cluster.

```sh
source ~/.vks-argocd.env
printf 'apiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: vks-clusters\nspec:\n  description: Only VKS guest clusters, from one repository, into this vSphere Namespace\n  sourceRepos:\n  - %s\n  destinations:\n  - name: %s\n    namespace: %s\n  namespaceResourceWhitelist:\n  - group: cluster.x-k8s.io\n    kind: Cluster\n' \
  "$CLUSTER_REPO" "$VKS_NAMESPACE" "$VKS_NAMESPACE" | sk apply -f -
argocd_session && argocd proj get vks-clusters | head -8
```

**Expect:** `appproject…/vks-clusters created` (or `unchanged`), the login line, then the
project with your repository under `Repositories` and your namespace under `Destinations`.

## 7. Create a guest cluster with ArgoCD

The cluster's description is a chart in this repository,
[`vks/argocd/guest-cluster`](argocd/guest-cluster). You give it four values; ArgoCD renders it
and applies the result to your vSphere Namespace, where VKS builds the cluster.

`CLUSTER_REVISION` in `~/.vks-argocd.env` pins the chart to one commit of this repository, so a
later change here cannot change your cluster. The commit this guide
was tested with is `e236f5c43aa2a1c7a9cc84e7f3cbdbc7024942d6`. For anything beyond trying this out, copy the
`vks/argocd/guest-cluster` folder into a Git repository of your own and set `CLUSTER_REPO` and
`CLUSTER_REVISION` to it: then only you decide what ArgoCD applies.

### Choose the cluster's values

This lists the Kubernetes versions, VM classes, storage classes and cluster classes to choose from.

```sh
source ~/.vks-argocd.env
echo "Kubernetes versions (newest last):"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr -o json | jq -r '.items[] | select([.status.conditions[]? | select(.type == "Ready" or .type == "Compatible") | .status] | length == 2 and all(. == "True")) | .spec.version | sub("-vkr\\.[0-9]+$"; "")' | sort -t. -k2,2n -k3,3n -k4,4n | tail -5
echo "VM classes:"
sk get virtualmachineclass --no-headers
echo "Storage classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get storageclass --no-headers | awk '{print $1}'
echo "Cluster classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get clusterclass --no-headers | awk '{print $1}' | tail -3
```

**Expect:** up to five versions such as `v1.36.2+vmware.2`, at least one VM class with its CPU
and memory, the Supervisor's storage classes (use one your vSphere Namespace is allowed; your
administrator knows which), and cluster classes such as `builtin-generic-v3.7.0`.

Open the env file and set `NEW_CLUSTER`, `K8S_VERSION`, `VM_CLASS` and `STORAGE_CLASS`. Write the version exactly as listed (the Supervisor stores it without the
`-vkr.N` ending its release name has; with that ending ArgoCD would report a difference forever).
A VM class with 2 CPUs and 4 GB is enough. Keep `CLUSTER_CLASS` unless your list lacks it; then
take the newest listed.

```sh
"${EDITOR:-nano}" ~/.vks-argocd.env
```

### Create the Application and look at what it will do

This creates the Application without applying anything, then shows the cluster ArgoCD would
create.

```sh
source ~/.vks-argocd.env
if [ -n "$(sk get cluster "$NEW_CLUSTER" --ignore-not-found -o name)" ] && [ -z "$(sk get applications.argoproj.io "$NEW_CLUSTER" --ignore-not-found -o name)" ]; then
  echo "STOP: a cluster named '$NEW_CLUSTER' already exists and this ArgoCD did not create it. Choose another NEW_CLUSTER."
elif argocd_session; then
  argocd app create "$NEW_CLUSTER" --upsert --project vks-clusters \
    --repo "$CLUSTER_REPO" --revision "$CLUSTER_REVISION" --path vks/argocd/guest-cluster \
    --dest-name "$VKS_NAMESPACE" --dest-namespace "$VKS_NAMESPACE" \
    --helm-set-string name="$NEW_CLUSTER" --helm-set-string kubernetesVersion="$K8S_VERSION" \
    --helm-set-string vmClass="$VM_CLASS" --helm-set-string storageClass="$STORAGE_CLASS" \
    --helm-set-string clusterClass="$CLUSTER_CLASS" \
    && argocd app diff "$NEW_CLUSTER"
fi
```

**Expect:** the login line, `application '<name>' created`, then a listing in which every line starts with `>`:
the `Cluster` object, with your name, version, VM class and storage class. Run again once the
cluster exists, the block instead lists ten lines starting with `<`: two settings the Supervisor
added to the cluster (certificate rotation and the network add-on). ArgoCD still reports
`Synced`, and a sync leaves them in place.

**If not:** `STOP: …` — ArgoCD would take over that cluster, and step 9 would delete it: use a
name no cluster has. `set kubernetesVersion` (or another `set …`) — that value is empty in the env file.
`repository not accessible` — the Supervisor cannot reach GitHub, or `CLUSTER_REVISION` is not a
commit of `CLUSTER_REPO`. `application destination … is not permitted in project` — step 6's
project block did not run.

### Sync, and wait for the cluster

`argocd app sync` applies the description once. The loop then waits until VKS reports the cluster
available: 4 to 7 minutes on the test system, longer on a busy one.

```sh
source ~/.vks-argocd.env
if argocd_session && argocd app sync "$NEW_CLUSTER" >/dev/null; then
  echo "synced"
  n=0
  until [ "$(sk get cluster "$NEW_CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ] || [ "$n" -ge 120 ]; do
    n=$((n + 1)); sleep 15
  done
  sk get cluster "$NEW_CLUSTER"
  argocd app get "$NEW_CLUSTER" | grep -E '^(Sync Status|Health Status):'
else
  echo "Not synced: see the error above"
fi
```

**Expect:** the login line, `synced`, then the cluster with `AVAILABLE True` and its control-plane and worker
counts, then `Sync Status: Synced …` and `Health Status: Healthy` (`Progressing` for a minute
more is normal).

**If not:** still not `True` after 30 minutes:
`sk describe cluster "$NEW_CLUSTER"` shows the condition that is waiting. A VM class that is too
small, or a namespace without room, shows there.

To use the new cluster, set `VKS_CLUSTER` in `~/.vks-golang-web.env` to its name and run the main
guide's step 7 from *Get the guest cluster's kubeconfig*.

ArgoCD now applies this cluster only when you run `argocd app sync`. Changing a value (for
example `--helm-set workerReplicas=3` on the `argocd app create --upsert` line) and syncing
again changes the cluster.

## 8. Add the new cluster to ArgoCD

This makes the guest cluster a destination too, so ArgoCD can deploy applications into it. The
**Edit** binding from step 6 already covers it.

```sh
source ~/.vks-argocd.env
printf 'apiVersion: argocd-service.vsphere.vmware.com/v1alpha1\nkind: ManagedEntity\nmetadata:\n  name: %s\nspec:\n  targetRef:\n    apiGroup: cluster.x-k8s.io\n    kind: Cluster\n    name: %s\n    namespace: %s\n' \
  "$NEW_CLUSTER" "$NEW_CLUSTER" "$VKS_NAMESPACE" | sk apply -f -
n=0
until [ "$(sk get managedentity "$NEW_CLUSTER" -o jsonpath='{.status.phase}')" = Ready ] || [ "$n" -ge 20 ]; do
  n=$((n + 1)); sleep 3
done
argocd_session && argocd cluster list
```

**Expect:** `managedentity…/<name> created`, the login line, then two destinations: your vSphere
Namespace, and `<cluster>-<namespace>` at `https://<an address>:6443`. The new one shows no status, or
`Unknown`, until an Application uses it; that is normal.

The service keeps this destination's login in a secret it owns. That login is the cluster's own
client certificate; whether the service renews it before it expires was not tested for this
guide.

## 9. Clean up (optional)

Run these in order. Each one waits for the thing it deletes to be gone, because the next depends
on it: ArgoCD must still exist while it deletes the cluster, and the service must still exist
while the instance is deleted.

### Delete the guest cluster

This removes the cluster from ArgoCD's destinations, then deletes the Application, which deletes
the cluster and its virtual machines.

```sh
source ~/.vks-argocd.env
if argocd_session; then
  sk delete managedentity "$NEW_CLUSTER" --ignore-not-found
  argocd app delete "$NEW_CLUSTER" --yes
  n=0
  until [ -z "$(sk get cluster,applications.argoproj.io "$NEW_CLUSTER" --ignore-not-found -o name || echo unknown)" ] || [ "$n" -ge 120 ]; do
    n=$((n + 1)); sleep 15
  done
  echo "left (nothing after the colon means gone): $(sk get cluster,applications.argoproj.io "$NEW_CLUSTER" --ignore-not-found -o name || echo unknown)"
fi
```

**Expect:** the login line, `managedentity… deleted`, `application '<name>' deleted`, and within
a few minutes `left (nothing after the colon means gone):` with nothing after it.

**If not:** a name, or `unknown`, after the colon: the cluster is still being deleted, or the
Supervisor login ended (main guide, step 7). Run the block again before you go on.

### Delete the ArgoCD instance

Skip this if the instance existed before you started this guide. This removes the project, the
destination, the role binding and the instance, then the two
secrets the instance leaves behind (a new instance would otherwise meet the old admin password).

```sh
source ~/.vks-argocd.env
sk delete appproject vks-clusters --ignore-not-found
sk delete managedentity "$VKS_NAMESPACE" --ignore-not-found
sk delete rolebinding argocd-k8s-sa-edit --ignore-not-found
sk delete argocd "$ARGOCD_NAME" --ignore-not-found
sk delete secret argocd-initial-admin-secret argocd-redis --ignore-not-found
echo "left (nothing after the colon means gone): $(sk get argocd --ignore-not-found -o name || echo unknown)"
unset ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_OPTS
```

**Expect:** six `deleted` lines, then `left (nothing after the colon means gone):` with nothing
after it.

### Uninstall the ArgoCD Service

Only for the user who did step 4, and only if step 4 installed the service (not if it was there
before). The block refuses while any vSphere Namespace on this Supervisor still has an ArgoCD
instance, and in a vCenter with more than one Supervisor, where the last three calls would
remove the service for all of them: use the vSphere Client there (**Supervisor Management** →
**Services**).

```sh
source ~/.vks-argocd.env
vc_login
SUP="$(vc /supervisors/summaries | jq -r 'if (.items | length) == 1 then .items[0].supervisor else empty end')"
LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocd -A -o name || echo unknown)"
if [ -z "$SUP" ] || [ -n "$LEFT" ]; then
  echo "Not uninstalling: this vCenter has more than one Supervisor, or ArgoCD instances remain (or could not be listed): ${LEFT}"
else
  S="/supervisors/${SUP}/supervisor-services/argocd-service.vsphere.vmware.com"
  vc "$S" -X DELETE -o /dev/null -w 'uninstall: HTTP %{http_code}\n'
  n=0
  until [ "$(vc "$S" -o /dev/null -w '%{http_code}')" = 404 ] || [ "$n" -ge 40 ]; do
    n=$((n + 1)); sleep 15
  done
  A=/supervisor-services/argocd-service.vsphere.vmware.com
  vc "$A?action=deactivate" -X PATCH -o /dev/null -w 'deactivate: HTTP %{http_code}\n'
  vc "$A/versions/1.2.0-25642124" -X DELETE -o /dev/null -w 'remove the version: HTTP %{http_code}\n'
  vc "$A" -X DELETE -o /dev/null -w 'remove the service: HTTP %{http_code}\n'
fi
vc_logout
```

**Expect:** `vCenter session opened`, then four lines ending `HTTP 204` (`uninstall`,
`deactivate`, `remove the version`, `remove the service`), then `vCenter session closed`.

**If not:** `Not uninstalling: …` names what remains. A line that does not end in `HTTP 204`:
run the block again; `HTTP 400` on *remove the service* means a step before it did not finish.

### Delete what this guide installed and wrote

```sh
rm -f ~/.vks-argocd.env ~/.vks-argocd.functions
unset ARGOCD_MANIFEST ARGOCD_NAME NEW_CLUSTER K8S_VERSION VM_CLASS STORAGE_CLASS CLUSTER_CLASS \
      CLUSTER_REPO CLUSTER_REVISION VC_SESSION SUPERVISOR_ID
unset -f sk vc_login vc vc_logout argocd_session 2>/dev/null || true
if /usr/local/bin/argocd version --client 2>/dev/null | grep -q -e -vcf; then sudo rm -f /usr/local/bin/argocd; fi
```

**Expect:** no output (after your `sudo` password).

## Fix common problems

| symptom | fix |
|---|---|
| `vc: no vCenter session — run vc_login` | A step 4 block was run without the one before it, or after `vc_logout`. Run `vc_login`, then the block again. |
| A step 4 block prints `unauthenticated` or `HTTP 401` | The vCenter session ended. Run `vc_login` (once), then the block again. |
| `argocd_session: command not found`, or `vc_login: command not found` | Re-run step 1's second block; it rewrites `~/.vks-argocd.functions` and keeps your values. |
| `argocd` asks `Proceed insecurely (y/n)?` or says it is not logged in | This terminal has no ArgoCD login: answer `n`, then run `argocd_session` first, as the blocks do. |
| `bad CPU type in executable` (macOS) | `softwareupdate --install-rosetta --agree-to-license` |
| The Application shows `OutOfSync` right after a sync | `K8S_VERSION` has a `-vkr.N` ending: remove it in the env file, run step 7's *Create the Application* block again, then sync. |
| Step 7's listing has lines starting with `<` or `>` that you did not expect | A sync would change the cluster that way. If you do not want that, do not sync. `argocd app delete "$NEW_CLUSTER" --cascade=false --yes` removes only the Application and keeps the cluster. |
| `argocd app delete` returns but the cluster stays for many minutes | Normal: VKS deletes the virtual machines first. Step 9's block waits up to 30 minutes. |
| The ArgoCD Service will not uninstall | An ArgoCD instance still exists somewhere on the Supervisor: `kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocd -A` lists them. Delete each (step 9) first. |
