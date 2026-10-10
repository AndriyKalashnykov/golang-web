# Harbor: use the one you have, or install one

[The main guide](README.md) pushes the `golang-web` image to a Harbor registry and lets a VKS
guest cluster pull it from there. This page tells you what you need from a Harbor that exists,
and where to go when none does.

## You already have a Harbor

Most companies do. Install nothing; ask the Harbor's administrator for five things:

| you need | for |
|---|---|
| Harbor's DNS name | `HARBOR_FQDN` in the env file |
| a project you may push to | `HARBOR_PROJECT` in the env file |
| a robot account for that project (name and secret), or the Harbor admin password | [the main guide](README.md), *Log in to Harbor* |
| the SHA-256 fingerprint of Harbor's CA certificate | comparing it in the main guide's [Download and check the Harbor CA](README.md#download-and-check-the-harbor-ca) |
| confirmation that your guest cluster's nodes resolve Harbor's name and trust its CA | the cluster pulling your image |

Then follow the main guide. To check the last row yourself once you have the cluster's
kubeconfig, run the block under *Check that a guest cluster can pull from Harbor* in
[HARBOR-auto.md](HARBOR-auto.md): it needs nothing else from that guide.

A guest cluster under the same Supervisor as a Harbor Supervisor Service trusts that Harbor's CA
without any setting. For any other Harbor with a private CA, the cluster's administrator adds the
CA to the cluster; that check tells you whether it was done.

## You have none: install the Harbor Supervisor Service

The two guides below install Harbor on the Supervisor, with its own load-balancer address (the
Contour service is not needed), then get it a DNS name, a trusted CA, a project and a robot
account. Both end where the main guide's registry steps begin.

| guide | how | for |
|---|---|---|
| [HARBOR-manual.md](HARBOR-manual.md) | the vSphere Client, with screenshots, for the install; short command blocks for the files before it and the checks after it | doing it once, or learning what each step does |
| [HARBOR-auto.md](HARBOR-auto.md) | command blocks only: vCenter's API with `curl` | repeating it, or working without a browser |

### Who can install it

Installing needs three things an application developer often lacks:

- the vCenter privileges **Manage Supervisor Services** and **Manage Supervisor Services on
  Supervisors** (a vCenter administrator has them);
- a Broadcom support account entitled to download **vSphere Supervisor Services**;
- someone who can create a DNS record for Harbor's name.

If you lack the first two, send this to your vCenter administrator, with your values in place of
the three in angle brackets:

> Please install the Harbor Supervisor Service (release 2.15.2) on the Supervisor
> `<Supervisor name>`, with the host name `<harbor.example.test>` and its own load-balancer
> address (`enableNginxLoadBalancer: true`, `enableContourHttpProxy: false`). The steps are in
> `vks/HARBOR-manual.md` (vSphere Client) and `vks/HARBOR-auto.md` (API) of
> https://github.com/AndriyKalashnykov/golang-web.
>
> Afterwards I need from you: the DNS record for that host name, in a zone the guest clusters'
> nodes use; the SHA-256 fingerprint of Harbor's CA certificate; a project named
> `<project>` that I may push to; and a robot account for that project (name and secret), sent
> over a channel meant for secrets.

What you get back is the list under *You already have a Harbor* above.

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
