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
# Ownership: everything `up` creates is written to
#   ${XDG_STATE_HOME:-$HOME/.local/state}/vks-mac-route/state
# and `down` removes only that: an alias it added (never one that was there before), a relay
# by its exact PID after checking the start time and the command line (a reused PID is left
# alone), a hosts line that is recorded AND still carries the marker. `down` twice is safe.
#
# Root: the alias, a relay on a port below 1024 and the /etc/hosts change need it. Only
# `sudo -n` is used; when it would ask for a password the script stops BEFORE changing anything
# and says to run `sudo -v`. No password is read or stored. /etc/hosts is changed through a
# temp file and `sudo -n cp` (the file's mode and owner stay), with a backup of the first
# original in the state directory; it is never edited in place.
#
# The relay is one process PER FORWARD: the app's address exists only after the guide's deploy
# step, so a forward is added to a running set, and that must not cut the connections the
# other forwards carry. It is `/usr/bin/python3` (Command Line Tools) running a small
# dependency-free script this file writes to the state directory; a relay binds the alias IP
# only and runs as root only when its port is below 1024.
#
# "Is the tunnel port listening" is asked with `lsof -nP -iTCP@127.0.0.1:<port> -sTCP:LISTEN`
# (macOS ships lsof). It reads the socket table; `nc -z` would open a real connection through
# the tunnel to the lab service on every check.
#
# Needs bash 3.2+ (macOS /bin/bash). Test seams, not for a walk: MAC_ROUTE_HOSTS (the hosts
# file), MAC_ROUTE_PYTHON (the interpreter). vks/test/README.md has the procedure.
set -u
umask 077

PROG=mac-route
SELF=$0
MARK='# vks-mac-route'
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/vks-mac-route
STATE=$STATE_DIR/state
RELAY=$STATE_DIR/relay.py
HOSTS=${MAC_ROUTE_HOSTS:-/etc/hosts}
PY=${MAC_ROUTE_PYTHON:-/usr/bin/python3}

FWD=""   # one "ip port tunnelport" per line
HST=""   # one "name ip" per line
MAC=""   # the ssh target of this Mac, for the owner's line
REASON=""

TMPD=""
scratch() { TMPD=$(mktemp -d) || die "mktemp failed"; trap 'rm -rf "$TMPD"' EXIT; }
say()  { echo "$PROG: $*"; }
die()  { echo "$PROG: $*" >&2; exit 2; }
usage() { sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'; }

# --- validation -------------------------------------------------------------------------------
# private_ip <ip>: 0 when it is a private IPv4 address; else 1 with REASON set.
private_ip() {
  local ip=$1 a b c d rest o
  REASON="$ip: not an IPv4 address (four numbers 0-255)"
  case $ip in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
  IFS=. read -r a b c d rest <<EOF
$ip
EOF
  [ -n "${d:-}" ] && [ -z "${rest:-}" ] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    case $o in 0 | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;; *) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
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

name_ok() {
  local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
  [ "${#1}" -le 253 ] || return 1
  [[ $1 =~ $re ]] || return 1
  case $1 in *[!0-9.]*) ;; *) return 1 ;; esac
  case $1 in localhost | broadcasthost) return 1 ;; esac
  return 0
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
      --mac)     [ $# -ge 2 ] || die "--mac needs <user>@<this Mac>"; MAC=$2; shift 2
                 case $MAC in *[!A-Za-z0-9@._:-]* | -*) die "--mac '$MAC': expected <user>@<address>" ;; esac ;;
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
  if [ "$PY" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then
    die "refused: /usr/bin/python3 is only a placeholder until the Command Line Tools are installed. Run: xcode-select --install"
  fi
}

sudo_ok() { sudo -n true </dev/null 2>/dev/null; }
require_sudo() {
  sudo_ok || die "refused: sudo would ask for a password, and nothing was changed. Run this first, then the same command again: sudo -v"
}

lo0_has() { ifconfig lo0 2>/dev/null | awk -v ip="$1" '$1 == "inet" && $2 == ip { f = 1 } END { exit !f }'; }
lo0_private() {
  ifconfig lo0 2>/dev/null | awk '$1 == "inet" { print $2 }' | while read -r ip; do
    private_ip "$ip" && echo "$ip"
  done
}

