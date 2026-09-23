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

### 1. The Mac's last run used values that are ALL STALE

| it used | actual (measured on the lab host, 2026-09-23) |
|---|---|
| `SUPERVISOR_ENDPOINT=172.17.0.4` | **192.168.101.128** (`https://…/` → 200) |
| `VCENTER_FQDN=vksa.mgmt.vks.lab` | **vcsa.env1.lab.test** = 192.168.100.50 |
| `HARBOR_FQDN=harbor.mgmt.vks.lab` | domain is **env1.lab.test** — Harbor's own name/IP is **UNVERIFIED**, see 2 |

### 2. Harbor's presence is UNKNOWN — establish it first, on the lab host

```sh
cd ~/projects/nested-vsphere-lab
make kubectl-login      # ⚠️ SPENDS AN SSO ATTEMPT; 3 failures = PERMANENT lockout. Never guess.
make creds              # now prints the HARBOR and ARGOCD sections it could not read before
```

`make creds` currently says it *cannot read* Harbor because the kubeconfig expired, and is
careful to add that this is **not** "Harbor is absent". `harbor-ca/ca.crt` in the lab state dir
is dated Sep 21, so one existed recently. If it is genuinely gone, `make services` installs it.

### 3. Give the Mac a route — DNS alone will NOT do it

`make creds` states it verbatim: *"THESE URLs RESOLVE AND ROUTE ONLY WHERE THE LAB RUNS — this
host."* Those addresses live on the lab host's libvirt bridges, so `/etc/hosts` entries on the
Mac cannot help by themselves; the packets have nowhere to go. Forward the ports instead:

```sh
# on the Mac. 443 is privileged, hence sudo. Keep the FQDN so TLS SAN matching still works.
sudo ssh -N -L 443:<harbor-ip>:443 andriy@<lab-host>
printf '127.0.0.1 harbor.env1.lab.test\n' | sudo tee -a /etc/hosts
```

The forward must terminate on the **FQDN**, not `localhost` — pointing the Mac at
`https://localhost` breaks certificate verification and P4 then measures the wrong failure.

### 4. Then the two-run experiment. ONE run cannot show it.

```sh
export HARBOR_FQDN=harbor.env1.lab.test VCENTER_FQDN=vcsa.env1.lab.test \
       SUPERVISOR_ENDPOINT=192.168.101.128
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
