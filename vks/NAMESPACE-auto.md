# Create a vSphere Namespace, with scripts

This guide creates a vSphere Namespace with command blocks only: vCenter's API with `curl`, or,
where your Supervisor has Namespace Self-Service switched on, one `kubectl` command. Every value
it needs is printed by a block. It was written for VMware Cloud Foundation 9.1.1 and run on a
Supervisor with vSphere Distributed Switch networking and the Foundation Load Balancer. It was
not run on a Supervisor with NSX.

The same result by hand, in the vSphere Client, is in [NAMESPACE-manual.md](NAMESPACE-manual.md).
If you already have a namespace, you need neither: see [NAMESPACE.md](NAMESPACE.md).

It continues [the main guide](README.md) and uses its env file, its tools, its vCenter CA file
and its Supervisor login. Run the blocks by copy and paste, in `bash` or `zsh`, on Linux or
macOS, from inside your `golang-web` clone. Each block is followed by **Expect:** — what you
should see — and, where it can go wrong, **If not:** — what to do. A block you run twice either
changes nothing or tells you what to do.

| you are | take |
|---|---|
| a vCenter administrator | [Create it with the vCenter API](#create-it-with-the-vcenter-api) |
| a user on a Supervisor with Namespace Self-Service on | [Create it with kubectl](#create-it-with-kubectl-namespace-self-service) |

## Create it with the vCenter API

Do this only if your SSO user is a vCenter administrator. Broadcom's documentation asks for the
*VI administrator* role to create a vSphere Namespace; with less, the create call below answers
`HTTP 403`: [NAMESPACE.md](NAMESPACE.md#if-you-are-not-a-vcenter-administrator) says what to
ask for then.

The calls below were proven on VMware Cloud Foundation 9.1.1, on a Supervisor whose workload
network is a vSphere Distributed Switch with the Foundation Load Balancer. A Supervisor on NSX
with VPC needs a different call, with a network description
([Broadcom: create a vSphere Namespace with shared subnets](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/vsphere-supervisor-installation-and-configuration/configuring-and-managing-vsphere-namespaces/managing-vsphere-namespaces-on-a-supervisor-with-nsx-vpc/create-and-configure-a-vsphere-namespace-on-a-supervisor-with-vpc/create-vsphere-namepsaces-with-shared-subnets.html)),
which this chapter does not cover. *Read the Supervisor's network type* below tells you which
you have, and the create block refuses the wrong one.

### Add the namespace's settings

The blocks below call vCenter with the main guide's helper commands (`vc_login`, `vc_api`, `vc`,
`vc_cluster_id`, `vc_logout`): one vCenter API session as your SSO user, its token in a file
only you can read, so neither the password nor the token is on a command line. This block adds
this chapter's four settings to your env file, each only if it is not there yet, and checks that
the helper commands are there.

```sh
if [ -f ~/.vks-golang-web.env ]; then
  grep -qs '^export VSPHERE_CLUSTER_ID=' ~/.vks-golang-web.env || printf '%s\n' 'export VSPHERE_CLUSTER_ID=""' >> ~/.vks-golang-web.env
  grep -qs '^export STORAGE_POLICY=' ~/.vks-golang-web.env || printf '%s\n' 'export STORAGE_POLICY=""' >> ~/.vks-golang-web.env
  grep -qs '^export NAMESPACE_VM_CLASSES=' ~/.vks-golang-web.env || printf '%s\n' 'export NAMESPACE_VM_CLASSES=""' >> ~/.vks-golang-web.env
  grep -qs '^export NAMESPACE_ROLE=' ~/.vks-golang-web.env || printf '%s\n' 'export NAMESPACE_ROLE="EDIT"' >> ~/.vks-golang-web.env
  echo "settings: $(grep -c -E '^export (VSPHERE_CLUSTER_ID|STORAGE_POLICY|NAMESPACE_VM_CLASSES|NAMESPACE_ROLE)=' ~/.vks-golang-web.env) of 4"
  echo "helper commands: $(grep -c -E '^(vc_login|vc_api|vc|vc_cluster_id|vc_logout)\(\)' ~/.vks-golang-web.functions) of 5"
else
  echo "No env file: do the main guide's first step, then run this block again"
fi
```

**Expect:** `settings: 4 of 4`, then `helper commands: 5 of 5`.

**If not:**
- `No env file: …`: the main guide's first step has not been done on this machine.
- `helper commands:` with a number below 5, or `No such file or directory`: your helper file was
  written by an older version of the main guide. Run the main guide's first block again: it
  writes the helper file from scratch and keeps your env file as it is.
- `settings:` with a number above 4: a setting is in the env file twice. Open the file and
  delete the line you do not want (the last one wins).

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
- `vc_login: command not found`: your helper file is older than this chapter. Run the main
  guide's first block again (it keeps your settings), then this block.

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
  vSphere Client ([NAMESPACE-manual.md](NAMESPACE-manual.md)), or follow Broadcom's page linked
  above, then continue at [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have).
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
disks (tens of GB per node, plus what your apps store). Policies with `Encryption` in their
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
([Choose the cluster's values](CLUSTER-auto.md#choose-the-clusters-values) has the sizes).

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

**Expect:** the editor opens the env file, and nothing is printed. Save and close it; the next
block reads the new values.

### Fill the namespace's description

The description is the file [`templates/namespace-spec.json`](templates/namespace-spec.json).
This looks up the IDs of your cluster and your storage policy, fills the file's `${…}` places
from your env file, and saves the result as `~/.config/vks-golang-web/namespace-spec.json`. It
refuses to fill the file while any value is empty, and creates nothing. The file's `description`
is a fixed text that marks the namespace as made by this guide; *Remove the namespace* deletes
only a namespace that carries it. Your own SSO user
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

**Expect:** the filled description: your namespace's name, the marker text, the cluster's ID, a storage policy ID
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
- `envsubst is missing`: install it with the block under
  [Install envsubst](SETUP.md#install-envsubst), then run this block again.

### Create the namespace

This checks the network type once more, checks that no namespace has the name yet, sends the
description to vCenter, and, only if vCenter accepted it, waits until the namespace runs
(seconds, normally). Then it closes the vCenter session, whatever happened.

```sh
source ~/.vks-golang-web.env
SPEC="$HOME/.config/vks-golang-web/namespace-spec.json"
C="$(jq -r '.cluster // empty' "$SPEC" 2>/dev/null)"
P="$(vc "/clusters/${C}" | jq -r '.network_provider // empty')"
H="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w '%{http_code}')"
if [ ! -s "$VC_SESSION" ]; then
  echo "STOP: no vCenter session is open. Run the first block of 'Open a vCenter session and find the Supervisor's cluster' again. Nothing was created."
elif [ "$(jq -r '.namespace // empty' "$SPEC" 2>/dev/null)" != "$VKS_NAMESPACE" ]; then
  echo "STOP: the filled description is missing, or is for another namespace. Run the block above again."
elif [ "$P" != VSPHERE_NETWORK ]; then
  echo "STOP: this Supervisor's network provider is '${P:-unknown}', not VSPHERE_NETWORK. Nothing was created."
elif [ "$H" = 200 ]; then
  echo "STOP: a vSphere Namespace named '${VKS_NAMESPACE}' already exists. Nothing was changed."
elif [ "$H" != 404 ]; then
  echo "STOP: vCenter did not say whether '${VKS_NAMESPACE}' exists (HTTP ${H}). Nothing was created."
else
  B="$(mktemp)"
  CODE="$(vc_api /namespaces/instances -X POST -H 'Content-Type: application/json' --data-binary "@${SPEC}" -o "$B" -w '%{http_code}')"
  if [ -s "$B" ]; then cat "$B"; echo; fi
  rm -f "$B"
  echo "create: HTTP ${CODE:-no answer}"
  if [ "$CODE" = 204 ]; then
    n=0; S=""
    until [ "$S" = RUNNING ] || [ "$S" = ERROR ] || [ "$n" -ge 40 ]; do
      [ "$n" -eq 0 ] || sleep 15
      n=$((n + 1))
      S="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" | jq -r '.config_status // empty')"
      echo "status: ${S:-no answer yet} (read ${n})"
    done
    vc_api "/namespaces/instances/${VKS_NAMESPACE}" | jq -r '"\(.config_status)  networks: \([.networks[]?] | join(","))  VM classes: \([.vm_service_spec.vm_classes[]?] | join(","))"'
  else
    echo "Not created: vCenter did not accept the description, so nothing is waited for."
  fi
fi
vc_logout
```

**Expect:** `create: HTTP 204`, one or more `status:` lines, the last one
`status: RUNNING (read <a number>)`, then
`RUNNING  networks: <a network name>  VM classes: <your classes>`, then `vCenter session closed`.
Now run both blocks of [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have).

**If not:**
- `create: HTTP 403`, then `Not created: …`: your SSO user may not create namespaces. Nothing
  was created: see [NAMESPACE.md](NAMESPACE.md#if-you-are-not-a-vcenter-administrator).
- `create: HTTP no answer`: vCenter did not answer in time, and the namespace may or may not
  exist. Run `vc_login`, then this block again: it says `already exists` if it does.
- `create: HTTP 400`, with a message above it: vCenter refused the description, and the message
  names the field. A VM class or a user that does not exist is the usual cause. Fix the value in
  the env file, then run *Fill the namespace's description* and this block again.
- `create: HTTP 401`, or `STOP: … (HTTP 401)`: the session ended. Run `vc_login`, then this
  block again.
- `STOP: … already exists`: this guide never changes a namespace that exists. If it is yours,
  check it ([Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have)); if not,
  choose another name.
- `STOP: … network provider …`: see *Read the Supervisor's network type*.
- `status: ERROR`, or no `RUNNING` after 10 minutes: open the namespace in the vSphere Client;
  its **Summary** shows the reason.
- `networks:` with nothing after it: the namespace has no workload network, and a cluster in it
  would get no addresses. Tell your administrator before you create a cluster.

Do not send a changed description to a namespace that exists. The list of VM classes in an
update *replaces* the namespace's list: a class an administrator added by hand, and that your
file does not name, is removed, and running clusters that use it are left without their class.
Change an existing namespace in the vSphere Client: [NAMESPACE-manual.md](NAMESPACE-manual.md)
shows where its storage, VM classes and permissions are.

## Create it with kubectl (Namespace Self-Service)

Do this INSTEAD of [Create it with the vCenter API](#create-it-with-the-vcenter-api), and only
when your administrator switched on Namespace Self-Service on the Supervisor. With
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

**If not:** `no` — Namespace Self-Service is off, or your user is not on its list. Take
[Create it with the vCenter API](#create-it-with-the-vcenter-api) or
[NAMESPACE-manual.md](NAMESPACE-manual.md).

Set `VKS_NAMESPACE` in `~/.vks-golang-web.env` to the new name (lower-case letters, digits and
`-`). Then create the namespace:

```sh
source ~/.vks-golang-web.env
if [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE" --ignore-not-found -o name)" ]; then
  echo "A namespace named '${VKS_NAMESPACE}' already exists (not changed)"
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" create namespace "$VKS_NAMESPACE"
  n=0
  until [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get virtualmachineclass -o name 2>/dev/null)" ] || [ "$n" -ge 12 ]; do
    sleep 5; n=$((n + 1))
  done
fi
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE" -o jsonpath='{.metadata.name}{"  self-service: "}{.metadata.annotations.vmware-system-self-service-namespace}{"\n"}'
```

**Expect:** `namespace/<your namespace> created`, then, after up to a minute while the
template's VM classes arrive, `<your namespace>  self-service: true`.
Now run both blocks of [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have):
they show what the template gave the namespace.

**If not:**
- `Forbidden`: the check above did not answer `yes`.
- `already exists (not changed)`, then `self-service:` with nothing after it: the name belongs
  to a namespace made another way. Use it only if it is yours.

`kubectl` cannot change this namespace afterwards (`kubectl label` and `kubectl annotate` are
refused), and it cannot delete a namespace that someone else made.

## Remove the namespace

**Deleting a vSphere Namespace destroys everything in it**: every guest cluster with its
virtual machines and disks, every ArgoCD instance, every secret, with no way back. So the two
blocks below delete only a namespace this guide made, and refuse every other one. They also
refuse while the namespace still holds a guest cluster: delete the cluster first, the way it was
made ([with scripts](CLUSTER-auto.md#delete-the-cluster) or
[by hand](CLUSTER-manual.md#8-delete-the-cluster-optional)).

If you created the namespace with the vCenter API, delete it there. This opens a session, reads
the namespace, and deletes it only if its description is the marker text *Fill the namespace's
description* wrote into it. Only if vCenter accepted the delete does it wait until the namespace
is gone. It closes the session, whatever happened.

```sh
source ~/.vks-golang-web.env
M="Created by the golang-web VKS guide (vks/NAMESPACE.md)"
if [ -z "$VKS_NAMESPACE" ]; then
  echo "Not deleting: VKS_NAMESPACE is empty"
elif LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io -o name || echo unknown)"; [ -n "$LEFT" ]; then
  echo "Not deleting '${VKS_NAMESPACE}': guest clusters remain, or could not be listed: ${LEFT}"
elif vc_login; then
  H="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w '%{http_code}')"
  D="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" | jq -r 'if type == "object" then (.description // "") else "" end')"
  if [ "$H" = 404 ]; then
    echo "Nothing to delete: vCenter has no namespace '${VKS_NAMESPACE}'"
  elif [ "$H" != 200 ]; then
    echo "Not deleting '${VKS_NAMESPACE}': vCenter did not show it (HTTP ${H:-no answer})"
  elif [ "$D" != "$M" ]; then
    echo "Not deleting '${VKS_NAMESPACE}': this namespace was not created by this guide. If it is yours, delete it in the vSphere Client."
  else
    CODE="$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -X DELETE -o /dev/null -w '%{http_code}')"
    echo "delete: HTTP ${CODE:-no answer}"
    if [ "$CODE" = 204 ]; then
      n=0
      until [ "$(vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w '%{http_code}')" = 404 ] || [ "$n" -ge 40 ]; do
        n=$((n + 1)); sleep 15
      done
      vc_api "/namespaces/instances/${VKS_NAMESPACE}" -o /dev/null -w 'the namespace now: HTTP %{http_code} (404 means gone)\n'
    else
      echo "Not deleted: vCenter did not accept the delete, so nothing is waited for."
    fi
  fi
  vc_logout
fi
```

**Expect:** `vCenter session opened`, `delete: HTTP 204`, within a minute
`the namespace now: HTTP 404 (404 means gone)`, then `vCenter session closed`.

**If not:**
- `Not deleting: VKS_NAMESPACE is empty`: set it in the env file.
- `Not deleting … guest clusters remain …`: the line names what remains. `unknown` means the
  clusters could not be listed: the Supervisor login ended, or your user may not read the
  namespace.
- `Not deleting … was not created by this guide`: the namespace's description is not this
  guide's marker. That is so for every namespace made in the vSphere Client, by `kubectl`, or by
  an administrator, and also for one you made with an older copy of this guide, whose
  description file had no marker yet. If it is yours, delete it in the vSphere Client:
  [Remove the namespace](NAMESPACE-manual.md#9-remove-the-namespace-optional).
- `delete: HTTP 403`, then `Not deleted: …`: your SSO user may not delete namespaces: a vCenter
  administrator can.
- A code other than 404 on the last line after 10 minutes: run the block again.

If you created the namespace with `kubectl` (Namespace Self-Service), delete it the same way.
The block refuses a namespace that Self-Service did not make. Only the user who created it, or
a user with the **Owner** role on it, may delete it.

```sh
source ~/.vks-golang-web.env
if [ -z "$VKS_NAMESPACE" ]; then
  echo "Not deleting: VKS_NAMESPACE is empty"
elif [ "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns "$VKS_NAMESPACE" -o jsonpath='{.metadata.annotations.vmware-system-self-service-namespace}')" != true ]; then
  echo "Not deleting '${VKS_NAMESPACE}': it was not created with kubectl (Namespace Self-Service), or it could not be read. If it is yours, delete it the way it was made."
elif LEFT="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get clusters.cluster.x-k8s.io -o name || echo unknown)"; [ -n "$LEFT" ]; then
  echo "Not deleting '${VKS_NAMESPACE}': guest clusters remain, or could not be listed: ${LEFT}"
else
  kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" delete namespace "$VKS_NAMESPACE" --ignore-not-found
fi
```

**Expect:** `namespace "<your namespace>" deleted` (it can take a minute).

**If not:**
- `Not deleting … was not created with kubectl …`: a `NotFound` line above it means the
  namespace is already gone. Otherwise the namespace was made another way: use the block above
  for one made with the vCenter API, and the vSphere Client for any other.
- `admission webhook … denied the request … is not associated with namespace`: you did not
  create this namespace and are not its Owner. Its Owner, or a vCenter administrator, can
  delete it.

To remove what this chapter wrote on your machine (the env file itself belongs to the main
guide):

```sh
source ~/.vks-golang-web.env
vc_logout
rm -f "$HOME/.config/vks-golang-web/namespace-spec.json"
unset VSPHERE_CLUSTER_ID STORAGE_POLICY STORAGE_POLICY_ID NAMESPACE_VM_CLASSES \
      NAMESPACE_VM_CLASSES_JSON NAMESPACE_USER NAMESPACE_DOMAIN NAMESPACE_ROLE
```

**Expect:** no output (`vCenter session closed` if a session was still open). The four settings
stay in the env file, which the last block of [CLEANUP.md](CLEANUP.md) deletes; the helper commands
belong to the main guide.

## Fix common problems

| symptom | fix |
|---|---|
| `vc_api: no vCenter session — run vc_login` | A block was run after `vc_logout`, or without *Open a vCenter session*. Run `vc_login`, then the block again. |
| `ERROR: UNAUTHENTICATED`, or `HTTP 401`, from a vCenter block | The vCenter session ended. Run `vc_login` (once), then the block again. |
| `vc_login: command not found`, or `vc_api: command not found` | Your `~/.vks-golang-web.functions` was written by an older version of the main guide. Run the main guide's first block again: it rewrites that file and keeps your values. |
| `error: You must be logged in to the server (Unauthorized)` | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's *Renew the Supervisor login* block. |
| The namespace exists in vCenter but `kubectl get ns` answers `Forbidden` | Your SSO user is not in the namespace's permissions, or it was added after you logged in. Ask for the **Edit** role, then run the main guide's *Delete the Supervisor login* block and log in again. |
| A cluster is refused with a message about the VM class or the storage class | The namespace does not have that class. The second block of [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have) lists what it has. |

## Next

Run both blocks of [Check the namespace you have](NAMESPACE.md#check-the-namespace-you-have),
then go on with [Use or create a guest cluster](CLUSTER.md).
