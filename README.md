[![ci](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml/badge.svg)](https://github.com/AndriyKalashnykov/golang-web/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/golang-web.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/golang-web/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/golang-web)
# HTTP web server with Prometheus metrics in Go

* http web server running by default on port 8080 that is intended for testing.
* Prometheus formatted metrics available at "/metrics" with key "total_request_count" using [prometheus/client_golang library](https://github.com/prometheus/client_golang).
* Kubernetes compatible health check available at "/healthz".

## Running image locally

In terminal #1
```bash
cd golang-web
make make image-test-fg
```

In terminal #2
```bash
xdg-open http://localhost:8080/myhello/
```

## Pulling image from GitHub Container Registry

```
docker pull ghcr.io/andriykalashnykov/golang-web:latest
```

## Environment variables available to image

* PORT - listen port, defaults to 8080
* APP_CONTEXT - base context path of app, defaults to '/'

## Environment variables populated from Downward API

* MY_NODE_NAME - name of k8s node
* MY_POD_NAME - name of k8s pod
* MY_POD_NAMESPACE - namespace of k8s pod
* MY_POD_IP - k8s pod IP
* MY_POD_SERVICE_ACCOUNT - service account of k8s pod

## Tagging

```bash
newtag=v0.0.1
git commit -a -m "changes for new tag $newtag" && git push
git tag $newtag && git push origin $newtag
```

## Deleting a tag

```bash
# delete local tag, then remote
todel=v0.0.1
git tag -d $todel && git push origin :refs/tags/$todel
```

# References

* https://ashishb.net/tech/docker-101-a-basic-web-server-displaying-hello-world/
* https://tutorialedge.net/golang/creating-simple-web-server-with-golang/
* https://blog.gopheracademy.com/advent-2017/kubernetes-ready-service/
* https://semaphoreci.com/community/tutorials/how-to-deploy-a-go-web-application-with-docker
* https://prometheus.io/docs/tutorials/instrumenting_http_server_in_go/