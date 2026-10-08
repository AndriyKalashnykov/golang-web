# HANDOFF — `vks/`

Resume point for the `vks/README.md` work. Read this before touching `vks/`. It holds the
current state, how to walk the guide again, and what is already measured. It is not a log:
replace what changes, and leave the history to git (the round-by-round record is in this file's
history up to 2026-10-05).

## Where it stands — 2026-10-07

`vks/README.md` builds `golang-web`, pushes it to Harbor and deploys it to a VKS guest cluster.
**All work is merged; nothing is in flight.** It is pinned to **VCF CLI 9.1.1.0**
(`vcf version` prints `v9.1.1.0.25662425`; the plugin bundle is build 25665404). The README has
54 `sh` blocks; all parse with `bash -n` and `zsh -n`.

Walks of the text as of `97adb90`, all on 2026-10-05 against the lab, each block run as written
and judged by its Expect line (step 7's login, alternative and renew blocks changed on
2026-10-07 and were run separately: see *kubectl and the VCF CLI* below):

| path | where | result |
|---|---|---|
| Linux podman 4.9.3 | clean `ubuntu:24.04` container, non-root user with sudo | 33 blocks, steps 1 to 10, every Expect matched |
| Linux docker 29.8.2, buildx 0.37.1 | the same, docker installed by step 2 | 36 blocks, steps 1 to 10, every Expect matched; this walk ran the pull-secret and port-forward blocks |
| macOS podman 6.1.3 | the M2, macOS 26.6.1, zsh | steps 1 to 10, every Expect matched, including the app over its LoadBalancer address |
| macOS docker (Colima 0.10.3, docker 29.8.2 client, 29.5.2 server) | the same | engine, switch-to-docker and Colima CA blocks, then steps 5 to 10; step 9's LoadBalancer `curl` timed out because that walk had no tunnel to the address, and the port-forward blocks served the page |

Older than the current text:

- **Linux arm64** was last walked end to end on 2026-09-29, with docker, in an aarch64
  `ubuntu:24.04` container under Colima. Since then the arm64 containers have run step 1's
  block, step 2's kubectl and docker install blocks and step 7's `kubectl_install` call.
- **The Supervisor-kubectl alternative** (step 2, collapsed) was run with steps 7 to 10 on Linux
  amd64 and the Mac on 2026-09-30, dl.k8s.io blocked and unblocked.
- **The Homebrew installer block** needs the Mac's login password, so the owner ran it in a
  terminal on the Mac; a session ran only the `PATH` block after it (`Homebrew 7.0.8`).

Never run by any walk: the editor block and the `REGISTRY_*` snippet (the harness edits the env
file instead), `brew install jq` on a macOS that lacks jq, and the Broadcom portal download.

## `ARGOCD-auto.md` and `ARGOCD-manual.md` — 2026-10-07

`vks/ARGOCD-auto.md` (named `ARGOCD.md` until the manual guide was added; `ARGOCD.md` is now a
two-row chooser) installs ArgoCD Service 1.2.0 on the Supervisor, starts an instance in the
vSphere Namespace and creates a guest cluster through it from the chart `vks/argocd/guest-cluster`
(pinned by commit; a change to the chart needs a new pin in the guide). 23 `sh` blocks; all parse
in bash 5, zsh 5.9 and bash 3.2.

| path | where | result |
|---|---|---|
| Linux, bash | clean `ubuntu:24.04` container, non-root user with sudo, bare lab (VCF 9.1.1, VKS 3.7.1, no Harbor) | all 21 blocks, twice; every Expect matched on the second walk, clean-up included; the install retry fired once for real (`attempt 2`); the name-collision `STOP` was forced once |
| macOS 26.6.1 (M2), zsh 5.9 | over SSH, the lab reached through the owner's tunnel | blocks 1 to 17, every Expect matched; cluster Available in under 7 minutes; the pinned `main` commit resolved |
| the same, bash 3.2 | the same | the four clean-up blocks, back to a bare lab; steps 1 to 3 separately |
| the same, `zsh -il` and `bash -il` reading the block from stdin | the same | four blocks fed line by line on a second run: `unchanged`, and the same output |

