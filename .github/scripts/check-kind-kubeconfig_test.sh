#!/usr/bin/env bash
# Tests for check-kind-kubeconfig.sh (run by `make scripts-test`). Each case copies the REAL
# Makefile into an empty directory, changes it the way the case names, runs the check there and
# compares the result with the expected pass or the expected error text. Nothing here runs
# kind, kubectl or a container engine: the check gives `make -n` do-nothing stand-ins, and the
# cases that call make themselves put stand-ins that FAIL first on PATH.
# shellcheck disable=SC2016  # the single-quoted $(...) and $1 are make and perl text, on purpose
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/check-kind-kubeconfig.sh   # used by the cases through CMD
export SCRIPT
REAL_MAKEFILE=$HERE/../../Makefile
fails=0
# Stand-ins that fail loudly: no case below may reach a real kind, kubectl or engine.
NOPE=$(mktemp -d)
for t in kind kubectl helm docker podman; do
  printf '#!/bin/sh\necho "TEST BUG: %s was really called: $*" >&2\nexit 97\n' "$t" > "$NOPE/$t"; chmod +x "$NOPE/$t"
done
trap 'rm -rf "$NOPE"' EXIT
# What a case runs in the fixture; the default is the check itself. A case sets CMD first.
CHECK='bash "$SCRIPT"'
CMD=$CHECK
# (kind-create's first recipe line holds $(MAKE), so even `make -n` runs its engine probe; the
# cases that need the printed text therefore dry-run kind-undeploy.)
# mk <make arguments>: a dry run cut off from this shell's make flags, kubeconfig and HOME.
mk() { env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL HOME="$D/home" KUBECONFIG=/dev/null make -n "$@" PATH="$NOPE:$PATH"; }

fixture() {
  D=$(mktemp -d)
  mkdir "$D/home"
  cp "$REAL_MAKEFILE" "$D/Makefile" || { echo "FAIL  test setup: cannot copy $REAL_MAKEFILE"; exit 1; }
}
# edit <perl -pe program>: change the copy, and FAIL THE TEST SETUP if nothing changed (a
# mutation that did not land would make its case pass or fail for the wrong reason).
edit() {
  cp "$D/Makefile" "$D/Makefile.before"
  perl -0777 -pi -e "$1" "$D/Makefile"
  if cmp -s "$D/Makefile" "$D/Makefile.before"; then echo "FAIL  test setup: the edit '$1' changed nothing"; fails=$((fails + 1)); fi
  rm -f "$D/Makefile.before"
}
# in_recipe <target> <line>: add a recipe line at the top of <target>'s recipe.
in_recipe() { T=$1 L=$2 edit 's/^(\Q$ENV{T}\E:[^\n]*\n)/$1\t$ENV{L}\n/m'; }

# run <label> <expect: pass | text of the expected error>
run() {
  local label=$1 want=$2 out rc
  out=$(cd "$D" && eval "$CMD" 2>&1); rc=$?
  CMD=$CHECK
  if [ "$want" = pass ]; then
    if [ "$rc" -eq 0 ]; then echo "PASS  $label"; else echo "FAIL  $label: rc=$rc: $out"; fails=$((fails + 1)); fi
  elif [ "$rc" -ne 0 ] && grep -qF -- "$want" <<<"$out"; then echo "PASS  $label (fails: $want)"
  else echo "FAIL  $label: rc=$rc, want an error containing '$want': $out"; fails=$((fails + 1)); fi
  rm -rf "$D"
}

fixture;                                                     run "the Makefile as committed"                   pass

# --- the defect this check exists for, one piece at a time ---------------------------------
fixture; edit 's/(kind create cluster [^\n]*?) \$\(KIND_KCFG\)/$1/'
                                                             run "kind create cluster loses the file"          'make kind-create: "kind create cluster" without --kubeconfig'
fixture; edit 's/(kind delete cluster --name \$\(KIND_CLUSTER_NAME\)) \$\(KIND_KCFG\)/$1/'
                                                             run "kind delete cluster loses the file"          'make kind-delete: "kind delete cluster" without --kubeconfig'
fixture; edit 's/(kind export kubeconfig --name \$\(KIND_CLUSTER_NAME\)) \$\(KIND_KCFG\);/$1;/'
                                                             run "kind export kubeconfig loses the file"       'make kind-create: "kind export kubeconfig" without --kubeconfig'
