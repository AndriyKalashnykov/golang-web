#!/usr/bin/env bash
# mac-route.sh — make the lab's addresses answer on a Mac that reaches the lab only through
# reverse ssh tunnels, so every name, IP and port in the vks/ guides stays as written.
#
#   mac-route.sh up           --forward <lab ip>:<port>:<tunnel port> [--forward …] [--host <name>=<lab ip> …]
#   mac-route.sh status
#   mac-route.sh down
#   mac-route.sh print-tunnel --forward … [--mac <user>@<this Mac>]     the OWNER's ssh line
#
# `--file PATH` gives the same list from a file: one `<lab ip>:<port>:<tunnel port>` or
# `<name>=<lab ip>` per line; empty lines and `#` comments are skipped.
#
# The owner opens the tunnels on the lab host (`print-tunnel` prints his line); each one ends on
# the Mac as a port on 127.0.0.1. THIS SCRIPT NEVER OPENS A TUNNEL. Per forward, `up` adds
#   - an `lo0` alias for the lab IP (only when lo0 does not have it already),
#   - a relay that listens on <lab ip>:<port> and connects to 127.0.0.1:<tunnel port>,
# and per --host one line in /etc/hosts that ends in the marker `# vks-mac-route`.
#
# An alias takes the place of the real owner of an address. `up` therefore refuses, before any
# change, a lab IP that is this Mac's default gateway, one of its DNS resolvers, one of its own
# addresses or inside the network of one of its interfaces, and names what it collided with.
# `--allow-onlink <ip>` overrides that for one address.
#
# Ownership: everything `up` creates is written to
#   ${XDG_STATE_HOME:-$HOME/.local/state}/vks-mac-route/state
# BEFORE it is created, and `down` removes only that: an alias it added (never one that was
# there before), a relay by its exact PID after checking the start time and the command line (a
# reused PID is left alone), a hosts line that is recorded AND carries the marker. Every value
# read back from the state file is checked like a command-line value; a line that does not
# pass is left alone and reported. `down` twice is safe. `up` and `down` hold a lock.
#
# Root: the alias, a relay on a port below 1024 and the /etc/hosts change need it. Only
# `sudo -n` is used, with absolute paths for what it runs; when it would ask for a password the
# script stops BEFORE changing anything and says to run `sudo -v`. No password is read or stored.
#
# /etc/hosts is replaced as a whole by `sudo -n /bin/cp` of a file built beside the state file
# (so its mode and owner stay; `cp` rewrites the file's content, it is not an atomic rename).
# Before the copy the new file is checked: not empty, the expected number of lines, every line
# that was not to be dropped still there. After the copy it is compared; when the copy or the
# compare fails, the content from before this run is copied back and the script says whether
# that worked. The first original is kept as `hosts.backup` in the state directory until a
# `down` finds the hosts file with no marked line and every other line still in place.
#
# The relay is one process PER FORWARD: the app's address exists only after the guide's deploy
# step, so a forward is added to a running set, and that must not cut the connections the
# other forwards carry. It is `/usr/bin/python3 -I -` (Command Line Tools) with its code fed on
# stdin from THIS file: root never runs code from a file a user can write. A relay binds the
# alias IP only; one on a port below 1024 is started through sudo, binds, then gives up root
# for the calling user before it opens its log, and ends instead when it cannot.
#
# "Is the tunnel port listening" is asked with `lsof -nP -iTCP@127.0.0.1:<port> -sTCP:LISTEN`
# (macOS ships lsof). It reads the socket table; `nc -z` would open a real connection through
# the tunnel to the lab service on every check.
#
# Needs bash 3.2+ (macOS /bin/bash). MAC_ROUTE_TEST=1 exists ONLY for mac-route_test.sh: with
# it, MAC_ROUTE_HOSTS (the hosts file), MAC_ROUTE_PYTHON (the interpreter) and MAC_ROUTE_BIN (a
# directory of stand-ins for the system tools) are honoured. Without it they are refused.
# vks/test/README.md has the procedure.
set -u
umask 077

PROG=mac-route
SELF=$0
MARK='# vks-mac-route'
TAG=vks-mac-route
TAB=$(printf '\t')
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/vks-mac-route
STATE=$STATE_DIR/state
LOCK=$STATE_DIR/lock

say()  { echo "$PROG: $*"; }
die()  { echo "$PROG: $*" >&2; exit 2; }
usage() { sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'; }

# --- the system tools: fixed absolute paths, unless the test switch is set --------------------
HOSTS=/etc/hosts
PY=/usr/bin/python3
SUDO=/usr/bin/sudo
IFCONFIG=/sbin/ifconfig
ROUTE=/sbin/route
SCUTIL=/usr/sbin/scutil
LSOF=/usr/sbin/lsof
PS=/bin/ps
CP=/bin/cp
KILL=/bin/kill
XCODE_SELECT=/usr/bin/xcode-select
if [ "${MAC_ROUTE_TEST:-}" = 1 ]; then
  HOSTS=${MAC_ROUTE_HOSTS:-$HOSTS}
  PY=${MAC_ROUTE_PYTHON:-$PY}
  if [ -n "${MAC_ROUTE_BIN:-}" ]; then
    SUDO=$MAC_ROUTE_BIN/sudo; IFCONFIG=$MAC_ROUTE_BIN/ifconfig; ROUTE=$MAC_ROUTE_BIN/route
    SCUTIL=$MAC_ROUTE_BIN/scutil; LSOF=$MAC_ROUTE_BIN/lsof; PS=$MAC_ROUTE_BIN/ps
    CP=$MAC_ROUTE_BIN/cp; KILL=$MAC_ROUTE_BIN/kill; XCODE_SELECT=$MAC_ROUTE_BIN/xcode-select
  fi
else
  for v in MAC_ROUTE_HOSTS MAC_ROUTE_PYTHON MAC_ROUTE_BIN; do
    [ -z "${!v:-}" ] || die "refused: $v is set. It is for mac-route_test.sh only (with MAC_ROUTE_TEST=1); unset it: unset $v"
  done
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
fi

FWD=""    # one "ip port tunnelport" per line
HST=""    # one "name ip" per line
ALLOW=""  # one ip per line: --allow-onlink
MAC=""    # the ssh target of this Mac, for the owner's line
REASON=""
TMPD=""
LOCKED=0
STATE_BAD=0

finish() {
  [ -n "$TMPD" ] && rm -rf "$TMPD"
  [ "$LOCKED" -eq 1 ] && rm -rf "$LOCK"
  return 0
}
trap finish EXIT
trap 'exit 130' INT TERM
scratch() { [ -n "$TMPD" ] || TMPD=$(mktemp -d) || die "mktemp failed"; }

# --- validation -------------------------------------------------------------------------------
# ipv4_ok <text>: four numbers 0-255, no leading zero
ipv4_ok() {
  local a b c d rest o
  case $1 in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
  IFS=. read -r a b c d rest <<EOF
$1
EOF
  [ -n "${d:-}" ] && [ -z "${rest:-}" ] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    case $o in 0 | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;; *) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
}

