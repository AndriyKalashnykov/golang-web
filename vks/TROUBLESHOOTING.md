# Fix common problems

This chapter lists the errors a reader of [the main guide](README.md), of [SETUP.md](SETUP.md)
and of [REGISTRY.md](REGISTRY.md) can meet, by the text they print, each with its fix. Find your
message in the left column. The other chapters end with a table of their own for what only they
can print. You need nothing but the terminal where the error appeared.

## Certificates and fingerprints

| symptom | fix |
|---|---|
| Fingerprint differs from your administrator's ([vCenter CA](README.md#download-and-check-the-vcenter-ca) or [Harbor CA](REGISTRY.md#download-and-check-the-harbor-ca)) | Do not continue. Check `VCENTER_FQDN` or `HARBOR_FQDN`; send the fingerprint you got to your administrator and ask them to confirm it or send the CA file. A company proxy replacing HTTPS certificates also causes this. |
| `x509: certificate signed by unknown authority` on login or push | Run the block for **your** engine under [Install the CA for your engine](REGISTRY.md#install-the-ca-for-your-engine); the directory must be exactly `$HARBOR_FQDN`. On macOS with Colima, `docker context show` must also print `colima`; if it does not, run `docker context use colima`. |
| `x509: "harbor" certificate is not standards compliant` (macOS) | If you added the CA to the macOS Keychain instead: use the podman or Colima block under [Install the CA for your engine](REGISTRY.md#install-the-ca-for-your-engine). |

## The tools on this machine

| symptom | fix |
|---|---|
| `docker: unknown command: docker buildx` (macOS) | Re-run the `ln -sfn … docker-buildx` line of the macOS docker block under [Install a container engine — pick one](SETUP.md#install-a-container-engine--pick-one). |
| `dial unix /var/run/docker.sock` (macOS) | `colima start`. If it prints `already running`, `docker` is pointed at another engine: `docker context use colima`. |
| `bad CPU type in executable` (macOS) | An Intel-only program (such as the Supervisor's kubectl, from the alternative under [Install kubectl](SETUP.md#install-kubectl)) needs Rosetta: `softwareupdate --install-rosetta --agree-to-license` |
| `vcf plugin list` pauses on `Refreshing plugin inventory cache` | Wait: it stops by itself after about 30 s (it cannot reach VMware's plugin server). The installed plugins do not need that server. |
| Every `vcf` command first prints `The vcf cli essential plugins have not been installed …` and `Failed to install plugin 'telemetry:v9.0.2'` | Harmless: the command still runs. `vcf` looks online for a plugin version that Broadcom has not published; it happens on a machine where `vcf` has been used before. The env file from [Set the variables](README.md#set-the-variables) sets `VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION=v9.1.1`, which stops it: run `source ~/.vks-golang-web.env` first. If your env file is older and lacks that line, add `export VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION=v9.1.1` to it. Broadcom does not document this setting. |
| `kubectl_install: command not found` | Re-run the first block of [Set the variables](README.md#set-the-variables); it rewrites `~/.vks-golang-web.functions` and keeps your values. |
| `kubectl_install: no version` under [Get the guest cluster's kubeconfig](README.md#get-the-guest-clusters-kubeconfig) | The guest cluster did not answer: check the kubeconfig block's output; if it shows `Unauthorized`, run the [Renew the Supervisor login](README.md#renew-the-supervisor-login) block, then the kubeconfig block again. |
| `kubectl_install: cannot reach dl.k8s.io` | Ask your administrator to allow dl.k8s.io (the real fix). Until then, run the *Alternative: download kubectl from your Supervisor* block under [Install kubectl](SETUP.md#install-kubectl): Intel/AMD machines only, and the Supervisor's older version. |
| `kubectl_install: the checksum of the download does not match` | The download arrived damaged. Run the block again; if it repeats, tell your administrator and do not install kubectl by hand from that download. |
| `kubectl_install: … installing into <your home>/.local/bin instead` | Not an error: `sudo` would have asked for a password, and the install never asks. To have kubectl in `/usr/local/bin`, run `sudo -v` as a block of its own, then the block again. |
| `kubectl_install: … was not on your PATH` | kubectl works in this terminal. For new terminals, add the `export PATH=…` line it printed to `~/.zshrc` (zsh) or `~/.bashrc` (bash). |
| `kubectl_install: could not write …` | The error above that line says why. Set `KUBECTL_DIR` in the env file to a directory you may write to, then run the block again. |
| `vc_login: command not found`, or `vc_api: command not found` | Your `~/.vks-golang-web.functions` was written by an older version of the main guide. Re-run the first block of [Set the variables](README.md#set-the-variables): it rewrites that file and keeps your values. |

## The Supervisor login

| symptom | fix |
|---|---|
| `error: You must be logged in to the server (Unauthorized)` from a Supervisor command | Your Supervisor login ended (it lasts about 10 hours). Run the [Renew the Supervisor login](README.md#renew-the-supervisor-login) block (the one inside the alternative under [Log in to the Supervisor](README.md#log-in-to-the-supervisor) if you logged in with the certificate checked), then the command again. |
| `context "supervisor" already exists` on login | A login is saved already. Run the [Delete the Supervisor login](README.md#delete-the-supervisor-login) block, then log in again. |

## The app on the cluster

| symptom | fix |
|---|---|
| `ImagePullBackOff` for the image `ghcr.io/…`, with a timeout or `no such host` in `kubectl describe pod` | The guest cluster's nodes cannot reach ghcr.io. Ask your administrator to allow it, or build the image yourself and run it from your Harbor: [REGISTRY.md](REGISTRY.md). |
| `ImagePullBackOff` with `x509` in `kubectl describe pod` | The guest cluster does not trust Harbor's CA. Ask your administrator to add Harbor's CA certificate (your `$HARBOR_CA` file) to the trusted CAs of the guest cluster `$VKS_CLUSTER`. |
| `ImagePullBackOff` with `pull access denied` or `no basic auth credentials` in `kubectl describe pod` | The project is private: run the pull-secret block under [Create a pull secret — only for a private project](REGISTRY.md#create-a-pull-secret--only-for-a-private-project), then `kubectl rollout restart deploy/golang-web` (running pods keep their old pull settings). |
| Pod crash-loops | `kubectl logs deploy/golang-web --previous`, and send the output to the app's owner. |
| `exec format error` in the pod | The image lacks the node's architecture: push again without `PUSH_PLATFORMS`, or include the node's (`linux/amd64`). |
| Pod rejected at admission | The cluster enforces the `restricted` security policy, and `k8s/golang-web.yaml` complies. If you changed the file, keep it compliant; if not, send the message from `kubectl get events` to your administrator. |

## Harbor, build and push

| symptom | fix |
|---|---|
| `403` on the lookup under [Check that Harbor has both architectures](REGISTRY.md#check-that-harbor-has-both-architectures) or [Deploy the image you pushed](REGISTRY.md#deploy-the-image-you-pushed) | The robot needs `artifact` read and list; create it with [Option A — create a robot account](REGISTRY.md#option-a--create-a-robot-account). |
| `unauthorized` on push | Re-run [Log the container engine in to Harbor](REGISTRY.md#log-the-container-engine-in-to-harbor). A robot stops working when its `duration` (days) ends: then create a new one with [Option A — create a robot account](REGISTRY.md#option-a--create-a-robot-account) (`ERROR CONFLICT` there says how). |
| `blob upload invalid` on push | Harbor's storage is full: ask your administrator to run garbage collection or add space, then push again. |
| `labelled the amd64 image variant 'v8'`, or `labelling the amd64 image with a variant`, on [Build and push](REGISTRY.md#build-and-push) | podman older than 5 on an arm64 Linux machine: push with docker (`CONTAINER_ENGINE=docker` in the env file), or podman 5.8 (measured correct). Only if every node is arm64: `PUSH_PLATFORMS=linux/arm64`. |
| `'podman buildx' is not available`, on [Build and push](REGISTRY.md#build-and-push) | podman older than 4.9 (Debian 12 has 4.3): push with docker (`CONTAINER_ENGINE=docker` in the env file). |