fixture; edit 's/^KCTX = \$\(KIND_KCFG\) /KCTX = /m'
                                                             run "KCTX loses the file (the old KCTX)"          'make kind-deploy: a kubectl call does not name the KinD kubeconfig'
fixture; edit 's/^(KCTX = \$\(KIND_KCFG\)) --context kind-\$\(KIND_CLUSTER_NAME\)/$1/m'
                                                             run "KCTX loses the context"                      'make kind-undeploy: a kubectl call does not name the KinD kubeconfig and context'
fixture; edit 's/^KIND_KCFG = .*$/KIND_KCFG = --kubeconfig "\$(HOME)\/.kube\/config"/m'
                                                             run "the file is hardcoded, not KIND_KUBECONFIG"  'make e2e: a kubectl call does not name the KinD kubeconfig'
fixture; edit 's/^(KIND_KCFG = .*)--kubeconfig "\$\(KIND_KUBECONFIG\)"$/$1--kubeconfig \$(KIND_KUBECONFIG)/m'
                                                             run "the path is not quoted"                      'does not name the KinD kubeconfig'
fixture; in_recipe kind-create '@kubectl config use-context kind-$(KIND_CLUSTER_NAME)'
                                                             run "bare kubectl config use-context is back"     'changes a kubeconfig with "config use-context"'
fixture; in_recipe kind-create '@kubectl $(KCTX) config use-context kind-$(KIND_CLUSTER_NAME)'
                                                             run "use-context even on the KinD file"           'changes a kubeconfig with "config use-context"'
fixture; in_recipe k8s-apply '@kubectl config set-context --current --namespace=x'
                                                             run "set-context in a current-context target"     '(k8s-apply) changes a kubeconfig with "config set-context"'

# --- planted calls: every form must be seen ------------------------------------------------
fixture; in_recipe kind-deploy '@kubectl get pods'
                                                             run "planted bare kubectl in kind-deploy"         '(kind-deploy): "kubectl" without $(KCTX)'
fixture; in_recipe kind-deploy '@kubectl get pods'
                                                             run "planted bare kubectl, seen in the dry run"   'make e2e: a kubectl call does not name the KinD kubeconfig and context: "kubectl get pods'
fixture; in_recipe kind-deploy '@helm list -A'
                                                             run "planted bare helm"                           'make kind-deploy: a helm call does not name'
fixture; in_recipe kind-undeploy '@echo pod | xargs kubectl delete pod'
                                                             run "kubectl behind xargs"                        'a kubectl call does not name the KinD kubeconfig and context: "kubectl delete pod'
fixture; in_recipe kind-deploy '@docker exec $(KIND_CLUSTER_NAME)-control-plane kubectl get nodes'
                                                             run "kubectl behind docker exec"                  '"kubectl get nodes'
fixture; in_recipe kind-deploy '@KUBECONFIG=/x kubectl --context kind-$(KIND_CLUSTER_NAME) get pods'
                                                             run "kubectl with --context only"                 '(kind-deploy): "kubectl" without $(KCTX)'
fixture; in_recipe deps-kind '@kubectl version'
                                                             run "bare kubectl in deps-kind (dry run only)"    'make deps-kind: a kubectl call does not name'
fixture; printf '\nsmoke:\n\t@kubectl get nodes\n' >> "$D/Makefile"
                                                             run "bare kubectl in a target not named kind-*"   '(smoke): "kubectl" without $(KCTX)'
fixture; printf '\nkind-extra: deps-kind\n\t@kubectl $(KCTX) get nodes\n' >> "$D/Makefile"
                                                             run "a new kind-* target that uses KCTX"          pass
fixture; in_recipe kind-delete '@kind export kubeconfig --name $(KIND_CLUSTER_NAME)'
                                                             run "planted bare kind export kubeconfig"         'make kind-delete: "kind export kubeconfig" without --kubeconfig'
fixture; in_recipe kind-create '@kind get kubeconfig --name $(KIND_CLUSTER_NAME) >/dev/null'
                                                             run "kind get kubeconfig prints, writes nothing"  pass
fixture; in_recipe kind-create '@kind export secrets --name $(KIND_CLUSTER_NAME)'
                                                             run "a kind subcommand the check does not know"   '"kind export secrets" is not a subcommand this check knows'
fixture; in_recipe kind-create '@$(MAKE) --no-print-directory deps-kind; kind get clusters'
                                                             run "kind on a line with \$(MAKE) runs in -n"     'the dry run EXECUTED these'

