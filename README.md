# HTTP web server with Prometheus metrics in Go

* http web server running by default on port 8080 that is intended for testing.
* Prometheus formatted metrics available at "/metrics" with key "total_request_count" using [prometheus/client_golang library](https://github.com/prometheus/client_golang).
* Kubernetes compatible health check available at "/healthz".

# Pulling image from GitHub Container Registry

```
docker pull ghcr.io/andriykalashnykov/golang-web:latest
```

# Environment variables available to image

* PORT - listen port, defaults to 8080
* APP_CONTEXT - base context path of app, defaults to '/'

# Environment variables populated from Downward API
* MY_NODE_NAME - name of k8s node
* MY_POD_NAME - name of k8s pod
* MY_POD_NAMESPACE - namespace of k8s pod
* MY_POD_IP - k8s pod IP
* MY_POD_SERVICE_ACCOUNT - service account of k8s pod

# Tagging
```
newtag=v0.0.1
git commit -a -m "changes for new tag $newtag" && git push
git tag $newtag && git push origin $newtag
```

# Deleting tag

```
# delete local tag, then remote
todel=v0.0.1
git tag -d $todel && git push origin :refs/tags/$todel
```
