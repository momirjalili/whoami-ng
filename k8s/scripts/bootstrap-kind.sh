#!/usr/bin/env bash
# Bootstrap a local, production-like kind cluster: Cilium (CNI + Gateway API +
# LB-IPAM/L2) with kube-proxy replacement, then hand off to Flux GitOps.
#
# Prereqs: docker, kind, kubectl, helm, flux CLIs; GITHUB_TOKEN env var.
# Usage:   docker build -t whoami-ng:dev .
#          GITHUB_TOKEN=ghp_xxx ./k8s/scripts/bootstrap-kind.sh

set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root (whoami-ng)

# shellcheck source=k8s/scripts/lib-flux-cilium.sh
source "k8s/scripts/lib-flux-cilium.sh"

CLUSTER_NAME="${CLUSTER_NAME:-whoami}"
KIND_CONFIG="k8s/scripts/kind-cluster.yaml"
APP_IMAGE="${APP_IMAGE:-whoami-ng:dev}"

for c in docker kind kubectl helm flux; do require "$c"; done

echo ">> Creating kind cluster '${CLUSTER_NAME}' (no default CNI, no kube-proxy)"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "   cluster already exists, reusing"
else
  kind create cluster --config "${KIND_CONFIG}"
fi

# kube-proxy-less Cilium needs to reach the API server directly: use the
# control-plane container's IP on the kind docker network.
K8S_SERVICE_HOST="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${CLUSTER_NAME}-control-plane")"

# LoadBalancer IPs must live inside the kind docker network subnet to be
# reachable from the host. Detect the subnet and default to a /26 slice of the
# common 172.18.0.0/16; override LB_CIDR if yours differs.
KIND_SUBNET="$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')"
echo ">> kind docker subnet: ${KIND_SUBNET}"
LB_CIDR="${LB_CIDR:-172.18.255.192/26}"
L2_INTERFACE="${L2_INTERFACE:-eth0}"
echo ">> Using LB_CIDR=${LB_CIDR} L2_INTERFACE=${L2_INTERFACE}"

# Side-load the app image (the kind overlay uses imagePullPolicy: IfNotPresent).
if docker image inspect "${APP_IMAGE}" >/dev/null 2>&1; then
  echo ">> Loading ${APP_IMAGE} into kind"
  kind load docker-image "${APP_IMAGE}" --name "${CLUSTER_NAME}"
else
  echo "   WARNING: ${APP_IMAGE} not found locally — build it (docker build -t ${APP_IMAGE} .)"
  echo "            and run: kind load docker-image ${APP_IMAGE} --name ${CLUSTER_NAME}"
fi

install_gateway_api_crds
install_cilium "${K8S_SERVICE_HOST}"
wait_cilium
write_cluster_vars "${K8S_SERVICE_HOST}" "${LB_CIDR}" "${L2_INTERFACE}"
install_flux_operator
create_flux_secret
apply_flux_instance "k8s/infra/controllers/flux"

echo ">> Done. Watch reconciliation: flux get kustomizations --watch"
