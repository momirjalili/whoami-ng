# whoami-ng

A [traefik/whoami](https://github.com/traefik/whoami)-inspired HTTP service with a
browser frontend, built for poking at a local Kubernetes cluster.

- `GET /api/whoami` — JSON info about the pod/host that answered: hostname, pod
  name/IP, node, namespace, local IPs, and details of the request itself
  (method, headers, remote addr).
- `GET /healthz`, `GET /readyz` — liveness/readiness probes.
- `GET /api/generate/stream` — server-sent-events endpoint that fires a batch of
  HTTP requests at a target URL from inside the pod (a "curl from the cluster"
  button), useful for testing in-cluster Service DNS and load balancing.
- A single-page frontend (`/`) showing the instance info, two traffic-generation
  modes (**ping** from the browser, **curl** from the server), live stats, a
  per-pod response chart, and a request log — so you can *watch* a Kubernetes
  Service load-balance across replica pods in real time.

No external dependencies — plain Go standard library + vanilla HTML/CSS/JS,
embedded into a single static binary.

## Run locally

```sh
go run .
# or: go build -o whoami-ng . && ./whoami-ng -addr :8080
```

Open http://localhost:8080.

## Build the image

```sh
docker build -t whoami-ng:dev .
```

## Deploy to a local cluster

### kind

```sh
kind load docker-image whoami-ng:dev
kubectl apply -f k8s/
kubectl port-forward svc/whoami-ng 8080:80
```

Open http://localhost:8080 — refresh or ping/curl repeatedly and watch the
"Responses by pod" chart fill in as the Service load-balances across the 3
replicas.

### minikube

```sh
minikube image load whoami-ng:dev
kubectl apply -f k8s/
kubectl port-forward svc/whoami-ng 8080:80
```

### kubeadm / bare containerd nodes (no registry)

For a multi-node cluster with no shared registry (e.g. kubeadm on VMs), load
the image directly into each node's containerd via `ctr`:

```sh
k8s/load-image.sh whoami-ng:dev
kubectl apply -k k8s/
kubectl rollout restart deployment/whoami-ng  # if it's already running
```

Assumes SSH access to each node (default hosts: `controller worker-1
worker-2`, override with `NODES="host1 host2" k8s/load-image.sh`) and `sudo
ctr` on the remote end.

### Any cluster with a registry

```sh
docker build -t <registry>/whoami-ng:dev .
docker push <registry>/whoami-ng:dev
# update k8s/deployment.yaml image: to <registry>/whoami-ng:dev
kubectl apply -f k8s/
```

## Trying it out

- Scale replicas and watch the pod chart pick up new bars:
  `kubectl scale deployment/whoami-ng --replicas=5`
- Kill a pod and watch requests keep flowing to the survivors:
  `kubectl delete pod -l app=whoami-ng --field-selector=status.phase=Running -o name | head -1 | xargs kubectl delete`
- Point curl-mode at another Service's DNS name
  (`http://<svc>.<namespace>.svc.cluster.local/...`) to test in-cluster service
  discovery from the browser.
- `kubectl logs -l app=whoami-ng -f --prefix` to watch access logs across all
  replicas as you generate traffic.

## Notes

This is a learning/testing tool, not hardened for public exposure — the
curl-mode generator will fetch whatever URL you give it from inside the pod, so
keep it on a local/private cluster.