# private_ip <ip>: 0 when it is a private IPv4 address; else 1 with REASON set.
private_ip() {
  local ip=$1 a b rest
  REASON="$ip: not an IPv4 address (four numbers 0-255)"
  ipv4_ok "$ip" || return 1
  IFS=. read -r a b rest <<EOF
$ip
EOF
  if [ "$a" -eq 127 ]; then REASON="$ip: a loopback address; only the lab's private addresses are forwarded"; return 1; fi
  if [ "$a" -eq 0 ]; then REASON="$ip: not a host address; only the lab's private addresses are forwarded"; return 1; fi
  REASON="$ip: not a private address (only 10/8, 172.16/12 and 192.168/16 are forwarded)"
  if [ "$a" -eq 10 ]; then return 0; fi
  if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then return 0; fi
  if [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; then return 0; fi
  return 1
}

# port_ok <text> <lowest>: a decimal port between <lowest> and 65535
port_ok() {
  case $1 in '' | *[!0-9]* | 0*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge "$2" ] && [ "$1" -le 65535 ]
}

pid_ok() {
  case $1 in '' | *[!0-9]* | 0*) return 1 ;; esac
  [ "${#1}" -le 7 ] && [ "$1" -gt 1 ]
}

name_ok() {
  local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
  [ "${#1}" -le 253 ] || return 1
  [[ $1 =~ $re ]] || return 1
  case $1 in *[!0-9.]*) ;; *) return 1 ;; esac
  case $1 in localhost | broadcasthost) return 1 ;; esac
  return 0
}

# target_ok <text>: an ssh target that is safe to print into a command line
target_ok() {
  case $1 in '' | *[!A-Za-z0-9@._:-]* | -* | *@*@*) return 1 ;; esac
  case $1 in ?*@?*) return 0 ;; esac
  return 1
}

add_forward() {
  local spec=$1 ip port tport extra oip oport otport
  IFS=: read -r ip port tport extra <<EOF
$spec
EOF
  [ -n "${tport:-}" ] && [ -z "${extra:-}" ] || die "'$spec': a forward is <lab ip>:<port>:<tunnel port>, e.g. 192.168.100.50:443:18443"
  private_ip "$ip" || die "refused: $REASON"
  port_ok "$port" 1 || die "refused: '$port' in '$spec' is not a port (1-65535)"
  port_ok "$tport" 1024 || die "refused: '$tport' in '$spec' is not a tunnel port (1024-65535; the owner's ssh opens it without root)"
  while read -r oip oport otport; do
    [ -n "$oip" ] || continue
    if [ "$oip $oport" = "$ip $port" ]; then
      [ "$otport" = "$tport" ] && return 0
      die "refused: $ip:$port is given twice, with tunnel ports $otport and $tport"
    fi
    [ "$otport" = "$tport" ] && die "refused: tunnel port $tport is given for both $oip:$oport and $ip:$port"
  done <<EOF
$FWD
EOF
  FWD="$FWD$ip $port $tport
"
}

add_host() {
  local spec=$1 name ip oname oip
  name=${spec%%=*}; ip=${spec#*=}
  [ "$name" != "$spec" ] && [ -n "$ip" ] || die "'$spec': a host is <name>=<lab ip>, e.g. vcsa.env1.lab.test=192.168.100.50"
  name_ok "$name" || die "refused: '$name' is not a host name (letters, digits and '-' in labels joined by '.')"
  private_ip "$ip" || die "refused: $REASON"
  while read -r oname oip; do
    [ -n "$oname" ] || continue
    if [ "$oname" = "$name" ]; then
      [ "$oip" = "$ip" ] && return 0
      die "refused: the name $name is given twice, for $oip and $ip"
    fi
  done <<EOF
$HST
EOF
  HST="$HST$name $ip
"
}

add_file() {
  local f=$1 line
  [ -r "$f" ] || die "--file $f: cannot read it"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d ' \t\r')
    [ -n "$line" ] || continue
    case $line in *=*) add_host "$line" ;; *) add_forward "$line" ;; esac
  done < "$f"
}

parse_list() {
  while [ $# -gt 0 ]; do
    case $1 in
      --forward) [ $# -ge 2 ] || die "--forward needs <lab ip>:<port>:<tunnel port>"; add_forward "$2"; shift 2 ;;
      --host)    [ $# -ge 2 ] || die "--host needs <name>=<lab ip>"; add_host "$2"; shift 2 ;;
      --file)    [ $# -ge 2 ] || die "--file needs a path"; add_file "$2"; shift 2 ;;
      --allow-onlink) [ $# -ge 2 ] || die "--allow-onlink needs a lab ip"
                 private_ip "$2" || die "refused: --allow-onlink $REASON"
                 ALLOW="$ALLOW$2
"; shift 2 ;;
      --mac)     [ $# -ge 2 ] || die "--mac needs <user>@<this Mac>"; MAC=$2; shift 2
                 target_ok "$MAC" || die "--mac '$MAC': expected <user>@<address>" ;;
      *) die "unknown argument '$1' (see: $SELF --help)" ;;
    esac
  done
}

# --- the machine ------------------------------------------------------------------------------
require_macos() {
  local os
  os=$(uname -s 2>/dev/null)
  [ "$os" = Darwin ] || die "refused: this is ${os:-an unknown system}, not macOS. $1 changes lo0 and /etc/hosts of a Mac; run it there."
}

python_ok() {
  if [ ! -x "$PY" ]; then
    die "refused: $PY is missing. Install the Command Line Tools, then run this again: xcode-select --install"
  fi
  if [ "$PY" = /usr/bin/python3 ] && ! "$XCODE_SELECT" -p >/dev/null 2>&1; then
    die "refused: /usr/bin/python3 is only a placeholder until the Command Line Tools are installed. Run: xcode-select --install"
  fi
}

sudo_ok() { "$SUDO" -n /usr/bin/true </dev/null 2>/dev/null; }
require_sudo() {
  sudo_ok || die "refused: sudo would ask for a password, and nothing was changed. Run this first, then the same command again: sudo -v"
}

lo0_addrs() { "$IFCONFIG" lo0 2>/dev/null | awk '$1 == "inet" { print $2 }'; }
lo0_has() {
  local a
  for a in $(lo0_addrs); do [ "$a" = "$1" ] && return 0; done
  return 1
}

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<EOF
$1
EOF
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
int2ip() { echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"; }

# What an alias could shadow. Read once, before any change.
NET_GW=""; NET_DNS=""; NET_IF=""
read_network() {
  NET_GW=$("$ROUTE" -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2; exit }')
  NET_DNS=$("$SCUTIL" --dns 2>/dev/null | awk '$1 ~ /^nameserver\[/ { print $3 }' | sort -u)
  NET_IF=$("$IFCONFIG" -a 2>/dev/null | awk '
    /^[^ \t]/ { iface = $1; sub(/:$/, "", iface); next }
    $1 == "inet" && iface != "lo0" {
      mask = "-"; peer = "-"
      for (i = 3; i <= NF; i++) { if ($i == "netmask") mask = $(i + 1); if ($i == "-->") peer = $(i + 1) }
      print iface, $2, mask, peer }')
}

# onlink <ip>: 0 when an lo0 alias for it shadows nothing this Mac uses; else 1 with REASON
onlink() {
  local ip=$1 d iface addr mask peer m bits net
  if [ -n "$NET_GW" ] && [ "$NET_GW" = "$ip" ]; then
    REASON="$ip is this Mac's default gateway (route -n get default)"; return 1
  fi
  for d in $NET_DNS; do
    if [ "$d" = "$ip" ]; then REASON="$ip is a DNS resolver of this Mac (scutil --dns)"; return 1; fi
  done
  while read -r iface addr mask peer; do
    [ -n "$iface" ] || continue
    if [ "$addr" = "$ip" ]; then REASON="$ip is this Mac's own address on $iface"; return 1; fi
    if [ "$peer" = "$ip" ]; then REASON="$ip is the far end of this Mac's $iface"; return 1; fi
    ipv4_ok "$addr" || { REASON="cannot read the address '$addr' of $iface, so $ip cannot be checked against it"; return 1; }
    case $mask in
      0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) m=$((mask)) ;;
      *) REASON="cannot read the netmask '$mask' of $iface ($addr), so $ip cannot be checked against it"; return 1 ;;
    esac
    [ "$m" -ne 0 ] || continue
    if [ $(($(ip2int "$ip") & m)) -eq $(($(ip2int "$addr") & m)) ]; then
      bits=0; d=$m
      while [ "$d" -ne 0 ]; do bits=$((bits + (d & 1))); d=$((d >> 1)); done
      net=$(int2ip $(($(ip2int "$addr") & m)))
      REASON="$ip is inside $net/$bits, the network of this Mac's $iface (its address there is $addr)"; return 1
    fi
  done <<EOF
$NET_IF
EOF
  return 0
}