`ARGOCD-manual.md` (27 `sh` blocks, 17 screenshots in `vks/img/argocd/`) was walked on 2026-10-07
against the same lab:

| path | where | result |
|---|---|---|
| the vSphere Client and the ArgoCD page | Chrome on Linux | the service removed and installed again; the Application created (once pre-filled through the page's address and synced, once by a simulated clipboard paste of the guide's 20 lines into the YAML editor, then SAVE and CREATE), synced, and deleted with Foreground |
| the `kubectl` blocks, Linux | bash and zsh | each non-destructive block as written, several as second runs |
| the `kubectl` blocks, macOS 26.6.1 (M2) | zsh for blocks 1 to 14 and the two instance clean-up blocks; bash 3.2 for the cluster registration, its removal, the by-name "is it gone" check and four second runs | every Expect matched, against a real instance and a real test guest cluster (Available in 5m16s); the three page actions were stood in for by `kubectl` on the Mac |

Step 5's browser check was done by the owner in Chrome on Linux (2026-10-07): the viewer's
**SHA-256 Fingerprints** / **Certificate** row equalled the printed fingerprint; other browsers
were not tried. The screenshots are crops of the Linux
walk and must be retaken when the vSphere Client or ArgoCD page changes. On the Mac the "delete
the Supervisor login, then log in again" remedy both guides give was needed for real (a stale
`supervisor` context) and worked.

Not covered: the main guide's kubeconfig pointer (end of step 7) on macOS, which had no tunnel
to the new cluster's address; a terminal paste on a real pty; a real `sudo` password prompt; the vSphere Client alternative in step 4 (taken from Broadcom's 9.1 pages);
the standard (non-legacy) manifest; a vCenter with more than one Supervisor; a user with only
the Edit role and no vCenter administrator rights; whether the guest-cluster destination's
client certificate is renewed.

Measured while writing it:
- Installing right after registering returns `HTTP 500 … service account is not ready`; a
  retry 10 s later is accepted. The service cannot be deleted while a version exists.
- The Supervisor stores `v1.36.2+vmware.2` for a release named `…-vkr.3`; with the long form in
  Git the Application never reads `Synced`. It adds two topology variables on admission; ArgoCD
  still reports `Synced` and a second sync keeps them.
- Deleting an instance leaves `argocd-initial-admin-secret` and `argocd-redis`; after one
  cluster delete a cert-manager secret `<cluster>-extensions-ca` stayed (removed by hand).
- Binding `admin` to `argocd-k8s-sa` is refused for an Edit user; `edit` is accepted.

## Not covered

- Terminal.app: every Mac walk ran over SSH. Bracketed paste was simulated with its escape codes.
- A Mac without Xcode, a Mac without Rosetta, and an Intel Mac (the `bad CPU type` line is
  inferred). Whether a 9.1.1 `Darwin_AMD64` plugin bundle exists is unknown.
- Docker Desktop or OrbStack installed beside Colima, and a failing `colima start`.
- macOS older than 26: whether it ships `jq` is unverified.
- podman 5.x on arm64 Linux other than 5.4.2, 5.7.0 (one push each, 2026-10-06) and 5.8.7; 4.9.3 fails (see below).
- The Supervisor's own VCF CLI download when it works (this lab returns 503; see below).
- `kubectl_install`'s new `sudo failed` message was not walked on the lab, only reproduced with
  a failing `sudo` on Linux and the Mac.

## How to walk it again

Extract every `sh` block from `vks/README.md` and run each in its **own fresh login shell** with
stdin from `/dev/null`, so a block that lacks a needed `source` fails. Judge each block by its
**Expect** line, not its exit code (a block's exit code is only its last command's). Recount
block numbers each time; they move whenever a block is added.

