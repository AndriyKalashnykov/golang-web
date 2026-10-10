# Install Harbor onto Supervisor

This guide installs the Harbor Supervisor Service on a vSphere Supervisor with vCenter's API,
gets Harbor a DNS name, and prepares it for [the main guide](README.md): a trusted CA, a project
and a robot account. It has 10 steps; step 10 is optional clean-up. It was written for VMware
Cloud Foundation 9.1.1 and Harbor Service 2.15.2.

The same result by hand, in the vSphere Client, is in [HARBOR-manual.md](HARBOR-manual.md). If
your company already has a Harbor, you need neither: see [HARBOR.md](HARBOR.md).

It continues the main guide and uses its env file, its tools and its Supervisor login. Run the
blocks in order, by copy and paste, in `bash` or `zsh`, on Linux or macOS. Each block is followed
by **Expect:** — what you should see — and, where it can go wrong, **If not:** — what to do. A
block you run twice either changes nothing or tells you what to do.

## Learn the terms

The main guide's [terms](README.md#learn-the-terms) apply. New here:

| term | meaning |
|---|---|
| Supervisor Service | an add-on a vCenter administrator installs on a Supervisor |
| Harbor Service | the Supervisor Service that runs one Harbor on the Supervisor |
| service manifest | the `.yml` file from Broadcom that describes the Harbor Service to vCenter |
| data values | the second `.yml` file from Broadcom: Harbor's settings, with placeholders you replace |
| configuration file | your filled-in copy of the data values; it holds Harbor's passwords |
| secrets file | a file only you can read, with the seven passwords and keys this Harbor is installed with |
| storage class | a kind of disk the Supervisor offers; Harbor needs one for its five volumes |
| LoadBalancer address | the IP address the Supervisor gives Harbor when it is installed |
| A record | the DNS entry that makes a name resolve to an IP address |
| Trivy | the scanner inside Harbor that checks pushed images for known vulnerabilities |

## Gather what you need

- The main guide's *Set the variables*, *Install the tools* (no container engine is needed for
  the install itself) and *Log in to the Supervisor* done on this machine (step 1 below checks
  it).
- An SSO user with the vCenter privileges **Manage Supervisor Services** and **Manage Supervisor
  Services on Supervisors**, who can also read Secrets on the Supervisor (a vCenter
  administrator can). If yours lacks them, send your vCenter administrator the request in
  [HARBOR.md](HARBOR.md).
- A Broadcom support account that can download **vSphere Supervisor Services** (step 2).
- The Supervisor must reach `projects.packages.broadcom.com` (it downloads Harbor from there).
  Harbor's scanner, Trivy, also fetches its data from `ghcr.io`.
- A storage class on the Supervisor with room for about 18 GiB (more if you choose a larger
  registry in step 4), and one free load-balancer address.
- Someone who can create a DNS record (step 6).

## 1. Check the main guide's steps and add the settings

This confirms the tools, the helper commands, the vCenter CA file and the Supervisor login, and
tells you whether this Supervisor already runs a Harbor.

```sh
source ~/.vks-golang-web.env
for t in curl openssl jq awk base64 kubectl; do
  command -v "$t" >/dev/null 2>&1 || echo "MISSING: $t"
done
for f in harbor_cfg vc_login vc vc_logout; do
  command -v "$f" >/dev/null 2>&1 || echo "MISSING: the helper command $f"
done
[ -s "$SUPERVISOR_CA" ] || echo "MISSING: the vCenter CA file (main guide, Download and check the vCenter CA)"
echo "Harbor on this Supervisor: $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o name || echo unknown)"
```

**Expect:** no `MISSING` line, then `Harbor on this Supervisor:` with nothing after it.

**If not:**
- `MISSING: <a tool>` or the CA file: do the main guide's part for it.
- `MISSING: the helper command …`: run the first block of the main guide's *Set the variables*
  again; it rewrites `~/.vks-golang-web.functions` and keeps your values.
