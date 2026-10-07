# Install ArgoCD onto Supervisor and create a VKS guest cluster with it

This guide has two versions. Both install the ArgoCD Supervisor Service, start an ArgoCD instance
in your vSphere Namespace, and create a VKS guest cluster through it.

| guide | how | for |
|---|---|---|
| [ARGOCD-manual.md](ARGOCD-manual.md) | the vSphere Client and the ArgoCD web page, with screenshots, and a few one-line `kubectl` commands | doing it once, or learning what each step does |
| [ARGOCD-auto.md](ARGOCD-auto.md) | command blocks only: vCenter's API with `curl`, and the `argocd` program | repeating it, or working without a browser |

Both continue from steps 1, 2 and 7 of [the main guide](README.md), and both use the chart in
[`argocd/guest-cluster`](argocd/guest-cluster).