listening() {
  local out
  out=$(lsof -nP -iTCP@127.0.0.1:"$1" -sTCP:LISTEN 2>/dev/null </dev/null)
  [ -n "$out" ] && return 0
  sudo_ok || return 1
  out=$(sudo -n lsof -nP -iTCP@127.0.0.1:"$1" -sTCP:LISTEN 2>/dev/null </dev/null)
  [ -n "$out" ]
}

proc_start() { LC_ALL=C ps -ww -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }
proc_cmd()   { ps -ww -o command= -p "$1" 2>/dev/null; }

# our_relay <pid> <ip> <port> <start time>: 0 when that PID is still the relay this script
# started; else 1 with REASON set.
our_relay() {
  local cmd
  cmd=$(proc_cmd "$1")
  if [ -z "$cmd" ]; then REASON="no process has PID $1 any more"; return 1; fi
  case "$cmd " in
    *"$RELAY --listen $2:$3 "*) ;;
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
    read -r _ _ sip sport <<EOF
$SSH_CONNECTION
EOF
    target="$(id -un)@$sip"
    [ "${sport:-22}" = 22 ] || popt=" -p $sport"
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

# --- the state file ---------------------------------------------------------------------------
state_lines() { [ -f "$STATE" ] && grep "^$1 " "$STATE"; }
state_add()   { mkdir -p "$STATE_DIR" && printf '%s\n' "$1" >> "$STATE"; }
state_del() {
  [ -f "$STATE" ] || return 0
  grep -vxF -- "$1" "$STATE" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}
state_forwards() { state_lines relay | awk '{ print $2, $3, $4 }'; }

# --- /etc/hosts -------------------------------------------------------------------------------
hosts_line() { printf '%s\t%s\t%s' "$2" "$1" "$MARK"; }   # <name> <ip>

# the lines of the hosts file that end in the marker
marked_lines() { awk -v mark="$MARK" '{ n = length($0) - length(mark) } n >= 0 && substr($0, n + 1) == mark' "$HOSTS"; }

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
hosts_write() {
  local new=$STATE_DIR/hosts.new
  mkdir -p "$STATE_DIR" || return 1
  if [ ! -f "$STATE_DIR/hosts.backup" ]; then
    cp "$HOSTS" "$STATE_DIR/hosts.backup" || { say "cannot save a backup of $HOSTS; it was not changed"; return 1; }
  fi
  if [ -s "$1" ]; then grep -vxFf "$1" "$HOSTS" | awk 1 > "$new"; else awk 1 "$HOSTS" > "$new"; fi
  cat "$2" >> "$new"
  sudo -n cp "$new" "$HOSTS" </dev/null || { rm -f "$new"; return 1; }
  cmp -s "$new" "$HOSTS" || { rm -f "$new"; return 1; }
  rm -f "$new"
}

# --- the relay --------------------------------------------------------------------------------
write_relay() {
  cat > "$1" <<'PYEOF'
#!/usr/bin/python3
"""TCP relay for vks/test/mac-route.sh: listen on ONE address, connect each client onward.

relay.py --listen IP:PORT --connect IP:PORT --log PATH [--foreground]

It binds first, so a bind error is reported by the command itself; then it goes to the
background and prints the PID of the process that stays. No payload is logged.
"""
import os
import signal
import socket
import sys
import threading
import time

CONNECT_TIMEOUT = 10
LOG = None
LOCK = threading.Lock()


def log(text):
    with LOCK:
        LOG.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), text))
        LOG.flush()


def endpoint(text):
    host, _, port = text.rpartition(":")
    if not host or not port.isdigit():
        raise SystemExit("relay: '%s' is not IP:PORT" % text)
    return host, int(port)


def pump(src, dst, count, key):
    """Copy src to dst until src ends, then pass the end on (half-close)."""
    clean = True
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            count[key] += len(data)
    except OSError:
        clean = False
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    if not clean:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(client, peer, target):
    count = {"out": 0, "back": 0}
    try:
        onward = socket.create_connection(target, CONNECT_TIMEOUT)
    except OSError as err:
        log("%s:%d refused: cannot connect to %s:%d: %s" % (peer[0], peer[1], target[0], target[1], err))
        client.close()
        return
    onward.settimeout(None)
    back = threading.Thread(target=pump, args=(onward, client, count, "back"))
    back.daemon = True
    back.start()
    pump(client, onward, count, "out")
    back.join()
    client.close()
    onward.close()
    log("%s:%d closed: %d bytes out, %d bytes back" % (peer[0], peer[1], count["out"], count["back"]))


