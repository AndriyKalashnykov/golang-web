# HANDOFF — `vks/` macOS verification

Resume point for the `vks/README.md` work. Read this before touching `vks/`.

## Where it stands

`vks/README.md` builds `golang-web`, pushes to Harbor, deploys to a VKS guest cluster.
It is **proven end-to-end on Linux, twice, with podman and with docker**, every block run
standalone. Pinned to **VCF CLI 9.1.1.0** (`vcf version` → `v9.1.1.0.25662425`).

macOS is proven too — see the next section. The old probe script `vks/macosx.sh` and its
`vks/macosx.res` were REMOVED (2026-09-23): running every README block verbatim on a real Mac
superseded the subset they checked. They are in git history; references to them below are history.

## ✅ THE WHOLE README PROVEN ON macOS, BOTH ENGINES — 2026-09-23

Every macOS block run VERBATIM in zsh on the rented Mac (macOS 26.6.2, arm64), selected by exact
heading, against this lab: **podman §1–§11 and docker/Colima §2–§11 both pass** — build (amd64 on
arm64), push to Harbor, deploy by digest, reach the app (LB + port-forward), clean up. Linux podman
§3–§11 re-passed on the lab host after the fixes. Test scaffolding (NOT under test): the Mac reached
the lab through `ssh -R` tunnels from the lab host + loopback aliases of the real lab IPs + root
`socat` forwarders, so every name/IP/port in the README was used unchanged; the podman/Colima VMs got
an `/etc/hosts` entry for Harbor pointing at the Mac.

