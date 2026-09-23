#!/usr/bin/env bash
# macosx.sh - check vks/README.md's macOS-specific claims on a real Mac.
#
# WRITES  : macosx.res, next to this script. Commit that file.
# USAGE   : ./vks/macosx.sh
#
# READ-ONLY. Installs nothing, touches no trust store, starts no VM, sends no
# credential. Every probe reads local state or makes one unauthenticated request.
#
# THE LAB IS NOT REQUIRED. Probes needing Harbor/vCenter/Supervisor report SKIPPED
# unless you export these first; everything else runs regardless, and that is the
# half that cannot be measured on Linux anyway:
#
#   export HARBOR_FQDN=harbor.my.lab VCENTER_FQDN=vcsa.my.lab SUPERVISOR_ENDPOINT=10.0.0.10

DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
OUT="$DIR/macosx.res"

# macOS ships no timeout(1). Without one, a probe that hangs takes the run with it.
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

# Collected for the machine-readable block at the end.
V_ENGINE=none; V_DAEMON=no; V_PROVIDER=none; V_REMOTE=unknown
V_BUILDX=no; V_ROSETTA=n/a; V_VCF=no; V_VCFPLUGINS=unknown; V_LAB=skipped
V_BASE64=unknown; V_INSTALLD=unknown; V_SED=unknown
V_SECURITY=no; V_IMPORTCA=unknown; V_LOCALBIN=unknown

lab_set() {
  case "${HARBOR_FQDN:-}" in ""|*example.test) return 1 ;; esac
  return 0
}

{
printf '=== macOS check for vks/README.md ===\n'
if [ "$(uname -s)" != Darwin ]; then
  printf '\n*** NOT macOS (uname -s = %s). This script is for a Mac. ***\n' "$(uname -s)"
  printf '*** Everything below is a DRY RUN and settles nothing about macOS. ***\n\n'
fi
printf 'generated : %s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'macOS     : %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null)" "$(sw_vers -buildVersion 2>/dev/null)"
printf 'arch      : %s\n'   "$(uname -m)"
printf 'shell     : %s\n'   "${SHELL:-unknown}"
printf 'bash      : %s\n'   "${BASH_VERSION:-n/a}"
printf 'lab vars  : %s\n'   "$(lab_set && echo 'set - lab probes will run' || echo 'UNSET - lab probes will report SKIPPED')"

printf '\n--- S1  base tools README assumes macOS ships ---\n'
for t in curl unzip openssl tar git make; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  %-8s OK   %s\n' "$t" "$(command -v "$t")"
  else
    printf '  %-8s MISSING  <-- README says this ships with macOS\n' "$t"
  fi
done
printf '  %-8s %s\n' mise "$(command -v mise >/dev/null 2>&1 && command -v mise || echo 'absent (make deps installs it)')"

printf '\n--- S2  Rosetta 2 ---\n'
# README section 7 pins PLUGIN_OS=darwin-amd64 on ALL Macs, saying no arm64 build
# exists and it runs under Rosetta 2. On Apple Silicon that is a hard prerequisite
# the README does not currently mention. This settles whether it holds.
case "$(uname -m)" in
  arm64)
    if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      V_ROSETTA=yes; printf '  Rosetta 2 : PRESENT - an x86_64 binary runs here\n'
    else
      V_ROSETTA=no
      printf '  Rosetta 2 : ABSENT - the darwin-amd64 kubectl the README downloads CANNOT run.\n'
      printf '              Fix: softwareupdate --install-rosetta --agree-to-license\n'
    fi ;;
  *) printf '  Intel Mac - Rosetta not applicable\n' ;;
esac

