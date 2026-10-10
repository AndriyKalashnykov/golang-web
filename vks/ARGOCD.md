# Use or install ArgoCD on the Supervisor

ArgoCD keeps what is described in Git applied to a destination. On a Supervisor it is a
Supervisor Service: once the service is installed, a vSphere Namespace can run its own ArgoCD
(an *instance*). This page tells you how to check an ArgoCD that exists, where to go when none
does, and what these guides use ArgoCD for.

**You need vCenter administrator rights to install the ArgoCD Service; to check and use an
ArgoCD instance you need only the Edit role on your vSphere Namespace.**

| your situation | go to |
|---|---|
| The ArgoCD Service is installed, or your namespace already runs ArgoCD | [Use the ArgoCD you have](#use-the-argocd-you-have), below |
| You have none: install it by hand | [ARGOCD-manual.md](ARGOCD-manual.md): the vSphere Client and the ArgoCD web page, with screenshots, a few short `kubectl` commands, and the `argocd` program for steps 8 and 9 |
| You have none: install it with scripts | [ARGOCD-auto.md](ARGOCD-auto.md): command blocks only, vCenter's API with `curl`, and the `argocd` program |

Both guides continue from [the main guide](README.md), after its
[Log in to the Supervisor](README.md#log-in-to-the-supervisor), and each removes what it
installed.

<a id="if-you-are-not-a-vcenter-administrator"></a>

<details>
<summary><b>If you are not a vCenter administrator</b></summary>

Only registering and installing the service needs a vCenter administrator. Ask one for:

- the ArgoCD Service (release 1.2.0) registered in vCenter and installed on your Supervisor:
  steps 2 and 3 of [ARGOCD-manual.md](ARGOCD-manual.md), or step 4 of
  [ARGOCD-auto.md](ARGOCD-auto.md);
- the **Edit** role (the vSphere Client calls it **Can edit**) on your vSphere Namespace for
  your SSO user;
- word when the service shows **Configured**. Everything after that you do yourself.

</details>

## Use the ArgoCD you have

Run the block by copy and paste, in `bash` or `zsh`, on Linux or macOS. It asks the Supervisor
three things: is the ArgoCD Service installed, does your vSphere Namespace run an ArgoCD
instance, and is that instance's first admin password still there.

```sh
source ~/.vks-golang-web.env
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" get argocdversion argocd-supported-versions -o name
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get argocd -o jsonpath='{range .items[*]}{"ArgoCD instance: "}{.metadata.name}{"  "}{.status.phase}{"  https://"}{.status.externalIP}{"\n"}{end}'
kubectl --kubeconfig "$SUPERVISOR_KUBECONFIG" -n "$VKS_NAMESPACE" get secret argocd-initial-admin-secret --ignore-not-found -o name
```

**Expect:** three lines: a name ending in `/argocd-supported-versions` (the service is
installed), then `ArgoCD instance: <its name>  Ready  https://<an address>` (your namespace runs
ArgoCD, and that address is its web page), then `secret/argocd-initial-admin-secret` (you can
log in as `admin` with the first password). With all three, install nothing: log in the way
[Log in to the ArgoCD web page](ARGOCD-manual.md#5-log-in-to-the-argocd-web-page) or
[Log in](ARGOCD-auto.md#log-in) shows, then go on with number 2 or 3 of the list below.

**If not:**
- `the server doesn't have a resource type "argocdversion"`: the ArgoCD Service is not installed
  on this Supervisor. Install it [by hand](ARGOCD-manual.md) or [with scripts](ARGOCD-auto.md).
- The first line only: the service is installed and your namespace has no instance yet. Start
  at [Create the ArgoCD instance](ARGOCD-manual.md#4-create-the-argocd-instance) (by hand) or
  [Create the ArgoCD instance](ARGOCD-auto.md#5-create-the-argocd-instance) (with scripts): the
  **Edit** role is enough from there on.
- No `secret/…` line: someone changed the admin password and removed the first one. Ask them
  for the login.
- `Forbidden`: your SSO user lacks the **Edit** role on the namespace. `Unauthorized`: run the
  main guide's [Renew the Supervisor login](README.md#renew-the-supervisor-login) block.

## What these guides do with ArgoCD

In this order:

1. **Install it.** Register the ArgoCD Service, install it on the Supervisor and start an
   instance in your vSphere Namespace: steps 1 to 6 of
   [ARGOCD-manual.md](ARGOCD-manual.md) (by hand) or [ARGOCD-auto.md](ARGOCD-auto.md) (with
   scripts).
2. **Create a guest cluster with it.** The same two guides, from their step 7 on:
   [Create a guest cluster with ArgoCD](ARGOCD-manual.md#7-create-a-guest-cluster-with-argocd)
   and [Add the new cluster to ArgoCD](ARGOCD-manual.md#8-add-the-new-cluster-to-argocd) by
   hand, or
   [Create a guest cluster with ArgoCD](ARGOCD-auto.md#7-create-a-guest-cluster-with-argocd)
   and [Add the new cluster to ArgoCD](ARGOCD-auto.md#8-add-the-new-cluster-to-argocd) with
   scripts. ArgoCD creates the cluster from the chart in
   [`argocd/guest-cluster`](argocd/guest-cluster); it is the same cluster that
   [CLUSTER.md](CLUSTER.md) creates without ArgoCD.
3. **Deploy this web app with it.** [Deploy golang-web with ArgoCD](ARGOCD-app.md) has ArgoCD
   deploy this repository's app into a guest cluster, whichever way that cluster was created.
4. **The vSphere Namespace is not created with ArgoCD.** A Supervisor has no declarative object
   for a vSphere Namespace. Where Namespace Self-Service is on, a `Namespace` created through
   the Supervisor's Kubernetes API becomes one
   ([NAMESPACE-auto.md](NAMESPACE-auto.md#create-it-with-kubectl-namespace-self-service)), and
   creating it from an ArgoCD Application has not been run. So the guides create the namespace
   first ([NAMESPACE.md](NAMESPACE.md)) and ArgoCD works inside it.

## Where the chart lives and what changes when you host it yourself

**You do not need the `helm` program for the ArgoCD guides:** ArgoCD renders the chart itself.

ArgoCD reads the chart from **Git**, not from a chart repository. An Application names three
things: the repository's address (`repoURL`), a revision of it (`targetRevision`: a commit, a tag
or a branch) and the folder inside it (`path`). ArgoCD downloads that folder, fills in the
values the Application carries, and applies the result. As written, both guides read
`vks/argocd/guest-cluster` from this repository on GitHub, at one fixed commit.

To host the chart yourself, copy the `vks/argocd/guest-cluster` folder into a Git repository of
your own (a fork of this one keeps the same path) and change these, all of them:

| what | [ARGOCD-auto.md](ARGOCD-auto.md) | [ARGOCD-manual.md](ARGOCD-manual.md) |
|---|---|---|
| the repository's address | `CLUSTER_REPO` in `~/.vks-argocd.env` | `repoURL:` in the Application's 20 lines |
| the revision: a commit of **your** repository | `CLUSTER_REVISION` in `~/.vks-argocd.env` | `targetRevision:` in the same lines |
| the folder, only if you moved it | `--path` in *Create the Application and look at what it will do* | `path:` in the same lines |
| the project's allowed repository | run the project block of *Let ArgoCD manage your vSphere Namespace* again: it takes `CLUSTER_REPO` | change the line under `sourceRepos:` in the project block of *Let ArgoCD manage your vSphere Namespace*, and run it again |
| a login, only for a private repository | see below | see below |

A project that still names the old repository answers
`application repo … is not permitted in project 'vks-clusters'`. A commit is the safest
revision: with a branch name, every push to that branch changes what the next sync applies.

**A private repository** needs a login that ArgoCD can use: a *repository* secret in your
vSphere Namespace, holding the address, a user name and an access token that may only read the
repository. The block under *Use your own Git repository* in
[Deploy golang-web with ArgoCD](ARGOCD-app.md#use-your-own-git-repository) creates it without
the token on a command line. It reads the address from `APP_REPO`: set that to the chart's
repository first. When the app and the chart are in one repository (a fork of this one), one
login covers both. A public repository needs no login.

**In Harbor, as an OCI chart: not covered.** ArgoCD 3.4 can read a chart from an OCI registry:
the Application then names the registry and project as `repoURL` and the chart as `chart`, in
place of `path`, with the chart's version as `targetRevision`
([ArgoCD 3.4.4, Helm](https://github.com/argoproj/argo-cd/blob/v3.4.4/docs/user-guide/helm.md)).
A registry that asks for a login needs a repository secret with `enableOCI: "true"`
([ArgoCD 3.4.4, Declarative Setup, Helm](https://github.com/argoproj/argo-cd/blob/v3.4.4/docs/operator-manual/declarative-setup.md#helm)),
and a registry with a certificate from a private CA, as a Harbor on the Supervisor has, needs
that CA given to ArgoCD
([the same page, Repositories using self-signed TLS certificates](https://github.com/argoproj/argo-cd/blob/v3.4.4/docs/operator-manual/declarative-setup.md#repositories-using-self-signed-tls-certificates-or-are-signed-by-custom-ca)).
These guides do not do that, and it was not tried on a Supervisor. It is also the one case that
needs the `helm` program on your machine: to package the chart and push it to Harbor.
