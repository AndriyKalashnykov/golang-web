# HANDOFF — `vks/` macOS verification

Resume point for the `vks/README.md` work. Read this before touching `vks/`.

## Where it stands

`vks/README.md` builds `golang-web`, pushes to Harbor, deploys to a VKS guest cluster.
It is **proven end-to-end on Linux and macOS, with podman and with docker** — all paths last
walked 2026-09-28. The 2026-09-29 rewrite (round 4) was re-walked on Linux podman only; see there, every block in its own fresh shell (next section). Pinned to **VCF CLI 9.1.1.0** (`vcf version` → `v9.1.1.0.25662425`).

macOS is proven too — see the next section. The old probe script `vks/macosx.sh` and its
`vks/macosx.res` were REMOVED (2026-09-23): running every README block verbatim on a real Mac
superseded the subset they checked. They are in git history; references to them below are history.

## ✅ ROUND 5 — plugins restored, Supervisor kubectl dropped, headings — 2026-09-29

This supersedes round 2's "no plugin bundle" and the Supervisor-kubectl flow described below.

- **The VCF CLI plugins bundle is back**, at the owner's request.
  - Its download row is restored, and step 2's block installs it offline
    (`vcf plugin install all --local-source`).
  - Measured: 13 plugins installed on Linux amd64, and the install also works with no network.
  - The block calls `/usr/local/bin/vcf` explicitly and warns if another `vcf` comes first on PATH.
    An adversary found `~/.local/bin/vcf` shadowing it on this box.
  - The checksum line prints the file name even when the folder has a space (gawk, mawk and macOS
    BSD awk).
- **Step 7 no longer installs a kubectl at the Supervisor's version.** Measured: the v1.37.1
  kubectl from step 2 ran `version`, `get ns` and `get secret` against the v1.34.9 Supervisor,
  printing only a skew warning. The guest-cluster kubectl install stays.
- **Every heading is a verb phrase**, e.g. "Create the namespace" or "Get the guest cluster's
  kubeconfig".
- **Walk harness renumbering.** The README has 48 blocks. The public/private check is 33, the
  secret block 34 (skipped when 33 prints `http=200`), and the port-forward 38.
- **Final walks 2026-09-29, all blocks exit 0 and every Expect matched:**

  | path | environment |
  |---|---|
  | Linux podman | clean `ubuntu:24.04` |
  | Linux docker | clean `ubuntu:24.04` |
  | macOS podman | M1, podman 6.1.2 |
  | macOS Colima | M1 |
  | Linux arm64 with **docker** | aarch64 `ubuntu:24.04` inside Colima |

  - The macOS podman walk found a real bug: step 10's clean-up failed when the docker CLI was
    installed but Colima was stopped. It is fixed:
    - it logs out with every installed engine. docker's logout needs no daemon (measured); a
      review measured that podman's remote client on macOS DOES need its machine;
    - it removes images only where the engine answers `info`. There is no time limit: a review
      measured that `perl -e 'alarm N; exec …'` does NOT stop docker or podman (Go catches
      SIGALRM), so the README says to press Ctrl-C if it hangs. The Makefile's `engine_ready` had
      the same dead bound; it now forks and kills the child (separate PR);
    - it prints "<engine> is not running … start it and run this block again" for a stopped engine
      (that engine keeps its images and, for podman on macOS, its login).
    Not walked: a stopped podman machine on macOS, because the Mac's machine belongs to another
    project.
  - Lab Harbor's registry volume filled again mid-walk (`blob upload invalid`). A second manual GC
    left 254 MB free (98%). Run GC before the next session.
- **Not yet available here:** a 9.1.1 plugin bundle for Linux_ARM64 or Darwin_AMD64. Only
  9.1.0.0400 for Linux_ARM64 is on hand, so the arm64 walk uses it as a disclosed deviation.

## ✅ ROUND 4 — README rewritten for users new to CI/CD — 2026-09-29

- **What changed.** `vks/README.md` now has an overview and a Terms table, and every block says
  what it does, why, **Expect:**, and **If not:**. The two fingerprint checks say what to check and
  what to ask the administrator, instead of "stop". Optional parts are marked.