printf '\n--- S3  container engine, and is it a VM client? ---\n'
for e in podman docker; do
  if command -v "$e" >/dev/null 2>&1; then
    printf '  %s present : %s\n' "$e" "$(command -v "$e")"
    if _t 25 "$e" info >/dev/null 2>&1; then
      [ "$V_ENGINE" = none ] && { V_ENGINE=$e; V_DAEMON=yes; }
      printf '    daemon   : UP\n'
      # The engines expose DIFFERENT fields: .Host.* is podman's, .ServerVersion docker's.
      # One shared template prints an empty line for one and a template error for the other.
      if [ "$e" = podman ]; then
        _t 25 podman info --format '{{.Host.OS}}/{{.Host.Arch}} remote={{.Host.ServiceIsRemote}} v{{.Version.Version}}' 2>&1 \
          | sed 's/^/    host     : /' | head -1
        case "$(_t 25 podman info --format '{{.Host.ServiceIsRemote}}' 2>/dev/null)" in
          true) V_REMOTE=true ;; false) V_REMOTE=false ;;
        esac
      else
        _t 25 docker info --format '{{.OperatingSystem}}/{{.Architecture}} server={{.ServerVersion}}' 2>&1 \
          | sed 's/^/    host     : /' | head -1
        case "$(_t 25 docker info --format '{{.OperatingSystem}}' 2>/dev/null)" in
          *Desktop*|*Colima*|*Linux*) V_REMOTE=true ;;
        esac
      fi
    else
      printf '    daemon   : DOWN - the CLI alone cannot build or push on macOS\n'
      _t 25 "$e" info 2>&1 | sed 's/^/    error    : /' | head -1
    fi
  else
    printf '  %s present : NO\n' "$e"
  fi
done

printf '  -- which VM provider is running? --\n'
# One line per provider ON PURPOSE: `for p in "a b c"; do set -- $p` does NOT split
# in zsh (measured bash argc=3, zsh argc=1) and macOS defaults to zsh.
if command -v podman >/dev/null 2>&1; then
  _t 25 podman machine list 2>&1 | sed 's/^/    podman machine: /' | head -3
  _t 25 podman machine list --format '{{.Running}}' 2>/dev/null | grep -qi true && V_PROVIDER=podman-machine
fi
if command -v colima >/dev/null 2>&1; then
  _t 25 colima status 2>&1 | sed 's/^/    colima: /' | head -3
  _t 25 colima status >/dev/null 2>&1 && V_PROVIDER=colima
fi
if [ -S /var/run/docker.sock ]; then
  printf '    /var/run/docker.sock: present\n'
  [ "$V_PROVIDER" = none ] && V_PROVIDER=docker.sock
else
  printf '    /var/run/docker.sock: ABSENT\n'
fi
[ "$V_DAEMON" = no ] && printf '    VERDICT: no working engine - brew install docker gives the CLIENT only.\n'

printf '\n--- S4  can this Mac build linux/amd64? ---\n'
if [ "$V_ENGINE" != none ]; then
  if _t 25 "$V_ENGINE" buildx version >/dev/null 2>&1; then
    V_BUILDX=yes
    _t 25 "$V_ENGINE" buildx version 2>&1 | sed "s/^/  $V_ENGINE buildx: /" | head -1
  else
    printf '  %s buildx: ABSENT - Makefile falls back to plain build\n' "$V_ENGINE"
  fi
else
  printf '  SKIPPED - no engine with a live daemon\n'
fi

printf '\n--- S5  VCF CLI on this Mac ---\n'
case "$(uname -m)" in arm64) ARCHIVE=Darwin_ARM64 ;; *) ARCHIVE=Darwin_AMD64 ;; esac
printf '  entitled archives for this Mac:\n'
printf '    VCF-Consumption-CLI-%s-<version>.tar.gz\n' "$ARCHIVE"
printf '    VCF-Consumption-CLI-PluginBundle-%s-<version>.tar.gz\n' "$ARCHIVE"
if command -v vcf >/dev/null 2>&1; then
  V_VCF=yes
  _t 25 vcf version 2>&1 | sed 's/^/  /' | head -4
  printf '  -- plugins: does the Darwin bundle actually install here? --\n'
  printf '  (README says this HANGS on a Mac with no plugins installed; capped at 25s.)\n'
  # Gate on OUTPUT, not exit status: measured, `vcf plugin list` prints a valid table
  # AND exits non-zero, so a status-gated check calls a working command broken.
  _pl="$(_t 25 vcf plugin list 2>&1)"; _plrc=$?
  if [ -n "$_pl" ]; then
    V_VCFPLUGINS="listed(rc=$_plrc)"
    printf '  produced output, rc=%s:\n' "$_plrc"
    printf '%s\n' "$_pl" | sed 's/^/    /' | head -14
  else
    V_VCFPLUGINS="no-output(rc=$_plrc)"
    printf '  NO OUTPUT at all, rc=%s - this is the hang the README warns about.\n' "$_plrc"
  fi