- **Linux:** a clean `ubuntu:24.04` container with `--privileged --network host`, a non-root
  user with sudo. For docker add `-v /var/lib/docker` and start `dockerd` by hand after the
  install block (the container has no systemd). The harness fills the env file with awk.
- **Check the lab first.** Harbor's `apps` project should have no `golang-web` repository and no
  robot, and the guest cluster no `golang-web` namespace. One walk found leftovers nobody
  could account for, and its blocks printed `unchanged` and `configured` instead of `created`.
- **Step 4 clones GitHub `main`**, so a Makefile change can only be walked after it is pushed;
  cloning a branch instead is a deviation to disclose.
- **A walk as a script cannot see paste defects.** The two rules for fenced blocks (no comment
  on a command line; nothing after a line that can prompt) are in CLAUDE.md's backlog. Check
  them by pasting into `zsh -i` and bash 3.2 on a pty.
- A transient Ubuntu mirror 404 during step 2's `apt-get install` has happened twice; retry.

### The Mac's route to the lab

The lab's addresses live on the lab host's libvirt bridges and the Mac cannot reach them. The
scaffolding below keeps every name, IP and port in the README unchanged. It is not under test,
and all of it is removed after a walk.

**The session may not open the tunnels or start the lab; the owner does both.** His two
commands, run on the lab host:

```
ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:192.168.100.50:443 -R 127.0.0.1:18444:192.168.101.128:443 -R 127.0.0.1:18445:192.168.101.128:6443 -R 127.0.0.1:18446:192.168.101.130:443 -R 127.0.0.1:18447:192.168.101.132:6443 m1@62.210.166.48
ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18448:<the assigned address>:8080 m1@62.210.166.48
```

The second is for the app's LoadBalancer address. The lab assigns it at deploy time (`.144`,
`.146` and `.148` on 2026-10-05), so that tunnel can only be opened after step 8. Both were
closed after the last walk.

The session's part, on the Mac: an `lo0` alias for each lab IP, a root `/usr/bin/python3` relay
from each alias to its tunnel port (one argument per forward, `<lab ip>:<port>:<tunnel port>`),
and two `/etc/hosts` lines for the vCenter and Harbor names. Neither engine VM needs its own
`/etc/hosts` entry: the podman machine and the Colima VM resolve Harbor's name through the Mac.
Copy the Darwin VCF CLI archives from the lab host's `~/Downloads/vcf` into the Mac's
`~/Downloads`.

## The lab

`~/projects/nested-vsphere-lab`. The owner started it on 2026-10-05 and it is his to stop
(`make -C ~/projects/nested-vsphere-lab lab-stop`). On 2026-10-06 at 15:11 the kernel OOM killer
killed its `esxi01` VM (a session filled `/tmp`, which is RAM on this host, with test-VM disks).
The owner restarted the lab the same day; nothing inside it was checked after the unclean stop.
`lab-start` took about an hour on 2026-10-05 until Harbor answered: Harbor's pods sat in
`FailedAttachVolume` for over 20 minutes and recovered without anyone deleting them.

`make creds` in that repo prints the endpoints; the passwords are in its gitignored
`secrets.env`.

| | value |
|---|---|
| `HARBOR_FQDN` | `harbor.env1.lab.test` = 192.168.101.130, project `apps` (**public**) |
| `VCENTER_FQDN` | `vcsa.env1.lab.test` = 192.168.100.50 |
| `SUPERVISOR_ENDPOINT` | `192.168.101.128` |
| `VKS_NAMESPACE` / `VKS_CLUSTER` | `lab` / `lab-gc1`, v1.36.2+vmware.2, guest API `192.168.101.132:6443` |
| guest kubeconfig | secret `lab-gc1-kubeconfig` in namespace `lab` (as of 2026-09-23) |
| Harbor's namespace on the Supervisor | `svc-harbor-90dbv` (as of 2026-09-23; platform-chosen) |