- **Reviews.** Two end-user reads. The first led to the rewrite; the second said "not ready — close",
  and its verified findings were applied.
  - One suggestion was deliberately NOT applied: always create the pull secret and drop the
    public/private check. The owner asked for the secret to be optional.
- **Commands changed in this round, only these four:**
  - step 8's check uses `curl -sS`, so a connection error is printed;
  - step 10 removes the clone only from inside it (tested in bash and zsh: inside, outside, and a
    look-alike directory);
  - the step 2 Check prints `MISSING: podman or docker` when neither is installed (tested both ways);
  - the Harbor delete is unchanged, but it is now marked as deleting the whole repository, every
    tag.
- **Walked on Linux podman** (clean `ubuntu:24.04`, the lab), every block compared with its Expect:
  34 blocks, all exit 0, every Expect matched. The check printed `http=200`, so block 35 was skipped, and the pod pulled from the public `apps` project with no secret. The pod's IMAGEID equalled the pushed digest, and the clone guard removed the clone. Not re-walked on macOS, docker or arm64. Their blocks are unchanged, and none of
  them contains the three changed commands except the shared Check line, which is engine-neutral.
- **Walk harness.** The step 8 check added a block, so every block after it moved up by one. The
  port-forward is now block 39 and the pull-secret block 35. `run_linux.sh` skips block 35 when
  block 34 printed `http=200`, as the README says.
- **Renovate did not track jq**: its tags are `jq-1.8.2`. Measured: with jq pinned at 1.8.1, the
  dry run proposed nothing; after the `extractVersion` rule in `renovate.json`, it proposed 1.8.2.

## ✅ ROUND 3 — multi-arch push, Rosetta, the three open items — 2026-09-29

- **`make image-push` pushes ONE tag holding linux/amd64 + linux/arm64** (`PUSH_PLATFORMS`), on
  Linux and macOS, podman and Docker. The Dockerfile cross-compiles and its final stage runs
  nothing, so no emulator is involved (measured: podman built both with no qemu installed).
  podman builds a manifest list under `localhost/golang-web-push:<ver>` — its own name, because a
  list and image-build's plain image cannot share one, a rebuild onto a list APPENDS (2 → 4
  entries, measured), and `podman rmi` on a list deletes its native instance and every tag sharing
  it (measured by the Docker adversary). Docker: `--load` on the context's own builder, then
  `docker push`; `--provenance=false --sbom=false` keeps both engines' index to two entries.
  A pod deployed by the index digest reports `imageID` = the index digest (measured on lab-gc1), so
  step 8's check is unchanged.
- **Rosetta is not needed** on the main path: podman 6.1.2 defaults `[machine] rosetta=false`
  (source-read; containers.conf) and Colima defaults it off. The rented Mac's `rosetta = true` is in
  `~/.config/containers/containers.conf.d/50-vks-rosetta.conf`, written 2026-09-28 by another
  project that shares the Mac. Only the amd64-only Supervisor kubectl (a troubleshooting fallback)
  needs Rosetta. So "engine VM start on a Mac that never had Rosetta" is CLOSED: nothing asks for it.
- **9.1.1 Linux_ARM64 exists** on the portal (`VCF-Consumption-CLI-Linux_ARM64-9.1.1.0.25662425.tar.gz`,
  32.54 MB, SHA-256 `0e8fe5cc…3c5f`); downloaded, checksum matched, walked. The CLI block now prints
  the archive's SHA-256 to compare with the portal's SHA2 column (every local copy matched).
- **Supervisor-served CLI (VCF Operations)**: NOT feasible in this lab. The page proxies the Fleet
  Depot Service inside VCF Management Services (needs VCF Operations + SDDC Manager 9.1.x, ~3 TB and
  58–82 GB RAM; this host has 101 GB disk free) — 2–5 days and an effectively irreversible
  conversion to a VCF fleet, to serve a file the portal already provides. The README keeps the
  KB-449965-backed note, marked untested. The Supervisor advertises build 25662425, the portal's.
