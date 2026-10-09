#!/usr/bin/env bash
# Tests for the context guard of `make k8s-apply` and `make k8s-delete` (run by
# `make scripts-test`). Those two targets act on kubectl's CURRENT context, which may be a real
# cluster, so they stop unless the context is a local KinD one (kind-*), or is named with
# K8S_CONTEXT=<name>, or CONFIRM=yes was typed on the make command line.
#
# Each case copies the REAL Makefile into an empty directory and runs the real target there
# with a stand-in `kubectl` first on PATH. The stand-in answers `config current-context` with
# the case's context and records every call, so a case can tell "applied" from "stopped". No
# real kubectl, cluster or kubeconfig is touched (HOME is an empty directory, KUBECONFIG is
# /dev/null).
# shellcheck disable=SC2016  # the single-quoted $... are make text and the stand-in's own script
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REAL_MAKEFILE=$HERE/../../Makefile
fails=0

fixture() {
  D=$(mktemp -d)
  mkdir -p "$D/bin" "$D/home" "$D/k8s"
  cp "$REAL_MAKEFILE" "$D/Makefile" || { echo "FAIL  test setup: cannot copy $REAL_MAKEFILE"; exit 1; }
  echo v0.0.0 > "$D/version.txt"
  printf '        image: ghcr.io/x/golang-web:v0\n' > "$D/k8s/golang-web.yaml"
  cat > "$D/bin/kubectl" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "config current-context") [ -n "$STUB_CTX" ] || { echo "error: current-context is not set" >&2; exit 1; }; echo "$STUB_CTX" ;;
  "config view") printf '%s' "$STUB_NS" ;;
  "apply -f") cat >/dev/null; echo "deployment.apps/golang-web created" ;;
  "delete -f") echo "deployment.apps \"golang-web\" deleted" ;;
  *) echo "stand-in kubectl: unexpected call: $*" >&2; exit 98 ;;
esac
EOF
  chmod +x "$D/bin/kubectl"
  : > "$D/log"
}

# run <label> <context> <expect> <make arguments...>
#   expect: applied | deleted | stopped:<text the message must contain>
# Environment for the make call comes from ENVV (reset after each case), e.g. ENVV="CONFIRM=yes".
ENVV=""
run() {
  local label=$1 ctx=$2 want=$3 out rc acted
  shift 3
  # shellcheck disable=SC2086  # ENVV is a list of VAR=value words
  out=$(cd "$D" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u CONFIRM -u K8S_CONTEXT $ENVV \
        STUB_CTX="$ctx" STUB_NS="${STUB_NS-}" STUB_LOG="$D/log" HOME="$D/home" KUBECONFIG=/dev/null \
        make "$@" PATH="$D/bin:$PATH" 2>&1); rc=$?
  acted=$(grep -E '^(apply|delete) ' "$D/log" | cut -d' ' -f1 | tr '\n' ' ')
  case "$want" in
    applied|deleted)
      [ "$want" = applied ] && verb=apply || verb=delete
      if [ "$rc" -eq 0 ] && [ "$acted" = "$verb " ]; then echo "PASS  $label ($want)"
      else echo "FAIL  $label: rc=$rc, kubectl did '${acted}', want '$verb': $out"; fails=$((fails + 1)); fi ;;
    stopped:*)
      if [ "$rc" -ne 0 ] && [ -z "$acted" ] && grep -qF -- "${want#stopped:}" <<<"$out"; then echo "PASS  $label (stopped: ${want#stopped:})"
      else echo "FAIL  $label: rc=$rc, kubectl did '${acted}', want a stop containing '${want#stopped:}': $out"; fails=$((fails + 1)); fi ;;
  esac
  ENVV=""; rm -rf "$D"
}

# --- a local KinD context needs nothing ----------------------------------------------------
fixture; run "kind context: k8s-apply proceeds"              kind-golang-web  applied  k8s-apply
fixture; run "kind context: k8s-delete proceeds"             kind-golang-web  deleted  k8s-delete
fixture; run "another kind cluster proceeds"                 kind-other       applied  k8s-apply

