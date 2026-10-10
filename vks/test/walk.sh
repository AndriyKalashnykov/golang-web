#!/usr/bin/env bash
# walk.sh — extract the `sh` blocks of a vks/ guide and run them one by one.
#
#   walk.sh extract   <guide.md> <outdir>            write NNN.sh + manifest.tsv
#   walk.sh --list    <outdir | guide.md>            print the manifest, run nothing
#   walk.sh run       <outdir> [options] --yes-run   run the blocks on this machine
#   walk.sh remote    <ssh-target> <outdir> [options] --yes-run     the same over ssh
#   walk.sh container <image> <outdir> [options] --yes-run          the same in a clean container
#
# Each block runs in its OWN fresh login shell, with stdin from /dev/null and a SCRUBBED
# environment (HOME, PATH, TERM, USER, LOGNAME, SHELL, LANG, plus any --pass-env NAME), so a block
# that lacks a needed `source` line fails even when your own shell has the env file loaded.
# The output files may hold secrets (a guide block can print a password): everything this
# script writes is created under umask 077. The harness does NOT decide pass or fail: a block's exit status
# is only its last command's. It prints the output's first line beside the guide's Expect text,
# and a person (or the calling session) judges. vks/test/README.md has the walk procedure.
#
# manifest.tsv, one row per block, TAB-separated, `-` for an empty field:
#   NNN  kind  term  line  heading path  first line  Expect text
#   kind: main | alt   (alt = inside <details>, an alternative the reader runs INSTEAD)
#   term: T | TN | -   (T = the guide says "this terminal" and the block only assigns variables;
#                       TN = its sentence goes on "until the end of step N". `run` puts such a
#                       block in front of every later block of the walk, as the reader's terminal
#                       would — but only when the walk RAN it; an alternative that was not
#                       selected leaves nothing behind)
#
# Needs bash 3.2+ and a POSIX awk. `.github/scripts/check-vks-docs.sh` uses `extract`, so the
# gate and a walk always see the same blocks.
set -u
umask 077