- **Walked on the branch code, all five paths passed steps 1–10**: Linux podman, Linux docker, Linux
  arm64 (real 9.1.1 Linux_ARM64 CLI), macOS podman, macOS Colima. This held while `image-push`
  relabelled the amd64 entry `v1` (below). That relabel is now removed, so Linux arm64 passes with
  **docker** (walked 2026-09-29), not podman 4.x.
- **podman 4.x on an arm64 Linux host cannot build a correct amd64 image (measured 2026-09-29,
  Ubuntu 24.04 arm64, podman 4.9.3 / buildah 1.33.7).**
  - It labels the amd64 entry `variant: v8` in the index and the image config. The cause is the
    Dockerfile's `FROM --platform=$BUILDPLATFORM` builder stage: a busybox-only build gets no
    variant.
  - No build shape avoids it: `$BUILDOS/$BUILDARCH`, `--platform=$TARGETPLATFORM` on the final
    stage, and `manifest add` without `--variant` all still gave `v8`. An amd64-only build produced
    an **arm64** image.
  - The earlier fix relabelled the entry `v1`. containerd (VKS) accepted that. But `podman pull
    --platform linux/amd64` rejects it on podman 4.9.3 and 6.1.2: `no image found … variant ""`.
    skopeo and CRI-O use the same library, which is inferred, not measured.
  - So `image-push` now **refuses** before pushing when an amd64 entry has any variant, and names
    Docker, a newer podman, or an arm64-only push for arm64-only clusters.
  - buildah 1.41 (podman 5.6+) changed variant handling and may fix this; UNVERIFIED. Settle it on
    arm64 Linux with podman 5.6+: `podman build --platform linux/amd64,linux/arm64 --manifest t .`,
    then `podman manifest inspect t`.
  - `image-push` still reads the list with **jq** (pinned in `.mise.toml`), and stops if its os/arch
    set differs from `PUSH_PLATFORMS`. Duplicates and a trailing comma are ignored.
- **The lab's `apps` Harbor project is PUBLIC** (`metadata.public=true`). Every walk therefore ran
  the pull-secret block without needing it. Measured 2026-09-28 against a temporary private
  project:
  - The step 8 no-login check prints `http=200` for a public project and `http=401` for a private
    one.
  - Public project with no secret, in a fresh namespace: the event says "Successfully pulled", and
    the pod runs.
  - Private project with no secret: `ImagePullBackOff`. The error says `pull access denied …
    no basic auth credentials`, not `401`/`unauthorized`.
  - Adding the secret afterwards leaves the pod stuck; `kubectl rollout restart` recovers it.
- **Lab Harbor's registry volume is 10 GiB and was 100% full**, which made pushes fail with
  "blob upload invalid" / `no space left on device` (the registry log says so; the client does
  not). Deleting a repository frees nothing until garbage collection, which had never run. One
  manual GC (untagged kept) freed ~350 MB; it is still ~98% used, mostly by the `cicd` project's
  39 repositories. Expect the next heavy session to fill it again: run GC, or grow the volume.
- Walk harness note: step 4 clones GitHub `main`, so a Makefile change is only walkable after the
  branch is pushed; the harness cloned the branch (disclosed deviation).

## ✅ ROUND 2 — kubectl, plugins and Linux arm64 — 2026-09-28