# --- the check must not pass by seeing nothing ---------------------------------------------
fixture; printf 'KIND_CLUSTER_NAME := golang-web\nKCTX = --kubeconfig "$(KIND_KUBECONFIG)" --context kind-$(KIND_CLUSTER_NAME)\nkind-create:\n\t@kubectl $(KCTX) get nodes\n' > "$D/Makefile"
                                                             run "a Makefile with one call: below the floors"  'saw only 1 targets, 1 kubectl/helm commands and 0 kind kubeconfig commands'
fixture; edit 's/^kind-deploy: kind-create$/kind-deploy: kind-create\n\t\@exit 0\nkind-deploy-old:/m'
                                                             run "kind-deploy's calls moved out of reach"      'saw only'
fixture; edit 's/^KIND_CLUSTER_NAME\s*:=.*$/KIND_CLUSTER_NAME := \$(PROJECT)/m'
                                                             run "cluster name the check cannot read"          'cannot read KIND_CLUSTER_NAME'
fixture; printf '\nkind-broken:\n\t@$(error boom)\n' >> "$D/Makefile"
                                                             run "a target whose dry run fails"                "'make -n kind-broken' failed"

# --- forms the first version of this check did not see -------------------------------------
fixture; in_recipe kind-deploy '@/usr/bin/kubectl get pods'
                                                             run "kubectl by absolute path, source"            '(kind-deploy): "kubectl" without $(KCTX)'
fixture; in_recipe kind-deploy '@/usr/bin/kubectl get pods'
                                                             run "kubectl by absolute path, dry run"           'make kind-deploy: a kubectl call does not name the KinD kubeconfig and context: "kubectl get pods'
fixture; in_recipe kind-create '@/usr/local/bin/kind create cluster --name $(KIND_CLUSTER_NAME)'
                                                             run "kind by absolute path, source"               '(kind-create): "kind create cluster" without $(KIND_KCFG)'
fixture; in_recipe kind-create '@/usr/local/bin/kind create cluster --name $(KIND_CLUSTER_NAME)'
                                                             run "kind by absolute path, dry run"              'make kind-create: "kind create cluster" without --kubeconfig'
fixture; printf '\ncluster-up:\n\t@kind create cluster --name other\n' >> "$D/Makefile"
                                                             run "bare kind create in a target not named kind-*" '(cluster-up): "kind create cluster" without $(KIND_KCFG)'
fixture; printf '\ncluster-down:\n\t@kind delete clusters --all\n' >> "$D/Makefile"
                                                             run "bare kind delete clusters elsewhere"         '(cluster-down): "kind delete clusters" without $(KIND_KCFG)'
fixture; in_recipe k8s-apply '@kind export kubeconfig --name $(KIND_CLUSTER_NAME)'
                                                             run "bare kind export in a current-context target" '(k8s-apply): "kind export kubeconfig" without $(KIND_KCFG)'
fixture; printf '\ncluster-up:\n\t@kind create cluster --name $(KIND_CLUSTER_NAME) $(KIND_KCFG)\n' >> "$D/Makefile"
                                                             run "kind create with the file, any target"       pass
fixture; in_recipe kind-deploy '@kubectl $(KCTX) --kubeconfig /other get pods'
                                                             run "a second --kubeconfig, source"               '(kind-deploy): "kubectl $(KCTX)" is followed by a second --kubeconfig'
fixture; in_recipe kind-deploy '@kubectl $(KCTX) --kubeconfig /other get pods'
                                                             run "a second --kubeconfig, dry run"              'make kind-deploy: a kubectl call names the KinD kubeconfig and context and then a second --kubeconfig'
fixture; in_recipe kind-undeploy '@kubectl $(KCTX) get pods --context=other'
                                                             run "a second --context"                          'and then a second --context'
fixture; in_recipe kind-deploy '@echo "Check it: kubectl get pods"'
                                                             run "a hint that names kubectl without the flags" 'make kind-deploy: a kubectl call does not name'

# --- an empty, ~ or relative KIND_KUBECONFIG: the Makefile refuses, and the check sees a bad default
fixture; CMD='KIND_KUBECONFIG= mk kind-create';              run "empty value: kind-create refuses"            'KIND_KUBECONFIG is set but empty'
fixture; CMD='KIND_KUBECONFIG= mk e2e';                      run "empty value: e2e refuses"                    'KIND_KUBECONFIG is set but empty'
# The refusal comes before the prerequisites: nothing of `deps` (mise) is printed or run first.
fixture; CMD='! KIND_KUBECONFIG= mk kind-undeploy 2>&1 | grep -q mise'
                                                             run "empty value: refused before any prerequisite" pass