- `unknown`, with `Unauthorized` above it: run the main guide's
  [Renew the Supervisor login](README.md#renew-the-supervisor-login) block. A kubeconfig that is
  not found: run [Log in to the Supervisor](README.md#log-in-to-the-supervisor).
- `namespace/svc-harbor-…` after the colon: this Supervisor already runs a Harbor. Do not install
  a second one: use it, as [HARBOR.md](HARBOR.md) describes, or go on at step 6.

Add this guide's settings to the env file. A line that is already there is kept, so you can run
this block again at any time.

```sh
E="$HOME/.vks-golang-web.env"
if [ -f "$E" ]; then
  grep -qs '^export HARBOR_MANIFEST=' "$E" || printf '%s\n' 'export HARBOR_MANIFEST="$HOME/Downloads/supervisor-service-harbor-legacy-v2.15.2+vmware.1-vks.1-25639075.yml"' >> "$E"
  grep -qs '^export HARBOR_VALUES_TEMPLATE=' "$E" || printf '%s\n' 'export HARBOR_VALUES_TEMPLATE="$HOME/Downloads/supervisor-service-harbor-data-values-v2.15.2.yml"' >> "$E"
  grep -qs '^export HARBOR_STORAGE_CLASS=' "$E" || printf '%s\n' 'export HARBOR_STORAGE_CLASS=""' >> "$E"
  grep -qs '^export HARBOR_REGISTRY_SIZE=' "$E" || printf '%s\n' 'export HARBOR_REGISTRY_SIZE="10Gi"' >> "$E"
  grep -qs '^export HARBOR_VALUES=' "$E" || printf '%s\n' 'export HARBOR_VALUES="$HOME/.config/vks-golang-web/harbor-data-values.yml"' >> "$E"
  grep -qs '^export HARBOR_SECRETS=' "$E" || printf '%s\n' 'export HARBOR_SECRETS="$HOME/.config/vks-golang-web/harbor-secrets.env"' >> "$E"
  grep -qsF '. "$HARBOR_SECRETS"' "$E" || printf '%s\n' 'if [ -r "$HARBOR_SECRETS" ]; then export HARBOR_ADMIN_PASSWORD="$(. "$HARBOR_SECRETS"; printf %s "$HARBOR_ADMIN_PASSWORD")"; fi' >> "$E"
  grep -qs '^export VC_SESSION=' "$E" || printf '%s\n' 'export VC_SESSION="$HOME/.config/vks-golang-web/vc-session"' >> "$E"
else
  echo "MISSING: $E (main guide, Set the variables)"
fi
```

**Expect:** no output.

The block adds eight lines. `HARBOR_MANIFEST` and `HARBOR_VALUES_TEMPLATE` are where you save the
two downloads of step 2. `HARBOR_STORAGE_CLASS` and `HARBOR_REGISTRY_SIZE` are set in step 4.
`HARBOR_SECRETS` is the secrets file step 3 creates and `HARBOR_VALUES` the configuration file
step 4 writes. The line that starts with `if` makes `HARBOR_ADMIN_PASSWORD` the admin password
from the secrets file, once that file exists, so you never copy it by hand. `VC_SESSION` is used
only by the vCenter API blocks of [HARBOR-auto.md](HARBOR-auto.md).

Now open the env file and set, in the lines the main guide created:

- `HARBOR_FQDN` — the DNS name this Harbor will have. Choose it before you install: Harbor makes
  its certificate for this name, and this guide does not cover changing it afterwards.
- `HARBOR_PROJECT` — the Harbor project step 8 creates for your images.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

## 2. Download the Harbor files

Download two files from Broadcom: the service manifest and the data values. Tick **"I agree to
the Terms and Conditions"** if the page shows it, or the download icon does nothing.

| file | where to click | direct link |
|---|---|---|
| `supervisor-service-harbor-legacy-v2.15.2+vmware.1-vks.1-25639075.yml` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → search **vSphere Supervisor Services** → **Harbor** → 2.15.2 → *Installation Package Manifest (VCF 9.0 or older and disconnected/airgapped VCF 9.1)* | [Harbor 2.15.2](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.15.2&os=&servicePk=545829&language=EN) |
| `supervisor-service-harbor-data-values-v2.15.2.yml` | [My Downloads](https://support.broadcom.com/group/ecx/downloads) → search **vSphere Supervisor Services** → **Harbor** → 2.15.2 → the row with this file name | [Harbor 2.15.2](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.15.2&os=&servicePk=545829&language=EN) |

- Take both files from the same release, 2.15.2: this guide's file names and checksums are for
  that release. If the page opens on another release, choose 2.15.2 in its release list.
- Take the manifest with **legacy** in its name. The page offers a second one without it,
  labelled *Installation Package Manifest (Internet Connected VCF 9.1 and newer)*. The legacy
  file downloads Harbor from `projects.packages.broadcom.com`, the other from a VCF Software
  Depot inside your environment. Use the legacy file when the Supervisor has internet access and
  no Software Depot. This guide does not cover the other file.
- These files are licensed to your Broadcom account. Do not put them, or copies of them, into a
  Git repository.

This block finds the two files and prints their checksums. If you saved them elsewhere than
`~/Downloads`, change `HARBOR_MANIFEST` and `HARBOR_VALUES_TEMPLATE` in the env file first.

```sh
source ~/.vks-golang-web.env
for f in "$HARBOR_MANIFEST" "$HARBOR_VALUES_TEMPLATE"; do
  if [ -f "$f" ]; then
    (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | awk '{h = $1; sub(/.*\//, ""); print "SHA-256: " h "  " $0}'
  else
    echo "Not found: ${f:-a file name that is empty in the env file (step 1)} — download it (table above)"
  fi
done
```

**Expect:** two `SHA-256:` lines, each equal to the value the download page shows for that file
(labelled **SHA2**). For the files named above:

| file | SHA-256 |
|---|---|
| `supervisor-service-harbor-legacy-v2.15.2+vmware.1-vks.1-25639075.yml` | `77115ad171c571a9e76ad234ca8fc9198aebdfc0db90e5244830603b52914902` |
| `supervisor-service-harbor-data-values-v2.15.2.yml` | `52167e43d58bad377c7f10dde87bb9b8e27faacacd9a3d9e1810cb8815f53805` |

**If not:** `Not found: …` — the file is not in `~/Downloads`, or its name differs. A checksum of
`d26fcbf774df52db4963bd34d43c3ac000c6d537a5cb98c81bf0b504fda4ab6e` means you took the manifest
without **legacy** in its name: download the other one. Any other checksum means a damaged or
wrong download: delete the file and download it again; if it still differs, do not use it.

## 3. Make the secrets file

Harbor is installed with seven passwords and keys: the admin password, a 16-character key that
encrypts what Harbor stores, the database password, and four more that Harbor's parts use among
themselves. The data values from Broadcom hold published example values for them, which you must
not use.

This block makes seven random values and saves them in the secrets file, readable only by you.
If the file already exists it is kept as it is. No value is shown.

```sh
source ~/.vks-golang-web.env
mkdir -p "$(dirname "$HARBOR_SECRETS")"
( umask 077; set -C
  { printf "HARBOR_ADMIN_PASSWORD='A%sz'\n"   "$(openssl rand -hex 12)"
    printf "HARBOR_SECRET_KEY='%s'\n"         "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
    printf "HARBOR_DB_PASSWORD='%s'\n"        "$(openssl rand -hex 16)"
    printf "HARBOR_CORE_SECRET='%s'\n"        "$(openssl rand -hex 16)"
    printf "HARBOR_XSRF_KEY='%s'\n"           "$(openssl rand -hex 16)"
    printf "HARBOR_JOBSERVICE_SECRET='%s'\n"  "$(openssl rand -hex 16)"
    printf "HARBOR_REGISTRY_SECRET='%s'\n"    "$(openssl rand -hex 16)"
  } > "$HARBOR_SECRETS" )
chmod 600 "$HARBOR_SECRETS"
( . "$HARBOR_SECRETS"
  echo "secrets file: $(grep -c '^HARBOR_' "$HARBOR_SECRETS") values, secretKey ${#HARBOR_SECRET_KEY} characters, xsrfKey ${#HARBOR_XSRF_KEY} characters" )
```

**Expect:** `secrets file: 7 values, secretKey 16 characters, xsrfKey 32 characters`. When the
file already exists, bash first prints `cannot overwrite existing file` and zsh prints
`file exists`: that is fine, your earlier values are kept.

**If not:** another count or length — the file was edited or cut short. If no Harbor was
installed with it yet, delete it (`rm "$HARBOR_SECRETS"`) and run the block again. Harbor needs
exactly 16 characters for the first key and exactly 32 for the second.

**Keep this file for as long as this Harbor exists**, and keep a copy where you keep other
passwords.

- Anything that changes this Harbor's configuration later sends all seven values again, and they
  must be the same ones. A Harbor that is given a different `HARBOR_SECRET_KEY` can no longer
  read what it encrypted with the old one, and that cannot be repaired.
- vCenter stores the configuration you send and returns it to whoever asks: **everyone who may
  manage Supervisor Services in this vCenter can read these seven values.**
- The admin password starts with `A` and ends with `z` only so that it holds an upper-case
  letter, a lower-case letter and a digit, which Harbor asks of passwords.

## 4. Write the configuration file

The data values from Broadcom are a template: a placeholder host name, placeholder storage
classes and example passwords. This step writes your configuration file from it.

### Choose the storage class and the registry size

Harbor keeps its data on five volumes: the registry (your images), the database, a cache, the job
logs and Trivy's data. Each needs a storage class. List the ones the Supervisor offers:

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get storageclass --no-headers | awk '{print $1}'
```

**Expect:** one name per line. Your vSphere administrator knows which one Supervisor Services may
use; it is a storage policy assigned to the Supervisor.

Open the env file and set:

- `HARBOR_STORAGE_CLASS` — one of the names listed. A name that does not exist is refused at
  install time; an empty one is accepted and Harbor then never starts, with no error.
- `HARBOR_REGISTRY_SIZE` — the size of the registry volume. Broadcom's default is `10Gi`, which
  fills up in regular use; a push to a full registry fails with `blob upload invalid`.
  Choose it now: this guide does not cover growing the volume later. Write it as Kubernetes does,
  for example `50Gi`.

```sh
"${EDITOR:-nano}" ~/.vks-golang-web.env
```

### Write the configuration file

This block copies the template to `$HARBOR_VALUES`, readable only by you, and changes these
values in the copy: the host name; the two switches that give Harbor its own load-balancer
address (so the Contour service is **not** needed); the seven values from the secrets file; the
five storage classes; the registry size. Everything else stays as Broadcom ships it. In
particular the certificate fields stay empty, so Harbor makes its own CA and certificate, and
Trivy stays on. The block prints the lines that hold no secret.

```sh
source ~/.vks-golang-web.env
if [ ! -r "$HARBOR_SECRETS" ] || [ ! -f "$HARBOR_VALUES_TEMPLATE" ] || [ -z "$HARBOR_STORAGE_CLASS" ] || [ -z "$HARBOR_REGISTRY_SIZE" ]; then
  echo "Not written: the secrets file (step 3), the data values (step 2), HARBOR_STORAGE_CLASS or HARBOR_REGISTRY_SIZE is missing"
else
  mkdir -p "$(dirname "$HARBOR_VALUES")"
  rm -f "$HARBOR_VALUES"
  ( umask 077
    set -a; . "$HARBOR_SECRETS"; set +a
    awk '
      function q(v) { return "\"" v "\"" }
      /^[A-Za-z][A-Za-z0-9_]*:/     { top = $1; sub(/:.*/, "", top); k4 = "" }
      /^    [A-Za-z][A-Za-z0-9_]*:/ { k4 = $1; sub(/:.*/, "", k4) }
      /^hostname:/                { print "hostname: " ENVIRON["HARBOR_FQDN"]; next }
      /^enableNginxLoadBalancer:/ { print "enableNginxLoadBalancer: true"; next }
      /^enableContourHttpProxy:/  { print "enableContourHttpProxy: false"; next }
      /^harborAdminPassword:/     { print "harborAdminPassword: " q(ENVIRON["HARBOR_ADMIN_PASSWORD"]); next }
      /^secretKey:/               { print "secretKey: " q(ENVIRON["HARBOR_SECRET_KEY"]); next }
      /^  password:/ && top == "database"   { print "  password: " q(ENVIRON["HARBOR_DB_PASSWORD"]); next }
      /^  secret:/   && top == "core"       { print "  secret: " q(ENVIRON["HARBOR_CORE_SECRET"]); next }
      /^  xsrfKey:/  && top == "core"       { print "  xsrfKey: " q(ENVIRON["HARBOR_XSRF_KEY"]); next }
      /^  secret:/   && top == "jobservice" { print "  secret: " q(ENVIRON["HARBOR_JOBSERVICE_SECRET"]); next }
      /^  secret:/   && top == "registry"   { print "  secret: " q(ENVIRON["HARBOR_REGISTRY_SECRET"]); next }
      /^ +storageClass:/          { sub(/storageClass:.*/, "storageClass: " q(ENVIRON["HARBOR_STORAGE_CLASS"])); print; next }
      /^      size:/ && top == "persistence" && k4 == "registry" { print "      size: " ENVIRON["HARBOR_REGISTRY_SIZE"]; next }
      { print }
    ' "$HARBOR_VALUES_TEMPLATE" > "$HARBOR_VALUES" )
  LEFT="$(grep -cE 'yourdomain\.com|insert-storage-class-name-here|change-it|Harbor12345|0123456789ABCDEF' "$HARBOR_VALUES")"
  SC="$(awk -v want="\"${HARBOR_STORAGE_CLASS}\"" '/^ +storageClass:/ { n++; if ($2 == want) m++ } END { print m + 0 " of " n + 0 }' "$HARBOR_VALUES")"
  SIZE="$(awk '/^[A-Za-z][A-Za-z0-9_]*:/ { top = $1; k4 = "" } /^    [A-Za-z][A-Za-z0-9_]*:/ { k4 = $1 } /^      size:/ && top == "persistence:" && k4 == "registry:" { print $2 }' "$HARBOR_VALUES")"
  grep -E '^(hostname|enableNginxLoadBalancer|enableContourHttpProxy):' "$HARBOR_VALUES"
  echo "storage class fields set to ${HARBOR_STORAGE_CLASS}: ${SC}"
  echo "registry volume: ${SIZE:-not found}"
  echo "placeholders left: ${LEFT}"
  if [ "$LEFT" != 0 ] || [ "$SC" != "5 of 5" ] || [ "$SIZE" != "$HARBOR_REGISTRY_SIZE" ]; then
    rm -f "$HARBOR_VALUES"
    echo "NOT USABLE: the data values are laid out differently from the 2.15.2 file this guide was written for. The configuration file was deleted."
  fi
fi
```

**Expect:**

```
hostname: harbor.example.test
enableNginxLoadBalancer: true
enableContourHttpProxy: false
storage class fields set to <your storage class>: 5 of 5
registry volume: 10Gi
placeholders left: 0
```

with your own host name, storage class and size, and no `NOT USABLE` line.

**If not:**
- `Not written: …` — do the step it names, or set the value in the env file.
- `NOT USABLE: …` — you downloaded another release's data values, or Broadcom changed the file.
  Take the 2.15.2 file (step 2). Do not install with a configuration this block refused.

The configuration file holds the seven values in clear text. Do not print it, attach it to a
ticket or commit it. The clean-up in step 10 deletes it.

## 5. Install the Harbor Service on the Supervisor

This is done once per Supervisor. The blocks use vCenter's API. Broadcom's documentation
describes only the vSphere Client for this; the API calls below are for VCF 9.1.1. `kubectl`
cannot do this step: a Supervisor Service is registered and installed through vCenter.

### Open a vCenter session

Check the password in the env file first: **five failed logins within 3 minutes lock the SSO
user for 5 minutes** (vCenter's default policy).

```sh
source ~/.vks-golang-web.env
vc_login
vc /supervisor-services | jq -r '.[] | "\(.supervisor_service)  \(.state)"'
```

**Expect:** `vCenter session opened`, then the Supervisor Services vCenter knows, one per line
(for example `tkg.vsphere.vmware.com  ACTIVATED`).

**If not:** a `curl:` certificate error — check `VCENTER_FQDN` and the vCenter CA file (main
guide, [Download and check the vCenter CA](README.md#download-and-check-the-vcenter-ca)). `401`
— the user name or password is wrong: fix the env file before you try again. A list that already
shows `harbor.tanzu.vmware.com`: the next blocks skip what is done.

### Check the manifest

This asks vCenter to read the manifest without registering anything, and saves the version it
finds in the env file as `HARBOR_SERVICE_VERSION`, for the blocks that follow.

```sh
source ~/.vks-golang-web.env
B="$(mktemp)"
base64 < "$HARBOR_MANIFEST" | tr -d '\n' | jq -Rs '{spec: {content: .}}' > "$B"
R="$(vc '/supervisor-services?action=checkContent' -X POST -H 'Content-Type: application/json' --data-binary "@$B")"
rm -f "$B"
printf '%s\n' "$R" | jq -r '"\(.content_type)  \(.carvel_apps_check_result.supervisor_service)  \(.carvel_apps_check_result.version)  \(.status)"'
V="$(printf '%s\n' "$R" | jq -r '.carvel_apps_check_result.version // empty')"
if [ -n "$V" ] && ! grep -qs '^export HARBOR_SERVICE_VERSION=' ~/.vks-golang-web.env; then
  printf "export HARBOR_SERVICE_VERSION='%s'\n" "$V" >> ~/.vks-golang-web.env
fi
grep '^export HARBOR_SERVICE_VERSION=' ~/.vks-golang-web.env
```

**Expect:** `CARVEL_APPS_YAML  harbor.tanzu.vmware.com  2.15.2+vmware.1-vks.1  VALID`, then
`export HARBOR_SERVICE_VERSION='2.15.2+vmware.1-vks.1'`. `VALID_WITH_WARNINGS` instead of `VALID`
is what vCenter answers when the service is already registered.

**If not:** `null  null  null  null` or a `jq:` error — vCenter did not accept the file as a
service manifest (is `HARBOR_MANIFEST` the file from step 2?), or the session ended: run
`vc_login`, then the block again. `HTTP 403` or `unauthorized` — your user lacks **Manage
Supervisor Services**. A version in the second line that differs from the first line's — the env
file holds the version of another release: delete that line from the env file and run the block
again.

### Register the service with vCenter

This sends the manifest to vCenter, which then knows the service and this version of it.

```sh
source ~/.vks-golang-web.env
A=/supervisor-services/harbor.tanzu.vmware.com
if [ -z "$HARBOR_SERVICE_VERSION" ]; then
  echo "Not registering: HARBOR_SERVICE_VERSION is empty (run the block above)"
elif vc "$A/versions" | jq -e --arg v "$HARBOR_SERVICE_VERSION" 'type == "array" and any(.[]; .version == $v)' >/dev/null 2>&1; then
  echo "already registered"
else
  B="$(mktemp)"
  base64 < "$HARBOR_MANIFEST" | tr -d '\n' | jq -Rs '{carvel_spec: {version_spec: {content: .}}}' > "$B"
  vc /supervisor-services -X POST -H 'Content-Type: application/json' --data-binary "@$B" -w 'HTTP %{http_code}\n'
  rm -f "$B"
fi
vc "$A/versions" | jq -r '.[] | "version \(.version)  \(.state)"'
```

**Expect:** `HTTP 201` (or `already registered`), then `version 2.15.2+vmware.1-vks.1  ACTIVATED`.

**If not:** `HTTP 403` — your user lacks **Manage Supervisor Services**: send your vCenter
administrator the request in [HARBOR.md](HARBOR.md). `HTTP 400` with a message saying the service
already exists — vCenter knows Harbor in another version only; adding a version to it is an
upgrade, which this guide does not cover. Any other `HTTP 400` — send the message to your
administrator; do not edit the manifest.

### Install it on your Supervisor

This waits until vCenter has verified the manifest's signature, sends the install request with
your configuration file, and waits until vCenter reports the service as configured (a few
minutes). With more than one Supervisor in this vCenter, the block lists them and stops: put the
ID of yours in the env file as `export SUPERVISOR_ID="…"`, run `vc_login`, then the block again.

```sh
source ~/.vks-golang-web.env
SUP="${SUPERVISOR_ID:-$(vc /supervisors/summaries | jq -r 'if (.items | length) == 1 then .items[0].supervisor else empty end')}"
if [ -z "$SUP" ]; then
  vc /supervisors/summaries | jq -r '.items[] | "\(.supervisor)  \(.info.name)"' \
    && echo "Set SUPERVISOR_ID in ~/.vks-golang-web.env to one of the IDs above, run vc_login, then this block again"
elif [ ! -s "$HARBOR_VALUES" ] || [ -z "$HARBOR_SERVICE_VERSION" ]; then
  echo "Not installing: the configuration file (step 4) or HARBOR_SERVICE_VERSION (Check the manifest) is missing"
else
  S="/supervisors/${SUP}/supervisor-services"
  C=200; n=0
  if [ "$(vc "$S/harbor.tanzu.vmware.com" -o /dev/null -w '%{http_code}')" != 200 ]; then
    until [ "$(vc "$S/harbor.tanzu.vmware.com/${HARBOR_SERVICE_VERSION}/signatures" | jq -r '.status // empty' 2>/dev/null)" = TRUSTED ] || [ "$n" -ge 12 ]; do
      n=$((n + 1)); sleep 5
    done
    echo "signature: $(vc "$S/harbor.tanzu.vmware.com/${HARBOR_SERVICE_VERSION}/signatures" | jq -r '.status // "no answer"' 2>/dev/null)"
    B="$(mktemp)"; R="$(mktemp)"
    base64 < "$HARBOR_VALUES" | tr -d '\n' \
      | jq -Rs --arg v "$HARBOR_SERVICE_VERSION" '{supervisor_service: "harbor.tanzu.vmware.com", version: $v, yaml_service_config: .}' > "$B"
    C=500; n=0
    until [ "$C" != 500 ] || [ "$n" -ge 30 ]; do
      [ "$n" -eq 0 ] || sleep 10
      n=$((n + 1))
      C="$(vc "$S" -X POST -H 'Content-Type: application/json' --data-binary "@$B" -o "$R" -w '%{http_code}')"
    done
    echo "install: HTTP ${C} (attempt ${n})"
    case "$C" in 2*) ;; *) jq -r '.messages[]?.default_message' "$R" 2>/dev/null ;; esac
    rm -f "$B" "$R"
  fi
  case "$C" in 2*)
    n=0
    until [ "$(vc "$S/harbor.tanzu.vmware.com" | jq -r --arg v "$HARBOR_SERVICE_VERSION" 'if .config_status == "CONFIGURED" and .current_version == $v then "yes" else "no" end' 2>/dev/null)" = yes ] || [ "$n" -ge 120 ]; do
      n=$((n + 1)); sleep 15
    done
    vc "$S/harbor.tanzu.vmware.com" | jq -r '"\(.config_status)  \(.current_version)  \(.messages[0].details.default_message // "")"'
    ;;
  esac