listening() {
  local out
  out=$("$LSOF" -nP -iTCP@127.0.0.1:"$1" -sTCP:LISTEN 2>/dev/null </dev/null)
  [ -n "$out" ] && return 0
  sudo_ok || return 1
  out=$("$SUDO" -n "$LSOF" -nP -iTCP@127.0.0.1:"$1" -sTCP:LISTEN 2>/dev/null </dev/null)
  [ -n "$out" ]
}
# wildcard <port>: 0 when something listens on that port on EVERY address
wildcard() {
  local out
  out=$("$LSOF" -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null </dev/null)
  if [ -z "$out" ] && sudo_ok; then out=$("$SUDO" -n "$LSOF" -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null </dev/null); fi
  case $out in *"TCP *:$1 (LISTEN)"*) return 0 ;; esac
  return 1
}
WILDCARD_WARNING="it listens on EVERY address of this Mac, not on 127.0.0.1: anyone who reaches the Mac reaches the lab service (GatewayPorts in the Mac's sshd_config, or a tunnel opened without the 127.0.0.1: in front)"

proc_start() { LC_ALL=C "$PS" -ww -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }
proc_cmd()   { "$PS" -ww -o command= -p "$1" 2>/dev/null; }

# our_relay <pid> <ip> <port> <start time>: 0 when that PID is still the relay this script
# started; else 1 with REASON set.
our_relay() {
  local cmd
  cmd=$(proc_cmd "$1")
  if [ -z "$cmd" ]; then REASON="no process has PID $1 any more"; return 1; fi
  case "$cmd " in
    *" - --tag $TAG --listen $2:$3 "*) ;;
    *) REASON="PID $1 is another program now ($cmd)"; return 1 ;;
  esac
  if [ "$(proc_start "$1")" != "$4" ]; then
    REASON="PID $1 was started at another time than the relay (the PID was reused)"; return 1
  fi
  return 0
}

# --- the owner's line -------------------------------------------------------------------------
# tunnel_line <list of "ip port tport" lines>
tunnel_line() {
  local target=$MAC popt="" r="" ip port tport sip sport
  if [ -z "$target" ] && [ -n "${SSH_CONNECTION:-}" ]; then
    read -r _ _ sip sport _ <<EOF
$SSH_CONNECTION
EOF
    target="$(id -un)@${sip:-}"
    if target_ok "$target" && port_ok "${sport:-}" 1; then
      [ "$sport" = 22 ] || popt=" -p $sport"
    else
      target=""
    fi
  fi
  [ -n "$target" ] || target="<user>@<this Mac's address>"
  while read -r ip port tport; do
    [ -n "$ip" ] || continue
    r="$r -R 127.0.0.1:$tport:$ip:$port"
  done <<EOF
$1
EOF
  echo "ssh -N -o ExitOnForwardFailure=yes$r$popt $target"
  case $target in *'<'*) echo "$PROG: (the Mac's address is not known here; give it with --mac <user>@<address>)" >&2 ;; esac
}

# --- the state directory, its lock, the state file --------------------------------------------
statedir_check() {
  local perms
  [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ] || return 0
  [ ! -L "$STATE_DIR" ] || die "refused: $STATE_DIR is a symbolic link. Nothing was changed."
  [ -d "$STATE_DIR" ] && [ -O "$STATE_DIR" ] || die "refused: $STATE_DIR is not a directory owned by you ($(id -un)). Nothing was changed."
  # shellcheck disable=SC2012  # the mode string of one directory; stat's options differ on macOS
  perms=$(ls -ld "$STATE_DIR" | cut -c6,9)
  [ "$perms" = "--" ] || die "refused: $STATE_DIR can be written by its group or by everyone. Nothing was changed. Close it first: chmod 700 $STATE_DIR"
}
statedir_make() {
  [ -d "$STATE_DIR" ] && return 0
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  chmod 700 "$STATE_DIR" || die "cannot close $STATE_DIR to others"
  statedir_check
}
lock() {
  local opid ocmd
  [ "$LOCKED" -eq 1 ] && return 0
  if mkdir "$LOCK" 2>/dev/null; then
    LOCKED=1; echo "$$" > "$LOCK/pid"; return 0
  fi
  opid=$(cat "$LOCK/pid" 2>/dev/null)
  ocmd=""
  pid_ok "$opid" && ocmd=$(proc_cmd "$opid")
  if [ -n "$ocmd" ]; then
    die "refused: another run holds the lock $LOCK: PID $opid ($ocmd). Nothing was changed. Wait for it; if that process is not a mac-route run, clear the lock: rm -r $LOCK"
  fi
  die "refused: the lock $LOCK is held by PID ${opid:-unknown}, which is not running any more (a run was killed). Nothing was changed. Clear it, then run this again: rm -r $LOCK"
}

# state_check <line>: 0 when the line is one this script writes and every value in it passes
# the same checks as a command-line value; else 1 with REASON.
state_check() {
  local line=$1 k a b c d e rest body ip name
  read -r k a b c d e rest <<EOF
$line
EOF
  case $k in
    alias)
      private_ip "$a" || return 1
      REASON="it is not 'alias <ip>' or 'alias <ip> pending'"
      { [ -z "$b" ] || [ "$b" = pending ]; } && [ -z "$c" ] || return 1
      [ "$line" = "alias $a${b:+ $b}" ] ;;
    relay)
      private_ip "$a" || return 1
      REASON="'$b' is not a port"; port_ok "$b" 1 || return 1
      REASON="'$c' is not a tunnel port"; port_ok "$c" 1024 || return 1
      REASON="'$d' is not a PID"; pid_ok "$d" || return 1
      REASON="'$e' is neither user nor root"; [ "$e" = user ] || [ "$e" = root ] || return 1
      REASON="its start time is not a time, or the line is not spaced as this script writes it"
      case $rest in '' | *[!A-Za-z0-9:\ ]*) return 1 ;; esac
      [ "$line" = "relay $a $b $c $d $e $rest" ] ;;
    hosts)
      body=${line#hosts }
      IFS=$TAB read -r ip name rest <<EOF
$body
EOF
      private_ip "$ip" || return 1
      REASON="'$name' is not a host name"; name_ok "$name" || return 1
      REASON="it is not '<ip> <name> $MARK', TAB-separated: without the marker a line is not this script's"
      [ "$body" = "$ip$TAB$name$TAB$MARK" ] ;;
    *) REASON="not a line this script writes"; return 1 ;;
  esac
}

