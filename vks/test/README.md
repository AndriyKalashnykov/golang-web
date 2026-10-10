# Walking the `vks/` guides

Internal, like `vks/HANDOFF.md`: how to run a guide's blocks the way a reader would, on Linux,
in a clean container and on the Mac. `walk.sh` does the mechanics. It does not judge: a block's
exit status is only its last command's, so every block is judged by its **Expect** text.

Two things run without a lab and are part of `make static-check`:

- `make check-vks-docs` reads the guides (`.github/scripts/check-vks-docs.sh`): every block
  parses in bash and zsh, has an Expect, sources its env file, holds no comment and nothing after
  a line that can prompt; links resolve. It prints `checked N block(s) in M file(s)`.
- `make scripts-test` runs `walk_test.sh`, `mac-route_test.sh` and the gate's own tests.

## Walk a guide

Extract the blocks, look at them, then run them. Block numbers move whenever a block is added,
so extract again before every walk.

```
vks/test/walk.sh extract vks/README.md ~/.cache/vks-walk/readme
vks/test/walk.sh --list ~/.cache/vks-walk/readme
vks/test/walk.sh run ~/.cache/vks-walk/readme --to 3
vks/test/walk.sh run ~/.cache/vks-walk/readme --to 3 --yes-run
```

Without `--yes-run` nothing runs: the blocks install software and change clusters, so the
selection is printed first. Each block runs in its own fresh login shell (`--shell bash` or
`zsh`) with stdin from `/dev/null` and a scrubbed environment: only `HOME`, `PATH`, `TERM`,
`USER`, `LOGNAME`, `SHELL` and `LANG` are passed on (`--pass-env NAME` adds one). A block that
lacks its `source` line therefore fails, as it would for a reader in a new terminal, even when
your own shell has the env file loaded. Output goes to `<outdir>/results/NNN.out`, the exit
status to `NNN.rc`, and one row per block to `results/summary.tsv`.

**The output may hold secrets.** A guide block can print a password (`ARGOCD-auto.md` has one
that prints ArgoCD's admin password), and the output file keeps it. Everything `walk.sh` writes
is readable only by you (umask 077). Keep the output directory under your home, not in `/tmp`,
and delete it after the walk.

What to know before a walk:

- **`alt` blocks** (inside `<details>`) are alternatives the reader runs INSTEAD of the block
  before them. They are skipped unless `--with-alt` is given or `--only` names them.
- **A "this terminal" block** (`T` in the manifest: the guide says "this terminal" and the block
  only assigns variables) is put in front of every later block, as the reader's terminal would
  still hold it — but only when this walk ran it. Starting after it (`--from`), or leaving it
  out, gives the later blocks what a new terminal has: nothing. Name it with `--only` to
  include it.
- **The working directory does not carry over.** After the main guide's step 4 (`git clone`),
  run the rest with `--from N --workdir <the clone>`.
- **The env file.** Step 1 writes example values. To walk with real ones, keep them in a file
  named as the guide names it and pass `--env-file <dir>/.vks-golang-web.env`: it is copied into
  the walk's HOME (mode 600) before the first block, and step 1's block then keeps it, as the
  guide says. The harness never prints it. Use `--home <scratch dir>` to keep a walk out of your
  own home.
- **Blocks that never end or that wait for a person:** the port-forward block, the editor
  blocks, the Homebrew installer. Leave them out with `--from`/`--to`/`--only`, or give
  `--timeout SECS`. Do not use `--timeout` where `sudo` asks for a password: the block then runs
  as a background job and cannot read the terminal.
- **Paste defects are not visible to a script.** The gate checks the two rules for fenced blocks
  from the text; the proof is still a paste into `zsh -i` and into bash 3.2 on a pty.

## Linux, in a clean container

`ubuntu:24.04` with `--privileged --network host` and a non-root user `walk` with passwordless
sudo, removed afterwards unless `--keep`:

```
CONTAINER_ENGINE=podman vks/test/walk.sh container ubuntu:24.04 ~/.cache/vks-walk/readme --to 3 --env-file ~/walk-env/.vks-golang-web.env --yes-run
```

The env file is mounted read-only and installed into the user's home. Results come back as
`<outdir>/results-container`. The container this run creates is removed on every way out,
Ctrl-C included. A container that already exists under the given `--name` is refused: the
walk did not create it, so it neither uses nor removes it.

To walk in stages (the docker path needs `dockerd` started by hand after the install block,
because the container has no systemd), keep the first run's container and walk in it again
with `--reuse`; a reused container is never removed by the harness:

```
WALK_CONTAINER_RUN_OPTS="-v /var/lib/docker" vks/test/walk.sh container ubuntu:24.04 ~/.cache/vks-walk/readme --name w1 --keep --to 9 --yes-run
vks/test/walk.sh container ubuntu:24.04 ~/.cache/vks-walk/readme --name w1 --reuse --from 10 --yes-run
docker rm -f w1
```

## The Mac, over ssh

```
WALK_SSH_OPTS="-o BatchMode=yes" vks/test/walk.sh remote m1@<the Mac> ~/.cache/vks-walk/readme --shell zsh --to 3 --yes-run
```

It copies the blocks and `walk.sh` to `~/walk-<outdir name>` on the Mac (`WALK_REMOTE_DIR`), runs
them there and copies the results back to `<outdir>/results-remote`. `--env-file` names a path
ON THE MAC; the harness copies no env file and passes no secret over ssh. The directory on the
Mac holds the same outputs and is left in place: delete it there after the walk. The lab's addresses
need the owner's tunnels and `mac-route.sh`: the next section.

## The Mac's route to the lab: `mac-route.sh`

The lab's addresses live on the lab host's bridges; a Mac elsewhere cannot reach them. The owner
opens reverse ssh tunnels from the lab host, and each lab `<ip>:<port>` then ends on the Mac as
a port on `127.0.0.1`. `mac-route.sh`, run ON THE MAC, makes the lab's own addresses and names
answer there, so every name, IP and port in the guides stays as written. It never opens a
tunnel.

Write the list once, one forward `<lab ip>:<port>:<tunnel port>` or one name `<name>=<lab ip>`
per line (`#` starts a comment). The addresses are the lab's (`make creds` in the lab's
repository prints them); the tunnel ports are free choices from 1024 up:

```
192.168.100.50:443:18443       # vCenter
192.168.101.128:443:18444      # Supervisor
192.168.101.128:6443:18445
192.168.101.130:443:18446      # Harbor
192.168.101.132:6443:18447     # the guest cluster's API
vcsa.env1.lab.test=192.168.100.50
harbor.env1.lab.test=192.168.101.130
```

The three commands, with the list in `~/lab.forwards` on the Mac:

```
vks/test/mac-route.sh up --file ~/lab.forwards
vks/test/mac-route.sh status
vks/test/mac-route.sh down
```

`--forward <lab ip>:<port>:<tunnel port>` and `--host <name>=<lab ip>` give the same on the
command line. `up` can be run again with a longer list: what is up stays up and keeps its
connections, only the new forward is added. The app's address exists only after the guide's
deploy step, so it is added that way:

```
vks/test/mac-route.sh up --file ~/lab.forwards --forward <the app's address>:8080:18448
```

**What the owner does, on the lab host.** `print-tunnel` prints his line for a list; it runs
anywhere, so the session prints it and hands it over:

```
vks/test/mac-route.sh print-tunnel --file ~/lab.forwards --mac m1@<the Mac>
```

It prints one `ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:<tunnel port>:<lab ip>:<port> … m1@<the Mac>`.
The owner runs it and leaves it running; he ends it after the walk. `up` refuses while a tunnel
port of the list is not listening on the Mac, names every such port and prints the same line.

**What `up` changes on the Mac**, per forward and per name:

| what | how to see it | how `down` undoes it |
|---|---|---|
| an alias for the lab IP on `lo0`, unless `lo0` has it already | `ifconfig lo0` | `ifconfig lo0 -alias <ip>`, only for an alias it added |
| a relay process listening on `<lab ip>:<port>`, connecting to `127.0.0.1:<tunnel port>` | `mac-route.sh status`; its log is `relay-<ip>-<port>.log` in the state directory | `kill` of the recorded PID, only while that PID still has the relay's start time and command line |
| a line in `/etc/hosts` ending in `# vks-mac-route` | `grep vks-mac-route /etc/hosts` | the recorded line is taken out, only when it still carries the marker |

Everything it creates is written to `~/.local/state/vks-mac-route/state` (under
`XDG_STATE_HOME` when that is set) before it is created, and `down` removes only what is
recorded there. An alias or a hosts line that was there before `up` is used and left alone.
`down` twice is safe. When `status` finds a relay or a marked hosts line that no state file
records, it lists it with the command that removes it by hand.

What to know:

- **An alias takes an address away from its real owner.** Before any change `up` refuses a lab
  IP that is the Mac's default gateway, one of its DNS resolvers, one of its own addresses, or
  inside the network of one of its interfaces, and says what it collided with. On a Mac whose
  own network overlaps the lab's, that is every forward. `--allow-onlink <ip>` lets one address
  through; give it only when the Mac needs nothing at that address during the walk.
- **Root.** The alias, a relay on a port below 1024 and the `/etc/hosts` change need root. Only
  `sudo -n` is used, and what it runs is named by absolute path. When sudo would ask for a
  password the script stops before changing anything and says to run `sudo -v` first. It reads
  and stores no password.