fi
vc_logout
```

**Expect:** `signature: TRUSTED`, then `install: HTTP 201 (attempt 1)` — a higher attempt number
is normal right after the block above, while vCenter prepares the service — then within a few
minutes `CONFIGURED  2.15.2+vmware.1-vks.1  Reason: ReconcileSucceeded. …`, then
`vCenter session closed`. The first two lines are not printed when the service was already
installed. vCenter marks that last message as a warning; with `ReconcileSucceeded` it is what
success looks like.

`CONFIGURED` means vCenter accepted the install, not that Harbor answers yet. Step 6 waits for
that.

**If not:**
- `install: HTTP 500 (attempt 30)` and a message — `signature verification result not found` or
  `service account is not ready`: vCenter was still not ready after five minutes; run the block
  again (start with `vc_login`). `is in terminating status`: a Harbor uninstalled a moment ago is
  still being removed; wait until step 10's check shows nothing left, then run the block again.
- `install: HTTP 403` — your user lacks **Manage Supervisor Services on Supervisors**.
- `install: HTTP 400` and a message — vCenter refused the configuration: send the message to
  your administrator.
- `signature:` with anything but `TRUSTED` and then a refused install — the manifest is not
  Broadcom's signed file: download it again (step 2).
- A status other than `CONFIGURED` after 30 minutes: the message on that line says why.
  `ReconcileFailed` with an image or download error means the Supervisor cannot reach
  `projects.packages.broadcom.com`: tell your administrator.

<details>
<summary><b>Alternative: the same step in the vSphere Client</b> (Broadcom's documented way)</summary>

The clicks, with screenshots, are *Register the service with vCenter* and *Install the service
on your Supervisor* in [HARBOR-manual.md](HARBOR-manual.md). Use them INSTEAD of the four blocks
above; steps 1 to 4 and 6 to 10 of this guide stay the same.

</details>

## 6. Find Harbor's address and get a DNS record

The Supervisor gives Harbor an IP address when it is installed; you do not choose it. Harbor's
name must resolve to that address from your machine **and** from the nodes of every guest
cluster that pulls images from it.

### Find the address and wait for Harbor

This block finds the namespace the Supervisor made for Harbor, reads the address of Harbor's
`harbor-nginx` service, and waits until Harbor answers there: about 7 to 8 minutes after the
install on a first run. The call needs no DNS record yet (`--resolve` tells `curl` the address)
and sends no password, so it does not check the certificate.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o jsonpath='{.items[*].metadata.name}')"
IP=""; H=000; n=0
until [ "$H" = 200 ] || [ -z "$NS" ] || [ "$n" -ge 80 ]; do
  [ "$n" -eq 0 ] || sleep 15
  n=$((n + 1))
  IP="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$NS" get svc harbor-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  [ -z "$IP" ] || H="$(curl -sk --connect-timeout 10 --resolve "${HARBOR_FQDN}:443:${IP}" -o /dev/null -w '%{http_code}' "https://${HARBOR_FQDN}/api/v2.0/health")"
done
echo "Harbor namespace: ${NS:-not found}"
echo "Harbor address:   ${IP:-none yet}"
echo "Harbor answers:   http=${H}"
echo "DNS record to ask for:  ${HARBOR_FQDN}  A  ${IP:-<no address yet>}"
```

