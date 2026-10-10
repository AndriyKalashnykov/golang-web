#!/usr/bin/env bash
# Check the two templates the vks/ guides fill with envsubst.
#
#   1. vks/templates/cluster.yaml and vks/templates/namespace-spec.json are rendered with example
#      values, and with the SAME explicit variable list the guides pass to envsubst. Fails when a
#      template names a variable that is not in its list (it would stay a literal "${...}"), when a
#      listed variable is not used, when any value renders empty, or when the JSON does not parse.
#   2. When helm and yq are installed, the chart vks/argocd/guest-cluster is rendered with the same
#      values and compared with the rendered cluster template, both as key-sorted JSON. They must
#      be the same object: vks/CLUSTER.md and the ArgoCD guides promise the same cluster.
#
# The last line says which arms ran. Arm 2 is SKIPPED, not failed, without helm or yq, unless
# REQUIRE_HELM=1 (set that in CI, where a skip would be a green that compared nothing).
# Not checked: that the guides' own envsubst lists equal the lists below (the docs gate owns the
# guides), and anything about a live Supervisor.
# Run from the repository root. Needs bash 3.2+, envsubst, grep, sed, sort, diff; jq for the JSON.
# shellcheck disable=SC2016,SC2086,SC2116  # literal ${...} patterns, and word lists split on purpose
set -euo pipefail

CLUSTER_TPL=vks/templates/cluster.yaml
NS_TPL=vks/templates/namespace-spec.json
CHART=vks/argocd/guest-cluster

CLUSTER_VARS="VKS_CLUSTER VKS_NAMESPACE PODS_CIDR SERVICES_CIDR CLUSTER_CLASS CLUSTER_CLASS_NAMESPACE K8S_VERSION CONTROL_PLANE_REPLICAS WORKER_REPLICAS VM_CLASS STORAGE_CLASS"
NS_VARS="VKS_NAMESPACE VSPHERE_CLUSTER_ID STORAGE_POLICY_ID NAMESPACE_VM_CLASSES_JSON NAMESPACE_USER NAMESPACE_DOMAIN NAMESPACE_ROLE"

# Example values. Every one differs from every other, so a swapped pair cannot compare equal.
export VKS_CLUSTER=example-cluster
export VKS_NAMESPACE=example-namespace
export PODS_CIDR=172.30.0.0/16
export SERVICES_CIDR=172.31.0.0/16
export CLUSTER_CLASS=builtin-generic-v9.9.9
export CLUSTER_CLASS_NAMESPACE=example-class-namespace
export K8S_VERSION=v1.99.1+vmware.7
export CONTROL_PLANE_REPLICAS=3
export WORKER_REPLICAS=5
export VM_CLASS=example-vm-class
export STORAGE_CLASS=example-storage-class
export VSPHERE_CLUSTER_ID=domain-c1234
export STORAGE_POLICY_ID=00000000-1111-2222-3333-444444444444
export NAMESPACE_VM_CLASSES_JSON='["example-vm-class","example-vm-class-2"]'
export NAMESPACE_USER=example-user
export NAMESPACE_DOMAIN=example.domain
export NAMESPACE_ROLE=EDIT

fail=0
err() { echo "ERROR: $*"; fail=1; }

command -v envsubst >/dev/null 2>&1 || { echo "ERROR: envsubst is not installed (gettext / gettext-base)."; exit 1; }
for f in "$CLUSTER_TPL" "$NS_TPL" "$CHART/Chart.yaml"; do
  [ -f "$f" ] || { echo "ERROR: $f is missing. Run this from the repository root."; exit 1; }
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# render TEMPLATE "VAR VAR ..." OUT: checks the list against the template, then renders.
render() {
  local tpl="$1" vars="$2" out="$3" v list="" used want
  used="$(grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$tpl" | sed 's/[${}]//g' | sort -u || true)"
  want="$(printf '%s\n' $vars | sort -u)"
  if [ "$used" != "$want" ]; then
    err "$tpl: the variables it uses differ from the list the guide passes to envsubst."
    echo "  used in the template: $(echo $used)"
    echo "  in the list:          $(echo $want)"
  fi
  for v in $vars; do
    if [ -z "$(printenv "$v" || true)" ]; then err "$tpl: no example value for $v"; fi
    list="$list \${$v}"
  done
  envsubst "$list" < "$tpl" > "$out"
  if grep -n '\${' "$out"; then err "$tpl: a \${...} was left in the rendered file (lines above)"; fi
}

