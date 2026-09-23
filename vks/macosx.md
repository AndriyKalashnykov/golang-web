# macOS verification probes

`vks/README.md` was proven end-to-end on **native Linux**. Four of its steps are
platform-specific and could not be run here, because on macOS both container engines run a Linux
VM and the TLS check happens *inside* it.

Run the script below on a Mac that can reach the Harbor and Supervisor endpoints, then save the
output as `vks/macosx.res`. Anything it contradicts gets fixed in the README.

**It is read-only except for two things it states before doing them:** it installs a CA into your
trust store, and (podman only) it may restart your podman machine. It never sends a credential —
every probe is unauthenticated, so a wrong value costs nothing.

## Fill these in, then paste the whole block into Terminal

```sh
export HARBOR_FQDN="harbor.example.test"     # <-- your Harbor DNS name
export VCENTER_FQDN="vcsa.example.test"      # <-- your vCenter FQDN
export SUPERVISOR_ENDPOINT="10.0.0.10"       # <-- your Supervisor API endpoint
export OUT="$HOME/macosx.res"
```

## Then run this

```sh
{
for v in HARBOR_FQDN VCENTER_FQDN SUPERVISOR_ENDPOINT; do
  eval "val=\$$v"
  case "$val" in ""|*example.test|10.0.0.10)
    printf 'STOP: %s is still the placeholder (%s).\n' "$v" "$val"
    printf '      Set all three above to YOUR values, or every probe below measures nothing.\n'
    exit 1 ;;
  esac
done

# macOS ships no `timeout`. Without one, a probe that hangs takes the whole run with it.
_t() {
  _s=$1; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$_s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$_s" "$@"
  else
    "$@" & _p=$!
    ( sleep "$_s"; kill -TERM "$_p" 2>/dev/null ) >/dev/null 2>&1 & _w=$!
    wait "$_p" 2>/dev/null; _r=$?
    kill "$_w" 2>/dev/null
    return "$_r"
  fi
}

printf '=== macOS verification for vks/README.md ===\n'
printf 'date            : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'macOS           : %s\n' "$(sw_vers -productVersion 2>/dev/null)"
printf 'arch            : %s\n' "$(uname -m)"
printf 'shell           : %s\n' "$SHELL"

printf '\n--- P1  which engine, and is it a VM client? ---\n'
ENGINE=""
for e in podman docker; do
  if command -v "$e" >/dev/null 2>&1; then
    printf '%s present : %s\n' "$e" "$(command -v $e)"
    if _t 20 "$e" info >/dev/null 2>&1; then
      [ -z "$ENGINE" ] && ENGINE="$e"
      printf '  %s daemon: UP\n' "$e"
      # The two engines expose DIFFERENT fields: .Host.* is podman's, .ServerVersion is docker's.
      # Using one template for both prints an empty line for one and a template error for the other.
      if [ "$e" = podman ]; then
        _t 20 podman info --format '{{.Host.OS}}/{{.Host.Arch}} remote={{.Host.ServiceIsRemote}} v{{.Version.Version}}' \
          2>&1 | sed 's/^/  podman host: /' | head -1
      else
        _t 20 docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}' \
          2>&1 | sed 's/^/  docker host: /' | head -1
      fi
    else
      printf '  %s daemon: DOWN -- the CLI alone cannot build or push on macOS\n' "$e"
      _t 20 "$e" info 2>&1 | sed "s/^/  $e err : /" | head -1
    fi
  else
    printf '%s present : NO\n' "$e"
  fi
done

printf '  --- which VM provider, if any, is actually running? ---\n'
# Written out one per line ON PURPOSE. `for p in "a b c"; do set -- $p` does NOT split
# in zsh (measured: bash argc=3, zsh argc=1) and macOS runs zsh, so the loop form was a no-op.
command -v podman >/dev/null 2>&1 && _t 20 podman machine list  2>&1 | sed 's/^/  podman machine: /' | head -2
command -v colima >/dev/null 2>&1 && _t 20 colima status        2>&1 | sed 's/^/  colima: /'         | head -2
[ -S /var/run/docker.sock ] && printf '  /var/run/docker.sock: present\n' \
                            || printf '  /var/run/docker.sock: ABSENT (no VM provider is running)\n'
[ -z "$ENGINE" ] && printf '  VERDICT: NO WORKING ENGINE -- P5 below cannot measure trust.\n'

printf '\n--- P2  can this Mac reach Harbor at all? ---\n'
curl -sk -o /dev/null -m 15 -w '  harbor /api/v2.0/health http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health" 2>&1 || printf '  UNREACHABLE (tunnel or /etc/hosts needed)\n'

printf '\n--- P3  does Harbor serve its own CA here? ---\n'
CA="$HOME/harbor-ca-probe.crt"
curl -sk -m 20 "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$CA" 2>/dev/null
if [ -s "$CA" ]; then printf '  bytes=%s\n' "$(wc -c < "$CA")"; else printf '  bytes=0 (nothing downloaded)\n'; fi
openssl x509 -in "$CA" -noout -subject -fingerprint -sha256 2>&1 | sed 's/^/  /'

printf '\n--- P4  does curl verify against it? (no -k) ---\n'
curl -s --cacert "$CA" -o /dev/null -m 15 -w '  http=%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health" 2>&1 | head -2

printf '\n--- P5  BASELINE: does login fail BEFORE trusting the CA? ---\n'
printf '  (expected: x509 unknown authority. If it SUCCEEDS, the CA is already trusted.)\n'
if command -v podman >/dev/null 2>&1; then
  printf 'x' | podman login --authfile /tmp/probe-auth.json -u probe --password-stdin "$HARBOR_FQDN" 2>&1 | sed 's/^/  podman: /' | head -2
fi
if command -v docker >/dev/null 2>&1; then
  printf 'x' | docker login -u probe --password-stdin "$HARBOR_FQDN" 2>&1 | sed 's/^/  docker: /' | head -2
fi

printf '\n--- P6  VCF CLI on THIS Mac ---\n'
A="$(uname -m)"; case "$A" in arm64) P=Darwin_arm64;; *) P=Darwin_amd64;; esac
printf '  entitled archive you need: VCF-Consumption-CLI-%s-<version>.tar.gz\n' "$P"
if command -v vcf >/dev/null 2>&1; then
  _t 20 vcf version 2>&1 | sed 's/^/  /' | head -4
  printf '  --- plugins (README claims the bundle is Linux-only; does it install here?) ---\n'
  printf '  (MEASURED on a Mac with no plugins: this HANGS on registry discovery -- capped at 25s)\n'
  _t 25 vcf plugin list 2>&1 | sed 's/^/  /' | head -8 || printf '  vcf plugin list: TIMED OUT or FAILED\n'
else
  printf '  vcf: NOT INSTALLED — record whether you could install it from the portal archive\n'
fi

printf '\n--- P6b  can the Mac reach the vCenter CA endpoint? ---\n'
curl -sk -o /dev/null -m 25 -w '  certs/download.zip http=%{http_code} bytes=%{size_download}\n' \
  "https://${VCENTER_FQDN}/certs/download.zip" 2>&1 || printf '  UNREACHABLE\n'

printf '\n--- P7  can the Mac build linux/amd64? ---\n'
if command -v podman >/dev/null 2>&1; then
  podman buildx version 2>&1 | sed 's/^/  podman buildx: /' | head -1
elif command -v docker >/dev/null 2>&1; then
  docker buildx version 2>&1 | sed 's/^/  docker buildx: /' | head -1
fi

printf '\n=== NOW DO THE TRUST STEP FROM README STEP 3 FOR YOUR ENGINE, THEN RE-RUN P5 ===\n'
printf 'Record below whether login stopped failing with x509.\n'
printf 'P5-after (podman): \n'
printf 'P5-after (docker): \n'
} 2>&1 | tee "$OUT"

echo; echo "Saved to $OUT  — commit it as vks/macosx.res"
```

