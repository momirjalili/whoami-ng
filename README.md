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

## Bootstrap a cluster (Flux GitOps)

The whole stack — Cilium (CNI + Gateway API + LoadBalancer IPAM), the Gateway
API CRDs, and this app — is reconciled from git by [Flux](https://fluxcd.io). A
small script creates/prepares the cluster and installs Cilium so the network
comes up, then runs `flux bootstrap`; after that **git is the source of truth**
and Flux keeps the cluster in sync.

Pinned, compatible versions: **Cilium 1.16.5**, **Gateway API v1.1.0**.

Layout:

```
k8s/
  clusters/{kind,kubeadm}/   # Flux entrypoints (bootstrap --path targets)
  infra/controllers/         # Gateway API CRDs, Cilium HelmRepository/HelmRelease
  infra/configs/cilium/      # LoadBalancer IP pool + L2 announcement policy
  app/{base,overlays}/       # the whoami-ng app
  scripts/                   # bootstrap-kind.sh, bootstrap-kubeadm.sh, lib
```

Per-cluster values (API server host, LB range, L2 interface) are injected via
Flux `postBuild` substitution from a `cluster-vars` ConfigMap that the bootstrap
script writes — so the `infra/` manifests are shared across both clusters.

Common prereqs: `kubectl`, `helm`, `flux` CLIs and a GitHub PAT exported as
`GITHUB_TOKEN` (repo scope).

### kind (local, multi-node, kube-proxy-less)

```sh
docker build -t whoami-ng:dev .
GITHUB_TOKEN=ghp_xxx ./k8s/scripts/bootstrap-kind.sh
```

Creates a 3-node kind cluster (no default CNI, no kube-proxy) and reconciles
`k8s/clusters/kind` → Cilium → LB-IPAM/L2 → `k8s/app/overlays/kind`.

### kubeadm (real cluster)

Initialise the control plane without kube-proxy and without a CNI:

```sh
kubeadm init --skip-phases=addon/kube-proxy   # plus your usual flags
```

Set your registry in `k8s/app/overlays/registry/kustomization.yaml`, push the
image, then (with your kubeconfig pointing at the cluster):

```sh
export LB_CIDR=192.168.10.240/28 L2_INTERFACE='^(eth|en).+'
GITHUB_TOKEN=ghp_xxx ./k8s/scripts/bootstrap-kubeadm.sh
```

Reconciles `k8s/clusters/kubeadm` → Cilium → LB-IPAM/L2 →
`k8s/app/overlays/registry`.

### Observe

```sh
flux get kustomizations --watch
cilium status
kubectl get gatewayclass
kubectl -n milestone get gateway,httproute
```

The `whoami-ng` Gateway gets an external IP from the Cilium pool; hit it and
watch the "Responses by pod" chart load-balance across the 3 replicas. To prove
GitOps is live, hand-edit a managed resource and watch Flux revert it.

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