# state_audit: says which lines of the state file are left alone; sets STATE_BAD
state_audit() {
  local line
  [ -f "$STATE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    state_check "$line" && continue
    STATE_BAD=1
    say "state  LEFT ALONE, nothing is done for this line of $STATE: '$line' ($REASON)"
  done < "$STATE"
}
# state_lines <kind>: the valid lines of that kind
state_lines() {
  local line
  [ -f "$STATE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in "$1 "*) state_check "$line" && printf '%s\n' "$line" ;; esac
  done < "$STATE"
}
state_has() { [ -f "$STATE" ] && grep -qxF -- "$1" "$STATE"; }
# Both writers build the whole new file beside the state file and rename it over; a failed
# write leaves the state file as it was.
state_add() {
  local n=0
  [ -f "$STATE" ] && n=$(grep -c '' "$STATE")
  { [ ! -f "$STATE" ] || cat "$STATE"; printf '%s\n' "$1"; } > "$STATE.tmp" 2>/dev/null || { rm -f "$STATE.tmp" 2>/dev/null; return 1; }
  [ "$(grep -c '' "$STATE.tmp")" = "$((n + 1))" ] || { rm -f "$STATE.tmp"; return 1; }
  mv "$STATE.tmp" "$STATE"
}
state_del() {
  local n hit rc
  [ -f "$STATE" ] || return 0
  n=$(grep -c '' "$STATE"); hit=$(grep -cxF -- "$1" "$STATE")
  [ "$hit" != 0 ] || return 0
  grep -vxF -- "$1" "$STATE" > "$STATE.tmp" 2>/dev/null; rc=$?
  [ "$rc" -le 1 ] || { rm -f "$STATE.tmp" 2>/dev/null; return 1; }
  [ "$(grep -c '' "$STATE.tmp" 2>/dev/null)" = "$((n - hit))" ] || { rm -f "$STATE.tmp" 2>/dev/null; return 1; }
  mv "$STATE.tmp" "$STATE"
}
state_forwards() { state_lines relay | awk '{ print $2, $3, $4 }'; }

# --- /etc/hosts -------------------------------------------------------------------------------
hosts_line() { printf '%s\t%s\t%s' "$2" "$1" "$MARK"; }   # <name> <ip>
# the lines of the hosts file that end in the marker
marked_lines() { grep -- "$MARK\$" "$HOSTS"; }

# hosts_entries <name>: one "<ip> own|other" per line of the hosts file that names it
hosts_entries() {
  awk -v want="$1" -v mark="$MARK" '
    { own = "other"; n = length($0) - length(mark)
      if (n >= 0 && substr($0, n + 1) == mark) own = "own"
      body = $0; sub(/#.*/, "", body)
      m = split(body, f, /[ \t]+/); first = (f[1] == "") ? 2 : 1
      for (i = first + 1; i <= m; i++) if (tolower(f[i]) == tolower(want)) print f[first], own }' "$HOSTS"
}

# hosts_write <file of exact lines to drop> <file of lines to add>
# 0: the hosts file is the new content. 1: it is as before this run. 2: DAMAGED, not restored.
hosts_write() {
  local new snap old dropped=0 added got line rc
  hw_fail() { say "hosts  $1; $HOSTS was NOT changed"; rm -f "$new" "$snap"; return 1; }
  new=$(mktemp "$STATE_DIR/hosts.new.XXXXXX") || { say "hosts  cannot create a work file in $STATE_DIR; $HOSTS was NOT changed"; return 1; }
  snap=$(mktemp "$STATE_DIR/hosts.snap.XXXXXX") || { snap=""; hw_fail "cannot create a work file in $STATE_DIR"; return 1; }
  cat "$HOSTS" > "$snap" || { hw_fail "cannot take a copy of $HOSTS"; return 1; }
  cmp -s "$snap" "$HOSTS" || { hw_fail "cannot take a copy of $HOSTS"; return 1; }
  if [ ! -f "$STATE_DIR/hosts.backup" ]; then
    cat "$snap" > "$STATE_DIR/hosts.backup.tmp" || { hw_fail "cannot save a backup of $HOSTS"; return 1; }
    cmp -s "$snap" "$STATE_DIR/hosts.backup.tmp" || { hw_fail "cannot save a backup of $HOSTS"; return 1; }
    mv "$STATE_DIR/hosts.backup.tmp" "$STATE_DIR/hosts.backup" || { hw_fail "cannot save a backup of $HOSTS"; return 1; }
  fi
  if [ -s "$1" ]; then
    grep -vxFf "$1" "$snap" > "$new"; rc=$?
    [ "$rc" -le 1 ] || { hw_fail "cannot build the new file (grep ended with $rc)"; return 1; }
    dropped=$(grep -cxFf "$1" "$snap")
  else
    cat "$snap" > "$new" || { hw_fail "cannot build the new file"; return 1; }
  fi
  if [ -s "$new" ] && [ -n "$(tail -c 1 "$new")" ]; then echo >> "$new" || { hw_fail "cannot build the new file"; return 1; }; fi
  cat "$2" >> "$new" || { hw_fail "cannot build the new file"; return 1; }

  # the new file is checked before root copies it
  old=$(grep -c '' "$snap"); added=$(grep -c '' "$2"); got=$(grep -c '' "$new")
  case "$old$dropped$added$got" in '' | *[!0-9]*) hw_fail "cannot count the lines of the new file"; return 1 ;; esac
  [ -s "$new" ] || { hw_fail "the new file is EMPTY"; return 1; }
  [ "$got" -eq $((old - dropped + added)) ] ||
    { hw_fail "the new file has $got line(s); $old - $dropped dropped + $added added were expected"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -s "$1" ] && grep -qxF -- "$line" "$1"; then continue; fi
    grep -qxF -- "$line" "$new" || { hw_fail "the new file lost the line '$line'"; return 1; }
  done < "$snap"
  while IFS= read -r line; do
    grep -qxF -- "$line" "$new" || { hw_fail "the new file lacks the line '$line'"; return 1; }
  done < "$2"

  if "$SUDO" -n "$CP" "$new" "$HOSTS" </dev/null && cmp -s "$new" "$HOSTS"; then
    rm -f "$new" "$snap"; return 0
  fi
  rm -f "$new"
  if cmp -s "$snap" "$HOSTS"; then
    say "hosts  the copy to $HOSTS failed; $HOSTS was NOT changed"; rm -f "$snap"; return 1
  fi
  say "hosts  !!! THE COPY TO $HOSTS WENT WRONG: it does not hold what was written. Putting back what it held before this run."
  if "$SUDO" -n "$CP" "$snap" "$HOSTS" </dev/null && cmp -s "$snap" "$HOSTS"; then
    say "hosts  RESTORED: $HOSTS is exactly as it was before this run."; rm -f "$snap"; return 1
  fi
  say "hosts  !!! $HOSTS IS DAMAGED AND COULD NOT BE RESTORED. What it held before this run is kept in $snap"
  say "hosts  !!! put it back by hand, now: sudo cp $snap $HOSTS"
  return 2
}

# hosts_intact <copy of the hosts file from before>: 0 when no marked line remains and every
# unmarked line of the copy is still in the hosts file
hosts_intact() {
  local line n
  n=$(grep -c -- "$MARK\$" "$HOSTS")
  [ "$n" = 0 ] || { REASON="$n line(s) ending in '$MARK' are still in $HOSTS"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in *"$MARK") continue ;; esac
    grep -qxF -- "$line" "$HOSTS" || { REASON="the line '$line' was in $HOSTS before and is not any more"; return 1; }
  done < "$1"
  return 0
}

# --- the relay --------------------------------------------------------------------------------
relay_source() {
  cat <<'PYEOF'
"""TCP relay for vks/test/mac-route.sh: listen on ONE address, connect each client onward.

python3 -I - --tag vks-mac-route --listen IP:PORT --connect IP:PORT --log PATH
             [--idle SECONDS] [--max CONNECTIONS] [--foreground]

It binds first, so a bind error is reported by the command itself. Started as root (through
sudo, for a port below 1024) it then becomes the calling user for good, before the log is
opened, and ends when it cannot. Then it goes to the background and prints the PID of the
process that stays. No payload is logged.
"""
import os
import signal
import socket
import sys
import threading
import time

CONNECT_TIMEOUT = 10
LOG_FD = -1
STOP = []


def log(text):
    """One write per line (O_APPEND); a log that cannot be written never stops the relay."""
    try:
        line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), text)
        os.write(LOG_FD, line.encode("utf-8", "replace"))
    except Exception:
        pass


def endpoint(text):
    host, _, port = text.rpartition(":")
    if not host or not port.isdigit():
        raise SystemExit("relay: '%s' is not IP:PORT" % text)
    return host, int(port)


def one_address(host):
    """Refuse every spelling of "every address": only a full dotted IPv4 address may be bound."""
    parts = host.split(".")
    if len(parts) != 4 or not all(p.isdigit() and int(p) <= 255 for p in parts):
        raise SystemExit("relay: refusing to listen on '%s': not one IPv4 address" % host)
    if all(int(p) == 0 for p in parts):
        raise SystemExit("relay: refusing to listen on every address")


def drop_root():
    """Become the user who called sudo, for good. Never go on as root."""
    if os.geteuid() != 0:
        return
    try:
        uid = int(os.environ["SUDO_UID"])
        gid = int(os.environ["SUDO_GID"])
        if uid == 0:
            raise ValueError("SUDO_UID is root")
        os.setgroups([gid])
        os.setgid(gid)
        os.setuid(uid)
    except (KeyError, ValueError, OSError) as err:
        raise SystemExit("relay: refusing to continue as root: cannot become the calling user: %r" % (err,))
    if os.getuid() == 0 or os.geteuid() == 0:
        raise SystemExit("relay: refusing to continue as root: still root after the drop")


def open_log(path):
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW
    try:
        return os.open(path, flags, 0o600)
    except OSError as err:
        raise SystemExit("relay: cannot open the log %s: %s" % (path, err))


def pump(src, dst, count, key):
    """Copy src to dst until src ends, then pass the end on (half-close)."""
    why = ""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            count[key] += len(data)
    except socket.timeout:
        why = "idle"
    except OSError:
        why = "error"
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    if why:
        if not count["why"]:
            count["why"] = why
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(client, peer, target, idle, slots):
    count = {"out": 0, "back": 0, "why": ""}
    onward = None
    try:
        try:
            onward = socket.create_connection(target, CONNECT_TIMEOUT)
        except OSError as err:
            log("%s:%d refused: cannot connect to %s:%d: %s" % (peer[0], peer[1], target[0], target[1], err))
            return
        client.settimeout(idle)
        onward.settimeout(idle)
        back = threading.Thread(target=pump, args=(onward, client, count, "back"))
        back.daemon = True
        back.start()
        pump(client, onward, count, "out")
        back.join()
        note = {"idle": " (closed after %d s without data)" % idle, "error": " (connection error)"}.get(count["why"], "")
        log("%s:%d closed: %d bytes out, %d bytes back%s" % (peer[0], peer[1], count["out"], count["back"], note))
    except Exception as err:
        log("%s:%d failed: %r" % (peer[0], peer[1], err))
    finally:
        for sock in (client, onward):
            try:
                if sock is not None:
                    sock.close()
            except OSError:
                pass
        slots.release()


def main(argv):
    global LOG_FD
    opts = {"--tag": None, "--listen": None, "--connect": None, "--log": None, "--idle": "1800", "--max": "64"}
    foreground = False
    args = argv[1:]
    while args:
        arg = args.pop(0)
        if arg == "--foreground":
            foreground = True
        elif arg in opts and args:
            opts[arg] = args.pop(0)
        else:
            raise SystemExit("relay: unknown or incomplete argument '%s'" % arg)
    if None in (opts["--listen"], opts["--connect"], opts["--log"]):
        raise SystemExit("relay: --listen, --connect and --log are all needed")
    if not (opts["--idle"].isdigit() and opts["--max"].isdigit() and int(opts["--idle"]) > 0 and int(opts["--max"]) > 0):
        raise SystemExit("relay: --idle and --max are positive numbers")
    idle = int(opts["--idle"])
    most = int(opts["--max"])
    listen = endpoint(opts["--listen"])
    target = endpoint(opts["--connect"])
    one_address(listen[0])

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(listen)
    except OSError as err:
        raise SystemExit("relay: cannot listen on %s:%d: %s" % (listen[0], listen[1], err))
    server.listen(64)
    drop_root()
    LOG_FD = open_log(opts["--log"])

    if not foreground:
        pid = os.fork()
        if pid:
            sys.stdout.write("%d\n" % pid)
            sys.stdout.flush()
            os._exit(0)
        os.setsid()
        null = os.open(os.devnull, os.O_RDWR)
        os.dup2(null, 0)
        os.dup2(LOG_FD, 1)
        os.dup2(LOG_FD, 2)
        os.close(null)

    signal.signal(signal.SIGTERM, lambda _s, _f: STOP.append(1))
    signal.signal(signal.SIGINT, lambda _s, _f: STOP.append(1))
    slots = threading.BoundedSemaphore(most)
    server.settimeout(0.5)
    log("listening on %s:%d, connecting to %s:%d, pid %d, uid %d, at most %d connections, idle limit %d s"
        % (listen[0], listen[1], target[0], target[1], os.getpid(), os.getuid(), most, idle))
    while not STOP:
        try:
            client, peer = server.accept()
        except socket.timeout:
            continue
        except OSError as err:
            if not STOP:
                log("accept failed: %s" % err)
                time.sleep(0.2)
            continue
        if not slots.acquire(False):
            log("%s:%d turned away: %d connection(s) are open already" % (peer[0], peer[1], most))
            client.close()
            continue
        try:
            worker = threading.Thread(target=serve, args=(client, peer, target, idle, slots))
            worker.daemon = True
            worker.start()
        except Exception as err:
            slots.release()
            client.close()
            log("cannot start a worker: %r" % (err,))
    log("stopped")
    os._exit(0)


if __name__ == "__main__":
    main(sys.argv)
PYEOF
}

