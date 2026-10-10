# Add-ons for a VKS guest cluster

An add-on is software you put on a guest cluster beside your app: a web page to look at the
cluster, a service mesh, a certificate manager. Nothing in [the main guide](../README.md) needs
one. Each chapter here is optional, comes after the main guide's *Check the guest cluster*, and
says what it needs.

## The two kinds

On VKS there are two ways to put such software on a cluster. They are different in who installs
it and where you manage it.

| | a VKS add-on | something you install yourself |
|---|---|---|
| what you write | one `AddonInstall` object on the **Supervisor**, in the vSphere Namespace that holds the cluster | a `helm install` or a `kubectl apply` on the **guest cluster** |
| who installs it | VKS: it puts the software into the guest cluster and keeps it there | you |
| which versions | the ones Broadcom ships with your VKS version (the add-on catalogue) | whatever the project publishes |
| the kubeconfig you use | the Supervisor's (`$SUPERVISOR_KUBECONFIG`) | the guest cluster's (`$GUEST_KUBECONFIG`) |
| its settings | an `AddonConfig` object that VKS creates; you change it, you never create it | a values file or the manifest |
| removing it | delete the `AddonInstall` | `helm uninstall` or `kubectl delete` |
| after the cluster is rebuilt | VKS installs it again | you install it again |

A VKS add-on needs a Supervisor whose VKS has the add-on catalogue; VKS 3.6 and 3.7 have it.
Your SSO user needs the **Edit** role on
the vSphere Namespace, as for creating a cluster. The chapters were written for VMware Cloud
Foundation 9.1.1 and VKS 3.7.

This lists the add-ons your Supervisor offers. It is read-only.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n vmware-system-vks-public get addons.addons.kubernetes.vmware.com
```

**Expect:** one line per add-on, among them `istio`, and on VKS 3.7 `headlamp`.

**If not:**
- `the server doesn't have a resource type "addons"`: this Supervisor's VKS has no add-on
  catalogue. Only the "install it yourself" ways work.
- `Forbidden`: your SSO user has no role on any vSphere Namespace of this Supervisor.
- `Unauthorized`: the Supervisor login ended. Run the main guide's *Renew the Supervisor login*
  block, then this block again.

## The add-ons covered

| add-on | what it is | ways to get it | chapter |
|---|---|---|---|
| Headlamp | a web page that shows what runs on the cluster | the desktop program on your machine (nothing installed on the cluster); the project's helm chart; the VKS add-on | [HEADLAMP.md](HEADLAMP.md) |
| Istio | a service mesh, and a gateway that brings traffic from outside to your app | the VKS add-on | [ISTIO.md](ISTIO.md) |

## What an add-on changes in the other chapters

Each add-on changes only what this table says. Everything else in the other chapters stays as
written, and a cluster without add-ons needs none of it.

| add-on | chapter it touches | what changes |
|---|---|---|
| Headlamp, desktop | none | nothing |
| Headlamp, helm chart | the main guide's tools | you also need `helm`, only for this |
| Headlamp, either way on the cluster | the main guide's clean-up | one more namespace on the guest cluster (`headlamp`), removed by the chapter's own uninstall block |
| Istio | [Create a guest cluster with kubectl](../CLUSTER.md), *Choose the cluster's values* | larger workers, or one more: the sizes table there has the row |
| Istio | the main guide's deploy and reach steps | the app's Service becomes `ClusterIP`, and you reach the app through the gateway's address on port 80, not the Service's own address on port 8080 |
| Istio | the main guide's clean-up | one more namespace on the guest cluster (`istio-ingress`) and one object on the Supervisor, removed by the chapter's own uninstall blocks |
