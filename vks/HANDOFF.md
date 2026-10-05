# HANDOFF — `vks/` macOS verification

Resume point for the `vks/README.md` work. Read this before touching `vks/`.

## Where it stands

`vks/README.md` builds `golang-web`, pushes to Harbor, deploys to a VKS guest cluster.
**All work is merged; nothing is in flight.** Pinned to
**VCF CLI 9.1.1.0** (`vcf version` → `v9.1.1.0.25662425`). Walk coverage of the CURRENT text:
Linux podman and Linux docker end to end on the lab, and the docker install block alone on
Debian 12 and arm64 Ubuntu (round 8); **macOS podman and macOS Colima end to end on the new Mac
(round 9, 2026-09-30)**. Linux arm64 was last walked end to end in round 5; no arm64-only block
has changed since. Round 10 added one optional block (the Supervisor's kubectl) and ran it, with
steps 7–10, on Linux and macOS. Its only other command change is `--connect-timeout 10` on the
dl.k8s.io downloads (blocks 1 and 13), re-run on Linux and on the Mac. Round 11 (2026-10-01)
changed three Colima blocks (steps 2, 3 and 10) and ran those three on the Mac, not the whole path.
**Round 12 (2026-10-01) then walked the macOS Colima path end to end at `8dcb88a`: every Expect
matched.** macOS podman was last walked in round 9; none of its blocks has changed since.

**2026-10-03, text only:** the Linux docker install block (step 2) lost its trailing
`# then LOG OUT AND BACK IN` comment, and the sentence moved into the Expect line. A comment on a
command line is passed as arguments in an interactive zsh without `interactivecomments` (measured
on the Mac while validating the root README). No command changed and the block was not re-run; all
50 blocks still parse with `bash -n` and `zsh -n`. The other `#` lines in fenced blocks sit inside
here-documents, which the shell does not parse as commands. Every walk so far ran each block as a
script (a fresh login zsh with stdin from /dev/null), so none of them could have shown this.

**2026-10-05, one message:** `kubectl_install` (step 1) said `cannot reach dl.k8s.io, or the
checksum did not match` when the download and checksum had passed and `sudo` failed. Reproduced
with a `sudo` that exits 1, in bash and zsh. The message now ends `…, the checksum did not match,
or sudo failed`, and step 2's If-not and the Troubleshooting row say what a `sudo:` line above it
means. The message still starts with `kubectl_install: cannot reach dl.k8s.io`, which is what
those rows key on. Re-run: the function with the failing `sudo` (new message, rc 1) and its
success path into a scratch directory, on Linux; all 50 blocks parse with `bash -n` and `zsh -n`.
The failing-`sudo` case was repeated on the Mac (zsh 5.9 and bash 3.2): same message, rc 1.
Not re-walked on the lab. The Homebrew block (step 2) is now two blocks, the installer alone and
then the four `PATH` lines: the installer asks questions, and a shell without bracketed paste
feeds it whatever was pasted after it. The second block was pasted into zsh on the Mac and
printed `Homebrew 7.0.8`. The installer block stops at `Password:` for a session (its `sudo -v`
wants the login password); the owner ran it in a terminal on the Mac and it printed
`==> Installation successful!`, with more text after it, so the Expect now says "near its end". Step 1's block, step 2's kubectl block and step 7's call (`kubectl_install
"v1.36.2+vmware.2"`) ran as written on the Mac (zsh) and in clean `ubuntu:24.04` and
`ubuntu:26.04` arm64 containers and an `ubuntu:26.04` amd64 one: v1.37.1, then v1.36.2. The Supervisor-kubectl alternative block has the same shape
(its `sudo` is inside the chain) but its message already says "see the error above"; unchanged.

**2026-10-05, Linux podman walked end to end on the lab** at `97adb90`, after the two text
changes above. Clean `ubuntu:24.04` container (`--privileged --network host`), a non-root user
with sudo, each block in a fresh login shell: 33 blocks, steps 1 to 10, every Expect matched.
Step 7 installed kubectl v1.36.2 for the guest's v1.36.2+vmware.2; step 6 pushed amd64 + arm64
in 70 s (podman 4.9.3 on amd64); the project was public, so the pull-secret block was skipped;
the app answered on its LoadBalancer address. Not run, as before: the editor block and the
`REGISTRY_*` snippet (the harness fills the env file with awk, so it no longer needs
`python3`), and the port-forward blocks. Step 10 left no repository, robot or namespace.
The owner started the lab for this (`lab-start`, about an hour until Harbor answered: its
pods sat in `FailedAttachVolume` for over 20 minutes, then recovered without anyone deleting them).
**The lab was left running.**

**Linux docker was walked the same way afterwards** (docker 29.8.2, buildx 0.37.1; the container
also needs `-v /var/lib/docker`, and the harness starts `dockerd` after the install block, since
the container has no systemd): 36 blocks, steps 1 to 10, every Expect matched; the push took
24 s. This walk also ran the pull-secret block (on a public project: `secret/harbor-creds
created`, `serviceaccount/default patched`) and the port-forward blocks (`Forwarding from
127.0.0.1:8080`, then the page). 
**macOS (26.6.1) was walked against the lab afterwards, both engines**, each block in a fresh
login zsh with stdin from /dev/null. podman 6.1.3: steps 1 to 9, then step 10's app, Harbor,
login and CA blocks. Colima (docker 29.8.2 client, 29.5.2 server): the engine, switch-to-docker
and Colima CA blocks, then steps 5 to 10 in full. Every Expect matched except the one the
scaffolding rules out: the LoadBalancer address has no tunnel, so step 9's `curl` timed out and
the port-forward blocks served the page, as its If-not says. Pushes took 32 s and 26 s, both
architectures each time. The Homebrew blocks were not part of this walk (the owner ran them).
Scaffolding as round 9, with one difference: **the session may not open the `ssh -N -R` tunnels
(nor start the lab); the owner ran that one command in his own terminal**, and the session added
the `lo0` aliases, the root python relay and the two `/etc/hosts` lines. All of it is removed,
with the env file, clone, archives and both kubeconfigs; kubectl on the Mac is v1.36.2 again and
both engines are stopped. The owner's tunnel process and the lab are his to stop.

**Resume point:** nothing is pending. The lab was **running** when round 9 began and was left
running after round 10: this session did not start it, so it did not stop it. If
`esxi01` is shut off, start it with
`make -C ~/projects/nested-vsphere-lab lab-start` (about 20 minutes; it prints `lab started`),
then the method below. The Linux harness container needs `python3` (ubuntu:24.04 lacks it) for the
step that fills the env file. Lab values: `make creds` in that repo prints the endpoints (Harbor
`harbor.env1.lab.test`, project `apps`, Supervisor `192.168.101.128`, vCenter
`vcsa.env1.lab.test`, cluster `lab-gc1` in namespace `lab`, guest API `192.168.101.132:6443`); the
passwords are in its gitignored
`secrets.env`. After round 10, Harbor has no `golang-web` repository and no robot in `apps`, and
the guest cluster has no `golang-web` namespace (all three checked from this host). Its registry
volume was
at 60% after a GC; run GC again if pushes fail with `blob upload invalid` (the volume is full).
Stop the lab when nobody else needs it: `make -C ~/projects/nested-vsphere-lab lab-stop`.

**2026-10-04:** the lab is **stopped**. The root-README session started it on 2026-10-03, pushed
`golang-web` to Harbor's `apps` project and deployed it to `lab-gc1` with `make k8s-apply` (not
this runbook), deleted the repository, the robot and the namespace again, and stopped the lab.

**The rented Mac was replaced on 2026-09-30** (owner decision: more RAM). The M1 at
`51.159.120.46` is deleted; everything below that describes "the rented Mac" before this date is
about that machine. The new one, measured over SSH on 2026-09-30:

| | |
|---|---|
| Scaleway server | id `65fa64c6-d0ed-49de-bcf1-a766b9f67a11`, zone **fr-par-1** |
| hardware / OS | **Apple M2**, 8 cores, 16 GB, 228 GB disk — **macOS 26.6.1 (25G76)**, arm64 |
| access | `ssh m1@62.210.166.48` (this lab host's `~/.ssh/id_ed25519`) |
| as delivered | Xcode at `/Applications/Xcode.app`; `/usr/bin/{jq,git,make,python3}`; Rosetta present; no `/usr/local/bin`; no Homebrew, engine, `vcf` or `kubectl` |
| after round 9 | Homebrew 7.0.7 with podman 6.1.3, colima 0.10.3, docker 29.8.2 and docker-buildx 0.37.2; `/usr/local/bin/{vcf,kubectl}` (kubectl v1.36.2); `~/.zprofile` (the README's Homebrew line) |

- It is macOS 26.6.1; every earlier macOS walk ran on 26.6.2 (25G83). Round 9 found no
  difference in behaviour.
- The podman machine and the Colima VM exist and are **stopped**; both cache the build's base
  images. To resume: `podman machine start` or `colima start`.
- The Darwin VCF CLI archives were removed from `~/Downloads`; copy them again from the lab host's
  `~/Downloads/vcf`. The tunnel, loopback-alias and relay scaffolding was removed too (round 9
  says how to rebuild it).
- Passwordless sudo is set up for `m1` (`/etc/sudoers.d/m1`, added by the owner 2026-09-30).
- It is kept for vks-airgap-cicd (B735 macOS jump box, B736 arm64 build tags). Apple's 24 h
  minimum runs from its creation on 2026-09-30.
- Scaleway ticket #1619590 is closed (by the owner, reported 2026-10-01). The older sections
  below that say to close it are history.

How to walk it again: extract every `sh` block from `vks/README.md` and run each in a fresh login
shell, in a clean `ubuntu:24.04` container (`--privileged --network host`, plus
`-v /var/lib/docker` for docker). Judge each block by its Expect line. Block numbers in the
round sections below are for the README at that round; recount before reusing them.

The old probe script `vks/macosx.sh` and its `vks/macosx.res` were REMOVED (2026-09-23): running
every README block verbatim on a real Mac superseded the subset they checked. They are in git
history; references to them below are history.

## ✅ ROUND 12 — macOS Colima walked end to end after round 11 — 2026-10-01

The README at `8dcb88a` (step 4 cloned `main`), every macOS Colima block verbatim, each in its own
fresh login zsh with stdin from `/dev/null`, judged by its Expect line. Machine: the M2, macOS
26.6.1, Colima 0.10.3, docker 29.8.2 client / 29.5.2 server, buildx 0.37.2.

- **Result:** 35 blocks run, steps 1–10, every Expect matched.
- **Starting state:** not from zero. Homebrew, Colima, docker, `vcf` and kubectl were already
  installed (round 9), the Colima VM existed and was stopped, and the build's layers were cached
  (the build and push took 27 s). There was no env file, clone, CA file or Harbor login.
- **Not run, as the README says:** the Homebrew block (`brew --version` works), `brew install jq`
  (macOS 26 has jq), the Supervisor-kubectl alternative (dl.k8s.io was reachable) and the
  pull-secret block (the check printed `http=200`). The editor block and the `REGISTRY_*` snippet
  were replaced by the harness editing the env file. Step 5 used option A (the robot account).
- **Checks that passed:**
  - both CA fingerprints equalled the lab's copies; both archive SHA-256 lines equalled the lab
    host's copies; 12 plugins `installed`;
  - step 2 printed `Current context is now "colima"` and `colima: Ubuntu 24.04.4 LTS/aarch64
    server=29.5.2`; step 3's Colima block printed nothing (Colima was running);
  - `Login Succeeded`; the push listed `amd64,arm64`; step 2's kubectl was v1.37.1 and step 7
    replaced it with v1.36.2 (guest `v1.36.2+vmware.2`);
  - the pod's `IMAGEID` equalled the pushed digest; `Hello, World` came back over the LoadBalancer
    address (`192.168.101.141`) and over the port-forward;
  - step 10 left no repository, no robot, no app address, no Harbor login, no image, no `vcf`
    context and an empty `certs.d` in the VM (Harbor and the address checked from the lab host).
- **Two things a reader will see that are fine:** step 10's local-image block prints
  `podman is not running: …` because podman is installed and stopped (the Expect covers it); the
  "Delete the files" block prints nothing but exits 1, because `~/.kube` still holds kubectl's
  `cache`, which the README says is kept.
- **The lab was restarted during the walk** by the nested-vsphere-lab session (`run.sh --restart`,
  13:32–14:04 local). The walk waited between step 2's engine blocks and the vCenter CA download;
  the addresses were unchanged afterwards.
- **Scaffolding (not under test):** as round 9 — `ssh -N -R` tunnels from the lab host, `lo0`
  aliases of the lab IPs, a root `/usr/bin/python3` relay, two `/etc/hosts` lines; the Darwin
  archives copied into `~/Downloads`. All removed afterwards; Colima and the podman machine are
  stopped. Installed tools stay.
- **Not covered:** an install from zero, Terminal.app (SSH only), Docker Desktop or OrbStack
  beside Colima.

## ✅ ROUND 11 — Colima: stopped VM, wrong docker context, stdin — 2026-10-01

Three macOS/Colima blocks changed; each was run verbatim on the Mac (M2, macOS 26.6.1, Colima
0.10.3, docker 29.8.2 client / 29.5.2 server), in its own fresh login zsh. **Not** an end-to-end
walk: no lab tunnel was built, so steps 5–9 were not re-run. The step 3 and step 10 blocks ran
against a stand-in CA file and a two-line env file (the block only copies bytes into the VM).

- **What was wrong (measured before the change):**
  - With Colima stopped, step 3's and step 10's `colima ssh` lines fail with
    `level=fatal msg="colima not running"` (rc 1) and the README had no line for it.
  - `colima stop` removes the `colima` docker context and `colima start` from stopped creates and
    selects it. `colima start` on a running Colima prints `already running, ignoring` (rc 0) and
    does **not** switch the context back. So "Colima running, `docker` pointed elsewhere" gave
    `dial unix /var/run/docker.sock`, and the troubleshooting row's `colima start` did not fix it.
  - `colima ssh -- <cmd>` reads stdin. Pasted without bracketed paste (bash 3.2, or zsh fed plain
    lines over a pty), it ate the next line of the block: a marker line after it did not run
    (0 of 1), and ran with `</dev/null` (1 of 1). zsh with bracketed paste, which Terminal uses,
    was not affected.
- **README changes:**
  - step 2: `docker context use colima` after `colima start`; the info line now starts with the
    engine's name (`colima: Ubuntu 24.04…`); an If-not for `DOCKER_HOST`/`DOCKER_CONTEXT`;
  - step 3 and step 10: `colima status >/dev/null 2>&1 || colima start` first; step 3's `mkdir`
    line has `</dev/null`; step 3 has an If-not for `colima not running`;
  - troubleshooting: the `dial unix` row adds `docker context use colima`, and the x509 row says
    `docker context show` must print `colima`.
- **Results (every block rc 0):**

  | block | state before | result |
  |---|---|---|
  | step 2 | Colima stopped | started; `Current context is now "colima"`; `colima: Ubuntu 24.04.4 LTS/aarch64 server=29.5.2` |
  | step 2 | running, context `default` | `already running, ignoring`; context switched; same info line |
  | step 2 | `DOCKER_HOST` set to a dead socket | the `Warning: DOCKER_HOST …` line and `: / server=`, as the If-not says |
  | step 3 | Colima stopped | started (ends with `done`); CA in the VM, SHA-256 equal; `docker` reaches `colima` |
  | step 3 | running | no output; SHA-256 equal |
  | step 3 | fed on stdin, zsh and bash 3.2 | no output; SHA-256 equal (the `tee` line was not eaten) |
  | step 10 | Colima stopped | started; `certs.d` in the VM empty |
  | step 10 | running | no output |

- **Not tested:** Docker Desktop or OrbStack installed beside Colima (neither is on the Mac; the
  wrong-context case was made with `docker context use default`), a failing `colima start`, and
  Terminal.app itself (SSH only; bracketed paste was simulated with its escape codes).
- The Mac was left as found: Colima and the podman machine stopped, no env file, no CA file.

## ✅ ROUND 10 — kubectl wording, and a Supervisor-kubectl alternative — 2026-09-30

- **README, step 2 "Install kubectl".** The intro now says the block installs the newest stable
  kubectl with `sudo`, and that step 7 installs the guest cluster's matching version over it. The
  old text put "`sudo` asks for your password" right after the step 7 sentence, so it read as
  being about step 7.
- **A collapsed alternative under that block** installs the kubectl the Supervisor serves, for
  sites where dl.k8s.io is blocked. The README now has **50** `sh` blocks; the new one is block 14,
  so every later block number in the round sections below is one higher.
  - It picks the platform with a `case` on `uname`, like the docker install block, and installs
    nothing on a platform the Supervisor has no build for.
  - **The download uses `curl -k` (owner decision, later the same day).** It first shipped with
    `--cacert "$SUPERVISOR_CA"`; the owner chose `-k` so the block needs no CA file. Do not put
    `--cacert` back without asking. The cost, stated once: the kubectl installed with `sudo` is
    not verified to come from the Supervisor, and this download has no checksum. `wget` was not
    used because macOS has none; measured, it refuses the Supervisor's certificate just as curl
    does unless given `--ca-certificate` or `--no-check-certificate`. The `-k` block was re-run
    with no CA file present on clean `ubuntu:24.04` (good case, unresolvable name, unreachable
    endpoint, 404, each with an existing kubectl left unchanged) and on the Mac in zsh and
    bash 3.2.
  - The Troubleshooting row for `cannot reach dl.k8s.io` no longer carries its own one-liner; it
    points at this block.
- **Measured on the lab Supervisor:** `/wcp/plugin/<platform>/vsphere-plugin.zip` answers 200 for
  `linux-amd64`, `darwin-amd64` and `windows-amd64`, and 404 for `linux-arm64` and
  `darwin-arm64`. The kubectl inside is `v1.32.9+vmware.2-fips`.
- **The block was run as written:**

  | where | result |
  |---|---|
  | clean `ubuntu:24.04` amd64, bash, dl.k8s.io blocked | step 2's block printed `cannot reach dl.k8s.io`; the alternative installed v1.32.9; step 7 logged in, read the kubeconfig, printed `cannot reach dl.k8s.io`, kept v1.32.9, and listed the nodes with a `version difference` warning |
  | the same, dl.k8s.io reachable | the alternative installed v1.32.9 over v1.37.1; step 7 replaced it with v1.36.2 |
  | macOS 26.6.1 arm64, zsh 5.9 and bash 3.2 | installed the Intel kubectl, which ran under Rosetta; step 7 behaved as on Linux, blocked and unblocked |
  | `ubuntu:24.04` arm64 (Colima on the Mac) | printed `No Supervisor kubectl for Linux/aarch64: nothing installed`, and installed nothing |
  | Linux, seven failure cases, with a kubectl already installed | wrong CA, missing CA file, empty endpoint, unresolvable name, a 404, an unreachable endpoint (stops after 20 s) and a kubectl that cannot run each printed the error, then `Nothing installed`, removed the temp directory, and left the existing kubectl as it was |
  | clean `ubuntu:24.04` amd64, dl.k8s.io blocked, **steps 8–10 with the v1.32.9 kubectl** | namespace, deploy by digest, `IMAGEID` equal to the pushed digest, `Hello, World` over the LoadBalancer and the port-forward, namespace and repository deleted. The namespace delete printed `very short watch` warnings from the old client and still deleted it |

- **A review found seven things; all applied.**
  - The block now runs the downloaded kubectl once before `sudo install`, so one that cannot run
    (no Rosetta, wrong platform) never replaces a working kubectl.
  - `mktemp` is inside the `if`, so a failed `mktemp` cannot make `unzip` write into the current
    directory.
  - The failure line says "the download … or the check of the downloaded kubectl, failed".
  - The If-not list first carried curl's CA error strings, which differ by platform (measured:
    `error setting certificate file` on curl 8.5, `error setting certificate verify locations` on
    macOS curl 8.7.1, `provided to --cacert does not exist` on curl 8.18). That bullet went away
    with the switch to `-k`.
- **`kubectl_install` and step 2's block got `--connect-timeout 10`.** This is a change to block 1
  and block 13, outside the alternative itself. Reason, measured with dl.k8s.io pointed at a
  black-hole address (a firewall that drops instead of refusing):

  | | before | after |
  |---|---|---|
  | step 2's kubectl block | 136 s, then `cannot reach dl.k8s.io` | 10 s |
  | `kubectl_install <guest version>` (what step 7 calls) | 1,089 s (about 18 minutes), then `cannot reach dl.k8s.io` | 94 s |

  The success path was re-run with the timeout on Linux (v1.37.1, then v1.36.2) and on the Mac in
  zsh and bash 3.2.
- **Steps 7–10 re-run with the final `-k` block, dl.k8s.io blocked, on both platforms**
  (README at `d11ed58`): clean `ubuntu:24.04` amd64 in bash, and the Mac (macOS 26.6.1) in zsh.
  On each: the alternative installed v1.32.9 with no CA argument; Supervisor login; namespace
  visible; guest kubeconfig (then `cannot reach dl.k8s.io`, kubectl kept); nodes `Ready` with the
  `version difference` warning; namespace created; deploy by digest rolled out; `IMAGEID` equal
  to the pushed digest; `Hello, World` over the LoadBalancer and the port-forward; namespace,
  repository, Supervisor login, files, clone and env file deleted. The image was pushed from the
  lab host with podman (amd64 only), as scaffolding; steps 5–6 were not part of this re-run. On
  the Mac the Harbor login used the admin account (option B) and both engines were stopped, so
  step 10's local-image block printed its two `is not running` lines.
- **Not measured:** an Intel Mac; an Apple-silicon Mac without Rosetta (the `bad CPU type` line is
  inferred).
- The Mac was left as round 9 left it: native kubectl v1.36.2, no scaffolding, both VMs stopped.
  This host's podman pushed the test image; its login, image and `certs.d` entry were removed.

## ✅ ROUND 9 — both macOS paths walked on the replaced Mac — 2026-09-30

The README at `09e2c84` (step 4 cloned `main`, no deviation), every macOS block verbatim, each in
its own fresh login `zsh`, judged by its Expect line. Machine: Apple M2, 16 GB, **macOS 26.6.1
(25G76)**, delivered that day with nothing installed.

| path | blocks run | result |
|---|---|---|
| macOS podman (6.1.3, applehv machine) | 35 | every Expect matched, steps 1–10 |
| macOS docker (Colima 0.10.3, docker 29.8.2 client / 29.5.2 server, buildx 0.37.2) | 35 | every Expect matched, steps 1–10 |

- **OS version.** The earlier macOS walks ran on 26.6.2 (25G83) on an M1 with 8 GB. On 26.6.1
  nothing behaved differently: no block needed a change, and the README needs no version note.
  Tool versions that differ from round 5: podman 6.1.3 (was 6.1.2), Homebrew 7.0.7. `/usr/bin`
  still has LibreSSL 3.3.6 (`SHA256 Fingerprint=`), curl 8.7.1, jq 1.7.1, GNU Make 3.81, zsh 5.9.
- **Not run, as the README says:** the editor block and the `REGISTRY_*` snippet (the harness
  edits the env file instead), `brew install jq` (macOS 26 has jq), the pull-secret block (the
  check printed `http=200`), and, on the docker path, the Homebrew block (already installed).
- **From zero.** The Homebrew block installed Homebrew in 20 s with no prompt (stdin was not a
  terminal; passwordless sudo). Xcode was already on the machine, so the installer's Command Line
  Tools download did not run here. `/usr/local/bin` did not exist; the kubectl and `vcf` blocks
  created it. `podman machine init`/`start` and `colima start` each ran from no prior state.
- **Checks that passed on both paths:**
  - both CA fingerprints equalled the lab's copies;
  - the two archive SHA-256 lines equalled the lab host's copies;
  - `vcf` ran with Safari's quarantine flag set on both archives, and installed 12 plugins;
  - the push listed `amd64` and `arm64`;
  - step 2's kubectl was v1.37.1 and step 7 replaced it with v1.36.2 (guest `v1.36.2+vmware.2`);
  - the pod's `IMAGEID` equalled the pushed digest;
  - `Hello, World` came back over the LoadBalancer address and over the port-forward;
  - step 10 left no repository, no robot, no namespace, no Harbor login and no `vcf` context.
- **The lab was not in the state this file described.** A `golang-web` namespace (22 h old, with a
  deployment and a `harbor-creds` secret) and an image pushed 2026-09-30 03:58 UTC already
  existed; who made them is not known. Effects on the podman walk: the namespace block printed
  `unchanged`, the deploy block `configured`, and the architecture check printed a second,
  untagged line for the older image. Step 10 removed all of it. The docker walk then ran against
  a clean lab and printed `created` and a single line.
- **Scaffolding (not under test).** `ssh -N -R 127.0.0.1:<high port>:<lab ip>:<port>` from the
  lab host for vCenter, the Supervisor, Harbor, the guest API and the app's LoadBalancer address
  (`.159`, then `.137`); `lo0` aliases of those lab IPs on the Mac; a root `/usr/bin/python3`
  relay from each alias to its tunnel port; two `/etc/hosts` lines for the vCenter and Harbor
  names. A Python relay replaced `socat`, so nothing outside the README was installed with
  Homebrew. Neither VM needed its own `/etc/hosts` entry: the podman machine and the Colima VM
  both resolved Harbor's name through the Mac and reached it by its lab IP (measured with
  `getent hosts` and `curl` inside each VM). All of it was removed afterwards.
- **Not covered:** a Mac without Rosetta (this image ships it), a Mac without Xcode, Terminal.app
  (the walk ran over SSH), and the Broadcom portal download itself.
- The walk logs were not committed.

## ✅ ROUND 8 — second end-user review, walked on the lab — 2026-09-29

- **README:** a second newcomer review (18 findings) and an adversary round, all applied:
  - the clone deletion is its own step-10 block, with a bold warning for a clone you already had;
  - step 10 says to run blocks in order (the last ones delete the clone and the env file);
  - every new terminal must `cd` back into the clone, and step 6's If-not names the error;
  - the editor defaults to `nano` (present on macOS 26 as pico), with a TextEdit warning;
  - the vCenter CA download is marked required for everyone;
  - Harbor's `getcert` 404 has its own If-not (Harbor source: `GetCA` returns NotFound when
    Harbor holds no CA file), and the block deletes a stale `$HARBOR_CA` first;
  - the docker block reads `ID` from `/etc/os-release` and installs only on `ubuntu`/`debian`;
    anything else prints "nothing installed" and changes nothing. Mint etc. are out of scope.
  - verb headings, missing "what this is for" sentences and If-not lines, two Terms rows.
- **Walked** (49 blocks, each in its own fresh login shell, ubuntu:24.04 container, lab):
  Linux podman end to end: pass. Linux docker: see below. The docker block alone: Debian 12
  amd64 and Ubuntu 24.04 arm64 (Colima on the Mac): pass. On the Mac, zsh: blocks 1 and the
  three split clean-up blocks: pass. Not re-walked on the Mac end to end: no macOS-only block
  changed.
- **Harness note:** the harness container needs `python3` (for the env-file fill step), which
  ubuntu:24.04 lacks; the first run failed on that, not on the README.

## ✅ ROUND 7 — end-user review applied, podman 4.x refused early — 2026-09-29

- **README:** a reviewer read it as a CI/CD newcomer (36 findings). Applied:
  - a warning that step 5's CONFLICT fix via step 10 also deletes the repository;
  - Broadcom account, sudo and the full host list added to Before you start;
  - the step 7 intro no longer contradicts the one-minor rule, and the OIDC path installs the
    matching kubectl;
  - the arm64 rule sits inside "pick one";
  - literal Expect lines (docker `WARNING!` first, `buildx is available.`, an empty architecture
    column for one platform, macOS `SHA256 Fingerprint=` — measured on the Mac, LibreSSL 3.3.6);
  - `###` headings in steps 3, 6 and 10, more Terms rows, Expect lines for the last two clean-up
    blocks.
  Not walked on the lab (it is stopped): the only command change is the step 10 `-w` labels. All
  48 blocks pass `bash -n` and `zsh -n`. Unverified: `jq` built into macOS before 26, and whether
  a 9.1.1 `Darwin_AMD64` plugin bundle exists (the README says untested).
- **Makefile:** `image-push` refuses podman older than 5 on arm64 Linux BEFORE building (the
  after-build check stays for every other case), and `make deps` prints a note when it installs
  such a podman there. Tested with stubbed `uname`/`podman` (aarch64 and arm64 with 4.9.3 and 3.4.4
  refused; 5.8.7, arm64-only, x86_64 and Darwin let through). Not run on a real arm64 podman 4.9
  host this round; the version line the stub prints is the real one's.

## ✅ ROUND 6 — the open items, settled by measurement — 2026-09-29

- **podman on arm64 Linux.** `quay.io/podman/stable` (podman 5.8.7), arm64, running
  `podman build --platform linux/amd64,linux/arm64 --manifest t` with this repo's Dockerfile gave
  `[{"architecture":"arm64","os":"linux"},{"architecture":"amd64","os":"linux"}]`: no variants.
  So podman 4.9.3 (Ubuntu 24.04's apt) mislabels and podman 5.8.7 does not; 5.0–5.7 are
  untested. The READMEs and the `image-push` message offer docker, or podman 5.8 as measured.
  Ubuntu 24.04 has no apt route to podman 5.8, so the vks README leads with docker.
  The real `make image-push` was also run under podman 5.8.7 on arm64, pointed at a registry that
  refuses connections. It built both platforms, passed the variant and platform checks with no
  refusal, and failed only at the push; the list held `arm64` and `amd64` with no variants.
- **9.1.1 Linux_ARM64 plugin bundle.** It exists on the portal:
  `VCF-Consumption-CLI-PluginBundle-Linux_ARM64-9.1.1.0.25665404.tar.gz`, SHA-256 `d996d1a7…fdd2`,
  matching the download. The README's install block (step 2), run as written on arm64
  `ubuntu:24.04` with the 9.1.1 CLI, installed every plugin. No version deviation is needed any
  more.
- **Step 10 with the podman engine unreachable (macOS).** podman was pointed at a connection whose
  socket does not exist (a stopped machine, from the client's side), and docker at a dead socket;
  the block ran in zsh with throwaway auth files. It printed "podman is not running …" and
  "docker is not running …", exited 0, and the podman auth file still held the Harbor entry,
  exactly as the message says. docker's logout still removed its entry.
- **Gatekeeper.** The two Darwin archives were given Safari's quarantine flag and the README
  block was run.
  - `/usr/local/bin/vcf` KEEPS the flag; the 24 plugin executables do not.
  - `spctl --assess -t open --context context:primary-signature` reports
    `accepted source=Notarized Developer ID` (VMware, EG7KH642X6), and `vcf` ran.
  - Terminal.app was not run. It should behave the same, because Gatekeeper assesses the file,
    not the terminal (inferred; checked over SSH only).
- **The warning when a tool is not on PATH.** Both PATH warnings (kubectl and vcf) printed an
  empty name when the tool was not on PATH at all. They now print `'not found'`.
- **The Supervisor's CLI download.** Earlier rounds said it "needs VCF Operations" on the strength
  of KB 449965, but that KB is about the vSphere Client's link ("Unable to connect to the Fleet
  Depot Service"), not the Supervisor page. Measured this time on the control plane
  (192.168.100.60): `/etc/vmware/wcp/nginx/forwarding_rules_vcf_cli.conf.jinja` proxies
  `/wcp/vcf-cli` to the FDS file depot "if FDS ManagementService is available", and otherwise
  renders `return 503 "VCF CLI is currently unavailable for download."`, which is what this lab
  serves. The build info it advertises (`/resources/cliBuildInfo/buildInfo.json`) is
  9.1.1.0 / 25662425. The template names only "FDS ManagementService". Placing the Fleet Depot
  Service in VCF Operations comes from KB 449965's naming, so that part is inferred. Not supported
  here; the README says so, and the working download path was never exercised.
- **Lab Harbor.** GC with `delete_untagged=true` freed 4.0 GB: 99% to 60% of 10 GiB.

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

> Superseded 2026-09-30: this machine was deleted and replaced. See "The rented Mac was replaced"
> under "Where it stands". The paragraphs below record the old M1's state.

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