# start_relay <ip> <port> <tport>: 0 and a state record, or 1 with REASON
start_relay() {
  local ip=$1 port=$2 tport=$3 log=$STATE_DIR/relay-$1-$2.log mode=user pid started
  scratch
  if [ "$port" -lt 1024 ]; then
    mode=root
    pid=$(relay_source | "$SUDO" -n "$PY" -I - --tag "$TAG" --listen "$ip:$port" --connect "127.0.0.1:$tport" --log "$log" 2>"$TMPD/relay.err")
  else
    pid=$(relay_source | "$PY" -I - --tag "$TAG" --listen "$ip:$port" --connect "127.0.0.1:$tport" --log "$log" 2>"$TMPD/relay.err")
  fi
  if ! pid_ok "$pid"; then
    REASON=$(tr '\n' ' ' < "$TMPD/relay.err"); REASON=${REASON:-the relay printed no PID}
    return 1
  fi
  started=$(proc_start "$pid")
  if [ -z "$started" ]; then REASON="the relay (PID $pid) ended at once; see $log"; return 1; fi
  if ! state_add "relay $ip $port $tport $pid $mode $started"; then
    if stop_relay "$pid" "$mode"; then REASON="it started (PID $pid) but could not be recorded in $STATE, so it was stopped again"
    else REASON="it started (PID $pid), could not be recorded in $STATE AND COULD NOT BE STOPPED. By hand: sudo kill $pid"; fi
    return 1
  fi
  RELAY_PID=$pid; RELAY_MODE=$mode
}