def main(argv):
    global LOG
    opts = {"--listen": None, "--connect": None, "--log": None}
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
    if None in opts.values():
        raise SystemExit("relay: --listen, --connect and --log are all needed")
    listen = endpoint(opts["--listen"])
    target = endpoint(opts["--connect"])
    if listen[0] in ("0.0.0.0", "", "*", "::"):
        raise SystemExit("relay: refusing to listen on every address")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(listen)
    except OSError as err:
        raise SystemExit("relay: cannot listen on %s:%d: %s" % (listen[0], listen[1], err))
    server.listen(64)
    LOG = open(opts["--log"], "a")

    if not foreground:
        pid = os.fork()
        if pid:
            sys.stdout.write("%d\n" % pid)
            sys.stdout.flush()
            os._exit(0)
        os.setsid()
        null = os.open(os.devnull, os.O_RDWR)
        os.dup2(null, 0)
        os.dup2(LOG.fileno(), 1)
        os.dup2(LOG.fileno(), 2)
        os.close(null)

    def stop(_signum, _frame):
        log("stopped")
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log("listening on %s:%d, connecting to %s:%d, pid %d" % (listen[0], listen[1], target[0], target[1], os.getpid()))
    while True:
        try:
            client, peer = server.accept()
        except OSError as err:
            log("accept failed: %s" % err)
            time.sleep(0.2)
            continue
        worker = threading.Thread(target=serve, args=(client, peer, target))
        worker.daemon = True
        worker.start()


if __name__ == "__main__":
    main(sys.argv)
PYEOF
}

# start_relay <ip> <port> <tport>: 0 and a state record, or 1 with REASON
start_relay() {
  local ip=$1 port=$2 tport=$3 log=$STATE_DIR/relay-$1-$2.log mode=user pid started
  : >> "$log"
  if [ "$port" -lt 1024 ]; then
    mode=root
    pid=$(sudo -n "$PY" "$RELAY" --listen "$ip:$port" --connect "127.0.0.1:$tport" --log "$log" 2>"$STATE_DIR/relay.err" </dev/null)
  else
    pid=$("$PY" "$RELAY" --listen "$ip:$port" --connect "127.0.0.1:$tport" --log "$log" 2>"$STATE_DIR/relay.err" </dev/null)
  fi
  case $pid in '' | *[!0-9]*)
    REASON=$(tr '\n' ' ' < "$STATE_DIR/relay.err"); REASON=${REASON:-the relay printed no PID}
    rm -f "$STATE_DIR/relay.err"; return 1 ;;
  esac
  rm -f "$STATE_DIR/relay.err"
  started=$(proc_start "$pid")
  if [ -z "$started" ]; then REASON="the relay (PID $pid) ended at once; see $log"; return 1; fi
  state_add "relay $ip $port $tport $pid $mode $started"
  RELAY_PID=$pid; RELAY_MODE=$mode
}

# stop_relay <pid> <mode>: 0 when the process is gone
stop_relay() {
  local i=0
  if [ "$2" = root ]; then sudo -n kill "$1" </dev/null 2>/dev/null; else kill "$1" 2>/dev/null; fi
  while [ $i -lt 50 ]; do
    [ -n "$(proc_cmd "$1")" ] || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# --- leftovers: things that look like this script's and are not in the state file ------------
# prints them with the command that removes each by hand; returns 1 when it found any
leftovers() {
  local all found=0 pid cmd line ip note=""
  all=$(ps -ww -Ao pid=,command= 2>/dev/null)
  while read -r pid cmd; do
    [ -n "$pid" ] || continue
    case "$cmd" in *"$RELAY --listen "*) ;; *) continue ;; esac
    state_lines relay 2>/dev/null | awk -v p="$pid" '$5 == p { f = 1 } END { exit !f }' && continue
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
      [ -f "$STATE" ] && grep -qxF -- "hosts $line" "$STATE" && continue
      [ $found -eq 0 ] && say "LEFTOVERS that the state file does not record:"
      found=1
      echo "  hosts    $line"
      echo "           remove by hand: grep -v '$MARK\$' $HOSTS > ~/hosts.new && sudo cp ~/hosts.new $HOSTS && rm ~/hosts.new"
    done <<EOF
