# Clean up

This chapter removes what these guides put into Harbor and onto this machine: the pushed image
and its robot account, the local image and the Harbor login, Harbor's CA, the saved files, the
clone and the env file. It comes after the two blocks under [Clean up](README.md#clean-up) of
[the main guide](README.md), which delete the app and the Supervisor login. You need the env
file and, for some blocks, the clone: that is why they go last.

Everything here is optional. Run only the blocks you want, but in the order shown. The
installed tools, base images, build cache and kubectl's `~/.kube/cache` are kept.

What a chapter created on the platform is removed by that chapter, before the blocks here.
**Go through the table from top to bottom:** what runs on a guest cluster goes before the
cluster, and an app that ArgoCD deployed goes before the cluster AND before ArgoCD (its
Application can be deleted only while ArgoCD runs and still reaches the cluster).

| created with | removed with |
|---|---|
| [ARGOCD-app.md](ARGOCD-app.md) (the app, deployed by ArgoCD) | [Delete the app](ARGOCD-app.md#delete-the-app): all its blocks, in order |
| [addons/ISTIO.md](addons/ISTIO.md) | [Remove the gateway and the route](addons/ISTIO.md#remove-the-gateway-and-the-route), then [Uninstall Istio](addons/ISTIO.md#uninstall-istio) |
| [addons/HEADLAMP.md](addons/HEADLAMP.md) | [Remove the add-on](addons/HEADLAMP.md#remove-the-add-on), or [Uninstall Headlamp](addons/HEADLAMP.md#uninstall-headlamp) for the one installed with helm |
| [addons/CERT-MANAGER.md](addons/CERT-MANAGER.md) | [Remove cert-manager](addons/CERT-MANAGER.md#remove-cert-manager), after the add-ons that use it |
| [ARGOCD-auto.md](ARGOCD-auto.md) or [ARGOCD-manual.md](ARGOCD-manual.md) | that guide's *Clean up (optional)* step: the guest cluster it created, then the ArgoCD instance |
| [CLUSTER-auto.md](CLUSTER-auto.md) | its [Delete the cluster](CLUSTER-auto.md#delete-the-cluster) |
| [CLUSTER-manual.md](CLUSTER-manual.md) | its [Delete the cluster (optional)](CLUSTER-manual.md#8-delete-the-cluster-optional) |
| [HARBOR-auto.md](HARBOR-auto.md) or [HARBOR-manual.md](HARBOR-manual.md) | that guide's *Uninstall Harbor (optional)* step |
| [NAMESPACE-auto.md](NAMESPACE-auto.md) | its [Remove the namespace](NAMESPACE-auto.md#remove-the-namespace) |
| [NAMESPACE-manual.md](NAMESPACE-manual.md) | its [Remove the namespace (optional)](NAMESPACE-manual.md#9-remove-the-namespace-optional) |

## Delete the image and the robot in Harbor

Only if you pushed an image with [REGISTRY.md](REGISTRY.md). This deletes the **whole
`golang-web` repository** in your
project — every tag, including any pushed by others. It needs `HARBOR_ADMIN_PASSWORD`; without it,
whoever has Harbor's admin login must delete the `golang-web` repository in your project and the
robot `robot$<your project>+golang-web-push`.

```sh
source ~/.vks-golang-web.env
harbor_cfg

curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/golang-web" \
  -o /dev/null -w 'delete repository: http=%{http_code}\n'

PID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" \
  "https://${HARBOR_FQDN}/api/v2.0/projects/${HARBOR_PROJECT}" | jq -r .project_id)"
RID="$(curl -s --cacert "$HARBOR_CA" -K "$CFG" --get \
  --data-urlencode "q=Level=project,ProjectID=${PID}" --data-urlencode 'page_size=100' \
  "https://${HARBOR_FQDN}/api/v2.0/robots" | jq -r '.[]|select(.name|test("golang-web-push"))|.id')"
[ -n "$RID" ] && curl -s --cacert "$HARBOR_CA" -K "$CFG" -X DELETE \
  "https://${HARBOR_FQDN}/api/v2.0/robots/${RID}" -o /dev/null -w 'delete robot: http=%{http_code}\n'

rm -f "$CFG"
```

**Expect:** `delete repository: http=200` and `delete robot: http=200` (no robot line if you used
the admin account or a robot this guide did not make). `http=404` means it was already gone;
`http=401` means the admin password is wrong.

## Delete the local image and the Harbor login

Only if you built an image with [REGISTRY.md](REGISTRY.md). This logs your container engine out
of Harbor and deletes the image you built from this machine. Run it from inside the clone.

```sh
source ~/.vks-golang-web.env
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  "$e" logout "$HARBOR_FQDN" 2>/dev/null
  if ! "$e" info >/dev/null 2>&1; then
    echo "$e is not running: its images (and, for podman on macOS, its Harbor login) stay. Start it and run this block again."
    continue
  fi
  [ "$e" = podman ] && podman manifest rm "localhost/golang-web-push:$(cat version.txt)" >/dev/null 2>&1
  "$e" rmi -f "${HARBOR_FQDN}/${HARBOR_PROJECT}/golang-web:$(cat version.txt)" 2>/dev/null
  "$e" image prune -f >/dev/null
done
```

**Expect:** a `… login credentials for <your Harbor>` line (docker may also print `Untagged:`
lines), or nothing if they were already gone. `… is not running` names an engine you have installed
but not started (on Linux, also docker when your user may not use it yet: log out and back in
after the docker install's `usermod`): start it and run the block again, or ignore it if you never used that
engine. If the block hangs, an engine is half-started: press Ctrl-C, start it fully, and run the block again.

## Remove the Harbor CA

Only if you installed it with [REGISTRY.md](REGISTRY.md). Skip this if you use this Harbor for
other work: those tools need the CA too. The block finds your engines itself: it removes podman's
copy, then Docker's, inside Colima on a Mac that has Colima, or under `/etc/docker` on Linux when
that copy exists.

```sh
source ~/.vks-golang-web.env
rm -rf "$HOME/.config/containers/certs.d/${HARBOR_FQDN:?}"
if [ "$(uname -s)" = Darwin ] && command -v colima >/dev/null 2>&1; then
  colima status >/dev/null 2>&1 || colima start
  colima ssh -- sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}" </dev/null
elif [ -d "/etc/docker/certs.d/${HARBOR_FQDN:?}" ]; then
  sudo rm -rf "/etc/docker/certs.d/${HARBOR_FQDN:?}"
fi
```

**Expect:** nothing, or Colima's start-up lines if it was stopped. On Linux with Docker, `sudo`
may ask for your password.

## Delete the files these guides wrote

This ends an open vCenter session and deletes the files the main guide and its chapters
([NAMESPACE-auto.md](NAMESPACE-auto.md), [CLUSTER.md](CLUSTER.md), [CLUSTER-auto.md](CLUSTER-auto.md), [REGISTRY.md](REGISTRY.md)) saved: the
two CA files, the two kubeconfigs, the vCenter session file and the two filled descriptions.
Empty directories are removed; anything else in them is kept.

```sh
source ~/.vks-golang-web.env
if command -v vc_logout >/dev/null 2>&1; then vc_logout; fi
rm -f  "$HARBOR_CA" "$SUPERVISOR_CA" "$SUPERVISOR_KUBECONFIG" "$GUEST_KUBECONFIG" "${GUEST_KUBECONFIG}.new"
rm -f  "${VC_SESSION:-$HOME/.config/vks-golang-web/vc-session}" "$HOME/.config/vks-golang-web/namespace-spec.json" "$HOME/.config/vks-golang-web/cluster.yaml"
rmdir  "$HOME/.config/vks-golang-web" 2>/dev/null
rmdir "$HOME/.config/containers/certs.d" "$HOME/.config/containers" "$HOME/.kube" 2>/dev/null
```

**Expect:** no output (`vCenter session closed` if a session was still open).

## Delete the clone

This deletes the `golang-web` directory the main guide's
[Check out the repo](README.md#check-out-the-repo) created, and leaves your terminal in the
directory above it. **If you used a clone you already had, do not run this: it deletes the whole
directory, including any changes you made in it.** Run it from inside the clone.

```sh
if [ -f version.txt ] && [ "${PWD##*/}" = golang-web ]; then cd .. && rm -rf golang-web; else echo "Not in the golang-web clone: remove it yourself"; fi
```

**Expect:** no output (or `Not in the golang-web clone: remove it yourself` if you ran it
elsewhere).

## Delete the env file and the variables

In any other terminal where you loaded the env file, run the `unset` lines too, or
close it.

```sh
rm -f ~/.vks-golang-web.env ~/.vks-golang-web.functions
unset HARBOR_FQDN HARBOR_PROJECT SUPERVISOR_ENDPOINT VCENTER_FQDN VKS_CLUSTER VKS_NAMESPACE \
      SSO_USERNAME VCF_CLI_VSPHERE_PASSWORD HARBOR_ADMIN_PASSWORD REGISTRY_USERNAME \
      REGISTRY_TOKEN HARBOR_CA SUPERVISOR_CA SUPERVISOR_KUBECONFIG GUEST_KUBECONFIG \
      IMAGE KUBECONFIG APP_IP CONTAINER_ENGINE VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION \
      VC_SESSION KUBECTL_DIR KUBECTL_MATCH \
      HARBOR_MANIFEST HARBOR_VALUES_TEMPLATE HARBOR_STORAGE_CLASS HARBOR_REGISTRY_SIZE \
      HARBOR_VALUES HARBOR_SECRETS HARBOR_SERVICE_VERSION SUPERVISOR_ID
unset ADDON_CATALOG_NAMESPACE ADDON_WAIT_MINUTES ADDON_NAME ADDON_INSTALL ADDON_RELEASE CERT_MANAGER_ADDON_RELEASE CERT_MANAGER_NAMESPACE HEADLAMP_ADDON_RELEASE HEADLAMP_ADDON_NAMESPACE HEADLAMP_ADDON_HOSTNAME HEADLAMP_ADDON_GATEWAY HEADLAMP_TOKEN_HOURS HEADLAMP_CHART_VERSION HEADLAMP_NAMESPACE HEADLAMP_LOCAL_PORT HEADLAMP_VERSION ISTIO_VERSION ISTIO_PILOT_REPLICAS ISTIO_PILOT_MEMORY ISTIO_SYSTEM_NAMESPACE ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY ISTIO_APP_NAMESPACE ISTIO_WAIT_MINUTES
unset ARGOCD_APP APP_NAMESPACE APP_REPO APP_REVISION APP_IMAGE APP_SERVICE_TYPE APP_REPO_USERNAME APP_REPO_TOKEN
unset -f harbor_cfg kubectl_install vc_login vc_api vc vc_cluster_id vc_logout 2>/dev/null || true
```

**Expect:** no output.