# stop_relay <pid> <mode>: 0 when the process is gone
stop_relay() {
  local i=0
  if [ "$2" = root ]; then "$SUDO" -n "$KILL" "$1" </dev/null 2>/dev/null; else "$KILL" "$1" 2>/dev/null; fi
  while [ $i -lt 50 ]; do
    [ -n "$(proc_cmd "$1")" ] || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# --- leftovers: things that look like this script's and are not in the state file ------------
# A relay counts when its command line carries the tag and a log under THIS state directory.
# prints them with the command that removes each by hand; returns 1 when it found any
leftovers() {
  local all found=0 pid cmd line ip note="" recorded
  all=$("$PS" -ww -Ao pid=,command= 2>/dev/null)
  recorded=$(state_lines relay | awk '{ print $5 }')
  while read -r pid cmd; do
    [ -n "$pid" ] || continue
    case "$cmd " in *" - --tag $TAG --listen "*" --log $STATE_DIR/relay-"*) ;; *) continue ;; esac
    for line in $recorded; do [ "$line" = "$pid" ] && continue 2; done
    [ $found -eq 0 ] && say "LEFTOVERS that the state file does not record:"
    found=1
    echo "  relay    PID $pid: $cmd"
    echo "           remove by hand: sudo kill $pid"
  done <<EOF
$all
EOF
  if [ -r "$HOSTS" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      state_has "hosts $line" && state_check "hosts $line" && continue
      [ $found -eq 0 ] && say "LEFTOVERS that the state file does not record:"
      found=1
      echo "  hosts    $line"
      echo "           remove by hand: grep -v '$MARK\$' $HOSTS > ~/hosts.new && sudo cp ~/hosts.new $HOSTS && rm ~/hosts.new"
    done <<EOF
$(marked_lines)
EOF
  fi
  for ip in $(lo0_addrs); do
    private_ip "$ip" || continue
    state_has "alias $ip" && continue
    state_has "alias $ip pending" && continue
    note="$note  alias    $ip on lo0 is not recorded: it was there before \`up\`, or something else added it.
           only if it is a leftover of an earlier walk: sudo ifconfig lo0 -alias $ip
"
  done
  [ -n "$note" ] && { say "note, not counted as a leftover:"; printf '%s' "$note"; }
  [ $found -eq 0 ]
}