**Expect:** a namespace such as `svc-harbor-…`, an IP address, `http=200`, and the DNS record to
ask for.

**If not:**
- `Harbor namespace: not found` — the service is not installed (step 5), or the Supervisor
  login ended: run the main guide's [Renew the Supervisor login](README.md#renew-the-supervisor-login)
  block, then this one again. Two names on that line mean two Harbor namespaces: send the line to
  your administrator.
- `Harbor address:   none yet` after 20 minutes — the Supervisor has no free load-balancer
  address, or Harbor's pods never started.
- An address but `http=000` or `http=503` after 20 minutes — Harbor's pods are not all running.
  For both, list them and their volumes with the command below. A volume that stays `Pending`
  means the storage class is wrong or was left empty (step 4): uninstall (step 10),
  correct it, install again.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o jsonpath='{.items[*].metadata.name}')"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$NS" get pods,pvc
```

**Expect:** every pod `Running` (or `Completed`) and five volumes `Bound`.

### Get a DNS record

Ask whoever runs your DNS for the record the block printed: an **A record** from `HARBOR_FQDN` to
Harbor's address, in a zone that your machine and the guest clusters' nodes both use.

- A line in your machine's `/etc/hosts` makes your machine find Harbor, but not the nodes: they
  ask the DNS server, and a pull then fails with `no such host`. Use it for a first look at most.
- The address changes when Harbor is uninstalled and installed again. The record must then be
  changed too.

### Check the DNS record

This compares the address your machine reaches Harbor's name at with the address the Supervisor
gave Harbor.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o jsonpath='{.items[*].metadata.name}')"
IP="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$NS" get svc harbor-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
GOT="$(curl -sk --connect-timeout 10 -o /dev/null -w '%{remote_ip}' "https://${HARBOR_FQDN}/api/v2.0/health")"
if [ -n "$IP" ] && [ "$GOT" = "$IP" ]; then
  echo "DNS is right: ${HARBOR_FQDN} is ${IP}"
else
  echo "DNS is NOT right: ${HARBOR_FQDN} leads to '${GOT:-nothing}', Harbor is at '${IP:-unknown}'"
fi
```

