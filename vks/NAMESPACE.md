# Use or create a vSphere Namespace

This chapter comes after the Supervisor login of [the main guide](README.md) and before you
create a guest cluster. You need the main guide's env file, its tools, its vCenter CA file and
its Supervisor login. At the end you have a vSphere Namespace that can hold a guest cluster.

A vSphere Namespace is your team's area on the Supervisor. It is made in vCenter, not in
Kubernetes: vCenter decides which virtual machine sizes (*VM classes*) and which disks (*storage
classes*) it may use, and who may work in it. There are four ways to get one. Take the first that
fits you:

| your situation | go to |
|---|---|
| Your administrator gave you a namespace | [Check the namespace you have](#check-the-namespace-you-have) |
| You have none, and no administrator rights in vCenter | [Ask your administrator](#ask-your-administrator) |
| You have none, and you are a vCenter administrator | [Create it with the vCenter API](#create-it-with-the-vcenter-api) |
| Your administrator switched on Namespace Self-Service | the collapsed alternative under [Create it with the vCenter API](#create-it-with-the-vcenter-api) |

Run the blocks by copy and paste, in `bash` or `zsh`, on Linux or macOS, from inside your
`golang-web` clone. Each block is followed by **Expect:** — what you should see — and, where it
can go wrong, **If not:** — what to do. A block you run twice either changes nothing or tells you
what to do.

## Check the namespace you have

Whichever way you got the namespace, these two blocks prove it can hold a guest cluster. Set
`VKS_NAMESPACE` in `~/.vks-golang-web.env` to its name first.

This checks that the namespace exists, that you can read it, and that you may create a cluster
in it.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" auth can-i create clusters.cluster.x-k8s.io
```

**Expect:** your vSphere Namespace, `Active`, then `yes`.

**If not:**
- `NotFound`: no namespace has that name. Check `VKS_NAMESPACE`; if it is right, the namespace
  does not exist yet: go to [Ask your administrator](#ask-your-administrator) or
  [Create it with the vCenter API](#create-it-with-the-vcenter-api).
- `Forbidden`, or `no` on the second line: the namespace exists but your SSO user has no role
  that lets it create clusters there. Ask your administrator for the **Edit** role on it
  ([Ask your administrator](#ask-your-administrator) has the text). If the role was given after
  you logged in, run the main guide's *Delete the Supervisor login* block and log in again.
- `Unauthorized`, or a login prompt: the Supervisor login ended. Run the main guide's *Renew the
  Supervisor login* block, then this block again.

This lists what the namespace offers a guest cluster: VM classes, storage classes, Kubernetes
releases and cluster classes.

```sh
source ~/.vks-golang-web.env
echo "VM classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineclass --no-headers
echo "Storage classes:"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get storagepolicyquota -o jsonpath='{range .items[*].status.total[*]}{.storageClassName}{"\n"}{end}' | sort -u
echo "Kubernetes releases ready to use: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get kr -o json | jq '[.items[] | select([.status.conditions[]? | select(.type == "Ready" or .type == "Compatible") | .status] | length == 2 and all(. == "True"))] | length')"
echo "Cluster classes: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get clusterclass -o name | wc -l | tr -d ' ')"
```

**Expect:** at least one line under `VM classes:` (a name with its CPU and memory), at least one
name under `Storage classes:`, then `Kubernetes releases ready to use:` and `Cluster classes:`,
each with a number above 0. Then the namespace is ready: go to **Next** at the end of this
chapter.

**If not:**
- `No resources found in <your namespace> namespace.` under `VM classes:`: no VM class is
  assigned to the namespace, so a cluster has no machine size to use. Ask your administrator to
  assign at least one (the request text below names them).
- Nothing under `Storage classes:`: no storage policy is assigned to the namespace, or your user
  may not read it. Ask your administrator to assign a storage policy.
- `Kubernetes releases ready to use: 0`: the Supervisor has no usable Kubernetes release. On a
  Supervisor that was switched on minutes ago, wait ten minutes and run the block again. If it
  stays 0, tell your administrator: the Supervisor's content library has no release it can use.
- `Cluster classes: 0`: the VKS service on this Supervisor is not running. Tell your
  administrator.

## Ask your administrator

Most readers have the **Edit** role in a namespace and no rights in vCenter, so they cannot make
a namespace themselves. Send your vCenter administrator the request below. Replace the name, the
user and the sizes with yours; an administrator can do all of it in the vSphere Client in a few
minutes.

```text
Please create a vSphere Namespace on our Supervisor for a VKS guest cluster.

  Name:            my-namespace
  Storage policy:  one policy whose datastore has about 150 GB free
  VM classes:      best-effort-small and best-effort-medium (or two classes of
                   2 CPUs with 4 GB and 2 CPUs with 8 GB of memory)
  Permission:      the Edit role (or Owner) for my SSO user, <user>@<domain>
  Limits:          none, or at least 8 CPUs, 24 GB of memory and 150 GB of storage
                   (one control-plane node and two or three worker nodes)

Please also send me the Supervisor's address and tell me that the namespace's
status is Running.
```

When the answer arrives, set `VKS_NAMESPACE` in `~/.vks-golang-web.env` to the name you were
given and run [Check the namespace you have](#check-the-namespace-you-have). If you were logged
in to the Supervisor before the namespace existed, run the main guide's *Delete the Supervisor
login* block and log in again first.

## Create it with the vCenter API

Do this only if your SSO user is a vCenter administrator. Broadcom's documentation asks for the
*VI administrator* role to create a vSphere Namespace; with less, the create call below answers
`HTTP 403`, and you take [Ask your administrator](#ask-your-administrator) instead.

The calls below were proven on VMware Cloud Foundation 9.1.1, on a Supervisor whose workload
network is a vSphere Distributed Switch with the Foundation Load Balancer. A Supervisor on NSX
with VPC needs a different call, with a network description
([Broadcom: create a vSphere Namespace with shared subnets](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration/configuring-and-managing-vsphere-namespaces/managing-vsphere-namespaces-on-a-supervisor-with-nsx-vpc/create-and-configure-a-vsphere-namespace-on-a-supervisor-with-vpc/create-vsphere-namepsaces-with-shared-subnets.html)),
which this chapter does not cover. *Read the Supervisor's network type* below tells you which
you have, and the create block refuses the wrong one.

### Add the settings and the helper commands

This adds five settings to your env file (each only if it is not there yet) and writes
`~/.vks-golang-web.vcenter.functions`, which is rewritten every time. The file holds five
helper commands: `vc_login` opens one vCenter API session as your SSO user and saves its token in
a file only you can read, so neither the password nor the token is on a command line; `vc_api`
and `vc` make one call with that session (`vc` for paths under `namespace-management`);
`vc_cluster_id` prints the ID of the vSphere cluster your Supervisor runs on; `vc_logout` ends
the session.

```sh
E="$HOME/.vks-golang-web.env"
if [ -f "$E" ]; then
  grep -qs '^export VC_SESSION=' "$E" || printf '%s\n' 'export VC_SESSION="$HOME/.config/vks-golang-web/vc-session"' >> "$E"
  grep -qs '^export VSPHERE_CLUSTER_ID=' "$E" || printf '%s\n' 'export VSPHERE_CLUSTER_ID=""' >> "$E"
  grep -qs '^export STORAGE_POLICY=' "$E" || printf '%s\n' 'export STORAGE_POLICY=""' >> "$E"
  grep -qs '^export NAMESPACE_VM_CLASSES=' "$E" || printf '%s\n' 'export NAMESPACE_VM_CLASSES=""' >> "$E"
  grep -qs '^export NAMESPACE_ROLE=' "$E" || printf '%s\n' 'export NAMESPACE_ROLE="EDIT"' >> "$E"
  grep -qs 'vks-golang-web.vcenter.functions' "$E" || printf '%s\n' '. "$HOME/.vks-golang-web.vcenter.functions"' >> "$E"
else
  echo "No env file: do the main guide's first step, then run this block again"
fi

cat >| ~/.vks-golang-web.vcenter.functions <<'EOF'
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
  ( umask 077; curl -fsS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$cfg" -X POST "https://${VCENTER_FQDN}/api/session" \
      | jq -r '"header = \"vmware-api-session-id: \(.)\""' > "$VC_SESSION" )
  rm -f "$cfg"
  if [ -s "$VC_SESSION" ]; then echo "vCenter session opened"; else
    rm -f "$VC_SESSION"; echo "vc_login: no session (see the curl error above) — do not retry a wrong password" >&2; return 1
  fi
}

vc_api() {
  local p="$1"; shift
  [ -s "$VC_SESSION" ] || { echo "vc_api: no vCenter session — run vc_login" >&2; return 1; }
  curl -sS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" "$@" \
    "https://${VCENTER_FQDN}/api/vcenter${p}"
}

vc() {
  local p="$1"; shift
  vc_api "/namespace-management${p}" "$@"
}

vc_cluster_id() {
  if [ -n "$VSPHERE_CLUSTER_ID" ]; then printf '%s\n' "$VSPHERE_CLUSTER_ID"; return 0; fi
  vc_api /cluster | jq -r 'if type == "array" and length == 1 then .[0].cluster else empty end'
}

vc_logout() {
  [ -s "$VC_SESSION" ] || return 0
  curl -sS --connect-timeout 10 --max-time 60 --cacert "$SUPERVISOR_CA" -K "$VC_SESSION" -X DELETE "https://${VCENTER_FQDN}/api/session"
  rm -f "$VC_SESSION"; echo "vCenter session closed"
}
EOF
```

**Expect:** no output.

**If not:** `No env file: …` — the main guide's first step has not been done on this machine.

### Open a vCenter session and find the Supervisor's cluster

Check the password in the env file first: **five failed logins within 3 minutes lock the SSO
user for 5 minutes** (vCenter's default policy). This opens the session the next blocks use, and
lists vCenter's clusters. The create call needs the cluster's ID, not its name.

```sh
source ~/.vks-golang-web.env
vc_login
vc_api /cluster | jq -r 'if type == "array" then .[] | "\(.cluster)  \(.name)" else "ERROR: \(.error_type // .)" end'
```

**Expect:** `vCenter session opened`, then one line per cluster: an ID such as `domain-c8`, then
the cluster's name. With one cluster you set nothing: the blocks below find it. With more than
one, put the ID of the cluster your Supervisor runs on in `~/.vks-golang-web.env`, as
`export VSPHERE_CLUSTER_ID="domain-c8"`.

**If not:**
- A `curl:` certificate error: check `VCENTER_FQDN` and the vCenter CA file (main guide,
  *Download and check the vCenter CA*).
- `vc_login: no session`, with `401` in the curl error above it: the user name or the password
  is wrong. Fix the env file before you try again.
- `ERROR: UNAUTHENTICATED`: the session ended. Run `vc_login`, then the block again.
- `vc_login: command not found`: the block above did not run.

### Read the Supervisor's network type

This reads how the Supervisor on that cluster connects its workloads. It changes nothing.

```sh
source ~/.vks-golang-web.env
C="$(vc_cluster_id)"
if [ -z "$C" ]; then
  echo "Set VSPHERE_CLUSTER_ID in ~/.vks-golang-web.env to one of the IDs above, then run this block again"
else
  vc "/clusters/${C}" | jq -r --arg c "$C" '"\($c)  network provider: \(.network_provider // "UNKNOWN")  Supervisor: \(.config_status // .error_type // "UNKNOWN")"'
fi
```

**Expect:** `<the cluster ID>  network provider: VSPHERE_NETWORK  Supervisor: RUNNING`.

**If not:**
- `network provider: NSX_VPC`, `NSXT_CONTAINER_PLUGIN` or any other value: **stop here.** The
  create call in this chapter is not made for that Supervisor. Create the namespace in the
  vSphere Client (the click list at the end of this section), or follow Broadcom's page linked
  above, then continue at [Check the namespace you have](#check-the-namespace-you-have).
- `network provider: UNKNOWN  Supervisor: NOT_FOUND`: that cluster has no Supervisor. Set
  `VSPHERE_CLUSTER_ID` to the cluster that has one.
- `Supervisor:` followed by anything but `RUNNING`: the Supervisor is not ready. Wait, or tell
  your administrator.
- `Set VSPHERE_CLUSTER_ID …`: vCenter has more than one cluster; see the block above.

### List the storage policies

A namespace gets its disks from a vCenter storage policy. This lists the policies by name.

```sh
source ~/.vks-golang-web.env
vc_api /storage/policies | jq -r 'if type == "array" then .[] | .name else "ERROR: \(.error_type // .)" end' | sort
```

**Expect:** one policy name per line. Choose one whose datastore has room for the cluster's
disks (about 25 GB per node, plus what your apps store). Policies with `Encryption` in their
name need a key provider; do not choose one unless your administrator says so.

**If not:** `ERROR: UNAUTHENTICATED` — run `vc_login`, then the block again.

### List the VM classes

This lists the VM classes vCenter has. A guest cluster can use only the classes you assign to
the namespace.

```sh
source ~/.vks-golang-web.env
vc /virtual-machine-classes | jq -r 'if type == "array" then .[] | "\(.id)  \(.cpu_count // "?") CPU  \(.memory_MB // "?") MB" else "ERROR: \(.error_type // .)" end' | sort
```

**Expect:** one class per line, such as `best-effort-small  2 CPU  4096 MB`. A class with 2 CPUs
and 4 GB is enough for this app; add one with 8 GB if you plan to add Istio later
([CLUSTER.md](CLUSTER.md) has the sizes).

**If not:** `ERROR: UNAUTHENTICATED` — run `vc_login`, then the block again.

### Choose the namespace's values

Open the env file and set these lines:

| setting | value |
|---|---|
| `VKS_NAMESPACE` | the new namespace's name: lower-case letters, digits and `-`, and a name no namespace has yet |
| `STORAGE_POLICY` | one name from the storage policy list, exactly as printed |
| `NAMESPACE_VM_CLASSES` | one or more names from the VM class list, separated by spaces, for example `"best-effort-small best-effort-medium"` |
| `NAMESPACE_ROLE` | the role your own SSO user gets in the namespace: `EDIT` (enough for everything in these guides) or `OWNER` (may also delete the namespace with `kubectl`) |
| `VSPHERE_CLUSTER_ID` | only if vCenter has more than one cluster |

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

### Fill the namespace's description

The description is the file [`templates/namespace-spec.json`](templates/namespace-spec.json).
This looks up the IDs of your cluster and your storage policy, fills the file's `${…}` places
from your env file, and saves the result as `~/.config/vks-golang-web/namespace-spec.json`. It
refuses to fill the file while any value is empty, and creates nothing. Your own SSO user
(`SSO_USERNAME`, split at the `@`) goes into the access list with the role you chose: without
it, only vCenter administrators could use the namespace.

```sh
source ~/.vks-golang-web.env
export VSPHERE_CLUSTER_ID="$(vc_cluster_id)"
export STORAGE_POLICY_ID="$(vc_api /storage/policies | jq -r --arg n "$STORAGE_POLICY" 'if type == "array" then ([.[] | select(.name == $n) | .policy][0] // empty) else empty end')"
export NAMESPACE_VM_CLASSES_JSON="$(printf '%s' "$NAMESPACE_VM_CLASSES" | tr ' ' '\n' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
export NAMESPACE_USER="${SSO_USERNAME%@*}"
export NAMESPACE_DOMAIN="${SSO_USERNAME##*@}"
[ "$NAMESPACE_USER" = "$SSO_USERNAME" ] && export NAMESPACE_DOMAIN=""
SPEC="$HOME/.config/vks-golang-web/namespace-spec.json"
M=""
for v in VKS_NAMESPACE VSPHERE_CLUSTER_ID STORAGE_POLICY_ID NAMESPACE_VM_CLASSES NAMESPACE_USER NAMESPACE_DOMAIN NAMESPACE_ROLE; do
  [ -n "$(printenv "$v")" ] || M="$M $v"
done
if [ -n "$M" ]; then
  echo "Not filled: no value for:$M"
elif [ ! -f vks/templates/namespace-spec.json ]; then
  echo "Not filled: run this block from inside your golang-web clone"
elif ! command -v envsubst >/dev/null 2>&1; then
  echo "Not filled: envsubst is missing (CLUSTER.md, Install envsubst)"
else
  mkdir -p "$(dirname "$SPEC")"
  ( umask 077; envsubst '${VKS_NAMESPACE} ${VSPHERE_CLUSTER_ID} ${STORAGE_POLICY_ID} ${NAMESPACE_VM_CLASSES_JSON} ${NAMESPACE_USER} ${NAMESPACE_DOMAIN} ${NAMESPACE_ROLE}' \
      < vks/templates/namespace-spec.json > "$SPEC" )
  jq . "$SPEC" || { rm -f "$SPEC"; echo "Not filled: a value broke the JSON (see the jq error above)"; }
fi
```

**Expect:** the filled description: your namespace's name, the cluster's ID, a storage policy ID
(a long string of hex digits and `-`), your VM classes as a list, and one access entry with your
user name, its domain and the role.

**If not:**
- `Not filled: no value for: STORAGE_POLICY_ID`: no storage policy has the name in
  `STORAGE_POLICY`, or the vCenter session ended (run `vc_login`). The name must equal one line
  of the list, capitals and spaces included.
- `Not filled: no value for: VSPHERE_CLUSTER_ID`: vCenter has more than one cluster; set
  `VSPHERE_CLUSTER_ID`.
- `Not filled: no value for: NAMESPACE_DOMAIN`: `SSO_USERNAME` has no `@domain` part. Write it
  in full, for example `administrator@vsphere.local`.
- Any other name after `no value for:`: that line in the env file is empty.
- `envsubst is missing`: install it with the block under *Install envsubst* in
  [CLUSTER.md](CLUSTER.md), then run this block again.

### Create the namespace

This checks the network type once more, checks that no namespace has the name yet, sends the
description to vCenter, and waits until the namespace runs (seconds, normally). Then it closes
the vCenter session.

```sh
source ~/.vks-golang-web.env
SPEC="$HOME/.config/vks-golang-web/namespace-spec.json"
C="$(jq -r '.cluster // empty' "$SPEC" 2>/dev/null)"
P="$(vc "/clusters/${C}" | jq -r '.network_provider // empty')"
H="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w '%{http_code}')"
if [ "$(jq -r '.namespace // empty' "$SPEC" 2>/dev/null)" != "$VKS_NAMESPACE" ]; then
  echo "STOP: the filled description is missing, or is for another namespace. Run the block above again."
elif [ "$P" != VSPHERE_NETWORK ]; then
  echo "STOP: this Supervisor's network provider is '${P:-unknown}', not VSPHERE_NETWORK. Nothing was created."
elif [ "$H" = 200 ]; then
  echo "STOP: a vSphere Namespace named '${VKS_NAMESPACE}' already exists. Nothing was changed."
elif [ "$H" != 404 ]; then
  echo "STOP: vCenter did not say whether '${VKS_NAMESPACE}' exists (HTTP ${H}). Nothing was created."
else
  vc_api /namespaces/instances -X POST -H 'Content-Type: application/json' --data-binary "@${SPEC}" -w 'create: HTTP %{http_code}\n'
  n=0; S=""
  until [ "$S" = RUNNING ] || [ "$S" = ERROR ] || [ "$n" -ge 40 ]; do
    [ "$n" -eq 0 ] || sleep 15
    n=$((n + 1))
    S="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" | jq -r '.config_status // empty')"
    echo "status: ${S:-no answer yet} (read ${n})"
  done
  vc_api "/namespaces/instances/${VKS_NAMESPACE}" | jq -r '"\(.config_status)  networks: \([.networks[]?] | join(","))  VM classes: \([.vm_service_spec.vm_classes[]?] | join(","))"'
fi
vc_logout
```

**Expect:** `create: HTTP 204`, one or more `status:` lines ending with `status: RUNNING`, then
`RUNNING  networks: <a network name>  VM classes: <your classes>`, then `vCenter session closed`.
Now run both blocks of [Check the namespace you have](#check-the-namespace-you-have).

**If not:**
- `create: HTTP 403`: your SSO user may not create namespaces. Nothing was created: take
  [Ask your administrator](#ask-your-administrator).
- `create: HTTP 400`, with a message above it: vCenter refused the description, and the message
  names the field. A VM class or a user that does not exist is the usual cause. Fix the value in
  the env file, then run *Fill the namespace's description* and this block again.
- `create: HTTP 401`, or `STOP: … (HTTP 401)`: the session ended. Run `vc_login`, then this
  block again.
- `STOP: … already exists`: this chapter never changes a namespace that exists. If it is yours,
  check it with the first section; if not, choose another name.
- `STOP: … network provider …`: see *Read the Supervisor's network type*.
- `status: ERROR`, or no `RUNNING` after 10 minutes: open the namespace in the vSphere Client;
  its **Summary** shows the reason.
- `networks:` with nothing after it: the namespace has no workload network, and a cluster in it
  would get no addresses. Tell your administrator before you create a cluster.

Do not send a changed description to a namespace that exists. The list of VM classes in an
update *replaces* the namespace's list: a class an administrator added by hand, and that your
file does not name, is removed, and running clusters that use it are left without their class.
Change an existing namespace in the vSphere Client.

<details>
<summary><b>Alternative: create it with kubectl</b> (only when your administrator switched on Namespace Self-Service)</summary>

Run this INSTEAD of the blocks above, from *Add the settings and the helper commands* on. With
Namespace Self-Service on, a plain `kubectl create namespace` on the Supervisor makes a real
vSphere Namespace. You do not choose its storage policy, its VM classes or its limits: they come
from a template your administrator wrote. Broadcom marks Namespace Self-Service without VCF
Automation as deprecated, so do not build on it for the long term.

This asks the Supervisor whether you may create namespaces.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" auth can-i create namespaces -A
```

**Expect:** `yes`.

**If not:** `no` — Namespace Self-Service is off, or your user is not on its list. Close this
alternative and take one of the other ways.

Set `VKS_NAMESPACE` in `~/.vks-golang-web.env` to the new name (lower-case letters, digits and
`-`). Then create the namespace:

```sh
source ~/.vks-golang-web.env
if [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE" --ignore-not-found -o name)" ]; then
  echo "A namespace named '${VKS_NAMESPACE}' already exists (not changed)"
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" create namespace "$VKS_NAMESPACE"
fi
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE" -o jsonpath='{.metadata.name}{"  self-service: "}{.metadata.labels.vmware-system-self-service-namespace}{"\n"}'
```

**Expect:** `namespace/<your namespace> created`, then `<your namespace>  self-service: true`.
Now run both blocks of [Check the namespace you have](#check-the-namespace-you-have): they show
what the template gave the namespace.

**If not:**
- `Forbidden`: the check above did not answer `yes`.
- `already exists (not changed)`, then `self-service:` with nothing after it: the name belongs
  to a namespace made another way. Use it only if it is yours.

`kubectl` cannot change this namespace afterwards (`kubectl label` and `kubectl annotate` are
refused), and it cannot delete a namespace that someone else made.

</details>

<details>
<summary><b>Alternative: the same step in the vSphere Client</b> (for a vCenter administrator, on any kind of Supervisor)</summary>

Do this INSTEAD of the blocks above. The names are those of the vSphere Client for VCF 9.1; an
older client says **Workload Management** where this list says **Supervisor Management**.

1. Log in to the vSphere Client as a vCenter administrator and open **Supervisor Management** →
   **Namespaces**.
2. Click **New Namespace**, select your Supervisor, type the namespace's name (lower-case
   letters, digits and `-`), and click **Create**. On a Supervisor with NSX, the dialog also asks
   for the network; take what your network administrator names.
3. On the new namespace's **Summary** page, in the **Permissions** card, click **Add
   Permissions**: choose the identity source, search for your SSO user, and give it **Can edit**
   (or **Owner**).
4. In the **Storage** card, click **Add Storage** and select one storage policy.
5. In the **VM Service** card, click **Add VM Class** and select the classes the cluster may use
   (one with 2 CPUs and 4 GB at least).
6. Leave **Capacity and Usage** without limits, or set limits that leave room for one
   control-plane node and two or three worker nodes.
7. Wait until the **Status** card shows **Running**, then run
   [Check the namespace you have](#check-the-namespace-you-have).

</details>

## Remove the namespace

**Deleting a vSphere Namespace destroys everything in it**: every guest cluster with its
virtual machines and disks, every ArgoCD instance, every secret, with no way back. Delete only a
namespace you created for this guide. The two blocks below refuse while the namespace still
holds a guest cluster: delete the cluster first ([CLUSTER.md](CLUSTER.md), *Delete the cluster*).

If you created the namespace with the vCenter API, delete it there. This opens a session,
deletes the namespace, waits until vCenter no longer has it, and closes the session.

```sh
source ~/.vks-golang-web.env
LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io -o name || echo unknown)"
if [ -n "$LEFT" ]; then
  echo "Not deleting '${VKS_NAMESPACE}': guest clusters remain, or could not be listed: ${LEFT}"
elif vc_login; then
  vc_api "/namespaces/instances/${VKS_NAMESPACE}" -X DELETE -w 'delete: HTTP %{http_code}\n'
  n=0
  until [ "$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w '%{http_code}')" = 404 ] || [ "$n" -ge 40 ]; do
    n=$((n + 1)); sleep 15
  done
  vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w 'the namespace now: HTTP %{http_code} (404 means gone)\n'
  vc_logout
fi
```

**Expect:** `vCenter session opened`, `delete: HTTP 204`, within a minute
`the namespace now: HTTP 404 (404 means gone)`, then `vCenter session closed`.

**If not:**
- `Not deleting …`: the line names what remains. `unknown` means the clusters could not be
  listed: the Supervisor login ended, or your user may not read the namespace.
- `delete: HTTP 403`: your SSO user may not delete namespaces: ask your administrator.
- `delete: HTTP 404`: the namespace was already gone.
- A code other than 404 on the last line after 10 minutes: run the block again.

If you created the namespace with `kubectl` (Namespace Self-Service), delete it the same way.
Only the user who created it, or a user with the **Owner** role on it, may do that.

```sh
source ~/.vks-golang-web.env
LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io -o name || echo unknown)"
if [ -n "$LEFT" ]; then
  echo "Not deleting '${VKS_NAMESPACE}': guest clusters remain, or could not be listed: ${LEFT}"
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" delete namespace "$VKS_NAMESPACE" --ignore-not-found
fi
```

**Expect:** `namespace "<your namespace>" deleted` (it can take a minute), or nothing if it was
already gone.

**If not:** `admission webhook … denied the request … is not associated with namespace` — you
did not create this namespace and are not its Owner. Ask your administrator to delete it.

To remove what this chapter wrote on your machine (the env file itself belongs to the main
guide):

```sh
source ~/.vks-golang-web.env
vc_logout
rm -f "$HOME/.config/vks-golang-web/namespace-spec.json" ~/.vks-golang-web.vcenter.functions
unset VC_SESSION VSPHERE_CLUSTER_ID STORAGE_POLICY STORAGE_POLICY_ID NAMESPACE_VM_CLASSES \
      NAMESPACE_VM_CLASSES_JSON NAMESPACE_USER NAMESPACE_DOMAIN NAMESPACE_ROLE
unset -f vc_login vc_api vc vc_cluster_id vc_logout 2>/dev/null || true
```

**Expect:** no output (`vCenter session closed` if a session was still open). Then remove the
line `. "$HOME/.vks-golang-web.vcenter.functions"` from `~/.vks-golang-web.env`, or every later
`source` of it prints `No such file or directory`.

## Fix common problems

| symptom | fix |
|---|---|
| `vc_api: no vCenter session — run vc_login` | A block was run after `vc_logout`, or without *Open a vCenter session*. Run `vc_login`, then the block again. |
| `ERROR: UNAUTHENTICATED`, or `HTTP 401`, from a vCenter block | The vCenter session ended. Run `vc_login` (once), then the block again. |
| `vc_login: command not found` | Run *Add the settings and the helper commands* again; it rewrites the helper file and keeps your values. |
| `error: You must be logged in to the server (Unauthorized)` | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block. |
| The namespace exists in vCenter but `kubectl get ns` answers `Forbidden` | Your SSO user is not in the namespace's permissions, or it was added after you logged in. Ask for the **Edit** role, then run the main guide's *Delete the Supervisor login* block and log in again. |
| A cluster is refused with a message about the VM class or the storage class | The namespace does not have that class. The second block of *Check the namespace you have* lists what it has. |

## Next

Go on with [Create a guest cluster with kubectl](CLUSTER.md), or go back to
[the main guide](README.md) if you already have a cluster in this namespace.