$(marked_lines)
EOF
  fi
  for ip in $(lo0_private); do
    [ -f "$STATE" ] && grep -qxF -- "alias $ip" "$STATE" && continue
    note="$note  alias    $ip on lo0 is not recorded: it was there before \`up\`, or something else added it.
           only if it is a leftover of an earlier walk: sudo ifconfig lo0 -alias $ip
"
  done
  [ -n "$note" ] && { say "note, not counted as a leftover:"; printf '%s' "$note"; }
  [ $found -eq 0 ]
}

# --- up ---------------------------------------------------------------------------------------
cmd_up() {
  local ip port tport name oip own line rc=0 need_root=0 missing="" todo="" drop add n pid mode started rest
  require_macos "up"
  parse_list "$@"
  [ -n "$FWD" ] || die "nothing to do: give at least one --forward <lab ip>:<port>:<tunnel port> (or --file)"
  python_ok

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
        state_del "$line"; line=""
      fi
    fi
    listening "$tport" || missing="$missing $tport"
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
    [ $n -eq 1 ] || hosts_line "$name" "$ip" >> "$add"
    [ $n -eq 1 ] || printf '\n' >> "$add"
  done <<EOF
$HST
EOF
  if [ -s "$add" ] || [ -s "$drop" ]; then need_root=1; fi
  [ $need_root -eq 0 ] || require_sudo
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"

  # 1. aliases
  for ip in $(printf '%s' "$FWD" | awk 'NF { print $1 }' | sort -u); do
    if lo0_has "$ip"; then
      if grep -qxF -- "alias $ip" "$STATE" 2>/dev/null; then say "alias  $ip on lo0: already up"
      else say "alias  $ip on lo0: was there before, left alone (and \`down\` will leave it)"; fi
      continue
    fi
    if sudo -n ifconfig lo0 alias "$ip" 255.255.255.255 </dev/null && lo0_has "$ip"; then
      state_add "alias $ip"; say "alias  $ip on lo0: added"
    else
      say "alias  $ip on lo0: COULD NOT BE ADDED. By hand: sudo ifconfig lo0 alias $ip 255.255.255.255"; rc=1
    fi
  done

  # 2. relays
  write_relay "$RELAY.new" && { cmp -s "$RELAY.new" "$RELAY" 2>/dev/null || cp "$RELAY.new" "$RELAY"; }; rm -f "$RELAY.new"
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

  # 3. names
  if [ -s "$add" ] || [ -s "$drop" ]; then
    if hosts_write "$drop" "$add"; then
      while IFS= read -r line; do state_del "hosts $line"; done < "$drop"
      while IFS= read -r line; do state_add "hosts $line"; say "hosts  $line: added to $HOSTS"; done < "$add"
    else
      say "hosts  $HOSTS COULD NOT BE CHANGED. The lines that are missing:"; cat "$add"; rc=1
    fi
  fi
  while read -r name ip; do
    [ -n "$name" ] || continue
    grep -qxF -- "$(hosts_line "$name" "$ip")" "$add" && continue
    line=$(hosts_line "$name" "$ip")
    if grep -qxF -- "$line" "$HOSTS"; then
      grep -qxF -- "hosts $line" "$STATE" 2>/dev/null || state_add "hosts $line"
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
  local rc=0 kind a b c d e rest dead=""
  [ $# -eq 0 ] || die "status takes no argument"
  require_macos "status"
  if [ ! -s "$STATE" ]; then
    say "no state file ($STATE): this script has nothing up."
    leftovers || return 1
    say "no leftovers found."
    return 0
  fi
  say "recorded in $STATE:"
  while read -r kind a b c d e rest; do
    case $kind in
      alias)
        if lo0_has "$a"; then echo "  alias    $a on lo0: present"; else echo "  alias    $a on lo0: MISSING"; rc=1; fi ;;
      relay)
        if our_relay "$d" "$a" "$b" "$rest"; then echo "  relay    $a:$b -> 127.0.0.1:$c: running, PID $d ($e), log $STATE_DIR/relay-$a-$b.log"
        else echo "  relay    $a:$b -> 127.0.0.1:$c: NOT RUNNING ($REASON)"; rc=1; fi
        if listening "$c"; then echo "  tunnel   127.0.0.1:$c: listening"
        else echo "  tunnel   127.0.0.1:$c: NOT LISTENING"; rc=1; dead=1; fi ;;
    esac
  done < "$STATE"
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    if grep -qxF -- "$rest" "$HOSTS"; then echo "  hosts    $rest: present"; else echo "  hosts    $rest: MISSING from $HOSTS"; rc=1; fi
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
cmd_down() {
  local need_root=0 kind a b c d e rest line drop add rc=0
  [ $# -eq 0 ] || die "down takes no argument: it removes what the state file records"
  require_macos "down"
  if [ ! -s "$STATE" ]; then
    say "nothing to remove: no state file ($STATE)."
    rm -f "$STATE" 2>/dev/null
    leftovers || true
    return 0
  fi
  while read -r kind a b c d e rest; do
    case $kind in
      alias) lo0_has "$a" && need_root=1 ;;
      relay) [ "$e" = root ] && our_relay "$d" "$a" "$b" "$rest" && need_root=1 ;;
      hosts) need_root=1 ;;
    esac
  done < "$STATE"
  [ $need_root -eq 0 ] || require_sudo

  # 1. names: a line must be recorded AND still be in the file with its marker
  scratch; drop=$TMPD/hosts.drop; add=$TMPD/hosts.add
  : > "$drop"; : > "$add"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in *"$MARK") ;; *) say "hosts  '$line' is recorded without the marker: left alone"; state_del "hosts $line"; continue ;; esac
    if grep -qxF -- "$line" "$HOSTS"; then printf '%s\n' "$line" >> "$drop"
    else say "hosts  $line: already gone"; state_del "hosts $line"; fi
  done <<EOF