**Linux + docker re-walked on the merged code** (2026-09-23, docker 29.8.1 + buildx 0.37.1, lab
host, bash): §1–§11, every block verbatim — the §1 env block, §3 CA fetch (byte-identical to the
lab's CA) and the sudo `certs.d` install, §5 buildx build (`linux/amd64`), §6 robot + login,
§7 push, §8 contexts + guest kubeconfig, §9 deploy by digest (the running pod's image ID equals
the pushed digest), §10 LoadBalancer and port-forward (path table matches: 200/307/200/404),
§11 cleanup (Harbor repo + robot deleted, `vcf context list` shows no `supervisor*` left — and
the pre-existing current context of another project was untouched). This Linux docker walk ran on
the merged code (9046066). The macOS walks ran before the last Dockerfile/Makefile fixes; after
them the Mac re-ran `make image-build` with both engines, not the whole README.

The Mac scaffolding (socat, lo0 aliases, `/etc/hosts`) and the lab-host tunnels were removed
2026-09-23. The Mac itself is still rented: delete it from 2026-09-24 13:41.

Fixes this found, each MEASURED failing before and passing after:
- **Apple's `/usr/bin/make` (GNU Make 3.81, Apple-patched) ignored the Makefile's exported PATH** for
  simple recipe lines (`posix_spawnp` searches make's own PATH), so `make deps` could not find the
  mise it had just installed. `SHELL := /usr/bin/env bash` fixes it; `/bin/bash` and `/bin/zsh` do
  NOT (Apple's `_is_posix_shell` list). Source: apple-oss-distributions/gnumake job.c.
- **`/usr/local/bin` does not exist on a fresh Apple Silicon Mac** → all three `sudo install`s failed.
- **Homebrew's docker-buildx is invisible to docker** until linked into `~/.docker/cli-plugins`.
- **Go crashes under Colima's QEMU amd64 emulation** (`marked free object in span` in
  `go mod download`); podman used Rosetta and was fine. The Dockerfile builder stage now runs on
  `$BUILDPLATFORM` and cross-compiles — no emulation; also verified amd64 and cross-arm64 on Linux.
- `make deps` swallowed a failed buildx check (exit 0); it now fails. Homebrew + CLT prerequisite
  added; `brew install make` dropped (it only adds `gmake`).
- The §3 Colima CA block (was UNTESTED) works as written; its new §11 cleanup line was run too.

## ✅ P4 PROVEN ON macOS — 2026-09-23 (supersedes "THE NEXT ACTION" and the Mac sections below)

All MEASURED on the rented Mac (macOS 26.6.2 25G83, arm64, podman 6.1.2, applehv), Harbor reached
through `ssh -R 127.0.0.1:8443:192.168.101.130:443` from the lab host, `HARBOR_FQDN=
harbor.env1.lab.test:8443` (`vks/macosx.res` is the "after" run):

- **P4:** before → `x509: "harbor" certificate is not standards compliant`; after (CA in
  `~/.config/containers/certs.d/<host>/`) → `invalid username/password`. TLS failure → auth failure.
- **Why not "unknown authority":** `podman login` runs on the Mac, through Apple's verifier, which
  rejects Harbor's default leaf (cert-manager, `duration: 87600h` = 3650 days) because a leaf under
  a private CA may be valid for at most 825 days — trusting the CA does not help (Apple support
  103769; `SecPolicyServer.c` `check_other_trust_ssl_validity_maximums`).
- **The 825-day rule MEASURED with controls** (2026-09-23, same Mac, `security verify-cert -p ssl -r
  <CA>` — the CA passed as an explicit trust anchor, so "untrusted CA" is ruled out): an 800-day leaf
  under a throwaway CA → **verification successful**; a 3650-day leaf under the same CA →
  `CSSMERR_TP_CERT_SUSPENDED`; the real Harbor leaf under the Harbor CA → the same
  `CSSMERR_TP_CERT_SUSPENDED`; wrong anchor → `CSSMERR_TP_NOT_TRUSTED` (so the instrument
  discriminates). Why `certs.d` escapes it (READ, Go `crypto/x509/verify.go`): with a system pool
  plus added roots, a failed platform verification falls back to Go's own verifier, which has no
  825-day rule; `push` runs in the Linux VM, never on Apple's verifier. macOS `/usr/bin/curl` 8.7.1
  defaults to LibreSSL, so the README's `--cacert` calls pass (`http=200`); forcing
  `CURL_SSL_BACKEND=securetransport` fails (`RecoverableTrustFailure`). Anything that uses Apple's
  verifier directly (Safari/Chrome on the Harbor UI, Keychain trust) cannot be fixed on the client —
  only a Harbor leaf of ≤825 days fixes that, which is a lab-side change.
- **The OLD README §3 macOS block could not work:** (1) `sudo security add-trusted-cert -d …` is
  denied without an on-screen admin login — a hard-coded authd rule, root is not exempt, and
  `authorizationdb write` of that right is itself refused (`-60005`); (2) even trusted, the 3650-day
  leaf fails Apple's check; (3) `podman machine set --import-native-ca` on a RUNNING machine fails
  (`unable to change settings unless vm is stopped`) — the order must be stop, set, start.
- **The NEW §3 block** (podman's CA directory, same on Linux and macOS) was run verbatim on a freshly
  recreated VM whose own trust store does not know Harbor: login and push both succeed. `push`
  runs in the VM, yet reads the CA from the Mac's `certs.d`.
- macOS + docker (Colima) was proven afterwards — see the section above.

**The Mac is no longer needed for P4.** Delete it from 2026-09-24 13:41 (Scaleway console →
the server → Delete). The lab-host tunnel is a background `ssh -N -R …`; kill it when done.

## ▶ A MAC IS RENTED — 2026-09-23 (supersedes the "blocked" state below)

| | |
|---|---|
| Scaleway server | `apple-silicon-angry-ardinghelli`, id `1d6892ed-5fa6-4dfe-9473-f329f3faa04b`, zone **fr-par-3** |
| hardware / OS | **M1-M**, 8 GB, 256 GB — **macOS Tahoe 26.6.2** (same build as the last Mac run) |
| access | `ssh m1@51.159.120.46` (key `udesk` = the lab host's `~/.ssh/id_ed25519`); VNC port 59010 |
| state at creation (13:41) | "Reinstalling", ~2 h per Scaleway; billed only once ready, €0.11/h |
| **deletable from** | **2026-09-24 13:41** (Apple's 24 h minimum) — delete it when P4 is done |

The M4-S turned out to need an explicit quota; only the M1-M had stock. Any Apple silicon works
for P4. Pre-flight and tunnel steps are unchanged — see "Once on the Mac" below.

## ⏸ BLOCKED ON A MAC — renting one (state as of 2026-09-23)

The Mac that produced `macosx.res` is not available, so a cloud Mac is being rented for P4.

**Requirements** (why most offers fail): a *physical* Mac, not a macOS VM (`podman machine`
runs its own Linux VM); **admin/sudo** (README section 3 trust step, `/etc/hosts`, binding
:443); SSH; **macOS Tahoe 26.x**; hourly/daily billing. Every vendor has a 24 h minimum
(Apple's macOS licence).

**Rejected:** MacinCloud *Managed* — "These plans DO NOT provide you administrator/root
access." HostMyApple — shared VM, no admin. MacRent — VM-based.

**Chosen: Scaleway Apple silicon M4-S** (16 GB, from €0.22/h, ~€5.28 for the 24 h minimum).
**Fallback: AWS `mac-m4.metal`**, ~$29.50/24 h, with a macOS 26.6.2 AMI that matches the
last run exactly (AWS macOS AMI release notes list 26.0.1 … 26.6.2).

**Where it stopped:**

| | |
|---|---|
| Scaleway org | `yars`, project `vks`, created 2026-09-23 |
| payment method | card added |
| identity | **Pending verification** |
| SSH key | `udesk` = this lab host's `~/.ssh/id_ed25519.pub` (MD5 `32:99:9f:20:…:d1:68`), added to project `vks` |
| create page | **every Mac type OUT OF STOCK in both PARIS 1 and PARIS 3** |
| support ticket | **#1619590**, opened 2026-09-23 09:48; **answered 10:21** (below) |

**Scaleway's answer (ticket #1619590, 2026-09-23):** the out-of-stock is **REAL**, "completely
unrelated to your account quotas"; **no restock ETA** — machines free up as other customers'
24 h rentals expire, so poll the console. The console distinguishes the two: **"Out of stock"**
= unavailable globally, **"Quota needed"** = the account is not authorised. And a **second
blocker**: for Apple silicon, identity verification is NOT enough — **a quota increase must be
requested explicitly**. They did not say whether the ticket itself counts as that request, and
did not name the exact Tahoe 26.x ("macOS Tahoe 26 is available").

**So Scaleway needs TWO things: stock AND an explicit Apple silicon quota.** Suggested ticket
reply: *"Please process this ticket as the explicit Apple silicon quota request: 1 × M4-S (or
1 × M2-M) in fr-par-1 or fr-par-3, hourly. Please also confirm the exact macOS Tahoe 26.x build."*

**Decision point:** if Scaleway is not creatable within ~1 day, switch to AWS `mac-m4.metal`.
Request the AWS Dedicated Host quota for `mac-m4` in parallel — new accounts usually have 0.

**Resume:** reload Bare Metal → Apple silicon → Create. **"Out of stock"** = still waiting on
Scaleway's hardware; **"Quota needed"** = chase the quota on the ticket. If M4-S is orderable:
M4-S, zone PAR, newest Tahoe 26.x, **hourly**, key `udesk`, accept the 24 h minimum. Then give
the session the public IP + SSH user.

**Once on the Mac, pre-flight BEFORE any real work** (a failure here costs only the 24 h):
`sw_vers`; `sudo -n true`; `security add-trusted-cert` into the System keychain works despite
Scaleway's MDM profiles; sshd allows remote forwarding. Then — because the Mac cannot reach
the lab host — open the tunnel **from the lab host**:
`ssh -N -R 443:192.168.101.130:443 <mac>` (`-R` binding :443 needs a root login on the Mac;
otherwise forward a high port and redirect 443 to it with `pf` — unverified on Scaleway), plus `127.0.0.1 harbor.env1.lab.test` in the Mac's
`/etc/hosts`. This **replaces** the `-L` recipe in section 2 below, which assumed the Mac can
SSH into the lab host. Then section 3's two runs. Delete the Mac when done.

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
Mac both engines are proven: podman, and docker with Colima as the engine (a bare `brew install
docker` is only a client with no daemon, which is why the README installs Colima).

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
./vks/macosx.sh                 # AFTER  trust — the error must CHANGE to "invalid username/password"
```

TLS-failure → auth-failure is the proof. `probe`/`x` stays a bad credential either way, so a
*successful* login would mean the CA was already trusted. Match podman's **text**, not a status
code — measured on Linux (podman 4.9.3, 2026-09-23), the two errors are exactly:

- before: `pinging container registry harbor.env1.lab.test: Get "https://harbor.env1.lab.test/v2/": tls: failed to verify certificate: x509: certificate signed by unknown authority`
- after: `Error: logging into "harbor.env1.lab.test": invalid username/password`

**The Mac must deploy by digest** (README section 9 now does). This lab's worker nodes still
cache older `golang-web:v0.0.3` images from earlier runs; deploying by tag started one that
crash-looped. The digest block is proven on these same nodes.

## Linux walk — 2026-09-23, against this lab after its restart

Every README section run on Linux, podman AND docker, blocks extracted verbatim:
**§2–§8, §10, §11 pass.** §9 by tag **FAILED** (cached image, CrashLoopBackOff, no logs), which
led to deploying by digest; the new §9 block then passed on the same nodes, and its `NOT FOUND`
branch applies nothing (deployment generation unchanged). P4's mechanism is proven on Linux
(above). The Supervisor serves kubectl **v1.32.9**, four minors behind the guest's v1.36.2, so
this lab needs the upstream-kubectl path. The robot name must go into the env file in **single
quotes** — measured, double quotes turn `robot$apps+golang-web-push` into
`robot+golang-web-push`. All 47 `sh` blocks parse under `bash -n` and `zsh -n`. Not exercised
here: the `sudo install` lines (no passwordless sudo on the lab host) and every macOS block.

## First-time-user walk — 2026-09-23, clean `ubuntu:26.04` container + the lab host

That earlier walk ran on a host that already had vcf, mise and Go, so it could not see
first-run defects. A clean container, as an ordinary user with sudo, blocks fed on stdin like a
paste, found them (all MEASURED): the VCF CLI tarball holds `vcf-cli-linux_amd64`, not `./vcf`,
so the old install never installed anything; a `*.tar.gz` wildcard breaks once a second version
is downloaded; the old §4 mise-activation line leaves `go` missing in every new shell on Ubuntu
(harmless — the Makefile puts the mise shims on PATH itself, so no activation is needed); and
`make deps` did NOT stop after installing mise as documented. An independent end-user review
added the rest: §2 `rm -rf ./bin` could delete `~/bin`; a private project broke §9 (pull
secret created after the deploy; the digest lookup was unauthenticated). MEASURED on a throwaway
private project: a push/pull robot gets **403** on the artifacts API; with `artifact` read+list
it gets 200 — so the robot now carries those permissions and both lookups authenticate.

After the rewrite: §1–§4 plus §8–§9 (namespace, pull secret) and §11 pass in the clean container;
§5–§11 pass on the lab host (rootless podman cannot run nested inside a container, so the build
was proven on the host). Not exercised: every macOS block (proven later — see the top of this
file), and Linux arm64.

## Settled — do not re-derive

Measured on macOS 26.6.2 / arm64 / bash 3.2.57 / podman 6.1.2 (`vks/macosx.res`):

| | |
|---|---|
| `engine_remote=true` | macOS runs a Linux VM — the reason every macOS/Linux split in section 3 exists |
| `import_native_ca=yes` | the flag exists — but section 3 NO LONGER uses it: podman's `certs.d` replaced the Keychain + `--import-native-ca` path (P4 above) |
| `xarch_build=ok` | `--platform linux/amd64` builds, and the image really is `linux/amd64` |
| `install -D` | **NOT supported** (BSD) — its Linux-only placement is load-bearing |
| `base64 -d` | works — step 8b is safe on both platforms |
| `group "root"` | **does not exist** on macOS — `install -g root` would fail |
| `rosetta2=yes` | on *this* Mac; the README now warns for the next one |
| `KUBECTL_VERSION` | the README's default **v1.36.2** matches the guest cluster exactly — no upstream fallback needed here |
| docker | CLI present, daemon down → `brew install docker` is client-only; the README runs the engine in Colima (proven, top of file) |

HISTORY — the README no longer has this block (see the `import_native_ca` row). Checked against
podman's own docs rather than assumed, for the old trust block's ORDER: `--import-native-ca` imports
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
