#!/usr/bin/env bash
# Smoke check of a built image: it starts, answers /healthz, and does NOT serve /shutdown unless
# ENABLE_SHUTDOWN=true. Run by `make image-smoke` and by the tag-only `docker` job in ci.yml.
#
# Two containers, every run:
#   control: -e ENABLE_SHUTDOWN=true, hard-coded. GET /shutdown must make it exit with code 0.
#            This proves the check can see an exit on this engine. If it cannot, the run fails as
#            a harness failure, never as "image OK".
#   subject: no -e at all, so the image's own defaults are tested (including any ENV a future
#            Dockerfile bakes in). GET /shutdown must be answered by the catch-all handler, which
#            echoes "GET /shutdown"; /healthz must still answer; the container must still be the
#            same running one (same start time, no restart).
# The operator's ENABLE_SHUTDOWN never reaches either container: only explicit -e values do.
#
# Inputs (environment): ENGINE (podman|docker), IMAGE_SMOKE_REF (image to test),
# IMAGE_SMOKE_TIMEOUT (seconds to wait for start and for the control's exit; default 30).
set -uo pipefail

ENGINE=${ENGINE:-}
REF=${IMAGE_SMOKE_REF:-}
TIMEOUT=${IMAGE_SMOKE_TIMEOUT:-30}
CTR_PORT=8080

NAMES=()
cleanup() {
  local n
  for n in "${NAMES[@]}"; do "$ENGINE" rm -f "$n" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
harness() { echo "FAIL (harness, not the image): $*" >&2; exit 1; }
logs() { echo "--- $1 logs ---" >&2; "$ENGINE" logs "$1" >&2 2>&1 || true; }

[ -n "$ENGINE" ] || harness "ENGINE is not set"
[ -n "$REF" ] || harness "IMAGE_SMOKE_REF is not set"
case "$TIMEOUT" in '' | *[!0-9]*) harness "IMAGE_SMOKE_TIMEOUT must be a whole number of seconds, got '$TIMEOUT'" ;; esac
"$ENGINE" image inspect "$REF" >/dev/null 2>&1 ||
  harness "image $REF is not in $ENGINE's image store. Build or pull it with $ENGINE first."

# start <name> [extra run args...]: run the image detached on an ephemeral 127.0.0.1 port.
# Sets PORT (a global, not printed: a value returned through $( ) would lose the NAMES entry).
start() {
  local name=$1 out
  shift
  NAMES+=("$name")
  "$ENGINE" run -d --name "$name" -p "127.0.0.1::$CTR_PORT" "$@" "$REF" >/dev/null ||
    harness "$ENGINE run failed for $name"
  out=$("$ENGINE" port "$name" "$CTR_PORT" 2>/dev/null | head -1)
  case "$out" in
    127.0.0.1:[0-9]*) PORT=${out#127.0.0.1:} ;;
    *) harness "could not read the host port of $name from '$ENGINE port' (got '$out')" ;;
  esac
}

running() { "$ENGINE" inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
identity() { "$ENGINE" inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$1" 2>/dev/null; }

healthy() {
  local body
  body=$(curl -s -m 2 "http://127.0.0.1:$PORT/healthz" 2>/dev/null) || return 1
  case "$body" in *'"health":"ok"'*) return 0 ;; *) return 1 ;; esac
}

# wait_ready <name>: poll /healthz until it answers, the container stops, or TIMEOUT passes.
wait_ready() {
  local i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    healthy && return 0
    if [ "$(running "$1")" != true ]; then logs "$1"; fail "$1 stopped before /healthz answered"; fi
    sleep 1
    i=$((i + 1))
  done
  logs "$1"
  fail "$1: /healthz did not answer within ${TIMEOUT}s"
}

echo "image-smoke: $REF on $ENGINE"

# ---- control arm: the check must be able to see an exit --------------------------------------
CTL=golang-web-smoke-ctl-$$
start "$CTL" -e ENABLE_SHUTDOWN=true
wait_ready "$CTL"
curl -s -o /dev/null -m 5 "http://127.0.0.1:$PORT/shutdown" >/dev/null 2>&1 || true
i=0
while [ "$(running "$CTL")" = true ] && [ "$i" -lt "$TIMEOUT" ]; do sleep 1; i=$((i + 1)); done
[ "$(running "$CTL")" = true ] && {
  logs "$CTL"
  harness "control container (ENABLE_SHUTDOWN=true) did not exit after GET /shutdown within ${TIMEOUT}s; this check cannot see an exit here"
}
code=$("$ENGINE" inspect -f '{{.State.ExitCode}}' "$CTL" 2>/dev/null)
[ "$code" = 0 ] || { logs "$CTL"; harness "control container exited with code '$code', expected 0"; }
echo "  control: ENABLE_SHUTDOWN=true -> GET /shutdown stopped the container (exit 0), as expected"

# ---- subject arm: the image's own defaults ----------------------------------------------------
SUB=golang-web-smoke-$$
start "$SUB"
wait_ready "$SUB"
before=$(identity "$SUB")
resp=$(curl -s -m 5 -w '\n%{http_code}' "http://127.0.0.1:$PORT/shutdown" 2>/dev/null)
rc=$?
status=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$rc" -ne 0 ]; then
  logs "$SUB"
  fail "/shutdown is served by default: GET /shutdown got no response (curl rc=$rc; container running: $(running "$SUB"))"
fi
case "$body" in
  *'GET /shutdown'*) ;;
  *) logs "$SUB"; fail "GET /shutdown (HTTP $status) was not answered by the catch-all handler; a /shutdown route is registered by default" ;;
esac
healthy || { logs "$SUB"; fail "/healthz stopped answering after GET /shutdown"; }
[ "$(running "$SUB")" = true ] || { logs "$SUB"; fail "the container stopped after GET /shutdown"; }
after=$(identity "$SUB")
[ "$before" = "$after" ] || fail "the container restarted after GET /shutdown (before: $before, after: $after)"
echo "  subject: image defaults -> GET /shutdown answered by the app page (HTTP $status), container still running"
echo "PASS: $REF keeps /shutdown closed by default"
