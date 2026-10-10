#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # fixtures are text in single quotes; `A && ok || bad` only prints
# Tests for mac-route.sh (run by `make scripts-test`). They run on Linux, with the script's test
# switch (MAC_ROUTE_TEST=1): `uname`, `ifconfig`, `route`, `scutil`, `sudo`, `lsof` and the
# relay's interpreter are stand-ins, the hosts file is a scratch file, and `ps`, `kill`, `cp`
# are the real ones behind a wrapper (a relay stand-in is a real process, so the PID, start
# time and command line checks are real). The relay itself is then run for real, on 127.0.0.1.
# Not reachable here: a bind to an lo0 alias, the drop from root, and macOS's own tools.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MR=$HERE/mac-route.sh
T=$(mktemp -d)
F=$T/fake
B=$T/bin
mkdir -p "$B" "$T/home" "$F" "$T/tmp"
: > "$F/pids"
cleanup() {
  local p cmd
  while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$F/pids"
  # anything a failed case left running: every process of this run names its scratch directory
  ps -ww -Ao pid=,command= | while read -r p cmd; do
    case $cmd in *"$T/"*) [ "$p" != "$$" ] && kill "$p" 2>/dev/null ;; esac
  done
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
checks=0
TAB=$(printf '\t')
MARK='# vks-mac-route'

ok()   { echo "PASS  $1"; checks=$((checks + 1)); }
bad()  { echo "FAIL  $1: $2"; fails=$((fails + 1)); checks=$((checks + 1)); }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "did not want '$3' in: $2"; else ok "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
alive() { [ -n "$(ps -o pid= -p "$1" 2>/dev/null)" ]; }
gone()  { local i=0; while alive "$1" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; ! alive "$1"; }

# --- the stand-ins ----------------------------------------------------------------------------
REAL_CP=$(PATH=/usr/bin:/bin type -P cp)
REAL_KILL=$(PATH=/usr/bin:/bin type -P kill)
REAL_PS=$(PATH=/usr/bin:/bin type -P ps)
REAL_GREP=$(PATH=/usr/bin:/bin type -P grep)
REAL_AWK=$(PATH=/usr/bin:/bin type -P awk)
cat > "$B/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
EOF
# ifconfig: only the exact argument shapes macOS takes are accepted
cat > "$B/ifconfig" <<'EOF'
#!/bin/sh
f=$FAKE/lo0
lo0() {
  echo "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384"
  echo "	inet 127.0.0.1 netmask 0xff000000"
  while read -r ip; do echo "	inet $ip netmask 0xffffffff"; done < "$f"
}
case "$*" in
  lo0) lo0 ;;
  -a) [ -z "${FAKE_IFCONFIG_A_FAIL:-}" ] || exit 1; lo0; cat "$FAKE/ifaces" ;;
  "lo0 alias "*" netmask 255.255.255.255")
    [ $# -eq 5 ] || exit 64
    [ -n "${FAKE_IFCONFIG_FAIL:-}" ] && exit 1
    echo "$3" >> "$f"
    [ -z "${FAKE_IFCONFIG_CRASH:-}" ] || kill -9 "$PPID" ;;
  "lo0 -alias "*) [ $# -eq 3 ] || exit 64; grep -vxF -- "$3" "$f" > "$f.t"; mv "$f.t" "$f" ;;
  *) echo "ifconfig stand-in: unexpected '$*'" >> "$FAKE/sudo.log"; exit 64 ;;
