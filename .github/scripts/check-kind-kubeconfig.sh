#!/usr/bin/env bash
# Verify the KinD and e2e targets use only KinD's own kubeconfig file (run by
# `make check-kind-kubeconfig`). Runs no kind, kubectl or container engine: it reads the
# Makefile and the text `make -n` prints.
#
# Why: `kind create cluster` and `kubectl config use-context` without --kubeconfig write the
# AMBIENT kubeconfig ($KUBECONFIG, else ~/.kube/config) and change its current-context. A
# developer whose KUBECONFIG names a real cluster's file got the KinD context merged into it.
#
# Checks:
#   1. Source, whole Makefile: outside the blocks that act on the developer's current context
#      on purpose (AMBIENT_BLOCKS below), every `kubectl`/`helm` word is `kubectl $(KCTX)` /
#      `helm $(KCTX)`, with no second --kubeconfig or --context after it.
#   2. Source, whole Makefile, the ambient blocks included: every `kind create cluster`,
#      `kind delete cluster` and `kind export kubeconfig` carries $(KIND_KCFG).
#   3. Source, whole Makefile: no command changes a kubeconfig's current-context or entries
#      (`kubectl config use-context`, set-context, ...). A hint inside a plain `echo "..."` is
#      not a command.
#   4. Dry run with a sentinel: `make -n <target>` for every kind-*, e2e* and deps-kind target
#      (derived from the Makefile), with KIND_KUBECONFIG set to a sentinel path. In the printed
#      text every `kubectl`/`helm` word must be followed by
#      `--kubeconfig "<sentinel>" --context kind-<cluster>` and by no second --kubeconfig or
#      --context, and every `kind create cluster` / `kind delete cluster` /
#      `kind export kubeconfig` must carry `--kubeconfig "<sentinel>"`. Other `kind` subcommands
#      must be ones known to touch no kubeconfig; an unknown one fails, so adding it is a decision.
#   5. Dry run with the DEFAULT: the same targets with KIND_KUBECONFIG not given. Every
#      --kubeconfig argument printed must be a quoted, non-empty, absolute path. (Check 4 always
#      passes its own path, so it cannot see a default that is empty or relative.)
#
# The words are matched in the TEXT, not parsed as shell, so the check fails closed:
#   - an operator hint inside a kind-*/e2e* target may not name kubectl or helm without the
#     full flags (write the hint with $(KCTX), or without the tool's name);
#   - the counts it prints are occurrences in the printed text, counted once per target whose
#     dry run prints them (a helper used by three targets counts three times, and so does a
#     command quoted in an error message). They are a floor for "the check still sees the
#     commands", not an inventory of calls.
#
# `make -n` still EXECUTES recipe lines that contain $(MAKE). So the dry run gets do-nothing
# stand-ins for kind, kubectl, helm, docker and podman first on PATH and an empty HOME, and
# fails if kind, kubectl or helm was called: such a line would run for real under `make -n`.
# The inner make does not inherit this make's command line (MAKEFLAGS), so
# `make check-kind-kubeconfig KIND_CLUSTER_NAME=x` checks the Makefile as written.
#
# Not detected: a kubectl started by a script or binary a recipe calls (none today), a call
# built from a variable (`K=kubectl; $K get`), and a kubeconfig named by other means than
# these flags (a KUBECONFIG=... prefix is refused only because the flags are then missing).
# Run from the repository root. Needs bash 3.2+, make, perl.
set -euo pipefail

# Blocks (targets or `define`s) that act on the developer's CURRENT context on purpose, plus
# deps-kind, which only tests that kubectl is installed (the dry runs cover deps-kind too).
AMBIENT_BLOCKS="kube_target k8s-apply k8s-delete deps-kind"
# Floors = the counts MEASURED on this Makefile (see the note on counts above). A count below
# a floor means the check no longer sees the commands, not that there are none. When you
# remove a command on purpose, lower its floor to the new count the error prints.
MIN_TARGETS=${KIND_KUBECONFIG_CHECK_MIN_TARGETS-9}
MIN_KUBECTL=${KIND_KUBECONFIG_CHECK_MIN_KUBECTL-18}
MIN_KIND=${KIND_KUBECONFIG_CHECK_MIN_KIND-10}