PROG=${0##*/}
SELF=$0
die() { echo "$PROG: $*" >&2; exit 2; }

usage() {
  sed -n '2,9p' "$SELF" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

run options:
  --yes-run          really run (without it the selection is printed and nothing runs)
  --from N, --to N   run blocks N..M of the manifest
  --only N,M,...     run exactly these blocks (alternatives included when named)
  --with-alt         also run `alt` blocks (default: main blocks only)
  --shell bash|zsh   the login shell each block runs in (default: bash)
  --workdir DIR      directory each block starts in (default: the current directory)
  --home DIR         HOME for the blocks (default: your HOME); use a scratch home for a dry walk
  --env-file PATH    copy PATH to $HOME/<its file name> (mode 600) before the walk, unless that
                     file exists; name it as the guide does, e.g. .vks-golang-web.env. Repeatable.
  --pass-env NAME    also give the blocks your variable NAME (the rest of your environment is
                     not passed on). Repeatable. Remote and container: the far side's NAME.
  --timeout SECS     stop a block after SECS (default 0: no limit). Not with a sudo that prompts.
  --stop-on-fail     stop after the first block whose exit status is not 0
remote:    WALK_SSH_OPTS (extra ssh options), WALK_REMOTE_DIR (default: walk-<outdir name>);
           --env-file names a path ON THE REMOTE machine; nothing secret is copied.
container: CONTAINER_ENGINE (podman|docker, default podman), WALK_CONTAINER_RUN_OPTS (extra
           `run` options, e.g. "-v /var/lib/docker"), WALK_CONTAINER_PKGS (default: sudo);
           --name NAME (the new container's name), --keep (do not remove it afterwards),
           --reuse (walk in the EXISTING container --name names; it is never removed);
           without --reuse an existing container of that name is refused, not taken over.
           --env-file is mounted read-only and installed into the walk user's home.
EOF
}

# ---------------------------------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------------------------------
cmd_extract() {
  [ $# -eq 2 ] || die "usage: $PROG extract <guide.md> <outdir>"
  local guide=$1 out=$2
  [ -f "$guide" ] || die "no such guide: $guide"
  mkdir -p "$out" || die "cannot create $out"
  rm -f "$out"/[0-9][0-9][0-9].sh "$out/manifest.tsv"
  awk -v out="$out" '
    function clean(s) { gsub(/\t/, " ", s); gsub(/^ +| +$/, "", s); return s == "" ? "-" : s }
    function hpath(   i, p) {
      p = ""
      for (i = 2; i <= 6; i++) if (h[i] != "") p = p (p == "" ? "" : " > ") h[i]
      return p == "" ? h[1] : p
    }
    function end_expect() { capturing = 0 }
    function ticks(s) { sub(/^ ? ? ?/, "", s); return match(s, /^`+/) ? RLENGTH : 0 }
    {
      line = $0
      if (infence) {
        if (line ~ /^ ? ? ?````*[ \t]*$/ && ticks(line) >= flen) {     # a fence closes with at least as many backticks
          if (infence == 1) {
            close(file); term[n] = "-"
            if (index(prose, "this terminal") && assign_only && nonblank) {
              term[n] = "T"
              if (match(prose, /this terminal until the end of step [0-9]+/)) {
                t = substr(prose, RSTART, RLENGTH); sub(/.* /, "", t); term[n] = "T" t
              }
            }
          }
          infence = 0; prose = ""; searching = (n > 0)
          next
        }
        if (infence == 1) {
          print line > file
          if (line !~ /^[ \t]*$/) {
            nonblank++
            if (first[n] == "") first[n] = line
            if (line !~ /^(export +)?[A-Za-z_][A-Za-z0-9_]*=/) assign_only = 0
          }
        }
        next
      }
      if (line ~ /^ ? ? ?```/) {
        end_expect(); searching = 0
        flen = ticks(line)
        lang = line; sub(/^ ? ? ?`+[ \t]*/, "", lang); sub(/[ \t].*$/, "", lang)
        if (lang == "sh" && flen == 3) {
          infence = 1; n++
          file = sprintf("%s/%03d.sh", out, n)
          printf "" > file
          kind[n] = depth > 0 ? "alt" : "main"; at[n] = NR + 1; head[n] = hpath()
          first[n] = ""; expect[n] = ""; assign_only = 1; nonblank = 0
        } else infence = 2
        next
      }
      if (line ~ /^##?#?#?#?#? /) {
        end_expect(); searching = 0; prose = ""
        lvl = index(line, " ") - 1
        t = line; sub(/^#+ +/, "", t)
        h[lvl] = t
        for (i = lvl + 1; i <= 6; i++) h[i] = ""
        next
      }
      tmp = line; depth += gsub(/<details/, "", tmp); depth -= gsub(/<\/details>/, "", tmp)
      tmp = line; gsub(/[*_]/, "", tmp); gsub(/[ \t]+/, " ", tmp); prose = prose " " tmp
      if (capturing) {
        if (line ~ /^[ \t]*$/) { end_expect(); next }
        expect[n] = expect[n] " " line
      } else if (searching && expect[n] == "" && (p = index(line, "**Expect:**"))) {
        expect[n] = substr(line, p + 11); capturing = 1
      }
      if (capturing && (p = index(expect[n], "**If not:**"))) { expect[n] = substr(expect[n], 1, p - 1); end_expect() }
    }
    END {
      if (infence) { printf "%s: line %d: a fenced block is not closed\n", FILENAME, NR > "/dev/stderr"; exit 3 }
      m = out "/manifest.tsv"
      printf "" > m
      for (i = 1; i <= n; i++)
        printf "%03d\t%s\t%s\t%d\t%s\t%s\t%s\n", i, kind[i], term[i], at[i], clean(head[i]), clean(first[i]), clean(expect[i]) > m
    }
  ' "$guide" || die "extract failed for $guide"
}

manifest_of() { # <outdir | guide.md> -> sets MANIFEST (extracting a guide into a temp dir)
  if [ -d "$1" ]; then
    MANIFEST=$1/manifest.tsv
  elif [ -f "$1" ]; then
    LIST_TMP=$(mktemp -d) || die "mktemp failed"
    cmd_extract "$1" "$LIST_TMP"
    MANIFEST=$LIST_TMP/manifest.tsv
  else
    die "no such directory or guide: $1"
  fi
  [ -f "$MANIFEST" ] || die "no manifest in $1 — run: $PROG extract <guide.md> $1"
}

cmd_list() {
  [ $# -eq 1 ] || die "usage: $PROG --list <outdir | guide.md>"
  LIST_TMP=""
  manifest_of "$1"
  cat "$MANIFEST"
  [ -z "$LIST_TMP" ] || rm -rf "$LIST_TMP"
}

# ---------------------------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------------------------
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Options shared by run, remote and container. Sets the O_* variables; leaves unknown ones in REST.
parse_run_opts() {
  O_YES=0; O_FROM=1; O_TO=999; O_ONLY=""; O_ALT=0; O_SHELL=bash; O_WORKDIR=""; O_HOME=""
  O_ENV=""; O_TIMEOUT=0; O_STOP=0; O_KEEP=0; O_NAME=""; O_REUSE=0; O_PASS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes-run)      O_YES=1 ;;
      --with-alt)     O_ALT=1 ;;
      --stop-on-fail) O_STOP=1 ;;
      --keep)         O_KEEP=1 ;;
      --reuse)        O_REUSE=1 ;;
      --from|--to|--only|--shell|--workdir|--home|--env-file|--pass-env|--timeout|--name)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --from)     is_num "$2" || die "--from needs a number, got '$2'"; O_FROM=$((10#$2)) ;;
          --to)       is_num "$2" || die "--to needs a number, got '$2'"; O_TO=$((10#$2)) ;;
          --only)     case "$2" in ''|*[!0-9,]*) die "--only needs numbers separated by commas, got '$2'" ;; esac
                      O_ONLY=$2 ;;
          --shell)    case "$2" in bash|zsh) O_SHELL=$2 ;; *) die "--shell must be bash or zsh, got '$2'" ;; esac ;;
          --workdir)  O_WORKDIR=$2 ;;
          --home)     O_HOME=$2 ;;
          --env-file) O_ENV="${O_ENV}${O_ENV:+
}$2" ;;
          --pass-env) case "$2" in ''|[0-9]*|*[!A-Za-z0-9_]*) die "--pass-env needs a variable NAME, got '$2'" ;; esac
                      O_PASS="$O_PASS $2" ;;
          --timeout)  is_num "$2" || die "--timeout needs seconds, got '$2'"; O_TIMEOUT=$((10#$2)) ;;
          --name)     O_NAME=$2 ;;
        esac
        shift ;;
      *) die "unknown option '$1' (see $PROG --help)" ;;
    esac
    shift
  done
}

selected() { # <NNN> <kind> -> 0 when the block is part of this walk
  local n=$((10#$1)) x
  if [ -n "$O_ONLY" ]; then
    local IFS=,
    for x in $O_ONLY; do [ -n "$x" ] && [ "$((10#$x))" -eq "$n" ] && return 0; done
    return 1
  fi
  [ "$n" -ge "$O_FROM" ] && [ "$n" -le "$O_TO" ] || return 1
  [ "$2" = main ] || [ "$O_ALT" -eq 1 ]
}

install_env_files() { # copies each --env-file into $1 (the walk's HOME); never prints a value
  local home=$1 f dest
  [ -n "$O_ENV" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || die "--env-file: no such file: $f"
    dest=$home/${f##*/}
    if [ -e "$dest" ]; then
      [ "$f" -ef "$dest" ] || echo "$PROG: $dest exists and is kept; --env-file $f was not copied" >&2
    else
      ( umask 077; cat "$f" > "$dest" ) || die "cannot write $dest"
    fi
  done <<EOF
$O_ENV
EOF
}

# run_block <script> <outfile> -> the block's exit status. With a time limit the block runs as
# a job of its own so that the limit can stop the block and what it started (rc 124).
run_block() {
  local script=$1 outfile=$2 pid watcher rc
  if [ "$O_TIMEOUT" -eq 0 ]; then
    ( cd "$WORKDIR" && exec env -i "${BLOCK_ENV[@]}" "$O_SHELL" -l "$script" ) </dev/null >"$outfile" 2>&1
    return $?
  fi
  set -m
  ( cd "$WORKDIR" && exec env -i "${BLOCK_ENV[@]}" "$O_SHELL" -l "$script" ) </dev/null >"$outfile" 2>&1 &
  pid=$!
  rm -f "$outfile.timeout"
  # The watcher: TERM to the block's process group, up to 5 s for it to go, then KILL.
  ( sleep "$O_TIMEOUT"; : > "$outfile.timeout"; kill -TERM -- "-$pid" 2>/dev/null
    n=0; while kill -0 -- "-$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  set +m
  wait "$pid" 2>/dev/null; rc=$?
  # Only the two jobs started above are ever signalled, each by its own process group.
  if [ -e "$outfile.timeout" ]; then
    # The limit fired. The block's first process is gone, but something it started may ignore
    # TERM: let the watcher finish its KILL step before going on.
    wait "$watcher" 2>/dev/null
    rm -f "$outfile.timeout"; rc=124
    echo "walk: stopped after ${O_TIMEOUT}s (--timeout)" >>"$outfile"
  else
    kill -TERM -- "-$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
  fi
  return "$rc"
}

cmd_run() {
  [ $# -ge 1 ] || die "usage: $PROG run <outdir> [options] --yes-run"
  local out=$1; shift
  parse_run_opts "$@"
  [ -f "$out/manifest.tsv" ] || die "no manifest in $out — run: $PROG extract <guide.md> $out"
  out=$(cd "$out" && pwd) || die "cannot enter $out"
  WORKDIR=${O_WORKDIR:-$PWD}; WALK_HOME=${O_HOME:-$HOME}
  [ -d "$WORKDIR" ] || die "--workdir: no such directory: $WORKDIR"
  [ -d "$WALK_HOME" ] || die "--home: no such directory: $WALK_HOME"
  command -v "$O_SHELL" >/dev/null 2>&1 || die "--shell $O_SHELL: not installed"

  local n kind term heading first expect count=0 carry="" rc firstout res=$out/results v
  # What a block may inherit: nothing but these, and what --pass-env names.
  BLOCK_ENV=("HOME=$WALK_HOME" "PATH=$PATH")
  for v in TERM USER LOGNAME SHELL LANG $O_PASS; do
    [ -n "${!v+set}" ] && BLOCK_ENV=("${BLOCK_ENV[@]}" "$v=${!v}")
  done
  if [ "$O_YES" -ne 1 ]; then
    echo "DRY RUN — nothing runs without --yes-run (the blocks install software and change clusters)."
    echo "Would run, each in a fresh '$O_SHELL -l' with a scrubbed environment, HOME=$WALK_HOME, in $WORKDIR:"
    while IFS=$'\t' read -r n kind term _ heading first expect; do
      selected "$n" "$kind" || continue
      count=$((count + 1))
      printf '  [%s] %-4s %s | %s\n' "$n" "$kind" "$heading" "$first"
    done < "$out/manifest.tsv"
    echo "$count block(s) selected."
    return 0
  fi

  install_env_files "$WALK_HOME"
  # The outputs may hold secrets: the directory and every file in it are for this user only.
  { mkdir -p "$res" && chmod 700 "$res"; } || die "cannot create $res"
  printf 'block\tkind\texit\theading\tfirst output line\texpect\n' > "$res/summary.tsv"
  # A fresh fd for the manifest: the blocks' own stdin is /dev/null and must not eat it.
  while IFS=$'\t' read -r n kind term _ heading first expect <&3; do
    if selected "$n" "$kind"; then
      count=$((count + 1))
      # The reader's terminal still holds what earlier "this terminal" blocks assigned.
      # shellcheck disable=SC2086  # $carry is a list of our own NNN.sh paths
      cat $carry "$out/$n.sh" > "$res/$n.run.sh"
      run_block "$res/$n.run.sh" "$res/$n.out"; rc=$?
      echo "$rc" > "$res/$n.rc"
      firstout=$(awk 'NF { gsub(/\t/, " "); print; exit }' "$res/$n.out")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$rc" "$heading" "${firstout:--}" "$expect" >> "$res/summary.tsv"
      printf '[%s] %-4s exit=%-3s %s\n      output: %s\n      expect: %s\n' \
        "$n" "$kind" "$rc" "$heading" "${firstout:-(none)}" "$expect"
      # Only a block this walk RAN is carried: an unselected alternative left nothing behind.
      case "$term" in T*) carry="$carry $out/$n.sh" ;; esac
      if [ "$rc" -ne 0 ] && [ "$O_STOP" -eq 1 ]; then
        echo "Stopped at block $n (--stop-on-fail)."
        break
      fi
    fi
  done 3< "$out/manifest.tsv"
  echo "walk: ran $count block(s); output in $res/NNN.out, the table in $res/summary.tsv."
  echo "Those files may hold secrets a block printed; they are readable only by you."
  echo "Judge each block by its Expect text, not by its exit status."
  [ "$count" -gt 0 ] || { echo "walk: nothing selected" >&2; return 1; }
}

# The run options as one shell-quoted string, for the far side. --home and --env-file are
# passed as given (paths over there); --workdir too.
far_opts() {
  local s="" f
  [ "$O_YES" -eq 1 ] && s="$s --yes-run"
  [ "$O_ALT" -eq 1 ] && s="$s --with-alt"
  [ "$O_STOP" -eq 1 ] && s="$s --stop-on-fail"
  [ -n "$O_ONLY" ] && s="$s --only $O_ONLY"
  s="$s --from $O_FROM --to $O_TO --shell $O_SHELL --timeout $O_TIMEOUT"
  [ -n "$O_WORKDIR" ] && s="$s --workdir $(printf '%q' "$O_WORKDIR")"
  [ -n "$O_HOME" ] && s="$s --home $(printf '%q' "$O_HOME")"
  for f in $O_PASS; do s="$s --pass-env $f"; done
  if [ "${1:-}" = with-env ] && [ -n "$O_ENV" ]; then
    while IFS= read -r f; do s="$s --env-file $(printf '%q' "$f")"; done <<EOF
$O_ENV
EOF
  fi
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------------------------
# remote — NOT RUN by the repo's tests (it needs another machine)
# ---------------------------------------------------------------------------------------------
cmd_remote() {
  [ $# -ge 2 ] || die "usage: $PROG remote <ssh-target> <outdir> [options] --yes-run"
  local target=$1 out=$2; shift 2
  parse_run_opts "$@"
  [ -f "$out/manifest.tsv" ] || die "no manifest in $out — run: $PROG extract <guide.md> $out"
  local rdir=${WALK_REMOTE_DIR:-walk-${out##*/}} opts q
  case "$rdir" in *[!A-Za-z0-9._/-]*|'') die "WALK_REMOTE_DIR may hold only letters, digits and . _ / -" ;; esac
  opts=$(far_opts with-env)
  q=$(printf '%q' "$rdir")
  if [ "$O_YES" -ne 1 ]; then
    echo "DRY RUN — would copy $out to $target:$rdir and run there: bash $rdir/walk.sh run $rdir$opts"
    cmd_run "$out" "$@"
    return 0
  fi
  cp "$SELF" "$out/walk.sh" || die "cannot copy walk.sh into $out"
  # shellcheck disable=SC2086,SC2029  # WALK_SSH_OPTS is a list of options; $q and $opts are quoted for the far shell
  ( cd "$out" && tar -cf - manifest.tsv walk.sh [0-9][0-9][0-9].sh ) \
    | ssh ${WALK_SSH_OPTS:-} "$target" "mkdir -p $q && tar -xf - -C $q" || die "copy to $target failed"
  # shellcheck disable=SC2086,SC2029
  ssh -n ${WALK_SSH_OPTS:-} "$target" "bash $q/walk.sh run $q$opts"
  local rc=$?
  mkdir -p "$out/results-remote" && chmod 700 "$out/results-remote"
  # shellcheck disable=SC2086,SC2029
  ssh -n ${WALK_SSH_OPTS:-} "$target" "tar -cf - -C $q/results ." | tar -xf - -C "$out/results-remote" \
    || echo "$PROG: could not copy the results back from $target:$rdir/results" >&2
  echo "walk: results copied to $out/results-remote; $target:$rdir is left in place (remove it yourself)."
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# container — the repo's tests run it against a stand-in engine only
# ---------------------------------------------------------------------------------------------
# CT_NAME is set only for a container THIS run created; nothing else is ever removed.
CT_ENG=""; CT_NAME=""
ct_cleanup() {
  [ -n "$CT_NAME" ] || return 0
  if [ "$O_KEEP" -eq 1 ]; then
    echo "walk: container '$CT_NAME' kept (--keep). Walk in it again with --name $CT_NAME --reuse; remove it with: $CT_ENG rm -f $CT_NAME"
  else
    "$CT_ENG" rm -f "$CT_NAME" >/dev/null 2>&1 && echo "walk: container '$CT_NAME' removed."
  fi
  CT_NAME=""
}

cmd_container() {
  [ $# -ge 2 ] || die "usage: $PROG container <image> <outdir> [options] --yes-run"
  local image=$1 out=$2; shift 2
  parse_run_opts "$@"
  [ -f "$out/manifest.tsv" ] || die "no manifest in $out — run: $PROG extract <guide.md> $out"
  local eng=${CONTAINER_ENGINE:-podman} name=${O_NAME:-walk-$$-$(date +%s)} mounts="" f opts rc
  case "$eng" in podman|docker) ;; *) die "CONTAINER_ENGINE must be podman or docker, got '$eng'" ;; esac
  opts=$(far_opts)
  if [ "$O_YES" -ne 1 ]; then
    echo "DRY RUN — would start $image as '$name' with $eng (--privileged --network host), add a"
    echo "non-root user 'walk' with sudo, and run there: bash /walk/walk.sh run /walk$opts"
    cmd_run "$out" "$@"
    return 0
  fi
  command -v "$eng" >/dev/null 2>&1 || die "$eng is not installed (set CONTAINER_ENGINE)"
  if [ -n "$O_ENV" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || die "--env-file: no such file: $f"
      f=$(cd "$(dirname "$f")" && pwd)/${f##*/}
      mounts="$mounts -v $f:/walk-env/${f##*/}:ro"
    done <<EOF
$O_ENV
EOF
  fi
  cp "$SELF" "$out/walk.sh" || die "cannot copy walk.sh into $out"
  if "$eng" container inspect "$name" >/dev/null 2>&1; then
    [ "$O_REUSE" -eq 1 ] || die "a container named '$name' already exists and this walk did not create it, so it is neither used nor removed. Give another --name, remove it yourself ($eng rm -f $name), or add --reuse to walk in it (it is then kept)"
    echo "walk: walking in the existing container '$name' (--reuse); it will not be removed"
  else
    [ "$O_REUSE" -eq 0 ] || die "--reuse: no container named '$name' exists"
    # From here on every way out, Ctrl-C included, removes the container this run creates.
    CT_ENG=$eng; CT_NAME=$name
    trap ct_cleanup EXIT
    trap 'ct_cleanup; exit 130' INT
    trap 'ct_cleanup; exit 143' TERM
    # shellcheck disable=SC2086  # option lists
    "$eng" run -d --name "$name" --privileged --network host $mounts ${WALK_CONTAINER_RUN_OPTS:-} \
      "$image" sleep infinity >/dev/null || die "$eng run failed"
    # A non-root user with passwordless sudo, as the guides assume; the env files land in its
    # home, readable only by it. Nothing here prints a value.
    # shellcheck disable=SC2016  # this text runs inside the container
    "$eng" exec -e "PKGS=${WALK_CONTAINER_PKGS:-sudo}" "$name" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq $PKGS >/dev/null
      id walk >/dev/null 2>&1 || useradd -m -s /bin/bash walk
      echo "walk ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/walk && chmod 440 /etc/sudoers.d/walk
      if [ -d /walk-env ]; then for f in /walk-env/* /walk-env/.[!.]*; do
        [ -f "$f" ] && install -m 600 -o walk -g walk "$f" "/home/walk/${f##*/}"
      done; fi
    ' || die "container setup failed"
  fi
  "$eng" exec "$name" rm -rf /walk
  { "$eng" cp "$out" "$name:/walk" && "$eng" exec "$name" chown -R walk:walk /walk; } \
    || die "copy into the container failed"
  # shellcheck disable=SC2086  # $opts was quoted by far_opts
  "$eng" exec -u walk -w /home/walk -e HOME=/home/walk "$name" sh -c "bash /walk/walk.sh run /walk$opts"
  rc=$?
  rm -rf "$out/results-container"
  "$eng" cp "$name:/walk/results" "$out/results-container" \
    || echo "$PROG: could not copy the results out of '$name'" >&2
  [ ! -d "$out/results-container" ] || chmod -R go-rwx "$out/results-container"
  ct_cleanup
  echo "walk: results copied to $out/results-container (they may hold secrets a block printed)."
  return "$rc"
}

case "${1:-}" in
  extract)   shift; cmd_extract "$@" ;;
  --list)    shift; cmd_list "$@" ;;
  run)       shift; cmd_run "$@" ;;
  remote)    shift; cmd_remote "$@" ;;
  container) shift; cmd_container "$@" ;;
  -h|--help) usage ;;
  *)         usage >&2; exit 2 ;;
esac