esac
EOF
cat > "$B/route" <<'EOF'
#!/bin/sh
[ "$*" = "-n get default" ] || exit 64
[ -s "$FAKE/gateway" ] || { echo "route: writing to routing socket: not in table" >&2; exit 1; }
echo "   route to: default"; echo "destination: default"; echo "    gateway: $(cat "$FAKE/gateway")"; echo "  interface: en0"
EOF
cat > "$B/scutil" <<'EOF'
#!/bin/sh
[ "$*" = "--dns" ] || exit 64
echo "DNS configuration"; echo; echo "resolver #1"; n=0
while read -r ip; do echo "  nameserver[$n] : $ip"; n=$((n + 1)); done < "$FAKE/dns"
echo "  flags    : Request A records"
EOF
# sudo: must be `-n`, and what it runs must be an absolute path
cat > "$B/sudo" <<'EOF'
#!/bin/sh
[ "${FAKE_SUDO:-yes}" = yes ] || { echo "sudo: a password is required" >&2; exit 1; }
[ "$1" = -n ] || { echo "sudo stand-in: called without -n: $*" >> "$FAKE/sudo.log"; exit 64; }
shift
echo "$*" >> "$FAKE/sudo.log"
case $1 in /*) ;; *) echo "sudo stand-in: NOT AN ABSOLUTE PATH: $1" >> "$FAKE/sudo.log"; exit 64 ;; esac
exec "$@"
EOF
# lsof: $FAKE/listening holds `<port>` (on 127.0.0.1) or `*<port>` (on every address)
cat > "$B/lsof" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case $a in
    -iTCP@127.0.0.1:*) port=${a##*:}; grep -qxF -- "$port" "$FAKE/listening" || exit 1
      echo "sshd 4242 m1 9u IPv4 0x0 0t0 TCP 127.0.0.1:$port (LISTEN)"; exit 0 ;;
    -iTCP:*) port=${a##*:}; rc=1
      grep -qxF -- "$port" "$FAKE/listening" && { echo "sshd 4242 m1 9u IPv4 0x0 0t0 TCP 127.0.0.1:$port (LISTEN)"; rc=0; }
      grep -qxF -- "*$port" "$FAKE/listening" && { echo "sshd 4242 m1 9u IPv4 0x0 0t0 TCP *:$port (LISTEN)"; rc=0; }
      exit $rc ;;
  esac
done
exit 64
EOF
cat > "$B/xcode-select" <<'EOF'
#!/bin/sh
[ -z "${FAKE_NO_CLT:-}" ]
EOF
# cp: the real one, except for what a case asks it to do to the hosts file
cat > "$B/cp" <<EOF
#!/bin/sh
for a in "\$@"; do tgt=\$a; done
if [ "\$tgt" = "\$FAKE_HOSTS" ]; then
  case \${FAKE_CP:-} in
    fail) exit 1 ;;
    truncate-fail) : > "\$tgt"; exit 1 ;;
    truncate-once) if [ ! -e "\$FAKE/cp.once" ]; then : > "\$FAKE/cp.once"; : > "\$tgt"; exit 0; fi ;;
  esac
fi
exec $REAL_CP "\$@"
EOF
printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_KILL" > "$B/kill"
printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_PS" > "$B/ps"
# grep and awk: the real ones, except when a case breaks them
cat > "$B/grep" <<EOF
#!/bin/sh
case "\${FAKE_GREP:-} \$1" in
  "dead-build -vxFf") exit 2 ;;
  "empty-build -vxFf") exit 1 ;;
  "short-build -vxFf") echo "127.0.0.1	localhost"; exit 0 ;;
esac
exec $REAL_GREP "\$@"
EOF
cat > "$B/awk" <<EOF
#!/bin/sh
[ -z "\${FAKE_AWK:-}" ] || exit 1
exec $REAL_AWK "\$@"
EOF
# The interpreter stand-in: keeps the code it was fed on stdin, records its arguments, leaves a
# process whose command line holds them (as the real relay's does), prints that PID and returns.
cat > "$T/fakepy" <<'EOF'
#!/bin/sh
cat > "$FAKE/py.stdin"
echo "$*" >> "$FAKE/py.log"
[ -z "${FAKE_PY_FAIL:-}" ] || { echo "relay: cannot listen on $6: [Errno 48] Address already in use" >&2; exit 1; }
bash -c 'while :; do sleep 1; done' "$@" >/dev/null 2>&1 </dev/null &
echo $! >> "$FAKE/pids"
echo $!
EOF
chmod +x "$B/"* "$T/fakepy"

SD=$T/xdg/vks-mac-route
ST=$SD/state
reset_fakes() {
  local p
  while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$F/pids"
  : > "$F/pids"; : > "$F/sudo.log"; : > "$F/py.log"; echo 172.20.10.1 > "$F/dns"; echo 172.20.10.1 > "$F/gateway"; rm -f "$F/cp.once" "$F/py.stdin"
  printf '%s\n' 192.168.101.128 > "$F/lo0"
  printf '%s\n' 18443 18444 18445 18446 > "$F/listening"
  printf 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet6 fe80::1%%en0 prefixlen 64\n\tinet 172.20.10.5 netmask 0xfffffff0 broadcast 172.20.10.15\n' > "$F/ifaces"
  printf '127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n192.168.101.130 harbor.env1.lab.test\n192.168.101.131\tregistry.lab.test\n' > "$T/hosts"
  chmod 644 "$T/hosts"; cp "$T/hosts" "$T/hosts.orig"
  rm -rf "$T/xdg"
}
# mr [VAR=value ...] -- <mac-route arguments>: sets out and rc
mr() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out=$(env PATH="$B:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/xdg" FAKE="$F" FAKE_HOSTS="$T/hosts" MAC_ROUTE_TEST=1 \
    TMPDIR="$T/tmp" MAC_ROUTE_BIN="$B" MAC_ROUTE_HOSTS="$T/hosts" MAC_ROUTE_PYTHON="$T/fakepy" \
    SSH_CONNECTION="198.51.100.4 50123 203.0.113.7 22" "${envs[@]}" bash "$MR" "$@" 2>&1)
  rc=$?
}
unchanged() {   # <label>: nothing on the "Mac" was touched
  eq "$1: lo0 is as before" "$(cat "$F/lo0")" 192.168.101.128
  cmp -s "$T/hosts" "$T/hosts.orig" && ok "$1: the hosts file is as before" || bad "$1: the hosts file is as before" "$(cat "$T/hosts")"
  [ ! -e "$SD" ] && ok "$1: no state directory" || bad "$1: no state directory" "$(ls -a "$SD")"
  eq "$1: no relay was started" "$(cat "$F/py.log")" ""
  eq "$1: sudo ran nothing but its own check and lsof" "$(grep -vx /usr/bin/true "$F/sudo.log" | grep -v "^$B/lsof ")" ""
}
relay_pids() { awk '$1 == "relay" { print $5 }' "$ST"; }
ME=$(id -un)
A=(--forward 192.168.100.50:443:18443 --forward 192.168.101.128:443:18444 --forward 192.168.101.128:6443:18445
   --forward 192.168.101.130:443:18446 --host vcsa.env1.lab.test=192.168.100.50 --host harbor.env1.lab.test=192.168.101.130)
OWNER="ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:192.168.100.50:443 -R 127.0.0.1:18444:192.168.101.128:443 -R 127.0.0.1:18445:192.168.101.128:6443 -R 127.0.0.1:18446:192.168.101.130:443 $ME@203.0.113.7"
VCLINE="192.168.100.50${TAB}vcsa.env1.lab.test${TAB}$MARK"

# --- bash 3.2: none of what macOS /bin/bash lacks ---------------------------------------------
eq "mac-route.sh uses nothing bash 3.2 lacks" "$(grep -nE 'declare -A|local -n|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|\|&|&>>|wait -n' "$MR")" ""

# --- the test switch --------------------------------------------------------------------------
for v in MAC_ROUTE_HOSTS MAC_ROUTE_PYTHON MAC_ROUTE_BIN; do
  out=$(env -u MAC_ROUTE_TEST "$v=$T/x" bash "$MR" print-tunnel --forward 10.0.0.1:443:18443 --mac m1@mac.example 2>&1); rc=$?
  has "$v without the test switch: refused" "$rc $out" "2 mac-route: refused: $v is set. It is for mac-route_test.sh only (with MAC_ROUTE_TEST=1); unset it: unset $v"
done
out=$(env -u MAC_ROUTE_TEST -u MAC_ROUTE_HOSTS -u MAC_ROUTE_PYTHON -u MAC_ROUTE_BIN PATH="$B:$PATH" bash "$MR" print-tunnel --forward 10.0.0.1:443:18443 --mac m1@mac.example 2>&1); rc=$?
eq "no switch, no seam: print-tunnel runs with the system's own tools" "$rc $out" "0 ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:10.0.0.1:443 m1@mac.example"

# --- refusals: each names its reason and changes nothing --------------------------------------
reset_fakes
mr FAKE_UNAME=Linux -- up "${A[@]}"
eq "not macOS: exit 2" "$rc" 2
has "not macOS: the reason" "$out" "mac-route: refused: this is Linux, not macOS. up changes lo0 and /etc/hosts of a Mac; run it there."
unchanged "not macOS"
mr FAKE_UNAME=Linux -- status
has "not macOS: status is refused too" "$rc $out" "2 mac-route: refused: this is Linux, not macOS."
mr FAKE_UNAME=Linux -- down
has "not macOS: down is refused too" "$rc $out" "2 mac-route: refused: this is Linux, not macOS."

mr FAKE_SUDO=no -- up "${A[@]}"
eq "sudo not cached: exit 2" "$rc" 2
has "sudo not cached: the reason and the command" "$out" "mac-route: refused: sudo would ask for a password, and nothing was changed. Run this first, then the same command again: sudo -v"
unchanged "sudo not cached"

while IFS='|' read -r ip why; do
  mr X=1 -- up --forward "$ip:443:18443"
  has "bad address $ip: refused with the reason" "$rc $out" "2 mac-route: refused: $ip: $why"
  mr X=1 -- up --forward 192.168.100.50:443:18443 --host "vcsa.env1.lab.test=$ip"
  has "bad address $ip for a name: refused the same way" "$rc $out" "2 mac-route: refused: $ip: $why"
done <<'EOF'
8.8.8.8|not a private address (only 10/8, 172.16/12 and 192.168/16 are forwarded)
172.32.0.1|not a private address (only 10/8, 172.16/12 and 192.168/16 are forwarded)
192.169.1.1|not a private address (only 10/8, 172.16/12 and 192.168/16 are forwarded)
127.0.0.1|a loopback address; only the lab's private addresses are forwarded
0.0.0.0|not a host address; only the lab's private addresses are forwarded
256.1.1.1|not an IPv4 address (four numbers 0-255)
10.1.1|not an IPv4 address (four numbers 0-255)
10.01.1.1|not an IPv4 address (four numbers 0-255)
10.1.1.1.1|not an IPv4 address (four numbers 0-255)
EOF
unchanged "bad addresses"
for ip in 10.0.0.1 172.16.0.1 172.31.255.254 192.168.0.1; do
  mr X=1 -- print-tunnel --forward "$ip:443:18443"
  has "private address $ip is accepted" "$rc $out" "0 ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:$ip:443 "
done
mr X=1 -- up --forward 192.168.100.50:0:18443
has "port 0: refused" "$rc $out" "2 mac-route: refused: '0' in '192.168.100.50:0:18443' is not a port (1-65535)"
mr X=1 -- up --forward 192.168.100.50:443:70000
has "tunnel port above 65535: refused" "$rc $out" "is not a tunnel port (1024-65535"
mr X=1 -- up --forward 192.168.100.50:443:443
has "tunnel port below 1024: refused" "$rc $out" "is not a tunnel port (1024-65535"
mr X=1 -- up --forward 192.168.100.50:443
has "a forward without its tunnel port: refused" "$rc $out" "2 mac-route: '192.168.100.50:443': a forward is <lab ip>:<port>:<tunnel port>"
mr X=1 -- up --forward 192.168.100.50:443:18443 --forward 192.168.100.50:443:18444
has "one address and port, two tunnel ports: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50:443 is given twice, with tunnel ports 18443 and 18444"
mr X=1 -- up --forward 192.168.100.50:443:18443 --forward 192.168.100.50:6443:18443
has "one tunnel port, two forwards: refused" "$rc $out" "2 mac-route: refused: tunnel port 18443 is given for both 192.168.100.50:443 and 192.168.100.50:6443"
for n in '-bad.lab' 'a..b' 'under_score.lab' '10.0.0.1' 'localhost' 'x;y'; do
  mr X=1 -- up --forward 192.168.100.50:443:18443 --host "$n=192.168.100.50"
  has "bad name '$n': refused" "$rc $out" "2 mac-route: refused: '$n' is not a host name"
done
mr X=1 -- up --forward 192.168.100.50:443:18443 --host vcsa.env1.lab.test=192.168.100.51
has "a name for an address without a forward: refused" "$rc $out" "2 mac-route: refused: --host vcsa.env1.lab.test=192.168.100.51 names an address no forward is given for"
mr X=1 -- up
has "up with nothing: says what to give" "$rc $out" "2 mac-route: nothing to do: give at least one --forward"
mr X=1 -- up --bogus
has "unknown argument" "$rc $out" "2 mac-route: unknown argument '--bogus'"
unchanged "bad arguments"

printf '%s\n' 18443 18446 '*18445' > "$F/listening"
mr X=1 -- up "${A[@]}"
eq "tunnel not listening: exit 2" "$rc" 2
has "tunnel not listening: names every port that is missing" "$out" "mac-route: refused: nothing listens on 127.0.0.1 for tunnel port(s) 18444 18445, and nothing was changed."
has "tunnel not listening: prints the owner's line for the whole list" "$out" "$OWNER"
has "tunnel on every address instead of 127.0.0.1: says so" "$out" "mac-route: tunnel port 18445: it listens on EVERY address of this Mac, not on 127.0.0.1"
unchanged "tunnel not listening"
reset_fakes

printf '10.0.0.9\tvcsa.env1.lab.test\n' >> "$T/hosts"; cp "$T/hosts" "$T/hosts.orig"
mr X=1 -- up "${A[@]}"
eq "name collision: exit 2" "$rc" 2
has "name collision: the reason" "$out" "mac-route: refused: $T/hosts already gives vcsa.env1.lab.test the address 10.0.0.9, in a line this script did not write. Nothing was changed."
unchanged "name collision"

mr MAC_ROUTE_PYTHON="$T/absent" -- up "${A[@]}"
has "no interpreter: says what to install" "$rc $out" "2 mac-route: refused: $T/absent is missing. Install the Command Line Tools, then run this again: xcode-select --install"
if [ -x /usr/bin/python3 ]; then
  mr MAC_ROUTE_PYTHON=/usr/bin/python3 FAKE_NO_CLT=1 -- up "${A[@]}"
  has "placeholder python3 without the Command Line Tools: refused" "$rc $out" "2 mac-route: refused: /usr/bin/python3 is only a placeholder"
fi
unchanged "no interpreter"

# --- an alias must not take the place of an address the Mac uses ------------------------------
reset_fakes
ONE=(--forward 192.168.100.50:443:18443)
echo 192.168.100.50 > "$F/gateway"
mr X=1 -- up "${ONE[@]}"
has "the default gateway: refused, with what it collided with" "$rc $out" "2 mac-route: refused: 192.168.100.50 is this Mac's default gateway (route -n get default); an lo0 alias would take its place on this Mac. Nothing was changed. Only if that is what you want: --allow-onlink 192.168.100.50"
unchanged "the default gateway"
echo 172.20.10.1 > "$F/gateway"; printf '%s\n' 9.9.9.9 192.168.100.50 > "$F/dns"
mr X=1 -- up "${ONE[@]}"
has "a DNS resolver: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50 is a DNS resolver of this Mac (scutil --dns); an lo0 alias would take its place"
unchanged "a DNS resolver"
echo 172.20.10.1 > "$F/dns"; printf 'en1: flags=8863<UP> mtu 1500\n\tinet 192.168.100.50 netmask 0xffffffff broadcast 192.168.100.50\n' >> "$F/ifaces"
mr X=1 -- up "${ONE[@]}"
has "the Mac's own address: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50 is this Mac's own address on en1; an lo0 alias would take its place"
unchanged "the Mac's own address"
reset_fakes
printf 'utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\tinet 10.8.0.2 --> 192.168.100.50 netmask 0xffffffff\n' >> "$F/ifaces"
mr X=1 -- up "${ONE[@]}"
has "the far end of a point-to-point interface: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50 is the far end of this Mac's utun4; an lo0 alias would take its place"
unchanged "the far end"
reset_fakes
printf 'en1: flags=8863<UP> mtu 1500\n\tinet 192.168.100.23 netmask 0xffffff00 broadcast 192.168.100.255\n' >> "$F/ifaces"
mr X=1 -- up "${ONE[@]}"
has "inside an interface's network: refused, with the network" "$rc $out" "2 mac-route: refused: 192.168.100.50 is inside 192.168.100.0/24, the network of this Mac's en1 (its address there is 192.168.100.23); an lo0 alias would take its place"
unchanged "inside an interface's network"
mr X=1 -- up "${ONE[@]}" --forward 192.168.100.60:443:18444 --allow-onlink 192.168.100.50
has "--allow-onlink is per address: the other one is still refused" "$rc $out" "2 mac-route: refused: 192.168.100.60 is inside 192.168.100.0/24"
unchanged "--allow-onlink for one of two"
mr X=1 -- up "${ONE[@]}" --allow-onlink 192.168.100.50
eq "--allow-onlink: the address is forwarded" "$rc" 0
has "--allow-onlink: its alias is added" "$out" "mac-route: alias  192.168.100.50 on lo0: added"
mr X=1 -- down
mr X=1 -- up "${ONE[@]}" --allow-onlink 8.8.8.8
has "--allow-onlink takes a private address only" "$rc $out" "2 mac-route: refused: --allow-onlink 8.8.8.8: not a private address"
reset_fakes
printf 'en1: flags=8863<UP> mtu 1500\n\tinet 192.168.7.1 netmask 255.255.255.0\n' >> "$F/ifaces"
mr X=1 -- up "${ONE[@]}"
has "a netmask it cannot read: refused, not guessed" "$rc $out" "2 mac-route: refused: cannot read the netmask '255.255.255.0' of en1 (192.168.7.1), so 192.168.100.50 cannot be checked against it"
unchanged "an unreadable netmask"

# what the check reads cannot be read: it cannot tell, so it refuses and says which
CANT="mac-route: refused: cannot tell whether an lo0 alias for 192.168.100.50 would take the place of an address this Mac uses: could not read"
reset_fakes; : > "$F/gateway"
mr X=1 -- up "${ONE[@]}"
has "route fails: refused, naming it" "$rc $out" "2 $CANT the default gateway (route -n get default). Nothing was changed. Only if you know that it does not: --allow-onlink 192.168.100.50"
unchanged "route fails"
reset_fakes; : > "$F/dns"
mr X=1 -- up "${ONE[@]}"
has "scutil names no resolver: refused, naming it" "$rc $out" "2 $CANT the DNS resolvers (scutil --dns). Nothing was changed."
unchanged "scutil names no resolver"
reset_fakes
mr FAKE_IFCONFIG_A_FAIL=1 -- up "${ONE[@]}"
has "ifconfig -a fails: refused, naming it" "$rc $out" "2 $CANT the interfaces' addresses (ifconfig -a). Nothing was changed."
unchanged "ifconfig -a fails"
printf 'en0: flags=8863<UP> mtu 1500\n\tinet6 fe80::1%%en0 prefixlen 64\n' > "$F/ifaces"
mr X=1 -- up "${ONE[@]}"
has "ifconfig -a shows no interface address but lo0's: refused, naming it" "$rc $out" "2 $CANT the interfaces' addresses (ifconfig -a). Nothing was changed."
unchanged "no interface address"
: > "$F/gateway"; : > "$F/dns"
mr X=1 -- up "${ONE[@]}"
has "none of the three can be read: all three are named" "$rc $out" "2 $CANT the default gateway (route -n get default), the DNS resolvers (scutil --dns), the interfaces' addresses (ifconfig -a). Nothing was changed."
unchanged "none of the three"
mr X=1 -- up "${ONE[@]}" --forward 192.168.100.60:443:18444 --allow-onlink 192.168.100.50
has "unreadable, --allow-onlink for one of two: the other is still refused" "$rc $out" "2 mac-route: refused: cannot tell whether an lo0 alias for 192.168.100.60 would take"
unchanged "unreadable, --allow-onlink for one of two"
mr X=1 -- up "${ONE[@]}" --allow-onlink 192.168.100.50
eq "unreadable, --allow-onlink for the address: it is forwarded" "$rc" 0
has "unreadable, --allow-onlink: its alias is added" "$out" "mac-route: alias  192.168.100.50 on lo0: added"
mr X=1 -- down

# --- the state directory and the lock ---------------------------------------------------------
reset_fakes
mkdir -p "$SD"; chmod 770 "$SD"
mr X=1 -- up "${A[@]}"
has "a state directory others can write: refused" "$rc $out" "2 mac-route: refused: $SD can be written by its group or by everyone. Nothing was changed. Close it first: chmod 700 $SD"
eq "… and nothing was started" "$(cat "$F/py.log")" ""
mr X=1 -- down
has "… down refuses it too" "$rc $out" "2 mac-route: refused: $SD can be written by its group or by everyone."
rmdir "$SD"; mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$SD"
mr X=1 -- up "${A[@]}"
has "a state directory that is a symbolic link: refused" "$rc $out" "2 mac-route: refused: $SD is a symbolic link. Nothing was changed."
rm "$SD"
mkdir -p "$SD/lock"; chmod 700 "$SD"; sleep 300 & holder=$!; echo "$holder" >> "$F/pids"; echo "$holder" > "$SD/lock/pid"
mr X=1 -- up "${A[@]}"
has "a held lock: refused, with whose it is" "$rc $out" "2 mac-route: refused: another run holds the lock $SD/lock: PID $holder (sleep 300). Nothing was changed."
eq "… and nothing was started" "$(cat "$F/py.log")" ""
kill "$holder"; gone "$holder"
mr X=1 -- up "${A[@]}"
has "a stale lock: refused, with how to clear it" "$rc $out" "2 mac-route: refused: the lock $SD/lock is held by PID $holder, which is not running any more (a run was killed). Nothing was changed. Clear it, then run this again: rm -r $SD/lock"
[ -d "$SD/lock" ] && ok "… and a lock it does not hold is not removed" || bad "… and a lock it does not hold is not removed" "gone"
eq "… and nothing was started" "$(cat "$F/py.log")" ""

# --- up ---------------------------------------------------------------------------------------
reset_fakes
mr X=1 -- up "${A[@]}"
eq "up: exit 0" "$rc" 0
has "up: the alias it needs is added" "$out" "mac-route: alias  192.168.100.50 on lo0: added"
has "up: an alias that was there is left alone" "$out" "mac-route: alias  192.168.101.128 on lo0: was there before, left alone"
has "up: a name that was there is left alone" "$out" "mac-route: hosts  harbor.env1.lab.test = 192.168.101.130: was there before, left alone"
has "up: says how to see and undo it" "$out" "up. See it: $MR status    Undo it: $MR down"
eq "up: lo0 has the addresses that are forwarded" "$(sort "$F/lo0" | tr '\n' ' ')" "192.168.100.50 192.168.101.128 192.168.101.130 "
has "up: the alias is added with the netmask keyword" "$(cat "$F/sudo.log")" "$B/ifconfig lo0 alias 192.168.100.50 netmask 255.255.255.255"
eq "up: four relays started" "$(grep -c . "$F/py.log")" 4
has "up: a relay is the interpreter in isolated mode, code on stdin, tagged, bound to the alias only" "$(cat "$F/py.log")" "-I - --tag vks-mac-route --listen 192.168.100.50:443 --connect 127.0.0.1:18443 --log $SD/relay-192.168.100.50-443.log"
has "up: a port below 1024 is started through sudo -n" "$(cat "$F/sudo.log")" "$T/fakepy -I - --tag vks-mac-route --listen 192.168.100.50:443"
hasnt "up: a port from 1024 up is started without root" "$(cat "$F/sudo.log")" "--listen 192.168.101.128:6443"
hasnt "up: nothing is told to listen on every address" "$(cat "$F/py.log")" "0.0.0.0"
bash "$MR" relay-source > "$T/relay.src"
cmp -s "$F/py.stdin" "$T/relay.src" && ok "up: the relay's code reaches the interpreter on stdin, from the script itself" || bad "up: the relay's code reaches the interpreter on stdin" "differs"
eq "up: no code is written where root could be made to run it" "$(find "$T/xdg" "$T/home" -name '*.py' | grep -c .)" 0
eq "up: everything sudo ran was an absolute path" "$(grep -v '^/' "$F/sudo.log")" ""
eq "up: the hosts file gained exactly the one marked line" "$(diff "$T/hosts.orig" "$T/hosts" | grep '^[<>]')" "> $VCLINE"
eq "up: the hosts file keeps its mode" "$(stat -c %a "$T/hosts")" 644
cmp -s "$SD/hosts.backup" "$T/hosts.orig" && ok "up: the original hosts file is kept as a backup" || bad "up: the original hosts file is kept as a backup" "differs"
has "up: the hosts file is replaced by sudo -n cp of a file built in the state directory" "$(cat "$F/sudo.log")" "$B/cp $SD/hosts.new."
eq "up: no work file is left behind" "$(find "$SD" -name 'hosts.new.*' -o -name 'hosts.snap.*' -o -name 'state.tmp' -o -name lock | grep -c .)" 0
eq "up: the state file records 2 aliases, 4 relays, 1 hosts line" "$(awk '{ print $1 }' "$ST" | sort | uniq -c | tr -s ' \n' ' ')" " 2 alias 1 hosts 4 relay "
hasnt "up: the alias that was there is not recorded" "$(cat "$ST")" "alias 192.168.101.128"
hasnt "up: no alias is left pending" "$(cat "$ST")" "pending"
eq "up: the relay source is valid Python" "$(python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read()); print("ok")' "$T/relay.src" 2>&1)" ok
eq "up: the state directory is the walker's only" "$(stat -c %a "$SD")" 700

# --- up twice: nothing is duplicated ----------------------------------------------------------
st1=$(cksum < "$ST"); h1=$(cksum < "$T/hosts"); l1=$(cat "$F/lo0"); s1=$(grep -c . "$F/sudo.log")
mr X=1 -- up "${A[@]}"
eq "up twice: exit 0" "$rc" 0
has "up twice: a relay is reported as already up" "$out" "mac-route: relay  192.168.100.50:443 -> 127.0.0.1:18443: already up"
has "up twice: its alias too" "$out" "mac-route: alias  192.168.100.50 on lo0: already up"
has "up twice: its name too" "$out" "mac-route: hosts  vcsa.env1.lab.test = 192.168.100.50: already up"
eq "up twice: the state file is unchanged" "$(cksum < "$ST")" "$st1"
eq "up twice: the hosts file is unchanged" "$(cksum < "$T/hosts")" "$h1"
eq "up twice: lo0 is unchanged" "$(cat "$F/lo0")" "$l1"
eq "up twice: no relay was started again" "$(grep -c . "$F/py.log")" 4
eq "up twice: sudo was not used to change anything" "$(sed -n "$((s1 + 1)),\$p" "$F/sudo.log" | grep -vx /usr/bin/true)" ""
mr FAKE_SUDO=no -- up "${A[@]}"
eq "up twice without sudo: nothing needs root, so it is not asked for" "$rc" 0

# --- a forward is added to a running set ------------------------------------------------------
pids1=$(relay_pids | tr '\n' ' ')
echo 18448 >> "$F/listening"
mr X=1 -- up "${A[@]}" --forward 192.168.101.148:8080:18448
eq "adding a forward: exit 0" "$rc" 0
has "adding a forward: only it is started" "$out" "mac-route: relay  192.168.101.148:8080 -> 127.0.0.1:18448: started, PID "
eq "adding a forward: one more relay" "$(grep -c . "$F/py.log")" 5
eq "adding a forward: the running relays keep their PIDs" "$(relay_pids | head -4 | tr '\n' ' ')" "$pids1"
mr X=1 -- up --forward 192.168.100.50:443:18446
has "another tunnel port for a running relay: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50:443 is already relayed to tunnel port 18443, not 18446. Take the old set down first: $MR down"

# --- status -----------------------------------------------------------------------------------
mr X=1 -- status
eq "status, all up: exit 0" "$rc" 0
has "status: an alias" "$out" "  alias    192.168.100.50 on lo0: present"
has "status: a relay with its PID" "$out" "  relay    192.168.101.128:6443 -> 127.0.0.1:18445: running, PID "
has "status: its tunnel port" "$out" "  tunnel   127.0.0.1:18445: listening"
has "status: a hosts line" "$out" "  hosts    $VCLINE: present"
has "status: an alias it did not add is a note, not a leftover" "$out" "  alias    192.168.101.128 on lo0 is not recorded: it was there before \`up\`, or something else added it."
has "status: the verdict" "$out" "mac-route: all of it is up. Undo it: $MR down"
echo '*18444' >> "$F/listening"
mr X=1 -- status
eq "status, a tunnel port open on every address: exit 1" "$rc" 1
has "status: warns about it" "$out" "  tunnel   WARNING, port 18444: it listens on EVERY address of this Mac, not on 127.0.0.1: anyone who reaches the Mac reaches the lab service (GatewayPorts"
grep -vxF '*18444' "$F/listening" > "$F/l.t"; mv "$F/l.t" "$F/listening"
p6443=$(awk '$1 == "relay" && $3 == 6443 { print $5 }' "$ST")
kill "$p6443"; gone "$p6443"
grep -vx 18443 "$F/listening" > "$F/l.t"; mv "$F/l.t" "$F/listening"
mr X=1 -- status
eq "status, a relay died and a tunnel closed: exit 1" "$rc" 1
has "status: the dead relay, with the reason" "$out" "  relay    192.168.101.128:6443 -> 127.0.0.1:18445: NOT RUNNING (no process has PID $p6443 any more)"
has "status: the closed tunnel" "$out" "  tunnel   127.0.0.1:18443: NOT LISTENING"
has "status: the owner's line for every recorded forward" "$out" "${OWNER% *} -R 127.0.0.1:18448:192.168.101.148:8080 $ME@203.0.113.7"
has "status: the verdict when not all is up" "$out" "mac-route: NOT all of it is up (see above)."
echo 18443 >> "$F/listening"
mr X=1 -- up "${A[@]}"
has "up again: the dead relay is started again" "$out" "mac-route: relay  192.168.101.128:6443 -> 127.0.0.1:18445: started, PID "
eq "up again: the state file has one record for it" "$(grep -c '^relay 192.168.101.128 6443 ' "$ST")" 1

# --- down: a reused PID is never killed -------------------------------------------------------
# (a) the PID now belongs to another program; (b) the same command line, another start time.
sleep 300 & other=$!; echo "$other" >> "$F/pids"
p8080=$(awk '$1 == "relay" && $3 == 8080 { print $5 }' "$ST")
p443=$(awk '$1 == "relay" && $2 == "192.168.101.130" { print $5 }' "$ST")
pvc=$(awk '$1 == "relay" && $2 == "192.168.100.50" { print $5 }' "$ST")
awk -v o="$other" -v p="$p443" '$1 == "relay" && $3 == 8080 { $5 = o }
  $1 == "relay" && $5 == p { print $1, $2, $3, $4, $5, $6, "Thu Jan 1 00:00:00 1970"; next } { print }' "$ST" > "$ST.t"
# awk rebuilt the relay rows with single spaces; the hosts row must keep its TABs
grep '^hosts ' "$ST" > "$ST.h"; grep -v '^hosts ' "$ST.t" > "$ST"; cat "$ST.h" >> "$ST"; rm -f "$ST.t" "$ST.h"
# a marked line this script has no record of: it is not this run's to remove
printf '10.9.9.9\tsomeone.else.test\t%s\n' "$MARK" >> "$T/hosts"; cp "$T/hosts.orig" "$T/hosts.want"; printf '10.9.9.9\tsomeone.else.test\t%s\n' "$MARK" >> "$T/hosts.want"
: > "$F/sudo.log"
mr X=1 -- down
has "down: a PID that is another program now is not killed, with the reason" "$out" "mac-route: relay  192.168.101.148:8080: nothing killed: PID $other is another program now (sleep 300)"
alive "$other" && ok "down: … and that program is still running" || bad "down: … and that program is still running" "PID $other is gone"
has "down: a PID with another start time is not killed, with the reason" "$out" "mac-route: relay  192.168.101.130:443: nothing killed: PID $p443 was started at another time than the relay (the PID was reused)"
alive "$p443" && ok "down: … and that process is still running" || bad "down: … and that process is still running" "PID $p443 is gone"
hasnt "down: sudo was not asked to kill either" "$(cat "$F/sudo.log")" "kill $p443"

# --- down removes exactly its own -------------------------------------------------------------
has "down: its relay is stopped by PID" "$out" "mac-route: relay  192.168.100.50:443: stopped (PID $pvc)"
has "down: a root relay is stopped through sudo -n, by absolute path" "$(cat "$F/sudo.log")" "$B/kill $pvc"
alive "$pvc" && bad "down: the relay process is gone" "PID $pvc lives" || ok "down: the relay process is gone"
has "down: its alias is removed" "$out" "mac-route: alias  192.168.100.50 on lo0: removed"
eq "down: the alias that was there before survives, and only it" "$(cat "$F/lo0")" 192.168.101.128
has "down: its hosts line is removed" "$out" "mac-route: hosts  $VCLINE: removed from $T/hosts"
cmp -s "$T/hosts" "$T/hosts.want" && ok "down: the hosts file lost its one line only: the unmarked lines AND the marked line it has no record of stay" || bad "down: the hosts file lost its one line only" "$(diff "$T/hosts.want" "$T/hosts")"
eq "down: the hosts file keeps its mode" "$(stat -c %a "$T/hosts")" 644
eq "down: everything sudo ran was an absolute path" "$(grep -v '^/' "$F/sudo.log")" ""
has "down: the backup is kept while a marked line is still in the hosts file" "$out" "mac-route: hosts  the backup $SD/hosts.backup is KEPT: 1 line(s) ending in '$MARK' are still in $T/hosts"
cmp -s "$SD/hosts.backup" "$T/hosts.orig" && ok "down: … and it still holds the original" || bad "down: … and it still holds the original" "differs or gone"
has "down: the verdict then" "$out" "mac-route: down: everything this script recorded is removed; $SD stays because of the hosts backup (above)."
has "down: the relays it did not dare to kill are shown as leftovers" "$out" "  relay    PID $p443: "
has "down: … with the command for each" "$out" "           remove by hand: sudo kill $p443"
has "down: the tunnels stay the owner's" "$out" "mac-route: the tunnels are the owner's: he ends his ssh on the lab host."
eq "down: exit 0" "$rc" 0
[ ! -e "$SD/lock" ] && [ ! -e "$ST" ] && ok "down: no lock and no state file are left" || bad "down: no lock and no state file are left" "$(ls -a "$SD")"

# --- down twice -------------------------------------------------------------------------------
kill "$p443" "$p8080" 2>/dev/null; gone "$p443"; gone "$p8080"
: > "$F/sudo.log"
mr X=1 -- down
eq "down twice: exit 0" "$rc" 0
has "down twice: says there is nothing" "$out" "mac-route: nothing to remove: no state file ($ST)."
eq "down twice: lo0 is untouched" "$(cat "$F/lo0")" 192.168.101.128
cmp -s "$T/hosts" "$T/hosts.want" && ok "down twice: the hosts file is untouched" || bad "down twice: the hosts file is untouched" "changed"
eq "down twice: sudo ran nothing" "$(grep -vx /usr/bin/true "$F/sudo.log")" ""
[ -f "$SD/hosts.backup" ] && ok "down twice: the backup is still kept" || bad "down twice: the backup is still kept" "gone"
cp "$T/hosts.orig" "$T/hosts"
mr X=1 -- down
[ ! -e "$SD" ] && ok "down once the hosts file is clean: the backup and the state directory go" || bad "down once the hosts file is clean: the backup and the state directory go" "$(ls -a "$SD")"
mr X=1 -- status
has "status after down: nothing up, no leftovers" "$rc $out" "mac-route: no leftovers found."

# --- a clean down, and down refusing before any change when sudo would prompt -----------------
mr X=1 -- up "${A[@]}"
st1=$(cksum < "$ST")
mr FAKE_SUDO=no -- down
has "down, sudo not cached: refused before any change" "$rc $out" "2 mac-route: refused: sudo would ask for a password, and nothing was changed."
eq "down, sudo not cached: the state file is unchanged" "$(cksum < "$ST")" "$st1"
eq "down, sudo not cached: the relays still run" "$(relay_pids | while read -r p; do alive "$p" && echo y; done | grep -c y)" 4
[ ! -e "$SD/lock" ] && ok "down, sudo not cached: the lock is released" || bad "down, sudo not cached: the lock is released" "held"
mr X=1 -- down
eq "clean down: exit 0" "$rc" 0
has "clean down: the verdict" "$out" "mac-route: down: everything this script created is removed, its state directory too."
cmp -s "$T/hosts" "$T/hosts.orig" && ok "clean down: the hosts file is the original again" || bad "clean down: the hosts file is the original again" "$(diff "$T/hosts.orig" "$T/hosts")"
[ ! -e "$SD" ] && ok "clean down: the state directory is gone" || bad "clean down: the state directory is gone" "$(ls -a "$SD")"

# --- the state file is not trusted: every value read back is checked --------------------------
reset_fakes
mr X=1 -- up "${A[@]}"
rootpids=$(awk '$1 == "relay" && $6 == "root" { print $5 }' "$ST" | sort | tr '\n' ' ')
sleep 300 & victim=$!; echo "$victim" >> "$F/pids"
{
  echo "alias 127.0.0.1"
  echo "alias 8.8.8.8"
  echo "alias 192.168.101.128 -alias 10.0.0.1"
  echo "relay 192.168.100.50 443 18443 1 root Sat Oct 10 10:00:00 2026"
  echo "relay 192.168.100.50 443 18443 $victim;id root Sat Oct 10 10:00:00 2026"
  echo "relay 192.168.100.50 443 18443 $victim admin Sat Oct 10 10:00:00 2026"
  echo "relay 192.168.100.50 0 18443 $victim root Sat Oct 10 10:00:00 2026"
  echo "relay 192.168.100.50 443 18443 $victim root \$(id)"
  printf 'hosts 192.168.101.131\tregistry.lab.test\n'
  printf 'hosts 127.0.0.1\tlocalhost\t%s\n' "$MARK"
  printf 'hosts 192.168.101.131\tbad_name\t%s\n' "$MARK"
  echo "hosts 192.168.101.130 harbor.env1.lab.test"
  echo "rm -rf /"
} > "$T/bad"
cat "$T/bad" >> "$ST"
echo 127.0.0.1 >> "$F/lo0.never"
: > "$F/sudo.log"
mr X=1 -- status
eq "tampered state: status exits 1" "$rc" 1
has "tampered state: status names a line it will not act on" "$out" "mac-route: state  LEFT ALONE, nothing is done for this line of $ST: 'alias 127.0.0.1' (127.0.0.1: a loopback address"
mr X=1 -- up "${A[@]}"
eq "tampered state: up exits 2" "$rc" 2
has "tampered state: up refuses" "$out" "mac-route: refused: $ST holds line(s) this script did not write (above). Nothing was changed."
mr X=1 -- down
eq "tampered state: down exits 1" "$rc" 1
while IFS='|' read -r line why; do
  has "tampered state: '$line' is left alone, with the reason" "$out" "LEFT ALONE, nothing is done for this line of $ST: '$line' ($why"
done <<EOF
alias 127.0.0.1|127.0.0.1: a loopback address
alias 8.8.8.8|8.8.8.8: not a private address
alias 192.168.101.128 -alias 10.0.0.1|it is not 'alias <ip>' or 'alias <ip> pending'
relay 192.168.100.50 443 18443 1 root Sat Oct 10 10:00:00 2026|'1' is not a PID
relay 192.168.100.50 443 18443 $victim;id root Sat Oct 10 10:00:00 2026|'$victim;id' is not a PID
relay 192.168.100.50 443 18443 $victim admin Sat Oct 10 10:00:00 2026|'admin' is neither user nor root
relay 192.168.100.50 0 18443 $victim root Sat Oct 10 10:00:00 2026|'0' is not a port
relay 192.168.100.50 443 18443 $victim root \$(id)|its start time is not a time
hosts 192.168.101.131${TAB}registry.lab.test|it is not '<ip> <name> $MARK', TAB-separated: without the marker a line is not this script's
hosts 127.0.0.1${TAB}localhost${TAB}$MARK|127.0.0.1: a loopback address
hosts 192.168.101.131${TAB}bad_name${TAB}$MARK|'bad_name' is not a host name
hosts 192.168.101.130 harbor.env1.lab.test|192.168.101.130 harbor.env1.lab.test: not an IPv4 address
rm -rf /|not a line this script writes
EOF
hasnt "tampered state: root was not asked to remove 127.0.0.1 from lo0" "$(cat "$F/sudo.log")" "127.0.0.1"
hasnt "tampered state: root was not asked to remove an alias from a crafted line" "$(cat "$F/sudo.log")" "10.0.0.1"
eq "tampered state: root killed its own three relays and nothing else" "$(grep "^$B/kill " "$F/sudo.log" | awk '{ print $2 }' | sort | tr '\n' ' ')" "$rootpids"
alive "$victim" && ok "tampered state: the process a crafted line named is still running" || bad "tampered state: the process a crafted line named is still running" "gone"
cmp -s "$T/hosts" "$T/hosts.orig" && ok "tampered state: only its own marked line left the hosts file; the unmarked lines a crafted record named stay" || bad "tampered state: the hosts file" "$(diff "$T/hosts.orig" "$T/hosts")"
eq "tampered state: the alias that was there before stays" "$(cat "$F/lo0")" 192.168.101.128
cmp -s "$ST" "$T/bad" && ok "tampered state: the state file keeps exactly the lines that were left alone" || bad "tampered state: the state file keeps exactly the lines that were left alone" "$(cat "$ST")"
has "tampered state: the verdict" "$out" "mac-route: NOT everything was removed. What is left is still recorded in $ST:"
[ -f "$SD/hosts.backup" ] && ok "tampered state: the backup is kept" || bad "tampered state: the backup is kept" "gone"
kill "$victim"

# --- an interrupted up: the alias is recorded before it is added ------------------------------
reset_fakes
mr FAKE_IFCONFIG_CRASH=1 -- up "${ONE[@]}"
eq "up killed right after ifconfig: the alias is on lo0" "$(tail -1 "$F/lo0")" 192.168.100.50
eq "up killed right after ifconfig: the state file already records it, as pending" "$(cat "$ST")" "alias 192.168.100.50 pending"
mr X=1 -- status
has "status: a killed run's lock is shown as stale" "$rc $out" "1 mac-route: recorded in $ST:"
has "status: the pending alias" "$out" "  alias    192.168.100.50 on lo0: PENDING (an \`up\` was interrupted while adding it); it is present"
mr X=1 -- down
has "down after a killed up: the stale lock is named with how to clear it" "$rc $out" "which is not running any more (a run was killed). Nothing was changed. Clear it, then run this again: rm -r $SD/lock"
rm -r "$SD/lock"
mr X=1 -- down
eq "down after a killed up: exit 0" "$rc" 0
has "down after a killed up: the pending alias is removed" "$out" "mac-route: alias  192.168.100.50 on lo0: removed"
eq "down after a killed up: lo0 is as before" "$(cat "$F/lo0")" 192.168.101.128
[ ! -e "$SD" ] && ok "down after a killed up: the state directory is gone" || bad "down after a killed up: the state directory is gone" "$(ls -a "$SD")"
mr FAKE_IFCONFIG_CRASH=1 -- up "${ONE[@]}"
rm -r "$SD/lock"
mr X=1 -- up "${ONE[@]}"
eq "up after a killed up: exit 0" "$rc" 0
has "up after a killed up: finishes the pending alias" "$out" "mac-route: alias  192.168.100.50 on lo0: an earlier \`up\` was interrupted while adding it; finishing"
eq "up after a killed up: the alias is recorded once, not pending" "$(grep -c '^alias' "$ST") $(grep '^alias' "$ST")" "1 alias 192.168.100.50"
mr X=1 -- down

# --- the hosts file is never left short -------------------------------------------------------
all_orig_lines() {   # every line of the original is still in the hosts file
  local l
  while IFS= read -r l; do grep -qxF -- "$l" "$T/hosts" || return 1; done < "$T/hosts.orig"
}
reset_fakes
mr FAKE_AWK=dead -- up "${A[@]}"
all_orig_lines && ok "awk failing: the hosts file keeps every original line" || bad "awk failing: the hosts file keeps every original line" "$(cat "$T/hosts")"
[ "$rc" -ne 0 ] && ok "awk failing: up does not report success" || bad "awk failing: up does not report success" "rc 0: $out"
mr X=1 -- down

reset_fakes
mr X=1 -- up "${A[@]}"
cp "$T/hosts" "$T/hosts.up"; st1=$(cksum < "$ST")
while IFS='|' read -r mode why; do
  : > "$F/sudo.log"
  mr FAKE_GREP="$mode" -- down
  has "building the new hosts file goes wrong ($mode): says so, the file is not changed" "$out" "mac-route: hosts  $why; $T/hosts was NOT changed"
  cmp -s "$T/hosts" "$T/hosts.up" && ok "($mode): the hosts file is untouched" || bad "($mode): the hosts file is untouched" "$(cat "$T/hosts")"
  hasnt "($mode): root copied nothing" "$(cat "$F/sudo.log")" "/cp "
  has "($mode): the line stays recorded" "$(cat "$ST")" "hosts $VCLINE"
  eq "($mode): down exits 1" "$rc" 1
  mr X=1 -- up "${A[@]}"
done <<EOF
dead-build|cannot build the new file (grep ended with 2)
empty-build|the new file is EMPTY
short-build|the new file has 1 line(s); 5 - 1 dropped + 0 added were expected
EOF
mr X=1 -- down
eq "after those: a clean down" "$rc" 0

reset_fakes
mr FAKE_CP=fail -- up "${A[@]}"
eq "cp fails without touching the file: up exits 1" "$rc" 1
has "cp fails without touching the file: says the file was not changed" "$out" "mac-route: hosts  the copy to $T/hosts failed; $T/hosts was NOT changed"
cmp -s "$T/hosts" "$T/hosts.orig" && ok "cp fails: the hosts file is as before" || bad "cp fails: the hosts file is as before" "$(cat "$T/hosts")"
hasnt "cp fails: no hosts line stays recorded" "$(cat "$ST")" "hosts "
mr X=1 -- down

reset_fakes
mr FAKE_CP=truncate-once -- up "${A[@]}"
eq "cp returns 0 but leaves the file empty: up exits 1" "$rc" 1
has "cp returns 0 but leaves the file empty: noticed by the compare" "$out" "mac-route: hosts  !!! THE COPY TO $T/hosts WENT WRONG: it does not hold what was written. Putting back what it held before this run."
has "… and the restore is reported" "$out" "mac-route: hosts  RESTORED: $T/hosts is exactly as it was before this run."
cmp -s "$T/hosts" "$T/hosts.orig" && ok "… and the hosts file is the original again" || bad "… and the hosts file is the original again" "$(cat "$T/hosts")"
hasnt "… and no hosts line stays recorded" "$(cat "$ST")" "hosts "
mr X=1 -- down
eq "… and down afterwards is clean" "$rc" 0

reset_fakes
mr FAKE_CP=truncate-fail -- up "${A[@]}"
eq "cp empties the file and fails, twice: up exits 1" "$rc" 1
snap=$(find "$SD" -name 'hosts.snap.*')
has "cp empties the file and fails, twice: says loudly that the file is damaged" "$out" "mac-route: hosts  !!! $T/hosts IS DAMAGED AND COULD NOT BE RESTORED. What it held before this run is kept in $snap"
has "… with the command that puts it back" "$out" "mac-route: hosts  !!! put it back by hand, now: sudo cp $snap $T/hosts"
cmp -s "$snap" "$T/hosts.orig" && ok "… and that file holds the original" || bad "… and that file holds the original" "differs"
eq "(the stand-in did leave the hosts file empty)" "$(wc -c < "$T/hosts" | tr -d ' ')" 0
DMG1="mac-route: hosts  !!! A RUN COULD NOT FINISH WRITING $T/hosts AND COULD NOT RESTORE IT. What it held before that run is kept in $snap"
DMG2="mac-route: hosts  !!! the hosts file from before this script's first change is kept in $SD/hosts.backup"
DMG3="mac-route: hosts  !!! look at the difference (diff $snap $T/hosts), put it back (sudo cp $snap $T/hosts), then delete that copy (rm $snap) and run: $MR down"
mr X=1 -- status
eq "status while the hosts file is damaged: exit 1" "$rc" 1
has "status while damaged: names the copy from before the failed run" "$out" "$DMG1"
has "status while damaged: names the backup" "$out" "$DMG2"
has "status while damaged: the sudo cp that puts it back" "$out" "$DMG3"
mr X=1 -- down
eq "down while the hosts file is damaged: exit 1" "$rc" 1
has "down while damaged: names the copy from before the failed run" "$out" "$DMG1"
has "down while damaged: names the backup" "$out" "$DMG2"
has "down while damaged: the sudo cp that puts it back" "$out" "$DMG3"
has "down after a damaged hosts file: the backup is KEPT" "$out" "mac-route: hosts  the backup $SD/hosts.backup is KEPT: a run could not finish writing $T/hosts, and what it held before is in $snap"
cmp -s "$SD/hosts.backup" "$T/hosts.orig" && ok "… the backup still holds the original" || bad "… the backup still holds the original" "differs or gone"
cmp -s "$snap" "$T/hosts.orig" && ok "… and so does the copy from before the failed run" || bad "… and so does the copy from before the failed run" "differs or gone"
eq "… while its aliases and relays are removed" "$(cat "$F/lo0")" 192.168.101.128
mr X=1 -- down
[ -f "$SD/hosts.backup" ] && ok "… and a second down keeps it too" || bad "… and a second down keeps it too" "gone"
eq "… and a second down (no state file left) still exits 1" "$rc" 1
has "… and still says how to put the file back" "$out" "$DMG3"
mr X=1 -- status
eq "… and status (no state file left) still exits 1" "$rc" 1
has "… and still names the copy" "$out" "$DMG1"
cp "$snap" "$T/hosts"; rm "$snap"
mr X=1 -- down
eq "… once the file is put back and that copy deleted: down exits 0" "$rc" 0
[ ! -e "$SD" ] && ok "… until the file is put back and that copy deleted: then the state directory goes" || bad "… then the state directory goes" "$(ls -a "$SD")"

# --- the state file is never left short -------------------------------------------------------
reset_fakes
mkdir -p "$SD/state.tmp"; chmod 700 "$SD"
mr X=1 -- up --forward 192.168.101.128:6443:18445
eq "state file cannot be written: up exits 1" "$rc" 1
has "a relay that started but could not be recorded is stopped again" "$out" "COULD NOT START: it started (PID "
has "… and says so" "$out" ") but could not be recorded in $ST, so it was stopped again"
rp=$(tail -1 "$F/pids")
gone "$rp" && ok "… and that process is gone" || bad "… and that process is gone" "PID $rp lives"
[ ! -s "$ST" ] && ok "… and the state file records nothing" || bad "… and the state file records nothing" "$(cat "$ST")"
mr X=1 -- up --forward 192.168.100.50:443:18443
has "an alias that cannot be recorded first is not added" "$out" "mac-route: alias  192.168.100.50 on lo0: NOT ADDED, it could not be recorded in $ST first"
eq "… lo0 is as before" "$(cat "$F/lo0")" 192.168.101.128
rmdir "$SD/state.tmp"
mr X=1 -- up "${A[@]}"
st1=$(cksum < "$ST"); mkdir "$SD/state.tmp"
mr X=1 -- down
eq "state file cannot be written: down exits 1" "$rc" 1
eq "… and the state file is not replaced by a shorter one" "$(cksum < "$ST")" "$st1"
has "… and says what it could not write" "$out" "removed from $T/hosts, but $ST could not be written"
rmdir "$SD/state.tmp"
mr X=1 -- down
eq "… and a later down finishes" "$rc" 0
[ ! -e "$SD" ] && ok "… and the state directory is gone" || bad "… and the state directory is gone" "$(ls -a "$SD")"

# --- status with leftovers and no state file --------------------------------------------------
reset_fakes
printf '%s\n' "$VCLINE" >> "$T/hosts"
lp=$(env FAKE="$F" "$T/fakepy" -I - --tag vks-mac-route --listen 192.168.100.50:443 --connect 127.0.0.1:18443 --log "$SD/relay-192.168.100.50-443.log" </dev/null)
echo 10.7.7.7 >> "$F/lo0"
mr X=1 -- status
eq "leftovers without a state file: exit 1" "$rc" 1
has "leftovers: says there is no state file" "$out" "mac-route: no state file ($ST): this script has nothing up."
has "leftovers: the heading" "$out" "mac-route: LEFTOVERS that the state file does not record:"
has "leftovers: the relay and its command" "$out" "           remove by hand: sudo kill $lp"
has "leftovers: the marked hosts line" "$out" "  hosts    $VCLINE"
has "leftovers: its command" "$out" "           remove by hand: grep -v '$MARK\$' $T/hosts > ~/hosts.new && sudo cp ~/hosts.new $T/hosts && rm ~/hosts.new"
has "leftovers: a private alias nobody recorded, with its command" "$out" "           only if it is a leftover of an earlier walk: sudo ifconfig lo0 -alias 10.7.7.7"
mr X=1 -- down
eq "down without a state file leaves leftovers alone: exit 0" "$rc" 0
alive "$lp" && ok "down without a state file: the unrecorded relay is not killed" || bad "down without a state file: the unrecorded relay is not killed" "gone"
has "down without a state file: the marked line it has no record of stays" "$(cat "$T/hosts")" "$VCLINE"
kill "$lp"

# --- its own marked line with another address is replaced; a failed relay is reported --------
reset_fakes
printf '10.1.1.1\tvcsa.env1.lab.test\t%s\n' "$MARK" >> "$T/hosts"
mr X=1 -- up "${A[@]}"
eq "own stale line: exit 0" "$rc" 0
hasnt "own stale line: the old address is gone" "$(cat "$T/hosts")" "10.1.1.1"
eq "own stale line: one line for the name" "$(grep -c 'vcsa.env1.lab.test' "$T/hosts")" 1
mr X=1 -- down
reset_fakes
mr FAKE_PY_FAIL=1 -- up "${ONE[@]}"
eq "relay cannot start: exit 1" "$rc" 1
has "relay cannot start: the relay's own reason" "$out" "mac-route: relay  192.168.100.50:443 -> 127.0.0.1:18443: COULD NOT START: relay: cannot listen on 192.168.100.50:443: [Errno 48] Address already in use"
has "relay cannot start: says the rest is recorded" "$out" "NOT fully up (see above). What was created is recorded; undo it: $MR down"
mr X=1 -- down
eq "relay cannot start: down removes the alias it had added" "$(cat "$F/lo0")" 192.168.101.128
reset_fakes
mr FAKE_IFCONFIG_FAIL=1 -- up "${ONE[@]}"
has "alias cannot be added: says so with the command" "$rc $out" "COULD NOT BE ADDED. By hand: sudo ifconfig lo0 alias 192.168.100.50 netmask 255.255.255.255"
eq "alias cannot be added: no relay is started on it" "$(cat "$F/py.log")" ""
eq "alias cannot be added: nothing stays recorded" "$(cat "$ST")" ""

# --- print-tunnel and --file ------------------------------------------------------------------
cat > "$T/forwards" <<'EOF'
# the lab, as `make creds` prints it
192.168.100.50:443:18443     # vCenter
192.168.101.128:443:18444
192.168.101.128:6443:18445

192.168.101.130:443:18446
vcsa.env1.lab.test = 192.168.100.50
harbor.env1.lab.test=192.168.101.130
EOF
mr FAKE_UNAME=Linux -- print-tunnel --file "$T/forwards"
eq "print-tunnel --file: the owner's line, on any system" "$rc $out" "0 $OWNER"
mr FAKE_UNAME=Linux -- print-tunnel --file "$T/forwards" --mac m1@mac.example
eq "print-tunnel --mac: the given target" "$out" "${OWNER% *} m1@mac.example"
mr SSH_CONNECTION="198.51.100.4 50123 203.0.113.7 2222" -- print-tunnel --forward 10.0.0.1:443:18443
eq "print-tunnel: another ssh port is passed on" "$out" "ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:10.0.0.1:443 -p 2222 $ME@203.0.113.7"
mr SSH_CONNECTION= -- print-tunnel --forward 10.0.0.1:443:18443
has "print-tunnel: an unknown Mac address is asked for" "$out" "give it with --mac <user>@<address>"
for crafted in '198.51.100.4 50123 203.0.113.7;reboot 22' '198.51.100.4 50123 $(reboot) 22' '198.51.100.4 50123 203.0.113.7 22;reboot' '198.51.100.4 50123 -oProxyCommand=x 22'; do
  mr SSH_CONNECTION="$crafted" -- print-tunnel --forward 10.0.0.1:443:18443
  eq "print-tunnel: a crafted SSH_CONNECTION ($crafted) does not reach the printed line" "$(sed -n 1p <<<"$out")" "ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:10.0.0.1:443 <user>@<this Mac's address>"
done
mr X=1 -- print-tunnel --forward 10.0.0.1:443:18443 --mac 'm1@host;reboot'
has "print-tunnel: a crafted --mac is refused" "$rc $out" "2 mac-route: --mac 'm1@host;reboot': expected <user>@<address>"
reset_fakes
mr X=1 -- up --file "$T/forwards"
eq "up --file: exit 0" "$rc" 0
eq "up --file: four relays" "$(grep -c . "$F/py.log")" 4
mr X=1 -- print-tunnel
eq "print-tunnel without a list: the recorded forwards" "$out" "$OWNER"
mr X=1 -- down
eq "down after up --file: exit 0" "$rc" 0
reset_fakes

# --- the real relay, on 127.0.0.1 -------------------------------------------------------------
# Everything but the bind to an lo0 alias and the drop from root: start (it goes to the
# background and prints its PID), bytes out, the end of the client's data passed on
# (half-close), bytes back, the log, the limits, stop.
R=$T/real; mkdir -p "$R"
SRC=$T/relay.src
# rr <label> <arguments…>: start a relay; sets out and rc; a PID it printed is remembered for cleanup
rr() {
  out=$(python3 -I - --tag vks-mac-route "$@" < "$SRC" 2>&1); rc=$?
  case $out in '' | *[!0-9]*) ;; *) echo "$out" >> "$F/pids" ;; esac
}
python3 - "$R/server.port" <<'PY' &
import os, socket, sys, threading
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".t", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".t", sys.argv[1])
def one(c):
    data = b""
    while True:
        d = c.recv(4096)
        if not d:
            break
        data += d
    c.sendall(b"got:" + data[::-1]); c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=one, args=(c,), daemon=True).start()
PY
srv=$!; echo "$srv" >> "$F/pids"
i=0; while [ ! -s "$R/server.port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sp=$(cat "$R/server.port" 2>/dev/null)
freeport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
lp=$(freeport)
rr --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/relay.log"
rpid=$out
case $rpid in '' | *[!0-9]*) bad "real relay: starts and prints its PID" "got '$rpid'"; rpid="" ;; *) ok "real relay: starts and prints its PID" ;; esac
if [ -n "$rpid" ]; then
  has "real relay: the PID it printed is the relay, and its command line carries the tag" "$(ps -ww -o command= -p "$rpid")" " -I - --tag vks-mac-route --listen 127.0.0.1:$lp "
  eq "real relay: its log is the walker's only" "$(stat -c %a "$R/relay.log")" 600
  reply=$(python3 - "$lp" <<'PY'
import socket, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5)
c.settimeout(5)
c.sendall(b"ping-1234"); c.shutdown(socket.SHUT_WR)
data = b""
while True:
    d = c.recv(4096)
    if not d:
        break
    data += d
print(data.decode())
PY
)
  eq "real relay: bytes go out, the end of the data is passed on, the answer comes back" "$reply" "got:4321-gnip"
  i=0; while ! grep -q 'closed' "$R/relay.log" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  has "real relay: logs what it listens on and its limits" "$(cat "$R/relay.log")" "listening on 127.0.0.1:$lp, connecting to 127.0.0.1:$sp, pid $rpid, uid $(id -u), at most 64 connections, idle limit 1800 s"
  has "real relay: logs the byte counts, not the bytes" "$(cat "$R/relay.log")" "closed: 9 bytes out, 13 bytes back"
  hasnt "real relay: no payload in the log" "$(cat "$R/relay.log")" "ping"
  rr --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/relay2.log"
  has "real relay: a taken port is reported by the command itself" "$rc $out" "1 relay: cannot listen on 127.0.0.1:$lp: "
  kill "$rpid"
  gone "$rpid" && ok "real relay: stops on SIGTERM" || bad "real relay: stops on SIGTERM" "PID $rpid lives"
  has "real relay: logs the stop" "$(tail -1 "$R/relay.log")" "stopped"
fi
# a tunnel that does not answer
lp=$(freeport); dead=$(freeport)
rr --listen "127.0.0.1:$lp" --connect "127.0.0.1:$dead" --log "$R/dead.log"; rpid=$out
python3 -c 'import socket, sys; c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5); c.settimeout(5); c.recv(1)' "$lp" 2>/dev/null
i=0; while ! grep -q 'refused' "$R/dead.log" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
has "real relay: a tunnel that does not answer is logged" "$(cat "$R/dead.log")" "refused: cannot connect to 127.0.0.1:$dead"
alive "$rpid" && ok "real relay: … and the relay stays up" || bad "real relay: … and the relay stays up" "gone"
kill "$rpid" 2>/dev/null
# the limits: one connection at most, closed after 1 s without data
lp=$(freeport)
rr --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/limit.log" --max 1 --idle 1; rpid=$out
limits=$(python3 - "$lp" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
a = socket.create_connection(("127.0.0.1", port), 5); a.settimeout(5)
a.sendall(b"x"); time.sleep(0.3)
b = socket.create_connection(("127.0.0.1", port), 5); b.settimeout(5)
print("second:", "turned away" if b.recv(1) == b"" else "served")
t = time.time()
print("first:", "closed" if a.recv(1) == b"" else "data", "after about", round(time.time() - t), "s")
PY
)
eq "real relay: more connections than --max are turned away; an idle one is closed" "$limits" "second: turned away
first: closed after about 1 s"
i=0; while ! grep -q 'without data' "$R/limit.log" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
has "real relay: logs the connection it turned away" "$(cat "$R/limit.log")" "turned away: 1 connection(s) are open already"
has "real relay: logs the idle close" "$(cat "$R/limit.log")" "(closed after 1 s without data)"
alive "$rpid" && ok "real relay: still running after both" || bad "real relay: still running after both" "gone"
kill "$rpid" 2>/dev/null
# what it refuses to bind, and where it refuses to log
for every in 0.0.0.0 0 '::' '' '*' 0.0 00.0.0.0 0x0; do
  rr --listen "$every:$lp" --connect "127.0.0.1:$sp" --log "$R/every.log"
  case "$rc $out" in "1 relay: refusing to listen on"* | "1 relay: ':$lp' is not IP:PORT") ok "real relay: refuses to listen on '$every'" ;; *) bad "real relay: refuses to listen on '$every'" "$rc $out" ;; esac
done
ln -s "$R/target.log" "$R/link.log"
lp=$(freeport)
rr --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/link.log"
has "real relay: a log path that is a symbolic link is refused" "$rc $out" "1 relay: cannot open the log $R/link.log: "
[ ! -e "$R/target.log" ] && ok "real relay: … and nothing was written through it" || bad "real relay: … and nothing was written through it" "exists"

# The drop from root cannot run here (no root). Its logic is run with the system calls
# replaced: what it calls, in which order, and that it never goes on as root.
droptest=$(python3 - "$SRC" <<'PY'
import os, sys, types
src = open(sys.argv[1]).read()
m = types.ModuleType("relay"); exec(compile(src, "relay", "exec"), m.__dict__)

class FakeOS:
    def __init__(self, euid, env, fail=None, stay_root=False):
        self.calls = []; self.uid = euid; self.environ = env; self.fail = fail; self.stay_root = stay_root
    def geteuid(self): return self.uid
    def getuid(self): return self.uid
    def _do(self, name, arg):
        if self.fail == name: raise PermissionError(1, "Operation not permitted")
        self.calls.append((name, arg))
    def setgroups(self, g): self._do("setgroups", g)
    def setgid(self, g): self._do("setgid", g)
    def setuid(self, u):
        self._do("setuid", u)
        if not self.stay_root: self.uid = u
    def __getattr__(self, name): return getattr(os, name)

def run(label, fake):
    m.os = fake
    try:
        m.drop_root(); print(label, "->", fake.calls, "uid", fake.uid)
    except SystemExit as e:
        print(label, "->", str(e).split(":")[1].strip(), "| calls", fake.calls)
    m.os = os

env = {"SUDO_UID": "501", "SUDO_GID": "20"}
run("not root", FakeOS(1000, {}))
run("root via sudo", FakeOS(0, env))
run("root, no SUDO_UID", FakeOS(0, {}))
run("root, SUDO_UID is 0", FakeOS(0, {"SUDO_UID": "0", "SUDO_GID": "0"}))
run("root, setgroups denied", FakeOS(0, env, fail="setgroups"))
run("root, setuid denied", FakeOS(0, env, fail="setuid"))
run("root, setuid has no effect", FakeOS(0, env, stay_root=True))
body = src[src.index("def main("):]
print("order in main:", body.index("server.bind(") < body.index("drop_root()") < body.index("open_log(") < body.index("os.fork()"))
m.LOG_FD = -1; m.log("a log that cannot be written"); print("log failure: survived")
PY
)
eq "relay: the drop from root — what it calls, in order, and that it never goes on as root" "$droptest" "not root -> [] uid 1000
root via sudo -> [('setgroups', [20]), ('setgid', 20), ('setuid', 501)] uid 501
root, no SUDO_UID -> refusing to continue as root | calls []
root, SUDO_UID is 0 -> refusing to continue as root | calls []
root, setgroups denied -> refusing to continue as root | calls []
root, setuid denied -> refusing to continue as root | calls [('setgroups', [20]), ('setgid', 20)]
root, setuid has no effect -> refusing to continue as root | calls [('setgroups', [20]), ('setgid', 20), ('setuid', 501)]
order in main: True
log failure: survived"

if [ "$fails" -eq 0 ]; then echo "mac-route.sh tests: all $checks checks passed"; else echo "mac-route.sh tests: $fails of $checks FAILED"; exit 1; fi