else
  printf '  vcf: NOT INSTALLED - note whether the portal archive installs cleanly\n'
fi

printf '\n--- S6  BSD userland vs the commands README actually runs ---\n'
# macOS ships BSD userland; the README was proven on GNU/Linux. These run the real
# commands against fixtures instead of assuming they port.

# README step 8b decodes the CAPI kubeconfig secret with `base64 -d`, on BOTH platforms.
if printf 'aGk=' | base64 -d >/dev/null 2>&1; then
  V_BASE64='-d ok'; printf '  base64 -d            : OK\n'
elif printf 'aGk=' | base64 -D >/dev/null 2>&1; then
  V_BASE64='needs -D'
  printf '  base64 -d            : FAILS - this base64 needs -D. README step 8b BREAKS here.\n'
else
  V_BASE64=broken;   printf '  base64               : neither -d nor -D worked\n'
fi

# `install -D` is GNU-only. README uses it under its LINUX headings only; if it fails
# here that separation is load-bearing, not cosmetic.
_id="$(mktemp -d)"
if install -D -m0644 /dev/null "$_id/a/b/c" >/dev/null 2>&1; then
  V_INSTALLD=yes; printf '  install -D           : supported (GNU-style)\n'
else
  V_INSTALLD=no;  printf '  install -D           : NOT supported (BSD) - README rightly keeps it Linux-only\n'
fi
rm -rf "$_id"

# the exact image-rewrite from README step 9, against a fixture
_sf="$(mktemp)"
printf 'spec:\n  containers:\n  - image: old.reg/apps/golang-web:v0\n' > "$_sf"
_got="$( IMAGE=new.reg/apps/golang-web:v9; sed "s|image: .*/golang-web:.*|image: ${IMAGE}|" "$_sf" )"
case "$_got" in
  *new.reg/apps/golang-web:v9*) V_SED=ok;   printf '  sed image rewrite    : OK\n' ;;
  *)                            V_SED=fail; printf '  sed image rewrite    : FAILED - README step 9 would not substitute here\n' ;;
esac
rm -f "$_sf"

printf '  -- macOS trust-path prerequisites --\n'
if command -v security >/dev/null 2>&1; then
  V_SECURITY=yes; printf '  security(1)          : present\n'
else
  printf '  security(1)          : ABSENT - macOS+podman trust step cannot run\n'
fi
if command -v podman >/dev/null 2>&1; then
  if podman machine set --help 2>&1 | grep -q -- --import-native-ca; then
    V_IMPORTCA=yes; printf '  --import-native-ca   : supported by this podman\n'
  else
    V_IMPORTCA=no;  printf '  --import-native-ca   : NOT in this podman - README macOS+podman step would fail\n'
  fi
fi
case ":$PATH:" in
  *:/usr/local/bin:*) V_LOCALBIN=yes; printf '  /usr/local/bin on PATH: yes\n' ;;
  *)                  V_LOCALBIN=no;  printf '  /usr/local/bin on PATH: NO - kubectl/vcf installed there will not be found\n' ;;
esac