- **The relay** is `/usr/bin/python3 -I -` (it comes with the Command Line Tools:
  `xcode-select --install`). Its code is fed on stdin from `mac-route.sh` itself, so root never
  runs a file from a directory a user can write. One process per forward, so adding a forward
  does not cut the others. A relay binds its lab IP only, never every address. One on a port
  below 1024 is started through sudo, binds, then becomes the calling user for good before it
  opens its log, and ends instead when it cannot. It serves at most 64 connections at a time,
  closes one after 1800 s without data, and logs connections and byte counts, never the bytes.
- **Addresses.** Only private addresses are accepted (10/8, 172.16/12, 192.168/16). A name that
  `/etc/hosts` already gives another address, in a line the script did not write, is refused.
- **`/etc/hosts`** is replaced as a whole by `sudo -n /bin/cp` of a file built in the state
  directory, so its mode and owner stay. Before the copy the new file is checked (not empty,
  the expected number of lines, every other line still there); after it, the result is
  compared. When the copy or the compare fails, what the file held before that run is copied
  back and the script says whether that worked; when it did not, it prints the `sudo cp` line
  that restores it from the copy it kept.
- **`hosts.backup`** in the state directory is the hosts file from before the first change.
  `down` deletes it, and the state directory, only when the hosts file then has no marked line
  and still has every other line it had before that `down`. Otherwise both stay and `down`
  says why.
- **The state file is not trusted.** Every value read back from it is checked like a
  command-line value (a private address, a numeric PID, a marked hosts line). A line that
  does not pass is left alone and reported, `down` and `status` then end with status 1, and
  `up` refuses until the line is corrected or deleted.
- **One run at a time.** `up` and `down` hold a lock directory in the state directory. A run
  that was killed leaves it; the next run names the PID and prints the `rm -r` that clears it.
  An `up` killed while adding an alias leaves it recorded as pending: `status` shows it and
  `down` removes it.
- **The tunnel check** is `lsof -nP -iTCP@127.0.0.1:<port> -sTCP:LISTEN`: it reads the socket
  table. A connect test would open a connection to the lab service through the tunnel.
  `status` warns when a tunnel port listens on every address of the Mac instead of
  `127.0.0.1` (`GatewayPorts` in the Mac's `sshd_config`): the lab service is then open to
  whoever reaches the Mac.
- **Not the engine VMs.** The podman machine and the Colima VM resolve the lab's names through
  the Mac and need no entry of their own.
- **`MAC_ROUTE_TEST=1`** exists only for `mac-route_test.sh`. With it the script takes its hosts
  file, interpreter and system tools from `MAC_ROUTE_HOSTS`, `MAC_ROUTE_PYTHON` and
  `MAC_ROUTE_BIN`; without it those variables are refused. Never set it for a walk.

## Not proven

- `remote`: covered by the tests only up to its dry run; never run against a machine.
- `container`: run once with podman and `ubuntu:24.04` on a two-block fixture guide (the `walk`
  user, passwordless sudo, the env file at mode 600, results copied back, container removed).
  Removal on Ctrl-C, the refusal of an existing name and `--reuse` are covered by the tests
  against a stand-in engine only. Not run: docker, and a real guide.
- bash 3.2 was not available where the harness was written: `walk.sh` avoids what 3.2 lacks,
  and its first run on the Mac is the proof.
- `mac-route.sh` has never run on a Mac. Its tests run on Linux with stand-ins for `uname`,
  `ifconfig`, `route`, `scutil`, `sudo`, `lsof` and the relay's interpreter; the relay itself
  is run for real on `127.0.0.1`, and the script (not its tests) ran under bash 3.2 with the
  same stand-ins. Not proven, each of them on macOS:
  - a bind to an `lo0` alias, and the argument shape `ifconfig lo0 alias <ip> netmask
    255.255.255.255`;
  - whether an `lo0` alias can be reached from outside the Mac (another host that routes the
    lab's address to it);
  - the relay's drop from root (`setgroups`, `setgid`, `setuid` to `SUDO_UID`/`SUDO_GID`): the
    tests run its logic with the system calls replaced, never as root;
  - a relay started through the real `sudo` staying up after sudo returns, and sudo's handling
    of `PATH`, `HOME` and stdin for `python3 -I -`;
  - what `ps` prints for the start time and command line, and whether it shows a non-root
    caller the arguments of a process that was started as root;
  - `lsof` seeing the tunnel's socket (it belongs to the Mac's sshd), and its `TCP *:<port>`
    form for a port open on every address;
  - the output of `route -n get default`, `scutil --dns` and `ifconfig -a` as the address
    check reads them (the stand-ins print those formats from memory, not from a Mac);
  - a name from `/etc/hosts` resolving without a cache flush.