fixture; CMD='mk kind-undeploy 2>&1 | grep -q mise';         run "(control) a good value does print the prerequisites" pass
fixture; CMD='mk kind-delete KIND_KUBECONFIG=';              run "empty on the command line: kind-delete refuses" 'KIND_KUBECONFIG is set but empty'
fixture; CMD="mk kind-create KIND_KUBECONFIG='~/.kube/x.yaml'"
                                                             run "~ value: refused"                            "KIND_KUBECONFIG starts with ~ ('~/.kube/x.yaml')"
fixture; CMD='mk kind-undeploy KIND_KUBECONFIG=kc.yaml';     run "relative value: refused"                     "KIND_KUBECONFIG is a relative path ('kc.yaml')"
fixture; printf 'KIND_KUBECONFIG ?= ~/.kube/x.yaml\n' > "$D/.env"; CMD='mk kind-create'
                                                             run "~ value from .env: refused"                  'KIND_KUBECONFIG starts with ~'
fixture; CMD='KIND_KUBECONFIG= mk help >/dev/null && KIND_KUBECONFIG= mk build >/dev/null'
                                                             run "empty value does not break help or build"    pass
fixture; CMD='mk kind-undeploy "KIND_KUBECONFIG=$D/home/my kube/kind.yaml" | grep -F -- "--kubeconfig \"$D/home/my kube/kind.yaml\"" >/dev/null'
                                                             run "an absolute path with a space is accepted"   pass
# The early refusal keys on the goal names; the one inside KIND_KCFG covers every other way in.
fixture; printf '\ncluster-up:\n\t@kind create cluster --name x $(KIND_KCFG)\n' >> "$D/Makefile"; CMD='KIND_KUBECONFIG= mk cluster-up'
                                                             run "empty value: refused in any target that uses the file" 'KIND_KUBECONFIG is set but empty'
fixture; edit 's/^KIND_KUBECONFIG \?= .*$/KIND_KUBECONFIG ?=/m'
                                                             run "empty DEFAULT: the check fails"              'KIND_KUBECONFIG is set but empty'
strip_refusal() { edit 's/^KIND_KCFG = \$\(if [^\n]*?\)\)--kubeconfig/KIND_KCFG = --kubeconfig/m; s/^ifneq \(\$\(kind_kubeconfig_error\),\)\n.*?\nendif\nendif\n//ms'; }
fixture; strip_refusal; edit 's/^KIND_KUBECONFIG \?= .*$/KIND_KUBECONFIG ?=/m'
                                                             run "empty DEFAULT and no refusal: check 5 sees it" 'with KIND_KUBECONFIG not given: the kubeconfig argument is "", not a quoted, non-empty, absolute path'
fixture; strip_refusal; edit 's/^KIND_KUBECONFIG \?= .*$/KIND_KUBECONFIG ?= kind.yaml/m'
                                                             run "relative DEFAULT and no refusal: check 5 sees it" 'the kubeconfig argument is "kind.yaml", not a quoted'
fixture; strip_refusal; CMD='KIND_KUBECONFIG= mk kind-undeploy | grep -F -- "--kubeconfig \"\"" >/dev/null'
                                                             run "(control) without the refusal an empty value reaches kind" pass

# --- the check must not depend on where it runs ---------------------------------------------
fixture; LONG=$D/$(printf '%150s' '' | tr ' ' x); mkdir "$LONG"; CMD='TMPDIR="$LONG" bash "$SCRIPT"'
                                                             run "a 150-character TMPDIR"                      pass
fixture; printf 'go:\n\t@bash "$(SCRIPT)"\n' > "$D/outer.mk"; CMD='make -f outer.mk go KIND_CLUSTER_NAME=x KIND_KUBECONFIG=/x/y KIND_NAMESPACE=z SCRIPT="$SCRIPT"'
                                                             run "run from a make with its own command-line variables" pass
fixture; CMD='KIND_KUBECONFIG= KUBECONFIG=/nonexistent/k bash "$SCRIPT"'
                                                             run "run from a shell with an empty KIND_KUBECONFIG" pass

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
