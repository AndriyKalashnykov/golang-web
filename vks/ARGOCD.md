# Install ArgoCD onto Supervisor and create a VKS guest cluster with it

This guide has two versions. Both install the ArgoCD Supervisor Service, start an ArgoCD instance
in your vSphere Namespace, and create a VKS guest cluster through it.

| guide | how | for |
|---|---|---|
| [ARGOCD-manual.md](ARGOCD-manual.md) | the vSphere Client and the ArgoCD web page, with screenshots, a few short `kubectl` commands, and the `argocd` program for steps 8 and 9 | doing it once, or learning what each step does |
| [ARGOCD-auto.md](ARGOCD-auto.md) | command blocks only: vCenter's API with `curl`, and the `argocd` program | repeating it, or working without a browser |

Both continue from [the main guide](README.md), after its
[Log in to the Supervisor](README.md#log-in-to-the-supervisor), and both use the chart in
[`argocd/guest-cluster`](argocd/guest-cluster).

## Deploy the app with ArgoCD

Once ArgoCD runs and a guest cluster exists (created by ArgoCD or with `kubectl`),
[Deploy golang-web with ArgoCD](ARGOCD-app.md) has ArgoCD deploy this repository's app into
that cluster.

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
