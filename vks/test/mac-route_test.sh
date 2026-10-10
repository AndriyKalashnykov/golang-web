#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # fixtures are text in single quotes; `A && ok || bad` only prints
# Tests for mac-route.sh (run by `make scripts-test`). They run on Linux: `uname`, `ifconfig`,
# `sudo`, `lsof` and the relay's interpreter are stand-ins, the hosts file is a scratch file, and
# `ps`, `kill`, `cp` are the real ones (a relay stand-in is a real process, so the PID, start
# time and command line checks are real). The relay itself is then run once for real, on
# 127.0.0.1. Not reachable here: a bind to an lo0 alias, macOS's own ifconfig, sudo and lsof.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MR=$HERE/mac-route.sh
T=$(mktemp -d)
F=$T/fake
mkdir -p "$T/bin" "$T/home" "$F"
: > "$F/pids"
cleanup() {
  local p
  while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$F/pids"
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

# --- the stand-ins ----------------------------------------------------------------------------
cat > "$T/bin/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
EOF
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/sh
f=$FAKE/lo0
case "$*" in
  lo0)
    echo "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384"
    echo "	inet 127.0.0.1 netmask 0xff000000"
    while read -r ip; do echo "	inet $ip netmask 0xffffffff"; done < "$f" ;;
  "lo0 alias "*) [ -n "${FAKE_IFCONFIG_FAIL:-}" ] && exit 1; echo "$3" >> "$f" ;;
  "lo0 -alias "*) grep -vxF -- "$3" "$f" > "$f.t"; mv "$f.t" "$f" ;;
  *) echo "ifconfig stand-in: unexpected '$*'" >&2; exit 64 ;;
