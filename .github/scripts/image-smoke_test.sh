#!/usr/bin/env bash
# Tests for image-smoke.sh with a stand-in container engine and curl (run by `make scripts-test`).
# Each case picks how the fake app behaves, runs the script for real, and checks its exit code
# and verdict line. The real images are checked by `make image-smoke` itself; these cases cover
# what no published image can show: a graceful /shutdown, a control that never exits, a restart,
# and the operator's own ENABLE_SHUTDOWN leaking into the subject container.
set -u
SCRIPT=${1:-$(dirname "$0")/image-smoke.sh}
fails=0

# new_case <scenario>: fake engine + curl in $D/bin. Scenarios (the subject container's behaviour):
#   closed   catch-all answers GET /shutdown (correct image)
#   open     GET /shutdown exits the process (0.0.4)
#   graceful GET /shutdown answers 200 with no body, process stays up for now (a drained shutdown)
#   restart  answers like `closed`, but the container's start time changes afterwards
#   stuck    like `closed`, and the CONTROL container ignores /shutdown too
#   noimage  the image is not in the store
new_case() {
  D=$(mktemp -d); mkdir -p "$D/bin" "$D/c"; echo 40000 > "$D/port"; echo "$1" > "$D/scen"
  cat > "$D/bin/eng" <<EOF
#!/usr/bin/env bash
c="$D/c"
case "\$1" in
  image) [ "\$(cat "$D/scen")" != noimage ] ;;
  run) shift; name=""; args="\$*"
       while [ \$# -gt 0 ]; do case "\$1" in --name) name=\$2; shift;; esac; shift; done
       p=\$(( \$(cat "$D/port") + 1 )); echo \$p > "$D/port"
       echo \$p > "\$c/\$name.port"; echo "\$name" > "$D/byport-\$p"
       case "\$args" in *"ENABLE_SHUTDOWN=true"*) role=ctl ;; *) role=sub ;; esac
       echo \$role > "\$c/\$name.role"; echo "\$args" >> "$D/\$role.args"
       echo true > "\$c/\$name.run"; echo T0 > "\$c/\$name.start"; echo cid ;;
  port) echo "127.0.0.1:\$(cat "\$c/\$2.port")" ;;
  inspect) f=\$3; n=\$4
       case "\$f" in
         *Running*) cat "\$c/\$n.run" ;;
         *ExitCode*) echo 0 ;;
         *StartedAt*) echo "\$(cat "\$c/\$n.start") 0" ;;
       esac ;;
  logs|rm) : ;;
  *) echo "unexpected eng \$*" >&2; exit 9 ;;
esac
EOF
  cat > "$D/bin/curl" <<EOF
#!/usr/bin/env bash
url=\${*: -1}; c="$D/c"; scen=\$(cat "$D/scen"); w=""
for a in "\$@"; do case "\$a" in '\n%{http_code}') w=1 ;; esac; done
p=\${url#http://127.0.0.1:}; p=\${p%%/*}; n=\$(cat "$D/byport-\$p" 2>/dev/null) || exit 7
[ "\$(cat "\$c/\$n.run")" = true ] || exit 7
role=\$(cat "\$c/\$n.role")
case "\$url" in
  */healthz) printf '{"health":"ok"}' ;;
  */shutdown)
    if [ "\$role" = ctl ]; then
      [ "\$scen" = stuck ] && { printf 'Hello\nrequest 0 GET /shutdown\n'; exit 0; }
      echo false > "\$c/\$n.run"; exit 52
    fi
    case "\$scen" in
      open) echo false > "\$c/\$n.run"; exit 52 ;;
      graceful) body="" ;;
      *) body='Hello, World
request 0 GET /shutdown' ;;
    esac
    [ "\$scen" = restart ] && echo T1 > "\$c/\$n.start"
    printf '%s' "\$body"; [ -n "\$w" ] && printf '\n200' ;;
esac
exit 0
EOF
  chmod +x "$D/bin/eng" "$D/bin/curl"
}

# check <name> <want-rc> <want-text>: run the script in the current case and compare.
check() {
  local out rc
  out=$(PATH="$D/bin:$PATH" ENGINE=eng IMAGE_SMOKE_REF=img IMAGE_SMOKE_TIMEOUT=2 \
        ENABLE_SHUTDOWN=true bash "$SCRIPT" 2>&1); rc=$?
  case "$out" in *"$3"*) ;; *) rc="$rc (text missing)" ;; esac
  if [ "$rc" = "$2" ]; then echo "ok   $1"; else
    echo "FAIL $1: rc=$rc, wanted rc=$2 and '$3'"; printf '%s\n' "$out"; fails=$((fails + 1)); fi
}

new_case closed;   check "correct image passes" 0 "PASS: img keeps /shutdown closed by default"
# The operator's ENABLE_SHUTDOWN=true (set in check) must reach only the control container.
# The fake engine appends each container's run arguments to $D/<role>.args: exactly one subject.
if [ "$(wc -l < "$D/sub.args" 2>/dev/null || echo 0)" -ne 1 ]; then
  echo "FAIL expected exactly one subject container run"; fails=$((fails + 1))
elif grep -q ENABLE_SHUTDOWN "$D/sub.args"; then
  echo "FAIL subject got ENABLE_SHUTDOWN: $(cat "$D/sub.args")"; fails=$((fails + 1))
else echo "ok   operator ENABLE_SHUTDOWN does not reach the subject container"; fi
rm -rf "$D"
new_case open;     check "open /shutdown fails"      1 "FAIL: /shutdown is served by default"; rm -rf "$D"
new_case graceful; check "graceful /shutdown fails"  1 "was not answered by the catch-all handler"; rm -rf "$D"
new_case restart;  check "restart is caught"         1 "the container restarted"; rm -rf "$D"
new_case stuck;    check "blind control is harness"  1 "FAIL (harness, not the image)"; rm -rf "$D"
new_case noimage;  check "missing image is harness"  1 "is not in eng's image store"; rm -rf "$D"

if [ "$fails" -ne 0 ]; then echo "image-smoke_test: $fails failed"; exit 1; fi
echo "image-smoke_test: all cases passed"
