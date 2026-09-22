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
export HARBOR_FQDN="harbor.example.test"        # your Harbor DNS name
export VCENTER_FQDN="${VCENTER_FQDN:-vcsa.example.test}"   # <-- SET THIS
SUPERVISOR_ENDPOINT="10.0.0.10"          # Supervisor API endpoint
export OUT="$HOME/macosx.res"
```

## Then run this

```sh
{
printf '=== macOS verification for vks/README.md ===\n'
printf 'date            : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'macOS           : %s\n' "$(sw_vers -productVersion 2>/dev/null)"
printf 'arch            : %s\n' "$(uname -m)"
printf 'shell           : %s\n' "$SHELL"

printf '\n--- P1  which engine, and is it a VM client? ---\n'
for e in podman docker; do
  if command -v "$e" >/dev/null 2>&1; then
    printf '%s present : %s\n' "$e" "$(command -v $e)"
    "$e" info --format '{{.Host.OS}}/{{.Host.Arch}} remote={{.Host.ServiceIsRemote}}' 2>&1 | sed "s/^/  $e info: /" | head -2
  else
    printf '%s present : NO\n' "$e"
  fi
done
command -v podman >/dev/null 2>&1 && podman machine list 2>&1 | sed 's/^/  machine: /' | head -3

printf '\n--- P2  can this Mac reach Harbor at all? ---\n'
curl -sk -o /dev/null -m 15 -w '  harbor /api/v2.0/health http=%%{http_code}\n' \
  "https://${HARBOR_FQDN}/api/v2.0/health" 2>&1 || printf '  UNREACHABLE (tunnel or /etc/hosts needed)\n'

printf '\n--- P3  does Harbor serve its own CA here? ---\n'
CA="$HOME/harbor-ca-probe.crt"
curl -sk -m 20 "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$CA" 2>/dev/null
printf '  bytes=%s\n' "$(wc -c < "$CA" 2>/dev/null || echo 0)"
openssl x509 -in "$CA" -noout -subject -fingerprint -sha256 2>&1 | sed 's/^/  /'

printf '\n--- P4  does curl verify against it? (no -k) ---\n'
curl -s --cacert "$CA" -o /dev/null -m 15 -w '  http=%%{http_code}\n' \
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
  vcf version 2>&1 | sed 's/^/  /' | head -4
  printf '  --- plugins (README claims the bundle is Linux-only; does it install here?) ---\n'
  vcf plugin list 2>&1 | sed 's/^/  /' | head -6
else
  printf '  vcf: NOT INSTALLED — record whether you could install it from the portal archive\n'
fi

printf '\n--- P6b  can the Mac reach the vCenter CA endpoint? ---\n'
curl -sk -o /dev/null -m 25 -w '  certs/download.zip http=%%{http_code} bytes=%%{size_download}\n' \
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