**Expect:** `DNS is right: <your Harbor name> is <the address>`.

**If not:** `leads to 'nothing'` — the name does not resolve yet (a new record can take some
minutes to arrive), or this machine cannot reach the address. Another address — the record is
old or wrong; a company proxy also causes this. `Harbor is at 'unknown'` — the Supervisor login
ended, or Harbor is not installed.

This proves the name from your machine only. The check in step 9 proves it from the
cluster's nodes.

## 7. Trust Harbor's CA and log in

Harbor made its own CA when it was installed. Nothing trusts that CA yet, and Harbor sends only
its own certificate, not the CA's, so the CA cannot be taken from the connection.

### Print the fingerprint of Harbor's CA

You installed this Harbor, so you are the administrator the main guide tells its reader to ask.
This block reads the CA certificate from the Supervisor, over your Supervisor login, and prints
its fingerprint. The Secret it reads also holds the CA's private key; the block asks for the
certificate only (`ca.crt`). Never print that Secret whole.

```sh
source ~/.vks-golang-web.env
NS="$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o jsonpath='{.items[*].metadata.name}')"
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$NS" get secret harbor-ca-key-pair -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | openssl x509 -noout -subject -fingerprint -sha256
```

**Expect:** a `subject=` line naming Harbor's CA, then `sha256 Fingerprint=…`
(`SHA256 Fingerprint=` on macOS). This is the fingerprint to give to everyone who will use this
Harbor.