[ -f Makefile ] || { echo "ERROR: no Makefile here; run from the repository root."; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "ERROR: perl is required by check-kind-kubeconfig.sh."; exit 1; }

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 1, 2 and 3: the Makefile source ------------------------------------------------------
src_out=$(AMBIENT_BLOCKS="$AMBIENT_BLOCKS" perl -e '
  my %ambient = map { $_ => 1 } split " ", $ENV{AMBIENT_BLOCKS};
  my ($block, $bad, $in_define) = ("(top)", 0, 0);
  while (my $l = <STDIN>) {
    chomp $l;
    if ($l =~ /^define\s+(\S+)/)               { $block = $1; $in_define = 1; next }
    if ($l =~ /^endef\b/)                      { $block = "(top)"; $in_define = 0; next }
    if (!$in_define && $l =~ /^([A-Za-z0-9_.-]+)\s*:(?!=)/) { $block = $1 }
    next if $l =~ /^\s*@?\s*#/;               # comment line (also a recipe `@# ...` line)
    # 3: a command that rewrites a kubeconfig. A plain echo "..." string is prose, not a command.
    (my $cmd = $l) =~ s/echo\s+"(?:[^"\\\$`]|\\.|\$(?!\$?\())*"//g;
    if ($cmd =~ /\bconfig\s+(use-context|set-context|set-cluster|set-credentials|delete-context|delete-cluster|delete-user|rename-context|unset|set)\b/) {
      print "ERROR: Makefile line $. ($block) changes a kubeconfig with \"config $1\". No target may switch or edit a kubeconfig; pass \$(KCTX) to each kubectl call instead.\n"; $bad++;
    }
    # 2: kind subcommands that read or write a kubeconfig, anywhere in the file.
    while ($l =~ /(?<![\w-])kind\s+(create\s+cluster|delete\s+clusters?|export\s+kubeconfig)(?![\w-])((?:\$\([^)]*\)|[^;|)])*)/g) {
      my ($verb, $rest) = ($1, $2);
      next if $rest =~ /\$\(KIND_KCFG\)/ || $rest =~ /--kubeconfig\s+\\?"\$\(KIND_KUBECONFIG\)\\?"/;
      print "ERROR: Makefile line $. ($block): \"kind $verb\" without \$(KIND_KCFG). It would write your own kubeconfig (\$KUBECONFIG or ~/.kube/config). Add \$(KIND_KCFG) to that command.\n"; $bad++;
    }
    next if $ambient{$block};
    # 1: outside the ambient blocks, kubectl/helm must be written with $(KCTX), once.
    my $rest = $l;
    while ($rest =~ s/(?<![\w-])(kubectl|helm)\s+\$\(KCTX\)((?:\$\([^)]*\)|[^;|)])*)/ $2/) {
      my ($tool, $args) = ($1, $2);
      if ($args =~ /(--(?:kubeconfig|context))(?![\w-])/) {
        print "ERROR: Makefile line $. ($block): \"$tool \$(KCTX)\" is followed by a second $1, which would replace the KinD one. Remove it.\n"; $bad++;
      }
    }
    if ($rest =~ /(?<![\w-])(kubectl|helm)(?![\w-])/) {
      print "ERROR: Makefile line $. ($block): \"$1\" without \$(KCTX). It would use your own kubeconfig and current context. Write: $1 \$(KCTX) ...   (a target meant to act on the current context belongs in AMBIENT_BLOCKS in check-kind-kubeconfig.sh)\n"; $bad++;
    }
  }
  exit($bad ? 1 : 0);
' < Makefile) || fail=1
[ -z "$src_out" ] || printf '%s\n' "$src_out"

# --- 4 and 5: the dry runs ------------------------------------------------------------------
targets=$(sed -nE 's/^((kind-|e2e)[A-Za-z0-9_-]*|deps-kind)[[:space:]]*:([^=].*)?$/\1/p' Makefile | sort -u)
n_targets=$(printf '%s\n' "$targets" | grep -c . || true)

mkdir -p "$tmp/bin" "$tmp/home"
for t in kind kubectl helm docker podman; do
  # `info` answers an architecture so kind-create gets past its engine probe.
  # shellcheck disable=SC2016  # $* and $1 belong to the stand-in script being written
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n[ "$1" = info ] && echo x86_64\nexit 0\n' "$t" "$tmp" > "$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
: > "$tmp/calls"
sentinel="$tmp/SENTINEL kind.kubeconfig"   # with a space: the recipes must quote the path
ambient="$tmp/ambient.kubeconfig"
printf 'ambient kubeconfig sentinel\n' > "$ambient"
cluster=$(sed -nE 's/^KIND_CLUSTER_NAME[[:space:]]*[:?]?=[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*$/\1/p' Makefile | head -1)
[ -n "$cluster" ] || { echo "ERROR: cannot read KIND_CLUSTER_NAME from the Makefile; this check's pattern needs fixing."; exit 1; }

# dry_run <target> [VAR=value ...]: `make -n` cut off from this shell's make flags, kubeconfig,
# home directory and KIND_KUBECONFIG, with the stand-ins first on PATH.
dry_run() {
  env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u KIND_KUBECONFIG HOME="$tmp/home" KUBECONFIG="$ambient" \
    make -n "$@" PATH="$tmp/bin:$PATH" KIND_ENGINE=docker CONTAINER_ENGINE=docker > "$tmp/out" 2> "$tmp/err"
}

n_kubectl=0; n_kind=0; n_default=0
for t in $targets; do
  # 4: with the sentinel.
  if ! dry_run "$t" KIND_KUBECONFIG="$sentinel"; then
    echo "ERROR: 'make -n $t' failed, so its commands could not be read:"; tail -5 "$tmp/err"; fail=1; continue
  fi
  res=$(TARGET="$t" SENTINEL="$sentinel" CLUSTER="$cluster" perl -0777 -e '
    my ($t, $s, $c) = @ENV{qw(TARGET SENTINEL CLUSTER)};
    my $txt = <STDIN>;
    $txt =~ s/^[ \t]*#.*$//mg;          # make -n prints `@# ...` recipe comments
    $txt =~ s/\\\n/ /g;                 # join continued lines
    # The two places deps-kind names kubectl without calling it.
    $txt =~ s/command -v kubectl >\/dev\/null/command -v PRESENCE-CHECK >\/dev\/null/g;
    $txt =~ s/echo "Error: kubectl required\./echo "Error: PRESENCE-CHECK required./g;
    my ($bad, $nk, $nkind) = (0, 0, 0);
    my $q = qr/\\?"\Q$s\E\\?"/;
    while ($txt =~ /(?<![\w-])(kubectl|helm)(?![\w-])/g) {
      my ($tool, $p) = ($1, pos($txt)); $nk++;
      # No fixed-size window: the sentinel path is as long as $TMPDIR makes it.
      if ($txt =~ /\G\s+--kubeconfig\s+$q\s+--context\s+kind-\Q$c\E(?![\w-])([^;|)\n]*)/gc) {
        my $args = $1;
        if ($args =~ /(--(?:kubeconfig|context))(?![\w-])/) {
          print "ERROR: make $t: a $tool call names the KinD kubeconfig and context and then a second $1, which would replace it. Remove the second one.\n"; $bad++;
        }
      } else {
        (my $after = substr($txt, $p, 90)) =~ s/\s+/ /g;
        print "ERROR: make $t: a $tool call does not name the KinD kubeconfig and context: \"$tool$after\". It would use your own kubeconfig. Write: $tool \$(KCTX) ...\n"; $bad++;
      }
      pos($txt) = $p;
    }
    while ($txt =~ /(?<![\w-])kind\s+(create|delete|export|get|load)\s+([A-Za-z-]+)([^;|)\n]*)/g) {
      my ($verb, $rest) = ("$1 $2", $3);
      if ($verb =~ /^(create cluster|delete clusters?|export kubeconfig)$/) {
        $nkind++;
        next if $rest =~ /\s--kubeconfig\s+$q/;
        print "ERROR: make $t: \"kind $verb\" without --kubeconfig. It would write your own kubeconfig (\$KUBECONFIG or ~/.kube/config). Add \$(KIND_KCFG).\n"; $bad++;
      } elsif ($verb !~ /^(get clusters|get nodes|get kubeconfig|load docker-image|load image-archive|export logs)$/) {
        print "ERROR: make $t: \"kind $verb\" is not a subcommand this check knows. If it reads or writes a kubeconfig give it \$(KIND_KCFG) and list it as such in check-kind-kubeconfig.sh; if it does not, list it as kubeconfig-free there.\n"; $bad++;
      }
    }
    print "COUNT $nk $nkind\n";
    exit($bad ? 1 : 0);
  ' < "$tmp/out") || fail=1
  printf '%s\n' "$res" | grep -v '^COUNT ' || true
  counts=$(printf '%s\n' "$res" | sed -n 's/^COUNT //p')
  [ -n "$counts" ] || { echo "ERROR: could not read the commands of 'make -n $t'."; fail=1; continue; }
  n_kubectl=$((n_kubectl + ${counts% *}))
  n_kind=$((n_kind + ${counts#* }))

  # 5: with the Makefile's own default.
  if ! dry_run "$t"; then
    echo "ERROR: 'make -n $t' failed without KIND_KUBECONFIG given, so its default could not be checked:"; tail -5 "$tmp/err"; fail=1; continue
  fi
  res=$(TARGET="$t" perl -0777 -e '
    my $t = $ENV{TARGET};
    my $txt = <STDIN>;
    $txt =~ s/^[ \t]*#.*$//mg;
    my ($bad, $n) = (0, 0);
    while ($txt =~ /--kubeconfig(?:=|\s+)(\\?"[^"\n]*"|\S*)/g) {
      my $arg = $1; $n++;
      next if $arg =~ m{^\\?"/[^"]*"$};
      print "ERROR: make $t, with KIND_KUBECONFIG not given: the kubeconfig argument is $arg, not a quoted, non-empty, absolute path. kind and kubectl would use your own kubeconfig, or write the cluster'"'"'s keys to the wrong place. Fix the default of KIND_KUBECONFIG in the Makefile.\n"; $bad++;
    }
    print "COUNT $n\n";
    exit($bad ? 1 : 0);
  ' < "$tmp/out") || fail=1
  printf '%s\n' "$res" | grep -v '^COUNT ' || true
  counts=$(printf '%s\n' "$res" | sed -n 's/^COUNT //p')
  n_default=$((n_default + ${counts:-0}))
done

if grep -qE '^(kind|kubectl|helm) ' "$tmp/calls"; then
  echo "ERROR: the dry run EXECUTED these (a recipe line that contains \$(MAKE) runs even under 'make -n'):"
  grep -E '^(kind|kubectl|helm) ' "$tmp/calls" | sort -u | sed 's/^/  /'
  echo "  Move the kind/kubectl/helm call to a recipe line of its own, without \$(MAKE)."
  fail=1
fi
[ "$(cat "$ambient")" = "ambient kubeconfig sentinel" ] || { echo "ERROR: the dry run changed the file \$KUBECONFIG pointed at."; fail=1; }
[ ! -e "$tmp/home/.kube" ] || { echo "ERROR: the dry run created .kube in the home directory, so something wrote a kubeconfig."; fail=1; }

if [ "$n_targets" -lt "$MIN_TARGETS" ] || [ "$n_kubectl" -lt "$MIN_KUBECTL" ] || [ "$n_kind" -lt "$MIN_KIND" ]; then
  echo "ERROR: saw only $n_targets targets, $n_kubectl kubectl/helm commands and $n_kind kind kubeconfig commands (floors: $MIN_TARGETS, $MIN_KUBECTL, $MIN_KIND). The check no longer sees the KinD targets' commands; fix its patterns, or lower the floors in check-kind-kubeconfig.sh with a reason."
  fail=1
fi
if [ "$n_default" -lt $((n_kubectl + n_kind)) ]; then
  echo "ERROR: with KIND_KUBECONFIG not given, the dry runs print only $n_default --kubeconfig arguments; with it given they print $((n_kubectl + n_kind)) commands that need one. Some command loses the file when the default is used."
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "KinD kubeconfig: $n_kubectl kubectl/helm and $n_kind kind kubeconfig commands, as printed by 'make -n' of $n_targets targets, all name KIND_KUBECONFIG; its default is an absolute path ($n_default arguments read); none uses your own kubeconfig."