# --- any other context stops, and says how to go on -----------------------------------------
fixture; run "other context: k8s-apply stops, names it"      prod-admin@prod  "stopped:kubectl's current context is 'prod-admin@prod' (namespace 'default'), which is not a local KinD cluster"  k8s-apply
fixture; STUB_NS=payments run "the stop names the namespace" prod-admin@prod  "stopped:(namespace 'payments')"  k8s-apply
unset STUB_NS
fixture; run "the stop gives the command with CONFIRM"       prod-admin@prod  "stopped:    make k8s-apply CONFIRM=yes"  k8s-apply
fixture; run "the stop gives the command with K8S_CONTEXT"   prod-admin@prod  "stopped:    make k8s-apply K8S_CONTEXT='prod-admin@prod'"  k8s-apply
fixture; run "other context: k8s-delete stops"               prod-admin@prod  "stopped:    make k8s-delete CONFIRM=yes"  k8s-delete
fixture; run "a context that only CONTAINS kind- stops"      my-kind-of-prod  "stopped:which is not a local KinD cluster"  k8s-apply

# --- CONFIRM=yes counts only on the command line -------------------------------------------
fixture; run "other context, CONFIRM=yes typed: applies"     prod-admin@prod  applied  k8s-apply CONFIRM=yes
fixture; run "other context, CONFIRM=yes typed: deletes"     prod-admin@prod  deleted  k8s-delete CONFIRM=yes
fixture; ENVV="CONFIRM=yes"
         run "CONFIRM=yes from the environment: stops"       prod-admin@prod  "stopped:which is not a local KinD cluster"  k8s-apply
fixture; printf 'CONFIRM ?= yes\n' > "$D/.env"
         run "CONFIRM from .env: stops"                      prod-admin@prod  "stopped:which is not a local KinD cluster"  k8s-apply
fixture; printf 'CONFIRM = yes\n' > "$D/.env"
         run "CONFIRM = yes in .env: stops"                  prod-admin@prod  "stopped:which is not a local KinD cluster"  k8s-delete
fixture; run "CONFIRM=no typed: stops"                       prod-admin@prod  "stopped:which is not a local KinD cluster"  k8s-apply CONFIRM=no
fixture; run "CONFIRM=YES typed (not the exact word): stops" prod-admin@prod  "stopped:which is not a local KinD cluster"  k8s-apply CONFIRM=YES

# --- K8S_CONTEXT must equal the current context ---------------------------------------------
fixture; run "K8S_CONTEXT matches: applies"                  prod-admin@prod  applied  k8s-apply K8S_CONTEXT=prod-admin@prod
fixture; ENVV="K8S_CONTEXT=prod-admin@prod"
         run "K8S_CONTEXT from the environment matches"      prod-admin@prod  deleted  k8s-delete
fixture; printf 'K8S_CONTEXT ?= prod-admin@prod\n' > "$D/.env"
         run "K8S_CONTEXT from .env matches"                 prod-admin@prod  applied  k8s-apply
fixture; printf 'K8S_CONTEXT ?= staging\n' > "$D/.env"
         run "K8S_CONTEXT from .env differs: stops"          prod-admin@prod  "stopped:K8S_CONTEXT is 'staging' but kubectl's current context is 'prod-admin@prod'"  k8s-delete
fixture; run "K8S_CONTEXT differs: stops, names both"        prod-admin@prod  "stopped:K8S_CONTEXT is 'staging' but kubectl's current context is 'prod-admin@prod'"  k8s-apply K8S_CONTEXT=staging
fixture; run "K8S_CONTEXT differs, current is kind: stops"   kind-golang-web  "stopped:K8S_CONTEXT is 'staging' but kubectl's current context is 'kind-golang-web'"  k8s-apply K8S_CONTEXT=staging
fixture; run "K8S_CONTEXT differs: CONFIRM does not override" prod-admin@prod "stopped:K8S_CONTEXT is 'kind-golang-web' but"  k8s-delete K8S_CONTEXT=kind-golang-web CONFIRM=yes
fixture; run "K8S_CONTEXT is a prefix of the current: stops" prod-admin@prod  "stopped:K8S_CONTEXT is 'prod-admin' but"  k8s-apply K8S_CONTEXT=prod-admin

# --- no context at all ----------------------------------------------------------------------
fixture; run "no current context: stops"                     ""               "stopped:No kubectl context is set"  k8s-apply CONFIRM=yes

if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