**If not:** `Forbidden` — your user may not read Secrets in Harbor's namespace: use the
fingerprint a vCenter administrator reads for you. An `openssl` error such as
`unable to load certificate` — the Secret was not found: check the namespace with the block in
step 6.

### Download the CA and trust it

Now do three parts of [the main guide](README.md), in this order:

1. [Download and check the Harbor CA](README.md#download-and-check-the-harbor-ca). The
   fingerprint it prints must equal the one printed above, ignoring colons and upper/lower case.
   If it differs, do not continue: the name leads to another server.
2. [Install the CA for your engine](README.md#install-the-ca-for-your-engine), if you will push
   images from this machine.
3. [Check the CA file](README.md#check-the-ca-file). It must print `http=200`.

### Log in as admin

This logs in to Harbor's API as `admin`, with the password from the secrets file and with the
certificate checked. Nothing is shown of the password.

```sh
source ~/.vks-golang-web.env
harbor_cfg && curl -sS --cacert "$HARBOR_CA" -K "$CFG" "https://${HARBOR_FQDN}/api/v2.0/users/current" \
  | jq -r 'if .username then "logged in as \(.username), administrator: \(.sysadmin_flag)" else "ERROR \(.errors[0].code): \(.errors[0].message)" end'
rm -f "$CFG"
```

**Expect:** `logged in as admin, administrator: true`.

**If not:**
- `harbor_cfg: empty user or password` — the env file does not read the secrets file: run
  step 1's settings block again, then this one.
- `ERROR UNAUTHORIZED` — this Harbor was installed with another admin password than the one in
  your secrets file, or someone changed it in Harbor since.
- A `curl:` certificate error — the CA file is not this Harbor's: do *Download the CA and trust
  it* again.

Harbor's web page is `https://<your Harbor name>`; log in there as `admin`. This prints the
password (anyone who can read your screen can then log in, so clear the terminal afterwards):

```sh
source ~/.vks-golang-web.env
( . "$HARBOR_SECRETS"; printf '%s\n' "$HARBOR_ADMIN_PASSWORD" )
```

**Expect:** the password, on a line of its own.

The browser warns about the certificate until the CA is in its trust store. Safari and Chrome on
macOS refuse the page even then: Harbor's certificate is valid for ten years, and macOS accepts
at most 825 days from a private CA. The command-line tools in these guides are not affected.

## 8. Create a project and a robot account

A new Harbor has one project, `library`. Images go into a project of your own.

### Create the project

This creates the project named by `HARBOR_PROJECT`, as a **private** one (Harbor's default): the
cluster then needs a pull secret, which the main guide creates. For a project anyone who reaches
Harbor may pull from without a login, change `false` to `true` before you run the block.

```sh
source ~/.vks-golang-web.env
harbor_cfg && jq -nc --arg p "$HARBOR_PROJECT" '{project_name: $p, public: false}' \
  | curl -sS --cacert "$HARBOR_CA" -K "$CFG" -X POST -H 'Content-Type: application/json' --data-binary @- \
      -o /dev/null -w 'create project: http=%{http_code}\n' "https://${HARBOR_FQDN}/api/v2.0/projects"
rm -f "$CFG"
```

**Expect:** `create project: http=201`, or `http=409` when the project already exists (it is
left as it is, also its public or private setting).

**If not:** `http=401` — the admin password is wrong (see *Log in as admin* in step 7).
`http=400` — Harbor refused the name: use lower-case letters and digits.

### Create a robot account and log in

Do the main guide's [Option A — create a robot account](README.md#option-a--create-a-robot-account),
which makes a robot that may push to and pull from this project only, and put its name and secret
in the env file as that section says. Then run
[Log the container engine in to Harbor](README.md#log-the-container-engine-in-to-harbor).

The main guide goes on from there: it builds the image, pushes it to this Harbor and deploys it.

## 9. Check that a guest cluster can pull from Harbor

Do this when you have a guest cluster and its kubeconfig ([the main guide](README.md),
*Get the guest cluster's kubeconfig*); skip it until then. A node must do two
things your machine has already done: find Harbor by name, and trust its certificate.

- **The name:** the nodes ask the DNS server their network gives them. This block is the check.
- **The certificate:** a guest cluster under the **same Supervisor** as this Harbor trusts
  Harbor's CA without any setting. A cluster elsewhere, or a Harbor with a CA of your own, needs
  the CA in the cluster's `osConfiguration.trust.additionalTrustedCAs` variable, which replaces
  the cluster's nodes one by one; see Broadcom's
  [example cluster with additional trusted CA certificates](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/using-the-versioned-clusterclass/v1beta1-example-cluster-with-additional-trusted-ca-certificates-for-ssl-tls.html)
  (written for VCF 9.0). This guide does not cover it.

The block asks the cluster to start a pod from an image that does not exist in your project, and
reads why the pull failed. *Not found* or *access denied* is the good answer: the node found
Harbor, trusted it, and Harbor said no. Nothing has to be pushed first, and the pod never runs.
The real proof is the main guide's deploy step, which pulls your image.

```sh
source ~/.vks-golang-web.env
kubectl -n default delete pod harbor-pull-check --ignore-not-found >/dev/null
kubectl -n default apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: harbor-pull-check
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: check
    image: ${HARBOR_FQDN}/${HARBOR_PROJECT}/pull-check:none
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
EOF
M=""; n=0
until [ -n "$M" ] || [ "$n" -ge 18 ]; do
  n=$((n + 1)); sleep 5
  M="$(kubectl -n default get events --field-selector involvedObject.name=harbor-pull-check,reason=Failed -o jsonpath='{.items[*].message}')"
done
kubectl -n default delete pod harbor-pull-check --ignore-not-found >/dev/null
case "$M" in
  "")                echo "NO ANSWER: the cluster reported no pull attempt in 90 seconds" ;;
  *"no such host"*)  echo "DNS: the nodes cannot resolve ${HARBOR_FQDN}" ;;
  *x509*)            echo "CA: the nodes do not trust the certificate of ${HARBOR_FQDN}" ;;
  *"not found"*|*"access denied"*|*nauthorized*|*insufficient_scope*)
                     echo "OK: the nodes resolve ${HARBOR_FQDN} and trust its certificate" ;;
  *)                 echo "OTHER: ${M}" ;;
esac
```

**Expect:** `pod/harbor-pull-check created`, then within a minute
`OK: the nodes resolve <your Harbor name> and trust its certificate`.

**If not:**
- `DNS: …` — the nodes' DNS server does not have the record. An `/etc/hosts` line on your machine
  does not help them: get the A record created (see *Get a DNS record* in step 6).
- `CA: …` — the cluster is not under this Harbor's Supervisor, or Harbor has another CA than the
  one the Supervisor knows: see the certificate note above.
- `OTHER: …` with `i/o timeout` or `connection refused` — the nodes resolve the name but cannot
  reach the address: a network or firewall matter for your administrator.
- `NO ANSWER: …` — `kubectl` does not reach the guest cluster, or the pod was refused: run
  `kubectl -n default get events` and read the last lines.

## 10. Uninstall Harbor (optional)

**Uninstalling destroys everything this Harbor holds**: every image, every project, every robot
account and the database, on all five volumes. Nothing of it can be brought back, and a new
install starts empty, with a new address and a new CA. Copy the images you still need to another
registry first.

### Uninstall Harbor from the Supervisor

This removes Harbor from your Supervisor and waits until its namespace is gone: a few minutes.
The service stays registered in vCenter, so it can be installed again with step 5's last block.

```sh
source ~/.vks-golang-web.env
vc_login
SUP="${SUPERVISOR_ID:-$(vc /supervisors/summaries | jq -r 'if (.items | length) == 1 then .items[0].supervisor else empty end')}"
if [ -z "$SUP" ]; then
  echo "Not uninstalling: this vCenter has more than one Supervisor and SUPERVISOR_ID is not set in the env file"
else
  S="/supervisors/${SUP}/supervisor-services/harbor.tanzu.vmware.com"
  vc "$S" -X DELETE -o /dev/null -w 'uninstall: HTTP %{http_code}\n'
  n=0
  until [ "$(vc "$S" -o /dev/null -w '%{http_code}')" = 404 ] || [ "$n" -ge 40 ]; do
    n=$((n + 1)); sleep 15
  done
  n=0
  until [ -z "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o name || echo unknown)" ] || [ "$n" -ge 40 ]; do
    n=$((n + 1)); sleep 15
  done
  echo "left (nothing after the colon means gone): $(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o name || echo unknown)"
fi
vc_logout
```

**Expect:** `vCenter session opened`, `uninstall: HTTP 204`, within a few minutes
`left (nothing after the colon means gone):` with nothing after it, then
`vCenter session closed`.

**If not:** `uninstall: HTTP 404` — Harbor was not installed on this Supervisor. A name, or
`unknown`, after the colon: the namespace is still being deleted, or the Supervisor login ended.
Run the block again before you install again or go on. Do not remove the namespace's finalizers
by hand to speed it up.

### Remove the service from vCenter

Only if no Supervisor of this vCenter will run this Harbor version again. The three calls must
come in this order: vCenter refuses to remove a service that is still active or still has a
version.

```sh
source ~/.vks-golang-web.env
vc_login
A=/supervisor-services/harbor.tanzu.vmware.com
if [ -z "$HARBOR_SERVICE_VERSION" ] || [ -n "$(kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o name || echo unknown)" ]; then
  echo "Not removing: Harbor is still installed (or could not be checked), or HARBOR_SERVICE_VERSION is empty"
else
  vc "$A?action=deactivate" -X PATCH -o /dev/null -w 'deactivate: HTTP %{http_code}\n'
  vc "$A/versions/${HARBOR_SERVICE_VERSION}" -X DELETE -o /dev/null -w 'remove the version: HTTP %{http_code}\n'
  vc "$A" -X DELETE -o /dev/null -w 'remove the service: HTTP %{http_code}\n'
fi
vc_logout
```

**Expect:** `vCenter session opened`, then three lines ending `HTTP 204` (`deactivate`,
`remove the version`, `remove the service`), then `vCenter session closed`.

**If not:** `Not removing: …` — run *Uninstall Harbor from the Supervisor* first. A line that
does not end in `HTTP 204`: run the block again; `HTTP 400` on *remove the service* means a step
before it did not finish, or vCenter holds another version of the service.

### Delete what this guide wrote

Run this when the Harbor is gone for good. It deletes the configuration file and the secrets
file: after that, nobody can install this Harbor again with the same values. Ask for the DNS
record to be removed too, and remove Harbor's CA from your machine with the main guide's
*Remove the Harbor CA*.

```sh
source ~/.vks-golang-web.env
rm -f "$HARBOR_VALUES" "$HARBOR_SECRETS"
```

**Expect:** no output. The settings step 1 added to the env file stay; they do no harm.

## Fix common problems

| symptom | fix |
|---|---|
| `vc: no vCenter session — run vc_login` | A step 5 or step 10 block was run without the one before it, or after `vc_logout`. Run `vc_login`, then the block again. |
| A step 5 block prints `unauthenticated` or `HTTP 401` | The vCenter session ended. Run `vc_login` (once), then the block again. |
| `vc_login: command not found` | Run the first block of the main guide's *Set the variables* again; it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| `install: HTTP 500` on every attempt | Read the message under it: step 5's **If not** names the three causes. |
| `error: You must be logged in to the server (Unauthorized)`, or `Harbor namespace: not found` although Harbor is installed | Your Supervisor login ended (it lasts about 10 hours). Run the main guide's [Renew the Supervisor login](README.md#renew-the-supervisor-login) block, then the block again. If you logged in with the certificate-checking alternative, use the renew block inside that alternative instead. |
| `harbor_cfg: command not found` | Run the first block of the main guide's *Set the variables* again; it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| Harbor's volumes stay `Pending` and Harbor never answers | A storage class was left empty or misspelled when the configuration file was written (step 4). Uninstall (step 10), correct `HARBOR_STORAGE_CLASS`, write the file again, install again. |
| The service's status is an error that names an image or a download | The Supervisor cannot reach `projects.packages.broadcom.com`: tell your administrator. If the message names `depot.kube-system.svc`, the manifest without **legacy** was used (step 2). |
| The name does not resolve on the nodes (`no such host` in a pod's events) | The A record is missing in the DNS the nodes use, or is only in your `/etc/hosts`. See *Get a DNS record* in step 6. |
| Everything worked, then every push and pull fails after Harbor was installed again | A new install has a new address, a new CA and an empty registry: change the DNS record, download and install the CA again (step 7), and create the project and the robot again (step 8). |
| `blob upload invalid` on push | The registry volume is full. In Harbor's web page delete what you do not need, then run **Administration** → **Clean Up** → **Garbage Collection**; deleting alone frees no space. |
| Harbor's page shows scans that fail or never finish | Trivy downloads its vulnerability data from `ghcr.io`. Without that access scans fail; pushes and pulls still work. |
| An install right after an uninstall answers `HTTP 500` with `is in terminating status` | The old namespace is still being deleted. Wait until step 10's check shows nothing left, then install again. |
| You want a newer Harbor release | Upgrading is not covered. The step from 2.14 to 2.15 converts Harbor's database to a newer PostgreSQL, which cannot be undone, and in this guide's test environment Harbor did not start afterwards. Plan it with Broadcom's documentation and a backup. |