# --- up ---------------------------------------------------------------------------------------
cmd_up() {
  local ip port tport name oip own line rc=0 need_root=0 missing="" todo="" drop add n pid mode started a had_state=0
  require_macos "up"
  parse_list "$@"
  [ -n "$FWD" ] || die "nothing to do: give at least one --forward <lab ip>:<port>:<tunnel port> (or --file)"
  python_ok
  statedir_check
  if [ -d "$STATE_DIR" ]; then lock; had_state=1; fi
  state_audit
  [ "$STATE_BAD" -eq 0 ] || die "refused: $STATE holds line(s) this script did not write (above). Nothing was changed. Correct or delete them, or run: $SELF down"

  # an alias must not take the place of an address this Mac uses
  read_network
  for ip in $(printf '%s' "$FWD" | awk 'NF { print $1 }' | sort -u); do
    for a in $ALLOW; do [ "$a" = "$ip" ] && continue 2; done
    onlink "$ip" || die "refused: $REASON; an lo0 alias would take its place on this Mac. Nothing was changed. Only if that is what you want: --allow-onlink $ip"
  done

  # what is already up, and what is not listening
  while read -r ip port tport; do
    [ -n "$ip" ] || continue
    line=$(state_lines relay | awk -v i="$ip" -v p="$port" '$2 == i && $3 == p')
    if [ -n "$line" ]; then
      read -r _ _ _ oip pid mode started <<EOF
$line
EOF
      if our_relay "$pid" "$ip" "$port" "$started"; then
        [ "$oip" = "$tport" ] || die "refused: $ip:$port is already relayed to tunnel port $oip, not $tport. Take the old set down first: $SELF down"
      else
        state_del "$line" || die "cannot write $STATE; nothing else was changed"
        line=""
      fi
    fi
    if ! listening "$tport"; then
      missing="$missing $tport"
      wildcard "$tport" && echo "$PROG: tunnel port $tport: $WILDCARD_WARNING" >&2
    fi
    if [ -z "$line" ]; then
      todo="$todo$ip $port $tport
"
      [ "$port" -lt 1024 ] && need_root=1
    fi
    lo0_has "$ip" || need_root=1
  done <<EOF
$FWD
EOF
  if [ -n "$missing" ]; then
    echo "$PROG: refused: nothing listens on 127.0.0.1 for tunnel port(s)$missing, and nothing was changed." >&2
    echo "$PROG: the tunnels are the owner's to open. He runs this on the lab host, for the whole list:" >&2
    tunnel_line "$FWD" >&2
    exit 2
  fi

  # the names
  scratch; drop=$TMPD/hosts.drop; add=$TMPD/hosts.add
  : > "$drop"; : > "$add"
  while read -r name ip; do
    [ -n "$name" ] || continue
    printf '%s\n%s\n' "$FWD" "$(state_forwards)" | awk -v i="$ip" '$1 == i { f = 1 } END { exit !f }' ||
      die "refused: --host $name=$ip names an address no forward is given for; add --forward $ip:<port>:<tunnel port>"
    n=0
    while read -r oip own; do
      [ -n "$oip" ] || continue
      if [ "$oip" = "$ip" ]; then n=1; continue; fi
      [ "$own" = own ] || die "refused: $HOSTS already gives $name the address $oip, in a line this script did not write. Nothing was changed. Look at it: grep -n '$name' $HOSTS"
      marked_lines | awk -v w="$name" -v o="$oip" '$1 == o { for (i = 2; i <= NF; i++) if (tolower($i) == tolower(w)) print $0 }' >> "$drop"
    done <<EOF
$(hosts_entries "$name")
EOF
    if [ $n -eq 0 ]; then hosts_line "$name" "$ip" >> "$add"; printf '\n' >> "$add"; fi
  done <<EOF
$HST
EOF
  if [ -s "$add" ] || [ -s "$drop" ]; then need_root=1; fi
  [ $need_root -eq 0 ] || require_sudo
  statedir_make
  lock
  if [ $had_state -eq 0 ] && [ -s "$STATE" ]; then die "refused: another run wrote $STATE meanwhile. Nothing was changed by this one; run it again."; fi

  # 1. aliases: recorded as pending, added, then confirmed
  for ip in $(printf '%s' "$FWD" | awk 'NF { print $1 }' | sort -u); do
    if state_has "alias $ip pending"; then
      say "alias  $ip on lo0: an earlier \`up\` was interrupted while adding it; finishing"
    elif lo0_has "$ip"; then
      if state_has "alias $ip"; then say "alias  $ip on lo0: already up"
      else say "alias  $ip on lo0: was there before, left alone (and \`down\` will leave it)"; fi
      continue
    elif ! state_add "alias $ip pending"; then
      say "alias  $ip on lo0: NOT ADDED, it could not be recorded in $STATE first"; rc=1; continue
    fi
    if ! lo0_has "$ip"; then "$SUDO" -n "$IFCONFIG" lo0 alias "$ip" netmask 255.255.255.255 </dev/null; fi
    if lo0_has "$ip"; then
      if state_add "alias $ip" && state_del "alias $ip pending"; then say "alias  $ip on lo0: added"
      else say "alias  $ip on lo0: added, but $STATE could not be written; it stays recorded as pending and \`down\` removes it"; rc=1; fi
    else
      state_del "alias $ip pending"
      say "alias  $ip on lo0: COULD NOT BE ADDED. By hand: sudo ifconfig lo0 alias $ip netmask 255.255.255.255"; rc=1
    fi
  done

  # 2. relays
  while read -r ip port tport; do
    [ -n "$ip" ] || continue
    if ! printf '%s' "$todo" | grep -qxF -- "$ip $port $tport"; then
      say "relay  $ip:$port -> 127.0.0.1:$tport: already up"; continue
    fi
    if ! lo0_has "$ip"; then say "relay  $ip:$port: NOT STARTED, lo0 has no $ip"; rc=1; continue; fi
    if start_relay "$ip" "$port" "$tport"; then
      say "relay  $ip:$port -> 127.0.0.1:$tport: started, PID $RELAY_PID ($RELAY_MODE)"
    else
      say "relay  $ip:$port -> 127.0.0.1:$tport: COULD NOT START: $REASON"; rc=1
    fi
  done <<EOF
$FWD
EOF

  # 3. names: recorded first, then written
  if [ -s "$add" ] || [ -s "$drop" ]; then
    n=0
    while IFS= read -r line; do state_add "hosts $line" || n=1; done < "$add"
    if [ $n -ne 0 ]; then
      while IFS= read -r line; do state_del "hosts $line"; done < "$add"
      say "hosts  $HOSTS was NOT changed: the new lines could not be recorded in $STATE first"; rc=1
    elif hosts_write "$drop" "$add"; then
      while IFS= read -r line; do state_del "hosts $line" || rc=1; done < "$drop"
      while IFS= read -r line; do say "hosts  $line: added to $HOSTS"; done < "$add"
    else
      while IFS= read -r line; do state_del "hosts $line"; done < "$add"
      say "hosts  the line(s) that are therefore missing from $HOSTS:"; cat "$add"; rc=1
    fi
  fi
  while read -r name ip; do
    [ -n "$name" ] || continue
    line=$(hosts_line "$name" "$ip")
    grep -qxF -- "$line" "$add" && continue
    if grep -qxF -- "$line" "$HOSTS"; then
      state_has "hosts $line" || state_add "hosts $line" || rc=1
      say "hosts  $name = $ip: already up"
    else
      say "hosts  $name = $ip: was there before, left alone (and \`down\` will leave it)"
    fi
  done <<EOF
$HST
EOF

  if [ $rc -eq 0 ]; then say "up. See it: $SELF status    Undo it: $SELF down"
  else say "NOT fully up (see above). What was created is recorded; undo it: $SELF down"; fi
  return $rc
}