esac
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/bin/sh
[ "${FAKE_SUDO:-yes}" = yes ] || { echo "sudo: a password is required" >&2; exit 1; }
[ "$1" = -n ] || { echo "sudo stand-in: called without -n: $*" >> "$FAKE/sudo.log"; exit 64; }
shift
echo "$*" >> "$FAKE/sudo.log"
exec "$@"
EOF
cat > "$T/bin/lsof" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case $a in -iTCP@127.0.0.1:*) port=${a##*:} ;; esac
done
grep -qxF -- "${port:-none}" "$FAKE/listening" || exit 1
echo "sshd 4242 m1 9u IPv4 0x0 0t0 TCP 127.0.0.1:$port (LISTEN)"
EOF
cat > "$T/bin/xcode-select" <<'EOF'
#!/bin/sh
[ -z "${FAKE_NO_CLT:-}" ]
EOF
# The interpreter stand-in: records its arguments, leaves a process whose command line holds
# them (as the real relay's does), prints that PID and returns — the real relay's contract.
cat > "$T/fakepy" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE/py.log"
[ -z "${FAKE_PY_FAIL:-}" ] || { echo "relay: cannot listen on $3: [Errno 48] Address already in use" >&2; exit 1; }
bash -c 'while :; do sleep 1; done' "$@" >/dev/null 2>&1 </dev/null &
echo $! >> "$FAKE/pids"
echo $!
EOF
chmod +x "$T/bin/"* "$T/fakepy"

SD=$T/xdg/vks-mac-route
ST=$SD/state
reset_fakes() {
  local p
  while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$F/pids"
  : > "$F/pids"; : > "$F/sudo.log"; : > "$F/py.log"
  printf '%s\n' 192.168.101.128 > "$F/lo0"
  printf '%s\n' 18443 18444 18445 18446 > "$F/listening"
  printf '127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n192.168.101.130 harbor.env1.lab.test\n' > "$T/hosts"
  chmod 644 "$T/hosts"; cp "$T/hosts" "$T/hosts.orig"
  rm -rf "$T/xdg"
}
# mr [VAR=value ...] -- <mac-route arguments>: sets out and rc
mr() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out=$(env PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/xdg" FAKE="$F" MAC_ROUTE_HOSTS="$T/hosts" \
    MAC_ROUTE_PYTHON="$T/fakepy" SSH_CONNECTION="198.51.100.4 50123 203.0.113.7 22" "${envs[@]}" bash "$MR" "$@" 2>&1)
  rc=$?
}
unchanged() {   # <label>: nothing on the "Mac" was touched
  eq "$1: lo0 is as before" "$(cat "$F/lo0")" 192.168.101.128
  cmp -s "$T/hosts" "$T/hosts.orig" && ok "$1: the hosts file is as before" || bad "$1: the hosts file is as before" "$(cat "$T/hosts")"
  [ ! -e "$SD" ] && ok "$1: no state directory" || bad "$1: no state directory" "$(ls -a "$SD")"
  eq "$1: no relay was started" "$(cat "$F/py.log")" ""
  hasnt "$1: sudo changed nothing" "$(cat "$F/sudo.log")" "lo0"
}
ME=$(id -un)
A=(--forward 192.168.100.50:443:18443 --forward 192.168.101.128:443:18444 --forward 192.168.101.128:6443:18445
   --forward 192.168.101.130:443:18446 --host vcsa.env1.lab.test=192.168.100.50 --host harbor.env1.lab.test=192.168.101.130)
OWNER="ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18443:192.168.100.50:443 -R 127.0.0.1:18444:192.168.101.128:443 -R 127.0.0.1:18445:192.168.101.128:6443 -R 127.0.0.1:18446:192.168.101.130:443 $ME@203.0.113.7"

# --- bash 3.2: none of what macOS /bin/bash lacks ---------------------------------------------
eq "mac-route.sh uses nothing bash 3.2 lacks" "$(grep -nE 'declare -A|local -n|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|\|&|&>>|wait -n' "$MR")" ""

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

printf '%s\n' 18443 18446 > "$F/listening"
mr X=1 -- up "${A[@]}"
eq "tunnel not listening: exit 2" "$rc" 2
has "tunnel not listening: names every port that is missing" "$out" "mac-route: refused: nothing listens on 127.0.0.1 for tunnel port(s) 18444 18445, and nothing was changed."
has "tunnel not listening: prints the owner's line for the whole list" "$out" "$OWNER"
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

# --- up ---------------------------------------------------------------------------------------
reset_fakes
mr X=1 -- up "${A[@]}"
eq "up: exit 0" "$rc" 0
has "up: the alias it needs is added" "$out" "mac-route: alias  192.168.100.50 on lo0: added"
has "up: an alias that was there is left alone" "$out" "mac-route: alias  192.168.101.128 on lo0: was there before, left alone"
has "up: a name that was there is left alone" "$out" "mac-route: hosts  harbor.env1.lab.test = 192.168.101.130: was there before, left alone"
has "up: says how to see and undo it" "$out" "up. See it: $MR status    Undo it: $MR down"
eq "up: lo0 now has both lab addresses that are forwarded from a new alias" "$(sort "$F/lo0" | tr '\n' ' ')" "192.168.100.50 192.168.101.128 192.168.101.130 "
eq "up: four relays started" "$(grep -c . "$F/py.log")" 4
has "up: a relay binds the alias only and connects to the tunnel port" "$(cat "$F/py.log")" "$SD/relay.py --listen 192.168.100.50:443 --connect 127.0.0.1:18443 --log $SD/relay-192.168.100.50-443.log"
has "up: a port below 1024 is started through sudo -n" "$(cat "$F/sudo.log")" "$T/fakepy $SD/relay.py --listen 192.168.100.50:443"
hasnt "up: a port from 1024 up is started without root" "$(cat "$F/sudo.log")" "--listen 192.168.101.128:6443"
hasnt "up: nothing is told to listen on every address" "$(cat "$F/py.log")" "0.0.0.0"
eq "up: the hosts file gained exactly the one marked line" "$(diff "$T/hosts.orig" "$T/hosts" | grep '^[<>]')" "> 192.168.100.50${TAB}vcsa.env1.lab.test${TAB}$MARK"
eq "up: the hosts file keeps its mode" "$(stat -c %a "$T/hosts")" 644
cmp -s "$SD/hosts.backup" "$T/hosts.orig" && ok "up: the original hosts file is kept as a backup" || bad "up: the original hosts file is kept as a backup" "differs"
has "up: the hosts file is replaced by sudo -n cp of a temp file" "$(cat "$F/sudo.log")" "cp $SD/hosts.new $T/hosts"
eq "up: the state file records 2 aliases, 4 relays, 1 hosts line" "$(awk '{ print $1 }' "$ST" | sort | uniq -c | tr -s ' \n' ' ')" " 2 alias 1 hosts 4 relay "
hasnt "up: the alias that was there is not recorded" "$(cat "$ST")" "alias 192.168.101.128"
eq "up: the relay script is written and is valid Python" "$(python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read()); print("ok")' "$SD/relay.py" 2>&1)" ok
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
eq "up twice: sudo was not used to change anything" "$(sed -n "$((s1 + 1)),\$p" "$F/sudo.log" | grep -vx true)" ""
mr FAKE_SUDO=no -- up "${A[@]}"
eq "up twice without sudo: nothing needs root, so it is not asked for" "$rc" 0

# --- a forward is added to a running set ------------------------------------------------------
pids1=$(awk '$1 == "relay" { print $5 }' "$ST" | tr '\n' ' ')
echo 18448 >> "$F/listening"
mr X=1 -- up "${A[@]}" --forward 192.168.101.148:8080:18448
eq "adding a forward: exit 0" "$rc" 0
has "adding a forward: only it is started" "$out" "mac-route: relay  192.168.101.148:8080 -> 127.0.0.1:18448: started, PID "
eq "adding a forward: one more relay" "$(grep -c . "$F/py.log")" 5
eq "adding a forward: the running relays keep their PIDs" "$(awk '$1 == "relay" { print $5 }' "$ST" | head -4 | tr '\n' ' ')" "$pids1"
mr X=1 -- up --forward 192.168.100.50:443:18446
has "another tunnel port for a running relay: refused" "$rc $out" "2 mac-route: refused: 192.168.100.50:443 is already relayed to tunnel port 18443, not 18446. Take the old set down first: $MR down"

# --- status -----------------------------------------------------------------------------------
mr X=1 -- status
eq "status, all up: exit 0" "$rc" 0
has "status: an alias" "$out" "  alias    192.168.100.50 on lo0: present"
has "status: a relay with its PID" "$out" "  relay    192.168.101.128:6443 -> 127.0.0.1:18445: running, PID "
has "status: its tunnel port" "$out" "  tunnel   127.0.0.1:18445: listening"
has "status: a hosts line" "$out" "  hosts    192.168.100.50${TAB}vcsa.env1.lab.test${TAB}$MARK: present"
has "status: an alias it did not add is a note, not a leftover" "$out" "  alias    192.168.101.128 on lo0 is not recorded: it was there before \`up\`, or something else added it."
has "status: the verdict" "$out" "mac-route: all of it is up. Undo it: $MR down"
p6443=$(awk '$1 == "relay" && $3 == 6443 { print $5 }' "$ST")
kill "$p6443"; while alive "$p6443"; do sleep 0.1; done
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
: > "$F/sudo.log"
mr X=1 -- down
has "down: a PID that is another program now is not killed, with the reason" "$out" "mac-route: relay  192.168.101.148:8080: nothing killed: PID $other is another program now (sleep 300)"
alive "$other" && ok "down: … and that program is still running" || bad "down: … and that program is still running" "PID $other is gone"
has "down: a PID with another start time is not killed, with the reason" "$out" "mac-route: relay  192.168.101.130:443: nothing killed: PID $p443 was started at another time than the relay (the PID was reused)"
alive "$p443" && ok "down: … and that process is still running" || bad "down: … and that process is still running" "PID $p443 is gone"
hasnt "down: sudo was not asked to kill either" "$(cat "$F/sudo.log")" "kill $p443"

# --- down removes exactly its own -------------------------------------------------------------
has "down: its relay is stopped by PID" "$out" "mac-route: relay  192.168.100.50:443: stopped (PID $pvc)"
has "down: a root relay is stopped through sudo -n" "$(cat "$F/sudo.log")" "kill $pvc"
alive "$pvc" && bad "down: the relay process is gone" "PID $pvc lives" || ok "down: the relay process is gone"
has "down: its alias is removed" "$out" "mac-route: alias  192.168.100.50 on lo0: removed"
eq "down: the alias that was there before survives, and only it" "$(cat "$F/lo0")" 192.168.101.128
has "down: its hosts line is removed" "$out" "mac-route: hosts  192.168.100.50${TAB}vcsa.env1.lab.test${TAB}$MARK: removed from $T/hosts"
cmp -s "$T/hosts" "$T/hosts.orig" && ok "down: the hosts file is the original again, the unmarked line included" || bad "down: the hosts file is the original again" "$(diff "$T/hosts.orig" "$T/hosts")"
eq "down: the hosts file keeps its mode" "$(stat -c %a "$T/hosts")" 644
[ ! -e "$SD" ] && ok "down: the state directory is gone" || bad "down: the state directory is gone" "$(ls -a "$SD")"
has "down: the verdict" "$out" "mac-route: down: everything this script created is removed, its state directory too."
has "down: the relays it did not dare to kill are shown as leftovers" "$out" "  relay    PID $p443: "
has "down: … with the command for each" "$out" "           remove by hand: sudo kill $p443"
has "down: the tunnels stay the owner's" "$out" "mac-route: the tunnels are the owner's: he ends his ssh on the lab host."
eq "down: exit 0" "$rc" 0

# --- down twice -------------------------------------------------------------------------------
kill "$p443" "$p8080" 2>/dev/null; while alive "$p443" || alive "$p8080"; do sleep 0.1; done
: > "$F/sudo.log"
mr X=1 -- down
eq "down twice: exit 0" "$rc" 0
has "down twice: says there is nothing" "$out" "mac-route: nothing to remove: no state file ($ST)."
eq "down twice: lo0 is untouched" "$(cat "$F/lo0")" 192.168.101.128
cmp -s "$T/hosts" "$T/hosts.orig" && ok "down twice: the hosts file is untouched" || bad "down twice: the hosts file is untouched" "changed"
hasnt "down twice: sudo changed nothing" "$(cat "$F/sudo.log")" "lo0"
mr X=1 -- status
has "status after down: nothing up, no leftovers" "$rc $out" "mac-route: no leftovers found."

# --- down refuses before changing anything when sudo would prompt ----------------------------
mr X=1 -- up "${A[@]}"
st1=$(cksum < "$ST")
mr FAKE_SUDO=no -- down
has "down, sudo not cached: refused before any change" "$rc $out" "2 mac-route: refused: sudo would ask for a password, and nothing was changed."
eq "down, sudo not cached: the state file is unchanged" "$(cksum < "$ST")" "$st1"
eq "down, sudo not cached: the relays still run" "$(awk '$1 == "relay" { print $5 }' "$ST" | while read -r p; do alive "$p" && echo y; done | grep -c y)" 4
mr X=1 -- down
eq "down afterwards: exit 0" "$rc" 0

# --- status with leftovers and no state file --------------------------------------------------
reset_fakes
printf '192.168.100.50\tvcsa.env1.lab.test\t%s\n' "$MARK" >> "$T/hosts"
mkdir -p "$SD"
lp=$(env FAKE="$F" "$T/fakepy" "$SD/relay.py" --listen 192.168.100.50:443 --connect 127.0.0.1:18443 --log "$SD/x.log")
echo 10.7.7.7 >> "$F/lo0"
mr X=1 -- status
eq "leftovers without a state file: exit 1" "$rc" 1
has "leftovers: says there is no state file" "$out" "mac-route: no state file ($ST): this script has nothing up."
has "leftovers: the heading" "$out" "mac-route: LEFTOVERS that the state file does not record:"
has "leftovers: the relay and its command" "$out" "           remove by hand: sudo kill $lp"
has "leftovers: the marked hosts line" "$out" "  hosts    192.168.100.50${TAB}vcsa.env1.lab.test${TAB}$MARK"
has "leftovers: its command" "$out" "           remove by hand: grep -v '$MARK\$' $T/hosts > ~/hosts.new && sudo cp ~/hosts.new $T/hosts && rm ~/hosts.new"
has "leftovers: a private alias nobody recorded, with its command" "$out" "           only if it is a leftover of an earlier walk: sudo ifconfig lo0 -alias 10.7.7.7"
mr X=1 -- down
eq "down without a state file leaves leftovers alone: exit 0" "$rc" 0
alive "$lp" && ok "down without a state file: the unrecorded relay is not killed" || bad "down without a state file: the unrecorded relay is not killed" "gone"
has "down without a state file: the marked line it has no record of stays" "$(cat "$T/hosts")" "vcsa.env1.lab.test${TAB}$MARK"
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
mr FAKE_PY_FAIL=1 -- up --forward 192.168.100.50:443:18443
eq "relay cannot start: exit 1" "$rc" 1
has "relay cannot start: the relay's own reason" "$out" "mac-route: relay  192.168.100.50:443 -> 127.0.0.1:18443: COULD NOT START: relay: cannot listen on 192.168.100.50:443: [Errno 48] Address already in use"
has "relay cannot start: says the rest is recorded" "$out" "NOT fully up (see above). What was created is recorded; undo it: $MR down"
mr X=1 -- down
eq "relay cannot start: down removes the alias it had added" "$(cat "$F/lo0")" 192.168.101.128
reset_fakes
mr FAKE_IFCONFIG_FAIL=1 -- up --forward 192.168.100.50:443:18443
has "alias cannot be added: says so with the command" "$rc $out" "COULD NOT BE ADDED. By hand: sudo ifconfig lo0 alias 192.168.100.50 255.255.255.255"
eq "alias cannot be added: no relay is started on it" "$(cat "$F/py.log")" ""

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
reset_fakes
mr X=1 -- up --file "$T/forwards"
eq "up --file: exit 0" "$rc" 0
eq "up --file: four relays" "$(grep -c . "$F/py.log")" 4
mr X=1 -- print-tunnel
eq "print-tunnel without a list: the recorded forwards" "$out" "$OWNER"
mr X=1 -- down
eq "down after up --file: exit 0" "$rc" 0
reset_fakes

# --- the real relay, once, on 127.0.0.1 -------------------------------------------------------
# Everything but the bind to an lo0 alias: start (it goes to the background and prints its PID),
# bytes out, the end of the client's data passed on (half-close), bytes back, the log, stop.
R=$T/real; mkdir -p "$R"
bash "$MR" write-relay "$R/relay.py"
python3 - "$R/server.port" <<'PY' &
import os, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1] + ".t", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".t", sys.argv[1])
c, _ = s.accept(); data = b""
while True:
    d = c.recv(4096)
    if not d:
        break
    data += d