## Results so far (`macosx.res`, 2026-09-23, macOS 26.6.2 / arm64 / zsh)

**Settled:**

| finding | evidence |
|---|---|
| the VCF CLI **does** ship and run on Apple Silicon | `vcf version` -> `v9.1.0.0.25296329`, `releaseType: ga`, Darwin arm64 |
| `vcf plugin list` **HANGS** on a Mac with no plugins installed | produced no output and had to be interrupted; the probe now caps it at 25s |

**NOT settled — the run could not reach anything:**

- `podman` absent; `docker` present at `/opt/homebrew/bin/docker` but **no daemon**
  (`dial unix /var/run/docker.sock: no such file or directory`). On macOS
  `brew install docker` installs **only the client** — there is no daemon until a VM
  provider (podman machine, or Colima running Docker Engine in a VM) is
  running. So P1's "macOS runs a Linux VM, so TLS is verified VM-side" is still untested,
  and P5 could not measure trust at all. P1 now detects and *names* this state instead of
  printing a bare socket error, and the README says which CA path each provider uses.
- Harbor and vCenter were unreachable because the three variables were left at their
  placeholder values, so P2-P5 measured nothing. The script now **refuses to start**
  in that state rather than emitting plausible-looking garbage.

**Three bugs in this script that the run exposed, now fixed:**

1. `curl -w '%%{http_code}'` printed a **literal** `%{http_code}` — curl renders `%%` as one
   `%`. Every `http=` reading in P2/P4/P6b was meaningless. Now `%{http_code}`.
2. With placeholder values every probe still ran and produced output that *looked* like a
   measurement. Now a guard exits 1 naming the offending variable.
4. The provider loop was written `for p in "a b c"; do set -- $p` — which **does not split
   in zsh** (measured: bash `argc=3`, zsh `argc=1`), and macOS runs zsh, so it would have been
   a complete no-op on the very machine it was written for. Now one explicit line per provider.
5. `podman info` and `docker info` expose **different fields** — `.Host.*` is podman's,
   `.ServerVersion` is docker's. One shared template printed an empty line for docker and a
   Go template error for podman. Now one template per engine.

3. When P3's download produced no file, `wc -c < "$CA"` made the **shell** emit
   `no such file or directory` to stderr before `wc` ran, so the `2>/dev/null` on `wc` could
   not suppress it. Now guarded with `[ -s "$CA" ]`.

## What each probe settles

| probe | the README claim it tests |
|---|---|
| P1 | that macOS runs a VM (`remote=true`), which is why the Linux paths do not apply |
| P2 | whether a Mac can reach Harbor without a tunnel |
| P3 | that Harbor publishes its own CA, so no file transfer is needed |
| P4 | that the published CA actually verifies Harbor's certificate |
| P5 | **the important one** — that login fails *before* the trust step and succeeds *after*, which is the whole reason step 3 exists |
| P6 | which entitled VCF CLI archive this Mac needs, and whether the plugin bundle (documented as Linux-only) installs here |
| P6b | that the Mac can reach vCenter's `certs/download.zip`, which step 8a needs for the Supervisor CA |
| P7 | that `buildx` is present, so `--platform linux/amd64` will work on Apple Silicon |

## After running it

```sh
cd <your golang-web checkout>
cp "$HOME/macosx.res" vks/macosx.res
```

P5 is the one that matters. If login still fails with `x509` after the step-3 trust block, the
README's macOS instructions are wrong and I will correct them against your output.