$(state_lines hosts | sed 's/^hosts //')
EOF
  if [ -s "$drop" ]; then
    if hosts_write "$drop" "$add"; then
      while IFS= read -r line; do state_del "hosts $line"; say "hosts  $line: removed from $HOSTS"; done < "$drop"
    else
      say "hosts  $HOSTS COULD NOT BE CHANGED; these lines are still in it:"; cat "$drop"; rc=1
    fi
  fi

  # 2. relays, by exact PID, only while the PID is still the relay
  while read -r kind a b c d e rest; do
    [ "$kind" = relay ] || continue
    line="relay $a $b $c $d $e $rest"
    if ! our_relay "$d" "$a" "$b" "$rest"; then
      say "relay  $a:$b: nothing killed: $REASON"; state_del "$line"; continue
    fi
    if stop_relay "$d" "$e"; then say "relay  $a:$b: stopped (PID $d)"; state_del "$line"
    else say "relay  $a:$b: PID $d COULD NOT BE STOPPED. By hand: sudo kill $d"; rc=1; fi
  done <<EOF
$(state_lines relay)
EOF

  # 3. aliases this script added
  while read -r kind a rest; do
    [ "$kind" = alias ] || continue
    if ! lo0_has "$a"; then say "alias  $a on lo0: already gone"; state_del "alias $a"; continue; fi
    if sudo -n ifconfig lo0 -alias "$a" </dev/null && ! lo0_has "$a"; then say "alias  $a on lo0: removed"; state_del "alias $a"
    else say "alias  $a on lo0: COULD NOT BE REMOVED. By hand: sudo ifconfig lo0 -alias $a"; rc=1; fi
  done <<EOF
$(state_lines alias)
EOF

  if [ $rc -eq 0 ] && [ ! -s "$STATE" ]; then
    rm -f "$STATE" "$RELAY" "$STATE_DIR"/relay-*.log "$STATE_DIR/hosts.backup" "$STATE_DIR/relay.err"
    rmdir "$STATE_DIR" 2>/dev/null
    say "down: everything this script created is removed, its state directory too."
    leftovers || true
    say "the tunnels are the owner's: he ends his ssh on the lab host."
    return 0
  fi
  say "NOT everything was removed. What is left is still recorded in $STATE:"
  sed 's/^/  /' "$STATE"
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
  write-relay) [ $# -eq 1 ] || die "write-relay needs a path"; write_relay "$1" ;;
  -h | --help | help) usage ;;
  *) die "unknown command '$cmd' (up, status, down, print-tunnel)" ;;
esac