c.sendall(b"got:" + data[::-1]); c.close()
PY
srv=$!; echo "$srv" >> "$F/pids"
i=0; while [ ! -s "$R/server.port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sp=$(cat "$R/server.port" 2>/dev/null)
lp=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
rpid=$(python3 "$R/relay.py" --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/relay.log" 2>"$R/relay.err")
case $rpid in '' | *[!0-9]*) bad "real relay: starts and prints its PID" "got '$rpid': $(cat "$R/relay.err")"; rpid="" ;; *) ok "real relay: starts and prints its PID"; echo "$rpid" >> "$F/pids" ;; esac
if [ -n "$rpid" ]; then
  has "real relay: the PID it printed is the relay" "$(ps -ww -o command= -p "$rpid")" "$R/relay.py --listen 127.0.0.1:$lp "
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
  has "real relay: logs what it listens on" "$(cat "$R/relay.log")" "listening on 127.0.0.1:$lp, connecting to 127.0.0.1:$sp, pid $rpid"
  has "real relay: logs the byte counts, not the bytes" "$(cat "$R/relay.log")" "closed: 9 bytes out, 13 bytes back"
  hasnt "real relay: no payload in the log" "$(cat "$R/relay.log")" "ping"
  out=$(python3 "$R/relay.py" --listen "127.0.0.1:$lp" --connect "127.0.0.1:$sp" --log "$R/relay2.log" 2>&1); rc=$?
  has "real relay: a taken port is reported by the command itself" "$rc $out" "1 relay: cannot listen on 127.0.0.1:$lp: "
  python3 -c 'import socket, sys; c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5); c.settimeout(5); c.recv(1)' "$lp" 2>/dev/null
  i=0; while ! grep -q 'refused' "$R/relay.log" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  has "real relay: a tunnel that does not answer is logged, the relay stays up" "$(cat "$R/relay.log")" "refused: cannot connect to 127.0.0.1:$sp"
  alive "$rpid" && ok "real relay: still running after it" || bad "real relay: still running after it" "gone"
  kill "$rpid"; i=0; while alive "$rpid" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  alive "$rpid" && bad "real relay: stops on SIGTERM" "PID $rpid lives" || ok "real relay: stops on SIGTERM"
  has "real relay: logs the stop" "$(tail -1 "$R/relay.log")" "stopped"
fi
out=$(python3 "$R/relay.py" --listen "0.0.0.0:$lp" --connect "127.0.0.1:$sp" --log "$R/relay3.log" 2>&1); rc=$?
has "real relay: refuses to listen on every address" "$rc $out" "1 relay: refusing to listen on every address"

if [ "$fails" -eq 0 ]; then echo "mac-route.sh tests: all $checks checks passed"; else echo "mac-route.sh tests: $fails of $checks FAILED"; exit 1; fi
