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
vks/test/walk.sh extract vks/README.md /tmp/w-readme
vks/test/walk.sh --list /tmp/w-readme
vks/test/walk.sh run /tmp/w-readme --to 3
vks/test/walk.sh run /tmp/w-readme --to 3 --yes-run
```

Without `--yes-run` nothing runs: the blocks install software and change clusters, so the
selection is printed first. Each block runs in its own fresh login shell (`--shell bash` or
`zsh`) with stdin from `/dev/null`: a block that lacks its `source` line fails, as it would for
a reader in a new terminal. Output goes to `<outdir>/results/NNN.out`, the exit status to
`NNN.rc`, and one row per block to `results/summary.tsv`.

What to know before a walk:

- **`alt` blocks** (inside `<details>`) are alternatives the reader runs INSTEAD of the block
  before them. They are skipped unless `--with-alt` is given or `--only` names them.
- **A "this terminal" block** (`T` in the manifest: the guide says "this terminal" and the block
  only assigns variables) is put in front of every later block, as the reader's terminal would
  still hold it.
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
CONTAINER_ENGINE=podman vks/test/walk.sh container ubuntu:24.04 /tmp/w-readme --to 3 --env-file ~/walk-env/.vks-golang-web.env --yes-run
```

The env file is mounted read-only and installed into the user's home. Results come back as
`<outdir>/results-container`. To walk in stages (the docker path needs `dockerd` started by hand
after the install block, because the container has no systemd), keep the container and name it:

```
WALK_CONTAINER_RUN_OPTS="-v /var/lib/docker" vks/test/walk.sh container ubuntu:24.04 /tmp/w-readme --name w1 --keep --to 9 --yes-run
vks/test/walk.sh container ubuntu:24.04 /tmp/w-readme --name w1 --keep --from 10 --yes-run
```

## The Mac, over ssh

```
WALK_SSH_OPTS="-o BatchMode=yes" vks/test/walk.sh remote m1@<the Mac> /tmp/w-readme --shell zsh --to 3 --yes-run
```

It copies the blocks and `walk.sh` to `~/walk-<outdir name>` on the Mac (`WALK_REMOTE_DIR`), runs
them there and copies the results back to `<outdir>/results-remote`. `--env-file` names a path
ON THE MAC; the harness copies no env file and passes no secret over ssh. The lab's addresses
need the owner's tunnels: `vks/HANDOFF.md`, "The Mac's route to the lab".

## Not proven

- `remote`: covered by the tests only up to its dry run; never run against a machine.
- `container`: run once with podman and `ubuntu:24.04` on a two-block fixture guide (the `walk`
  user, passwordless sudo, the env file at mode 600, results copied back, container removed).
  Not run: docker, `--keep` with `--name`, and a real guide.
- bash 3.2 was not available where the harness was written: `walk.sh` avoids what 3.2 lacks,
  and its first run on the Mac is the proof.