- After the last walk Harbor's `apps` has no `golang-web` repository and no robot, and the
  guest cluster has no `golang-web` namespace.
- **Harbor's registry volume is 10 GiB and fills up.** A push then fails with
  `blob upload invalid` (the registry log says `no space left on device`; the client does not).
  Deleting a repository frees nothing until garbage collection runs. GC with
  `delete_untagged=true` took it from 99% to 60% on 2026-09-29. Most of it is the `cicd`
  project's repositories.
- The worker nodes cache older `golang-web` tags; deploying by tag once started a stale image
  that crash-looped. That is why the README deploys by digest.

## The Mac

| | |
|---|---|
| Scaleway server | id `65fa64c6-d0ed-49de-bcf1-a766b9f67a11`, zone **fr-par-1** |
| hardware / OS | **Apple M2**, 8 cores, 16 GB, 228 GB disk, **macOS 26.6.1 (25G76)**, arm64 |
| access | `ssh m1@62.210.166.48` (the lab host's `~/.ssh/id_ed25519`) |
| as delivered | Xcode; `/usr/bin/{jq,git,make,python3}`; Rosetta; no `/usr/local/bin`; no Homebrew, engine, `vcf` or `kubectl` |
| installed since | Homebrew with podman 6.1.3, colima 0.10.3, docker 29.8.2 and docker-buildx 0.37.2; `/usr/local/bin/{vcf,kubectl}` (kubectl v1.36.2); `~/.zprofile` (the README's Homebrew line) |

- It replaced an M1 with 8 GB on 2026-09-30 (owner decision: more RAM). The earlier walks ran
  on that M1 with macOS 26.6.2; nothing behaved differently on 26.6.1.
- The podman machine and the Colima VM exist and are **stopped** (checked 2026-10-06); both
  cache the build's base images. No clone, env file, archives or scaffolding are on it.
- `m1` has passwordless sudo (`/etc/sudoers.d/m1`, added by the owner). `sudo -v` still asks
  for the login password, which is why a session cannot run the Homebrew installer.
- **Do not delete it without asking:** it is kept for vks-airgap-cicd (B735 macOS jump box,
  B736 arm64 build tags in that repo's `BACKLOG.md`).
- Renting another: Scaleway Apple silicon needs stock **and** an explicitly requested quota,
  and every vendor has Apple's 24 h minimum. A physical Mac with admin rights is required
  (`podman machine` runs its own VM). Scaleway ticket #1619590 is closed.

## Owner decisions — do not revert without asking

- **The Supervisor-kubectl alternative downloads with `curl -k`**, so the block needs no CA
  file. The cost, stated once: the kubectl installed with `sudo` is not verified to come from
  the Supervisor, and the download has no checksum.
- **The Supervisor login skips the certificate check by default** (`--insecure-skip-tls-verify
  --auth-type basic`, 2026-10-07); the `--ca-certificate` login is the collapsed alternative, with
  its own renew block. A review asked to keep the CA login as the default and was declined. The
  cost is stated once above the block: the SSO password, and every later `kubectl` call to the
  Supervisor (the read of the guest cluster's kubeconfig included), go to an unchecked server.
- **Step 8 of both ArgoCD guides adds the new cluster with Broadcom's `argocd` program**
  (`argocd cluster add … --upsert -y`, 2026-10-08); the `ManagedEntity` is the collapsed
  alternative. Both store the cluster's one-year administrator certificate; the guides say so,
  print the end date and say how to renew. The token form (below) was not chosen for the guides:
  it needs three more blocks.
- **The VCF CLI plugin bundle is installed** (offline, `vcf plugin install all
  --local-source`), although `vcf context create` was measured to work with zero plugins.
- **The pull secret is optional**, behind the public/private check. A review's suggestion to
  always create it was declined.
- **Linux support is Ubuntu and Debian only.** The docker install block reads `ID` from
  `/etc/os-release` and installs nothing elsewhere.

## Settled — do not re-derive

Everything here was measured unless it says otherwise.

### Registry trust on macOS

- **Apple's verifier rejects Harbor's default leaf even with its CA trusted.** The leaf is
  valid for 3650 days, and a leaf under a private CA may be valid for at most 825 (Apple
  support 103769). Measured with `security verify-cert -p ssl -r <CA>`: an 800-day leaf under a
  throwaway CA passed; a 3650-day leaf under it and the real Harbor leaf both gave
  `CSSMERR_TP_CERT_SUSPENDED`; a wrong anchor gave `CSSMERR_TP_NOT_TRUSTED`. In `podman login`
  it shows as `x509: "harbor" certificate is not standards compliant`.
- **So the README uses podman's `certs.d`, not the Keychain.** With the CA in
  `~/.config/containers/certs.d/<host>/` the login error changes from the x509 one to
  `invalid username/password`. Why it works (read in Go's `crypto/x509/verify.go`, not
  measured): with added roots, a failed platform verification falls back to Go's own verifier,
  which has no 825-day rule. `push` runs in the VM yet reads the CA from the Mac's `certs.d`.
- The Keychain path could not work anyway: `sudo security add-trusted-cert -d` is denied
  without an on-screen admin login (root is not exempt), and `podman machine set
  --import-native-ca` fails on a running machine.
- macOS `/usr/bin/curl` 8.7.1 uses LibreSSL, so the README's `--cacert` calls pass. Anything on
  Apple's verifier (Safari or Chrome on the Harbor UI) cannot be fixed on the client; only a
  Harbor leaf of 825 days or less fixes it.
- On Linux the two login errors are `x509: certificate signed by unknown authority` before the
  CA and `invalid username/password` after (podman 4.9.3).
- Colima: login fails with `x509: unknown authority` without the CA in the VM and succeeds with
  it; no `colima restart` is needed.

### Colima and docker on macOS

- `colima stop` removes the `colima` docker context; `colima start` from stopped creates and
  selects it. `colima start` on a running Colima prints `already running, ignoring` and does
  **not** switch the context back. Hence `docker context use colima` in step 2.
- With Colima stopped, `colima ssh` fails with `colima not running`. Hence
  `colima status >/dev/null 2>&1 || colima start` in steps 3 and 10.
- `colima ssh -- <cmd>` reads stdin and, pasted without bracketed paste, eats the next line of
  the block. Hence `</dev/null` on step 3's `mkdir` line.
- `brew install docker` is a client only; the README runs the engine in Colima. Homebrew's
  docker-buildx is invisible to docker until linked into `~/.docker/cli-plugins`.
- Go crashes under Colima's QEMU amd64 emulation (`marked free object in span`). The
  Dockerfile's builder stage runs on `$BUILDPLATFORM` and cross-compiles, so nothing is
  emulated and Rosetta is not needed for the build. podman 6 and Colima both default Rosetta
  off. Only the Supervisor's Intel kubectl needs it on Apple silicon.
- `docker logout` needs no daemon. podman's remote client on macOS does need its machine, so
  with the machine stopped step 10 prints `podman is not running …` and the podman login stays,
  as the message says.
- `perl -e 'alarm N; exec …'` does **not** stop docker or podman (Go catches SIGALRM). Step 10
  has no time limit and says to press Ctrl-C; the Makefile's `engine_ready` forks and kills.
- Step 10's "Delete the files" block prints nothing and exits 1, because `~/.kube` still holds
  kubectl's `cache`, which the README says is kept.

### macOS itself

- A fresh Apple Silicon Mac has no `/usr/local/bin`; the kubectl and `vcf` blocks create it.
- Apple's `/usr/bin/make` (GNU Make 3.81, patched) ignores the Makefile's exported `PATH` for
  simple recipe lines. `SHELL := /usr/bin/env bash` fixes it; `/bin/bash` and `/bin/zsh` do not.
- `install -D` is not supported and the group `root` does not exist; `base64 -d` works.
  `mktemp -t PREFIX` is not portable either (see Traps).
- macOS 26 ships `/usr/bin/jq` (1.7.1), LibreSSL 3.3.6 (it prints `SHA256 Fingerprint=`),
  zsh 5.9 and bash 3.2.
- The Homebrew installer installs the Command Line Tools itself (measured on a vanilla macOS
  26.6.2 guest in tart). With passwordless sudo and stdin not a terminal it ran in 20 s with no
  prompt on the delivered M2; from a terminal it asks for the login password.
- **Gatekeeper:** the installed `vcf` keeps Safari's quarantine flag and runs, because it is
  `Notarized Developer ID` (VMware, EG7KH642X6). SSH does enforce Gatekeeper: a quarantined
  ad-hoc-signed binary was killed (`rc=137`) and ran once unquarantined. Terminal.app is
  inferred to behave the same.

### How ArgoCD logs in to a guest cluster, and for how long

Measured 2026-10-08 on the lab (argocd `v3.4.4+696352d56-vcf`, ArgoCD Service 1.2.0, guest
cluster v1.36.2), from Linux and from the M2 (the Intel build under Rosetta):
- `argocd cluster add <context> --kubeconfig <the cluster's kubeconfig>` works, and stores what
  the kubeconfig signs in with. The cluster's own kubeconfig holds the `kubernetes-admin`
  certificate (`O=system:masters`, valid one year from when the cluster issued it), so ArgoCD
  stores that certificate; the `argocd-manager` token the program creates is not used. That is
  upstream's rule (READ: argo-cd `cmd/util/cluster.go`, the token is set "only if the key/cert
  data is absent"). Given a kubeconfig that signs in with a token and has no certificate, it
  stores the `argocd-manager` token, which has no end date.
- A `ManagedEntity` stores the same certificate (same serial). After the cluster issued a new
  one, the service kept the old for 9 minutes of watching (its log: one pass per entity, none
  after in 5 h); a change to the entity's spec made it copy the new one in 25 s.
- Re-adding: the identical `cluster add` again is fine; with `--upsert` a different login
  REPLACES the stored one; a different login WITHOUT `--upsert` made the ArgoCD server exit
  (`bufio.Scanner: token too long`, exit 141) and restart 10 s later, twice out of two. Both
  guides therefore always pass `--upsert`.
- `argocd cluster rm <name>` removes the ArgoCD entry, then looks for a kubeconfig context of
  that same name to delete the account on the cluster. Added under the context's own name (no
  `--name`) and with `KUBECONFIG` set, it removed the account, role and binding; with a custom
  `--name` it failed after removing the entry and left them.
- With no ArgoCD login, `cluster add` created the account on the cluster and then failed.
- Interactive `argocd login <address> --username admin --grpc-web` asks `Proceed insecurely
  (y/n)?` (the certificate names no address) and then the password; `argocd logout <address>`
  asks the same question and answers `token successfully invalidated on server`.
- Nothing in the ArgoCD page shows which login a destination holds; the guides' *How long this
  login lasts* block reads it from the cluster Secret and prints the kind and end date only.
- Walked 2026-10-08 in a clean `ubuntu:24.04` container (bash, non-root with sudo) against a
  guest cluster made outside ArgoCD: the manual guide's checksum, install, save-kubeconfig,
  login (on a terminal, answers typed by the harness), add, check, add again, remove and logout
  blocks; the scripted guide's add, check, add again and the new removal lines, with
  `argocd_session` replaced by a token file because this lab's first admin password secret no
  longer exists. Every Expect matched.

### kubectl and the VCF CLI

- `vcf context refresh`, measured 2026-10-07 on Linux (Ubuntu 26.04, bash and zsh) and on the M2
  (zsh and bash 3.2), vcf v9.1.1.0, each block run as printed in a clean home with a closed stdin:
  - while the login is valid it does nothing (`Token is still active. Skipped the token
    refresh`), sends no login and needs no password; the token lasts 10 hours (read from it);
  - after it ends it is a full password login from `VCF_CLI_VSPHERE_PASSWORD` (it prompts when
    the variable is unset) and saves the namespace contexts again; with no saved login it says
    `context supervisor not found`;
  - the certificate choice lives in the kubeconfig's cluster entry and refresh keeps it when
    given no flag; **refresh with `--insecure-skip-tls-verify` on a login made with a CA removes
    the CA and writes the skip flag, silently** (seen on both machines). A renew line with no
    flag would be safe on both paths; the owner wants the skip flag shown on the default path,
    so each path has its own renew block and every pointer to the default one names the other;
  - a namespace granted after login does not appear while the token is valid (not run: read
    from the skip message), so the remedy for that is delete and log in again.
- `vcf context create … --workload-cluster-name <cluster> --workload-cluster-namespace <ns>`
  (not used by the guide), measured 2026-10-07 on Linux against a 3-minute-old guest cluster:
  it writes a second context `<name>:<cluster>` at the guest's API address with the guest's CA
  and a 10-hour token for the SSO user (`sso:Administrator@vsphere.local`; `can-i '*' '*'`
  yes). Right after the cluster is created it prints `Following contexts may not be ready` and
  kubectl is refused until the guest's `guest-cluster-auth-svc` pod runs (about 3 minutes
  here); the `vcf context refresh` it recommends does nothing then. After the guest token
  ends, `vcf context refresh <name>:<cluster>` renews it; refreshing the parent does not.
  `vcf cluster kubeconfig get` needs the cluster plugin (`unknown command "cluster"` without).
  VMware's 9.1 pages give these two as the end-user ways and the `<cluster>-kubeconfig` Secret
  the guide reads as the administrator way. The guide keeps the Secret: it does not end after
  10 hours, and an Edit user is cluster-admin in the guest either way (READ, 9.0 page).
- The changed blocks also ran in a clean `ubuntu:24.04` container (bash, non-root, only `vcf`
  and `kubectl` added), every Expect matched. Not run: a login with `--auth-type basic` on a
  Supervisor that has an external identity provider (READ, Broadcom KB 417617; the lab has none).

- kubectl comes from dl.k8s.io through `kubectl_install`: newest stable in step 2 (v1.37.1 on
  2026-10-05), then the guest's version in step 7 (v1.36.2). The v1.37.1 client ran `version`,
  `get ns` and `get secret` against the v1.34.9 Supervisor with only a skew warning, so no
  Supervisor-version kubectl is installed.
- The Supervisor serves `/wcp/plugin/<platform>/vsphere-plugin.zip` for `linux-amd64`,
  `darwin-amd64` and `windows-amd64` (200) and not for `linux-arm64` or `darwin-arm64` (404).
  The kubectl inside is `v1.32.9+vmware.2-fips`. With it, steps 8 to 10 passed; the namespace
  delete printed `very short watch` warnings and still deleted it.
- `--connect-timeout 10` on the dl.k8s.io downloads: with dl.k8s.io pointed at a black-hole
  address, step 2's block took 136 s before and 10 s after, and `kubectl_install <version>`
  1,089 s before and 94 s after.
- The alternative block runs the downloaded kubectl once before `sudo install`, so one that
  cannot run never replaces a working kubectl. Seven failure cases each left the existing
  kubectl unchanged.
- `kubectl_install`'s failure message starts with `kubectl_install: cannot reach dl.k8s.io`;
  the If-not and Troubleshooting rows key on that prefix. It ends `…, the checksum did not
  match, or sudo failed`.
- The functions live in their own file (`~/.vks-golang-web.functions`), rewritten by step 1
  every time, because the env file is written under `set -C` and an existing user would never
  receive a new function.
- The VCF CLI tarball holds `vcf-cli-linux_amd64`, not `./vcf`. The install block calls
  `/usr/local/bin/vcf` explicitly and warns when another `vcf` comes first on `PATH`.
- The 9.1.1 Linux_ARM64 CLI and plugin bundle exist on the portal and install as written.
  Public packages.broadcom.com stops at v9.0.2, so the portal is the source.
- **The Supervisor's CLI download page** (`/wcp/vcf-cli/`) returns 503 here. Its nginx template
  (`forwarding_rules_vcf_cli.conf.jinja` on the control plane) proxies to the FDS file depot
  "if FDS ManagementService is available" and otherwise returns a hard-coded 503. That the
  Fleet Depot Service is placed in VCF Operations comes from KB 449965's naming, which is about
  the vSphere Client's link, so that part is inferred. The README says it is untested.
- vCenter SSO locks an account after 5 failed logins in 180 s and unlocks after 300 s. Three
  failures is the VCSA root policy.

### Build and push

- `make image-push` pushes one tag holding `linux/amd64` and `linux/arm64` (`PUSH_PLATFORMS`).
  podman builds the manifest list under its own name, `localhost/golang-web-push:<ver>`: a list
  and a plain image cannot share a name, a rebuild onto a list appends (2 entries became 4),
  and `podman rmi` on a list deletes its native instance and every tag sharing it. Docker uses
  `--provenance=false --sbom=false` to keep the index to two entries.
- A pod deployed by the index digest reports `imageID` equal to the index digest, which is what
  step 8's check compares.
- **podman 4.9.3 on arm64 Linux cannot build a correct amd64 image.** It labels the amd64 entry
  `variant: v8` (cause: the `FROM --platform=$BUILDPLATFORM` stage), no build shape avoids it,
  and an amd64-only build produced an arm64 image. Relabelling the entry `v1` was tried and
  dropped: containerd accepted it, but `podman pull --platform linux/amd64` rejects it. podman
  5.8.7 on arm64 builds both entries with no variant. So `image-push` refuses podman older than
  5 on arm64 Linux before building, and refuses any amd64 entry that carries a variant. Ubuntu
  24.04 has no apt route to podman 5, so the README leads with docker there.
- The Dockerfile names its base `docker.io/library/golang:…`. A short name fails on a stock
  Ubuntu 24.04 podman, which has no unqualified-search registries.
- Rootless podman cannot run nested in an unprivileged container, hence `--privileged`.

### Harbor

- The no-login check in step 8 prints `http=200` for a public project and `http=401` for a
  private one. A private project with no secret gives `ImagePullBackOff` with `pull access
  denied … no basic auth credentials`. Adding the secret afterwards leaves the pod stuck;
  `kubectl rollout restart` recovers it.
- A push/pull robot gets 403 on the artifacts API; with `artifact` read and list it gets 200,
  so the README's robot carries those permissions.
- The robot name goes into the env file in **single quotes**: double quotes turn
  `robot$apps+golang-web-push` into `robot+golang-web-push`.
- Harbor's `getcert` returns 404 when Harbor holds no CA file (read in Harbor's source); the
  README has an If-not for it.

## Traps already paid for

- **Gate on OUTPUT, not exit status.** `vcf plugin list` prints a valid table **and exits
  non-zero**; a status-gated check calls a working command broken.
- **`mktemp -t PREFIX` is not portable.** BSD reads a prefix, GNU wants a template and errors,
  leaving the variable empty. Use plain `mktemp` / `mktemp -d`.
- **An authfile must not pre-exist.** `mktemp` creates it empty and podman parses it as JSON,
  dying before it reaches the network. That silently broke a login probe for three runs.
- **`vcf plugin list` stalls ~25 s** on an unreachable plugin registry. It is a network timeout,
  not an empty plugin set.
- **tart needs a user keychain.** Over SSH, create and unlock one, or it fails
  `Failed to create new HostKey`. An M1 guest has no nested virtualization, so engine VMs
  cannot start inside it.