printf '\n--- S7  lab-dependent probes ---\n'
if lab_set; then
  V_LAB=ran
  printf '  HARBOR_FQDN=%s  VCENTER_FQDN=%s  SUPERVISOR_ENDPOINT=%s\n' \
    "$HARBOR_FQDN" "${VCENTER_FQDN:-unset}" "${SUPERVISOR_ENDPOINT:-unset}"

  printf '  P1 reach Harbor:\n'
  curl -sk -o /dev/null -m 15 -w '    /api/v2.0/health http=%{http_code}\n' \
    "https://${HARBOR_FQDN}/api/v2.0/health" 2>&1 || printf '    UNREACHABLE\n'

  printf '  P2 Harbor serves its own CA:\n'
  CA="$(mktemp -t harborca)"
  curl -sk -m 20 "https://${HARBOR_FQDN}/api/v2.0/systeminfo/getcert" -o "$CA" 2>/dev/null
  if [ -s "$CA" ]; then
    printf '    bytes=%s\n' "$(wc -c < "$CA" | tr -d ' ')"
    openssl x509 -in "$CA" -noout -subject -fingerprint -sha256 2>&1 | sed 's/^/    /'
    printf '  P3 curl verifies against it (no -k):\n'
    curl -s --cacert "$CA" -o /dev/null -m 15 -w '    http=%{http_code}\n' \
      "https://${HARBOR_FQDN}/api/v2.0/health" 2>&1 | head -2
  else
    printf '    bytes=0 - nothing downloaded; P3 skipped\n'
  fi
  rm -f "$CA"

  printf '  P4 BASELINE: does login fail BEFORE the CA is trusted?\n'
  printf '     (expect x509 unknown authority; SUCCESS means it is already trusted.\n'
  printf '      The password sent is the literal string x - not a credential.)\n'
  if [ "$V_ENGINE" = podman ]; then
    printf 'x' | podman login --authfile "$(mktemp -t probeauth)" -u probe --password-stdin "$HARBOR_FQDN" 2>&1 \
      | sed 's/^/    podman: /' | head -2
  elif [ "$V_ENGINE" = docker ]; then
    printf 'x' | docker login -u probe --password-stdin "$HARBOR_FQDN" 2>&1 | sed 's/^/    docker: /' | head -2
  else
    printf '    SKIPPED - no engine with a live daemon\n'
  fi

  if [ -n "${VCENTER_FQDN:-}" ]; then
    printf '  P5 vCenter CA endpoint (README step 8a):\n'
    curl -sk -o /dev/null -m 25 -w '    /certs/download.zip http=%{http_code} bytes=%{size_download}\n' \
      "https://${VCENTER_FQDN}/certs/download.zip" 2>&1 || printf '    UNREACHABLE\n'
  fi
  if [ -n "${SUPERVISOR_ENDPOINT:-}" ]; then
    printf '  P6 Supervisor kubectl download (README step 7):\n'
    for p in darwin-amd64 darwin-arm64; do
      curl -sk -o /dev/null -m 25 -w "    $p http=%{http_code} bytes=%{size_download}\n" \
        "https://${SUPERVISOR_ENDPOINT}/wcp/plugin/$p/vsphere-plugin.zip" 2>&1
    done
    printf '    (README pins darwin-amd64 because darwin-arm64 404s. If arm64 is 200 here, fix the README.)\n'
  fi
else
  printf '  SKIPPED - lab endpoints not set. To include them:\n'
  printf '    export HARBOR_FQDN=... VCENTER_FQDN=... SUPERVISOR_ENDPOINT=...\n'
  printf '    %s\n' "$0"
  printf '  Unset is the EXPECTED state on a Mac with no lab. Everything above still measured.\n'
fi

printf '\n=== SUMMARY (machine-readable) ===\n'
printf 'arch=%s\n'            "$(uname -m)"
printf 'macos=%s\n'           "$(sw_vers -productVersion 2>/dev/null)"
printf 'rosetta2=%s\n'        "$V_ROSETTA"
printf 'engine=%s\n'          "$V_ENGINE"
printf 'daemon_up=%s\n'       "$V_DAEMON"
printf 'vm_provider=%s\n'     "$V_PROVIDER"
printf 'engine_remote=%s\n'   "$V_REMOTE"
printf 'buildx=%s\n'          "$V_BUILDX"
printf 'vcf_cli=%s\n'         "$V_VCF"
printf 'vcf_plugin_list=%s\n' "$V_VCFPLUGINS"
printf 'base64_flag=%s\n'     "$V_BASE64"
printf 'install_D=%s\n'       "$V_INSTALLD"
printf 'sed_rewrite=%s\n'     "$V_SED"
printf 'security_cmd=%s\n'    "$V_SECURITY"
printf 'import_native_ca=%s\n' "$V_IMPORTCA"
printf 'usr_local_bin=%s\n'   "$V_LOCALBIN"
printf 'lab_probes=%s\n'      "$V_LAB"
printf '=== end ===\n'
} 2>&1 | tee "$OUT"

printf '\nSaved to %s\n' "$OUT"
printf 'Commit it:  git add %s && git commit -m "vks: macOS probe results" && git push\n' "${OUT#"$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)/"}"
