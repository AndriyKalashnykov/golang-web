# Walking the `vks/` guides

Internal, like `vks/HANDOFF.md`: how to run a guide's blocks the way a reader would, on Linux,
in a clean container and on the Mac. `walk.sh` does the mechanics. It does not judge: a block's
exit status is only its last command's, so every block is judged by its **Expect** text.

Two things run without a lab and are part of `make static-check`:

- `make check-vks-docs` reads the guides (`.github/scripts/check-vks-docs.sh`): every block
  parses in bash and zsh, has an Expect, sources its env file, holds no comment and nothing after
  a line that can prompt; links resolve. It prints `checked N block(s) in M file(s)`.
- `make scripts-test` runs `walk_test.sh` and the gate's own tests.

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
need the owner's tunnels: `vks/HANDOFF.md`, "The Mac's route to the lab".

## Not proven

- `remote`: covered by the tests only up to its dry run; never run against a machine.
- `container`: run once with podman and `ubuntu:24.04` on a two-block fixture guide (the `walk`
  user, passwordless sudo, the env file at mode 600, results copied back, container removed).
  Removal on Ctrl-C, the refusal of an existing name and `--reuse` are covered by the tests
  against a stand-in engine only. Not run: docker, and a real guide.
- bash 3.2 was not available where the harness was written: `walk.sh` avoids what 3.2 lacks,
  and its first run on the Mac is the proof.