# --- status -----------------------------------------------------------------------------------
cmd_status() {
  local rc=0 kind a b c d e rest dead="" line
  [ $# -eq 0 ] || die "status takes no argument"
  require_macos "status"
  statedir_check
  if [ ! -s "$STATE" ]; then
    say "no state file ($STATE): this script has nothing up."
    [ -f "$STATE_DIR/hosts.backup" ] && say "a backup of the hosts file from an earlier run is kept: $STATE_DIR/hosts.backup"
    [ -d "$LOCK" ] && say "a lock is held: $LOCK (PID $(cat "$LOCK/pid" 2>/dev/null))"
    leftovers || return 1
    say "no leftovers found."
    return 0
  fi
  state_audit
  [ "$STATE_BAD" -eq 0 ] || rc=1
  say "recorded in $STATE:"
  while read -r kind a b; do
    [ -n "$kind" ] || continue
    if [ "$b" = pending ]; then
      echo "  alias    $a on lo0: PENDING (an \`up\` was interrupted while adding it); it is $(lo0_has "$a" && echo present || echo absent)"; rc=1
    elif lo0_has "$a"; then echo "  alias    $a on lo0: present"
    else echo "  alias    $a on lo0: MISSING"; rc=1; fi
  done <<EOF
$(state_lines alias)
EOF
  while read -r kind a b c d e rest; do
    [ -n "$kind" ] || continue
    if our_relay "$d" "$a" "$b" "$rest"; then echo "  relay    $a:$b -> 127.0.0.1:$c: running, PID $d (started as $e), log $STATE_DIR/relay-$a-$b.log"
    else echo "  relay    $a:$b -> 127.0.0.1:$c: NOT RUNNING ($REASON)"; rc=1; fi
    if listening "$c"; then echo "  tunnel   127.0.0.1:$c: listening"
    else echo "  tunnel   127.0.0.1:$c: NOT LISTENING"; rc=1; dead=1; fi
    if wildcard "$c"; then echo "  tunnel   WARNING, port $c: $WILDCARD_WARNING"; rc=1; fi
  done <<EOF
$(state_lines relay)
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qxF -- "$line" "$HOSTS"; then echo "  hosts    $line: present"; else echo "  hosts    $line: MISSING from $HOSTS"; rc=1; fi
  done <<EOF
$(state_lines hosts | sed 's/^hosts //')
EOF
  if [ -n "$dead" ]; then
    say "a tunnel is the owner's to open. His line, on the lab host, for every recorded forward:"
    tunnel_line "$(state_forwards)"
  fi
  leftovers || rc=1
  if [ $rc -eq 0 ]; then say "all of it is up. Undo it: $SELF down"
  else say "NOT all of it is up (see above). Start again with \`$SELF up …\`, or undo it: $SELF down"; fi
  return $rc
}

# --- down -------------------------------------------------------------------------------------
# down_backup <copy of the hosts file from before this run, or "">: delete the backup only when
# the hosts file is clean; 0 when the state directory is gone afterwards
down_backup() {
  local pre=$1 f
  if [ ! -f "$STATE_DIR/hosts.backup" ]; then
    rm -f "$STATE_DIR"/hosts.new.* "$STATE_DIR"/hosts.pre.* "$STATE_DIR/hosts.backup.tmp" "$STATE.tmp"
    return 0
  fi
  if [ -z "$pre" ]; then
    scratch; pre=$TMPD/hosts.now
    cat "$HOSTS" > "$pre" || { say "hosts  cannot read $HOSTS; the backup $STATE_DIR/hosts.backup is KEPT"; return 1; }
  fi
  for f in "$STATE_DIR"/hosts.snap.*; do
    [ -e "$f" ] || continue
    say "hosts  the backup $STATE_DIR/hosts.backup is KEPT: a run could not finish writing $HOSTS, and what it held before is in $f"
    say "hosts  compare them (diff $f $HOSTS); put it back if needed (sudo cp $f $HOSTS); then delete $f and run \`$SELF down\` again"
    return 1
  done
  if hosts_intact "$pre"; then
    rm -f "$STATE_DIR/hosts.backup" "$STATE_DIR"/hosts.new.* "$STATE_DIR"/hosts.pre.* "$STATE_DIR/hosts.backup.tmp" "$STATE.tmp"
    return 0
  fi
  say "hosts  the backup $STATE_DIR/hosts.backup is KEPT: $REASON"
  return 1
}

cmd_down() {
  local need_root=0 kind a b c d e rest line drop add rc=0 pre="" w
  [ $# -eq 0 ] || die "down takes no argument: it removes what the state file records"
  require_macos "down"
  statedir_check
  if [ ! -s "$STATE" ]; then
    say "nothing to remove: no state file ($STATE)."
    if [ -d "$STATE_DIR" ]; then
      lock
      rm -f "$STATE"
      if down_backup ""; then rm -rf "$LOCK"; LOCKED=0; rmdir "$STATE_DIR" 2>/dev/null; fi
    fi
    leftovers || true
    return 0
  fi
  lock
  state_audit
  [ "$STATE_BAD" -eq 0 ] || rc=1
  while read -r kind a b c d e rest; do
    case $kind in
      alias) lo0_has "$a" && need_root=1 ;;
      relay) [ "$e" = root ] && our_relay "$d" "$a" "$b" "$rest" && need_root=1 ;;
    esac
  done <<EOF
$(state_lines alias; state_lines relay)
EOF
  [ -z "$(state_lines hosts)" ] || need_root=1
  [ $need_root -eq 0 ] || require_sudo

  # 1. names: a line is taken out only when it is recorded, passes the state check (which
  #    demands the marker) and is in the file exactly so
  pre=$(mktemp "$STATE_DIR/hosts.pre.XXXXXX") || die "cannot create a work file in $STATE_DIR; nothing was changed"
  cat "$HOSTS" > "$pre" || die "cannot take a copy of $HOSTS in $STATE_DIR; nothing was changed"
  cmp -s "$pre" "$HOSTS" || die "cannot take a copy of $HOSTS in $STATE_DIR; nothing was changed"
  scratch; drop=$TMPD/hosts.drop; add=$TMPD/hosts.add
  : > "$drop"; : > "$add"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qxF -- "$line" "$HOSTS"; then printf '%s\n' "$line" >> "$drop"
    else say "hosts  $line: already gone"; state_del "hosts $line" || rc=1; fi
  done <<EOF
$(state_lines hosts | sed 's/^hosts //')
EOF
  if [ -s "$drop" ]; then
    hosts_write "$drop" "$add"; w=$?
    if [ $w -eq 0 ]; then
      while IFS= read -r line; do
        if state_del "hosts $line"; then say "hosts  $line: removed from $HOSTS"
        else say "hosts  $line: removed from $HOSTS, but $STATE could not be written"; rc=1; fi
      done < "$drop"
    else
      [ $w -eq 2 ] || { say "hosts  these lines are therefore still in $HOSTS:"; cat "$drop"; }
      rc=1
    fi
  fi

  # 2. relays, by exact PID, only while the PID is still the relay
  while read -r kind a b c d e rest; do
    [ "$kind" = relay ] || continue
    line="relay $a $b $c $d $e $rest"
    if ! our_relay "$d" "$a" "$b" "$rest"; then
      say "relay  $a:$b: nothing killed: $REASON"; state_del "$line" || rc=1; continue
    fi
    if stop_relay "$d" "$e"; then say "relay  $a:$b: stopped (PID $d)"; state_del "$line" || rc=1
    else say "relay  $a:$b: PID $d COULD NOT BE STOPPED. By hand: sudo kill $d"; rc=1; fi
  done <<EOF
$(state_lines relay)
EOF

  # 3. aliases this script added (a pending one too: `up` was interrupted while adding it)
  while read -r kind a b; do
    [ "$kind" = alias ] || continue
    line="alias $a${b:+ $b}"
    if ! lo0_has "$a"; then say "alias  $a on lo0: already gone"; state_del "$line" || rc=1; continue; fi
    "$SUDO" -n "$IFCONFIG" lo0 -alias "$a" </dev/null
    if ! lo0_has "$a"; then say "alias  $a on lo0: removed"; state_del "$line" || rc=1
    else say "alias  $a on lo0: COULD NOT BE REMOVED. By hand: sudo ifconfig lo0 -alias $a"; rc=1; fi
  done <<EOF
$(state_lines alias)
EOF

  if [ $rc -eq 0 ] && [ ! -s "$STATE" ]; then
    rm -f "$STATE" "$STATE_DIR"/relay-*.log
    if down_backup "$pre"; then
      rm -rf "$LOCK"; LOCKED=0
      rmdir "$STATE_DIR" 2>/dev/null
      say "down: everything this script created is removed, its state directory too."
    else
      rm -f "$pre"
      say "down: everything this script recorded is removed; $STATE_DIR stays because of the hosts backup (above)."
    fi
    leftovers || true
    say "the tunnels are the owner's: he ends his ssh on the lab host."
    return 0
  fi
  rm -f "$pre"
  say "NOT everything was removed. What is left is still recorded in $STATE:"
  sed 's/^/  /' "$STATE"
  [ ! -f "$STATE_DIR/hosts.backup" ] || say "the first original of the hosts file is kept: $STATE_DIR/hosts.backup"
  return 1
}

cmd_print_tunnel() {
  parse_list "$@"
  [ -n "$FWD" ] || FWD=$(state_forwards)
  [ -n "$FWD" ] || die "no forward given and none recorded: give --forward <lab ip>:<port>:<tunnel port> (or --file)"
  tunnel_line "$FWD"
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd=$1; shift
case $cmd in
  up) cmd_up "$@" ;;
  status) cmd_status "$@" ;;
  down) cmd_down "$@" ;;
  print-tunnel) cmd_print_tunnel "$@" ;;
  relay-source) relay_source ;;
  -h | --help | help) usage ;;
  *) die "unknown command '$cmd' (up, status, down, print-tunnel)" ;;
esac