Researched by agents, the design attacked by three adversaries (VKS, Kubernetes, shell) before it
was built, then walked verbatim on FIVE paths: Linux podman, Linux docker, macOS podman, macOS
Colima, and **Linux arm64** (clean aarch64 `ubuntu:24.04` in Colima's VM). All pass steps 1–10.

- **kubectl is upstream (dl.k8s.io), native on every platform**, via `kubectl_install` in
  `~/.vks-golang-web.functions`: bootstrap `stable.txt`, then pinned to the Supervisor's version in
  step 7, then to the guest's. Measured: v1.37.1 → v1.34.9 → v1.36.2 on all five paths. The
  Supervisor-served kubectl was linux/darwin **amd64 only** and v1.32.9 against a v1.34 Supervisor
  (already outside ±1 skew). `vcf context create` needs no kubectl at all.
- **No VCF CLI plugins needed**: with ZERO plugins, `vcf context create` succeeded in 2 s and
  installed nothing; context list/delete work. The PluginBundle download is gone. (Round 5
  RESTORED the bundle at the owner's request; see there.)
- **Functions live in their own file**, rewritten by step 1 every time, because the env file is
  written under `set -C` and an existing user would never receive a new function. The upgrade
  path (old step 1 from `main`, then the new one) was walked: one `source` line, both functions load.
- ~~Rosetta stays~~ — **CORRECTED in round 3 above**: that vfkit `--device rosetta` came from
  ANOTHER project's `~/.config/containers/containers.conf.d/50-vks-rosetta.conf`, not podman's
  default. **`xcode-select --install` is gone**: the Homebrew installer installs CLT itself
  (measured on a fresh macOS guest) and falls back to xcode-select itself when interactive.
- **Fresh macOS proven** two ways: a tart vanilla macOS 26.6.2 guest (no CLT/Homebrew/Rosetta)
  passed the Homebrew block and every `brew install`; engine VMs cannot start there (M1 has no
  nested virtualization), so a brand-new host user started podman and Colima from zero state.
  tart needs a user keychain: over SSH, create and unlock one, or it fails `Failed to create new HostKey`.
- **The Supervisor's own VCF CLI download** (`/wcp/vcf-cli/`) answers 503 here: it proxies VCF
  Operations' Fleet Depot Service (KB 449965). Public packages.broadcom.com stops at v9.0.2. So the
  portal stays the source; the README mentions the Supervisor page for VCF-Operations sites.
- **Evidence** (measured in the 2026-09-28 session; the logs were not committed): the five walk
  logs; the zero-plugin `vcf context create`; the tart guest runs of the Homebrew and engine
  blocks; the new-user podman/Colima runs; the vfkit argv. The implementation was attacked by
  the same three adversaries after it was built; their fixes (noclobber-proof `>|`, newline-safe
  append, one "cannot reach dl.k8s.io" message, printed Supervisor/guest versions, a runnable
  fallback row) were re-walked.
- **Open (closed in round 3 above):** the 9.1.1 Linux_ARM64 archive; an engine VM start on a Mac
  that has never had Rosetta.

## ✅ ALL FOUR PATHS RE-WALKED AGAIN — 2026-09-28 (the flow BEFORE round 2: plugin bundle, Supervisor kubectl)

Same method (each block verbatim in its own fresh login shell, pass/fail from the Expect lines):
Linux podman and Linux docker in clean `ubuntu:24.04` containers, macOS podman and Colima on the
rented Mac — all four pass steps 1–10. The Mac ran on the same tunnel/alias/socat scaffolding as
before, all removed afterwards; the lab had been down since a host reboot and was started with
`make lab-start`. Fixed in the README from this walk, each MEASURED:

- Step 7 said three failed logins lock the SSO account. The SSO policy is 5 failures per 180 s
  with a 300 s auto-unlock (nested-vsphere-lab DOCTRINE.md B223); three is the VCSA root policy.
- Step 3's `colima restart` was not needed: login failed `x509: unknown authority` without the
  CA, succeeded with it and no restart, and failed again once it was removed.
- Step 10 removed all of `~/.kube/cache`, including other clusters' cache; it now leaves it.
- macOS 26 ships `/usr/bin/jq`, so `brew install jq` is a no-op there (noted, kept for older macOS).
- The Darwin VCF CLI archives were tagged with Safari's quarantine flag to match a browser
  download: `vcf` (Developer ID: VMware) and its plugins installed and ran. The walk ran over
  SSH, and a negative control proves SSH ENFORCES Gatekeeper: a quarantined ad-hoc-signed binary
  was killed (`rc=137`), the same binary unquarantined ran. A GUI Terminal applies the same
  policy (a dialog instead of a kill). The one step no harness can run is the Broadcom portal
  download itself (it needs a Broadcom login); on Linux there is no quarantine, so staging the
  archive in `~/Downloads` is already equivalent to downloading it.

## ✅ ALL FOUR PATHS RE-WALKED, EACH BLOCK IN A NEW TERMINAL — 2026-09-24

The walk followed the source-line audit (three blocks don't use the env file: step 2 Check,
step 4 clone, step 10 vcf contexts). Every README block for the path ran verbatim, in order, and
each ran in its **own fresh login shell** with nothing loaded, so a block missing a needed
`source` fails. Pass/fail came from each block's **Expect** line, not its exit code (a block's
exit code is only its last command's). The checks were: step 2 versions, both CA fingerprints,
`Login Succeeded`, the pushed digest, the SSO login, nodes `Ready` with matching client/server
versions, `successfully rolled out`, `IMAGEID` equal to the deployed digest, `Hello, World` over
the LoadBalancer and over the port-forward, `/myhello/` and `/healthz` 200 with `/` 404, and the
repo and robot deleted. Results:

| path | where | result |
|---|---|---|
| Linux podman | clean `ubuntu:24.04` container, non-root user with sudo, rootless podman 4.9.3 | 20/20 |
| Linux docker | clean `ubuntu:24.04` container, docker-ce from step 2 (dockerd started by hand, no systemd) | 20/20 |
| macOS podman | the rented Mac, zsh, podman 6.1.2 machine | 20/20 |
| macOS docker | the rented Mac, zsh, Colima | 20/20 |

- **One real defect, fixed in #179 (`cdda1ad`).** The Dockerfile's `FROM golang:…` is a short
  name. podman from apt on a stock Ubuntu 24.04 has no unqualified-search registries, so step 6
  died with `short-name "golang@sha256:…" did not resolve`. It had passed before only because
  the lab host and the podman machine VM configure docker.io. It is now
  `docker.io/library/golang:…` with the same digest; `check-toolchain-alignment` accepts that form.
- Two walk attempts hit an Ubuntu mirror 404 on `libexpat1` during step 2's `apt-get install`.
  This was transient: the retry passed.
- Harness setup, not under test: the same Mac tunnels, loopback aliases and socat forwarders as
  before, plus one for the app's LoadBalancer IP, which changes with every deploy (.159, then
  .137). All of it was removed afterwards, along with the containers and the host tunnels, and
  Colima was stopped. Harbor ended with no `golang-web` repo and no robot.

**Mac cleaned up 2026-09-24, and KEPT (owner decision): vks-airgap-cicd still needs it.**
B735 (macOS jump box) and B736 (arm64 build tags) are open in that repo's `BACKLOG.md`, and
their done-when criteria and open items need a real Mac. Do NOT delete the Scaleway server until
they are done or dropped. Removed from the Mac:

- the network scaffolding (tunnels, socat, loopback aliases, `/etc/hosts` in the Mac and both VMs);
- the leftover `~/vks-airgap-cicd` clone, which held a `.env` and a `secrets/` dir;
- `~/.config/vcf` (no contexts left);
- the toolchain that repo's `make deps` put in `~/.local` (mise, uv, argocd, kubectl, tkn) and its
  mise state;
- `~/go` and `~/.cache`;
- every harness file in `/tmp` and `~/wh`;
- both Darwin VCF CLI archives from `~/Downloads`.

Left, and gone with the machine: Homebrew and its packages (podman, colima, docker,
docker-buildx, jq, socat, git, make, GNU utilities), `/usr/local/bin/{vcf,kubectl}` from the
README, `~/.zprofile` (only the README's Homebrew line), empty engine configs, and the podman and
Colima VMs, both stopped. To resume there: `podman machine start` or `colima start`, re-clone
vks-airgap-cicd, and copy the Darwin VCF CLI archives back from the lab host's `~/Downloads/vcf`.
Delete the server and close ticket #1619590 only once B735/B736 no longer need it.

**Used again 2026-09-24/25** for the repo-wide Makefile, README and `.env` verification (see the
root HANDOFF.md). Left as found: podman machine and Colima stopped, `~/go` and every clone and
harness file removed. Colima's VM still caches the images those runs pulled (act runner, kind node).

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
2026-09-23. (Cleaned up 2026-09-24 and KEPT for vks-airgap-cicd B735/B736; see the section above.)

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
| **deletable from** | **2026-09-24 13:41** (Apple's 24 h minimum), but KEPT: vks-airgap-cicd B735/B736 still need it |

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
