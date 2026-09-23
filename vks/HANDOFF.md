# HANDOFF — `vks/` macOS verification

Resume point for the `vks/README.md` work. Read this before touching `vks/`.

## Where it stands

`vks/README.md` builds `golang-web`, pushes to Harbor, deploys to a VKS guest cluster.
It is **proven end-to-end on Linux, twice, with podman and with docker**, every block run
standalone. Pinned to **VCF CLI 9.1.1.0** (`vcf version` → `v9.1.1.0.25662425`).

`vks/macosx.sh` checks the macOS-specific claims and writes `vks/macosx.res` beside itself.
Run it, commit the `.res`. It needs **no lab** — lab probes report SKIPPED.

## ▶ THE NEXT ACTION — one claim is still unverified, and it needs the lab reachable FROM THE MAC

**P4, the login baseline:** that `podman login` fails with `x509: certificate signed by
unknown authority` *before* the CA is trusted and stops failing that way *after*. That is the
entire justification for README section 3, and no run has ever measured it.

### 1. The endpoints — CONFIRMED on the lab host 2026-09-23, after `make kubectl-login`

| | value | evidence |
|---|---|---|
| `HARBOR_FQDN` | **harbor.env1.lab.test** = 192.168.101.130 | `/api/v2.0/health` → **200** |
| `VCENTER_FQDN` | **vcsa.env1.lab.test** = 192.168.100.50 | `POST /api/session` → 401 (the unauthenticated reply) |
| `SUPERVISOR_ENDPOINT` | **192.168.101.128** | `https://…/` → **200** |
| ArgoCD | argocd.env1.lab.test = 192.168.101.131 | namespace `lab` |
| Harbor namespace | `svc-harbor-90dbv` | platform-chosen, not from `input.yaml` |
| `VKS_NAMESPACE` | **lab** | `cicd` also exists and has its own cluster |
| `VKS_CLUSTER` | **lab-gc1** | Provisioned + Available, `builtin-generic-v3.7.0`, **v1.36.2+vmware.2** |
| guest kubeconfig | secret `lab-gc1-kubeconfig` in ns `lab` | the Pinniped-free path README step 8b uses |

**Harbor is installed and healthy** — the earlier "UNKNOWN" is resolved. Its CA verifies it:
`curl --cacert .../harbor-ca/ca.crt` → 200, and the CA that README step 3 *fetches* from
`/api/v2.0/systeminfo/getcert` is **byte-identical** to the stored one, so that step's mechanism
is already proven against this Harbor from the lab host.

⚠️ The Mac's last run used `*.mgmt.vks.lab` and `172.17.0.4`. **Every one of those is stale** —
they belong to an older lab generation. Use the table above.

⚠️ `make creds` warns: use **`podman login --cert-dir`**, not `docker login` — docker reads its
CA from the root-owned `/etc/docker/certs.d`, podman takes `--cert-dir` and needs no sudo. On the
Mac podman is the working engine anyway (docker CLI is present with no daemon).

### 2. Give the Mac a route — DNS alone will NOT do it

`make creds` states it verbatim: *"THESE URLs RESOLVE AND ROUTE ONLY WHERE THE LAB RUNS — this
host."* Those addresses live on the lab host's libvirt bridges, so `/etc/hosts` entries on the
Mac cannot help by themselves; the packets have nowhere to go. Forward the ports instead:

```sh
# on the Mac. 443 is privileged, hence sudo. Keep the FQDN so TLS SAN matching still works.
sudo ssh -N -L 443:192.168.101.130:443 andriy@<lab-host>   # Harbor
printf '127.0.0.1 harbor.env1.lab.test\n' | sudo tee -a /etc/hosts
```

The forward must terminate on the **FQDN**, not `localhost` — pointing the Mac at
`https://localhost` breaks certificate verification and P4 then measures the wrong failure.

### 3. Then the two-run experiment. ONE run cannot show it.

```sh
export HARBOR_FQDN=harbor.env1.lab.test      # 192.168.101.130
export VCENTER_FQDN=vcsa.env1.lab.test       # 192.168.100.50
export SUPERVISOR_ENDPOINT=192.168.101.128
export VKS_NAMESPACE=lab VKS_CLUSTER=lab-gc1
./vks/macosx.sh                 # BEFORE trust — P4 must say x509 unknown authority
#   then README section 3: security add-trusted-cert + podman machine set --import-native-ca
#                          + podman machine stop && podman machine start
./vks/macosx.sh                 # AFTER  trust — the error must CHANGE to auth (401/unauthorized)
```

TLS-failure → auth-failure is the proof. `probe`/`x` stays a bad credential either way, so a
*successful* login would mean the CA was already trusted.

## Settled — do not re-derive

Measured on macOS 26.6.2 / arm64 / bash 3.2.57 / podman 6.1.2 (`vks/macosx.res`):

| | |
|---|---|
| `engine_remote=true` | macOS runs a Linux VM — the reason every macOS/Linux split in section 3 exists |
| `import_native_ca=yes` | the flag section 3's podman path depends on |
| `xarch_build=ok` | `--platform linux/amd64` builds, and the image really is `linux/amd64` |
| `install -D` | **NOT supported** (BSD) — its Linux-only placement is load-bearing |
| `base64 -d` | works — step 8b is safe on both platforms |
| `group "root"` | **does not exist** on macOS — `install -g root` would fail |
| `rosetta2=yes` | on *this* Mac; the README now warns for the next one |
| `KUBECTL_VERSION` | the README's default **v1.36.2** matches the guest cluster exactly — no upstream fallback needed here |
| docker | CLI present, daemon down → `brew install docker` is client-only |

Checked against podman's own docs rather than assumed, for the trust block's ORDER: `--import-native-ca` imports
*"during machine startup"*, so `set` → `stop && start` is correct, and the bare flag is valid.

## Traps already paid for

- **Gate on OUTPUT, not exit status.** `vcf plugin list` prints a valid table **and exits
  non-zero**; a status-gated check calls a working command broken.
- **`mktemp -t PREFIX` is not portable.** BSD reads a prefix, GNU wants a template and errors,
  leaving the variable empty. Use plain `mktemp` / `mktemp -d`.
- **An authfile must not pre-exist.** `mktemp` creates it empty and podman parses it as JSON,
  dying before it reaches the network — that silently broke P4 for three runs.
- **`vcf plugin list` stalls ~25 s** on an unreachable plugin registry. It is a network timeout,
  not an empty plugin set.
- The `.res` in git is the **Mac's** run. Running the script locally overwrites it —
  `git checkout vks/macosx.res` afterwards.