render "$CLUSTER_TPL" "$CLUSTER_VARS" "$T/cluster.yaml"
render "$NS_TPL" "$NS_VARS" "$T/namespace-spec.json"

# Empty substitutions. In the YAML an empty value leaves "key:" or "-" with nothing after it, on a
# line that had a ${...} in the template; compare line by line so a real parent key ("spec:") does
# not count.
n=0
while IFS= read -r tline <&3 && IFS= read -r rline <&4; do
  n=$((n + 1))
  case "$tline" in
    *'${'*)
      case "$rline" in
        *:|*:[[:space:]]|*-|*-[[:space:]]) err "$CLUSTER_TPL line $n rendered empty: '$rline'" ;;
      esac ;;
  esac
done 3< "$CLUSTER_TPL" 4< "$T/cluster.yaml"

if command -v jq >/dev/null 2>&1; then
  if ! jq -e . "$T/namespace-spec.json" >/dev/null; then
    err "$NS_TPL does not render to valid JSON"
  elif ! jq -e '[.. | select(type == "string" or type == "array") | length] | all(. > 0)' "$T/namespace-spec.json" >/dev/null; then
    err "$NS_TPL rendered an empty string or an empty list"
  elif ! jq -e '(.namespace == env.VKS_NAMESPACE) and (.cluster == env.VSPHERE_CLUSTER_ID)
        and (.storage_specs == [{policy: env.STORAGE_POLICY_ID}])
        and (.storage_specs[0] | has("limit") | not)
        and (.vm_service_spec.vm_classes == (env.NAMESPACE_VM_CLASSES_JSON | fromjson))
        and (.access_list == [{subject_type: "USER", subject: env.NAMESPACE_USER, domain: env.NAMESPACE_DOMAIN, role: env.NAMESPACE_ROLE}])' \
        "$T/namespace-spec.json" >/dev/null; then
    err "$NS_TPL did not render the expected object (a value landed in the wrong field, or a storage limit was added)"
  fi
  json_arm="checked"
else
  err "jq is not installed, so $NS_TPL was not checked"
  json_arm="NOT checked"
fi

# Arm 2: the chart must render the same object.
helm_arm="SKIPPED (helm or yq is not installed)"
if command -v helm >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
  helm template check "$CHART" --namespace "$VKS_NAMESPACE" \
    --set-string name="$VKS_CLUSTER" --set-string kubernetesVersion="$K8S_VERSION" \
    --set-string vmClass="$VM_CLASS" --set-string storageClass="$STORAGE_CLASS" \
    --set-string clusterClass="$CLUSTER_CLASS" --set-string clusterClassNamespace="$CLUSTER_CLASS_NAMESPACE" \
    --set controlPlaneReplicas="$CONTROL_PLANE_REPLICAS" --set workerReplicas="$WORKER_REPLICAS" \
    --set-string podsCidr="$PODS_CIDR" --set-string servicesCidr="$SERVICES_CIDR" > "$T/chart.yaml"
  yq -o=json 'sort_keys(..)' "$T/chart.yaml" > "$T/chart.json"
  yq -o=json 'sort_keys(..)' "$T/cluster.yaml" > "$T/template.json"
  if [ "$(grep -c . "$T/chart.json")" -lt 20 ]; then
    err "the chart rendered almost nothing: the comparison would be empty"
  elif ! diff -u "$T/chart.json" "$T/template.json"; then
    err "$CLUSTER_TPL and the chart $CHART describe different objects (diff above: - chart, + template)"
  fi
  helm_arm="compared"
elif [ "${REQUIRE_HELM:-0}" = 1 ]; then
  err "REQUIRE_HELM=1, but helm or yq is not installed"
fi

echo "check-vks-templates: rendered 2 templates (${CLUSTER_TPL}: 11 variables, ${NS_TPL}: 7 variables); JSON ${json_arm}; chart = template: ${helm_arm}"
exit "$fail"
