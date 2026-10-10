# Use or install Harbor on the Supervisor

[REGISTRY.md](REGISTRY.md) pushes the `golang-web` image to a Harbor registry and lets a VKS
guest cluster pull it from there. This page tells you how to check a Harbor that exists, what
you need from it, and where to go when none does.

**You need vCenter administrator rights to install Harbor; to check and use one you need only a
Harbor project you may push to.**

| your situation | go to |
|---|---|
| You have a Harbor | [Use the Harbor you have](#use-the-harbor-you-have), below |
| You have none: install it by hand | [HARBOR-manual.md](HARBOR-manual.md): the vSphere Client, with screenshots, for the install; short command blocks for the files before it and the checks after it |
| You have none: install it with scripts | [HARBOR-auto.md](HARBOR-auto.md): command blocks only, vCenter's API with `curl` |

Both guides install Harbor on the Supervisor, with its own load-balancer address (the Contour
service is not needed), then get it a DNS name, a trusted CA, a project and a robot account.
Both end where [REGISTRY.md](REGISTRY.md) begins, and each uninstalls only a Harbor it
installed.

<a id="if-you-are-not-a-vcenter-administrator"></a>

<details>
<summary><b>If you are not a vCenter administrator</b></summary>

Ask a vCenter administrator for these three things:

- the Harbor Supervisor Service (release 2.15.2) installed on your Supervisor with
  [HARBOR-manual.md](HARBOR-manual.md) or [HARBOR-auto.md](HARBOR-auto.md), in a maintenance
  window: the install replaces every node of every guest cluster on that Supervisor;
- a DNS record for Harbor's name, in a zone the guest clusters' nodes use;
- afterwards, the five values in the table under *Use the Harbor you have*.

</details>

## Use the Harbor you have

Most companies have one. Install nothing. Set `HARBOR_FQDN` in `~/.vks-golang-web.env` to
Harbor's DNS name, then run this block by copy and paste, in `bash` or `zsh`, on Linux or macOS.
It asks whether a Harbor runs as a Supervisor Service on your Supervisor, and whether the Harbor
at `HARBOR_FQDN` answers. It sends no login, and it does not check Harbor's certificate:
[REGISTRY.md](REGISTRY.md) does that before anything is sent.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get ns -l appplatform.vmware.com/serviceId=harbor -o name
echo "Harbor at ${HARBOR_FQDN:-HARBOR_FQDN is empty}: http=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://${HARBOR_FQDN}/api/v2.0/ping")"
```

**Expect:** `namespace/svc-harbor-…` when a Harbor runs on this Supervisor (no such line for a
Harbor elsewhere), then `Harbor at <your Harbor's name>: http=200`.

**If not:**
- `http=000`: nothing answered at that name. The name does not resolve on this machine, or
  Harbor is not reachable from it. Check `HARBOR_FQDN`;
  [Check the DNS record](HARBOR-auto.md#check-the-dns-record) tests the name.
- `Harbor at HARBOR_FQDN is empty: …`: set `HARBOR_FQDN` in the env file.
- No `namespace/…` line and no Harbor elsewhere: you have none. Install one
  [by hand](HARBOR-manual.md) or [with scripts](HARBOR-auto.md).
- `Unauthorized` on the first line: run the main guide's
  [Renew the Supervisor login](README.md#renew-the-supervisor-login) block.
- `Forbidden` on the first line (`cannot list resource "namespaces"`): your user has a role on
  your vSphere Namespace only and may not list the Supervisor's namespaces. The second line
  still says whether Harbor answers.

You need five values from that Harbor. For a Harbor that runs on this Supervisor, the scripted
guide prints or creates each one (run its step 1 first); for a Harbor elsewhere, its
administrator has them.

| you need | for | on this Supervisor |
|---|---|---|
| Harbor's DNS name | `HARBOR_FQDN` in the env file | [Find the address and wait for Harbor](HARBOR-auto.md#find-the-address-and-wait-for-harbor) |
| a project you may push to | `HARBOR_PROJECT` in the env file | [Create the project](HARBOR-auto.md#create-the-project) |
| a robot account for that project (name and secret) | [Log in to Harbor](REGISTRY.md#log-in-to-harbor) | [Create a robot account and log in](HARBOR-auto.md#create-a-robot-account-and-log-in) |
| the SHA-256 fingerprint of Harbor's CA certificate | comparing it in [Download and check the Harbor CA](REGISTRY.md#download-and-check-the-harbor-ca) | [Print the fingerprint of Harbor's CA](HARBOR-auto.md#print-the-fingerprint-of-harbors-ca) |
| confirmation that your guest cluster's nodes resolve Harbor's name and trust its CA | the cluster pulling your image | [Check that a guest cluster can pull from Harbor](HARBOR-auto.md#9-check-that-a-guest-cluster-can-pull-from-harbor) |

Then follow [REGISTRY.md](REGISTRY.md).

A guest cluster under the same Supervisor as a Harbor Supervisor Service trusts that Harbor's CA
without any setting, unless that Harbor was installed with its own certificate and no `ca.crt`
in its configuration. For any other Harbor with a private CA, the cluster's administrator adds the
CA to the cluster; the last row's check tells you whether it was done.

## Install the Harbor Supervisor Service

### Who can install it

Installing needs three things:

- the vCenter privileges **Manage Supervisor Services** and **Manage Supervisor Services on
  Supervisors** (a vCenter administrator has them);
- a Broadcom support account entitled to download **vSphere Supervisor Services**;
- someone who can create a DNS record for Harbor's name.

### What an install means

- **Installing or uninstalling Harbor replaces every node of every guest cluster on that
  Supervisor**, one node at a time. Do it before clusters exist, or in a maintenance window:
  [Install Harbor before you create clusters](CLUSTER.md#install-harbor-before-you-create-clusters).
- **Seven passwords and keys** are made once and kept in a file by whoever installs. They are
  needed again for every later change to this Harbor, and vCenter shows them to everyone who may
  manage Supervisor Services.
- **Harbor's address is given at install time** and changes with every reinstall, so the DNS
  record follows the install, not the other way round. Its CA changes too: everyone who uses
  the Harbor downloads and trusts the new one.
- **The registry volume has a fixed size**, 10 GiB unless you choose another before installing.
- **Uninstalling deletes every image and all settings.** There is no way back.
- **Upgrading to a newer release is not covered** by these guides.
