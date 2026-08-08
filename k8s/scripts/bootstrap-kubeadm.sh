#!/usr/bin/env bash
# Bootstrap Cilium (CNI + Gateway API + LB-IPAM/L2) and Flux GitOps onto an
# EXISTING kubeadm cluster.
#
# Cluster prerequisites (at `kubeadm init` time):
#   - kube-proxy skipped:  kubeadm init --skip-phases=addon/kube-proxy ...
#   - NO CNI installed yet (Cilium becomes the CNI; nodes stay NotReady until then)
#   - your kubeconfig points at the cluster (KUBECONFIG or ~/.kube/config)
#
# Tooling prereqs: kubectl, helm, flux CLIs; GITHUB_TOKEN env var.
#
# Cluster-specific overrides (export before running):
#   LB_CIDR           LoadBalancer IP range on your LAN   (default 192.168.10.240/28)
#   L2_INTERFACE      NIC regex for L2 announcements       (default ^(eth|en).+)
#   K8S_SERVICE_HOST  API server host (default: parsed from kubeconfig)
#
# Usage: GITHUB_TOKEN=ghp_xxx ./k8s/scripts/bootstrap-kubeadm.sh

set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root (whoami-ng)

# shellcheck source=k8s/scripts/lib-flux-cilium.sh
source "k8s/scripts/lib-flux-cilium.sh"

for c in kubectl helm flux; do require "$c"; done

# Derive the API server host from the current kubeconfig unless overridden.
if [[ -z "${K8S_SERVICE_HOST:-}" ]]; then
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  K8S_SERVICE_HOST="$(printf '%s' "${server}" | sed -E 's#^https?://##; s#:[0-9]+$##')"
fi

LB_CIDR="${LB_CIDR:-192.168.10.240/28}"
L2_INTERFACE="${L2_INTERFACE:-^(eth|en).+}"

echo ">> Target API server host: ${K8S_SERVICE_HOST}"
echo ">> LB_CIDR=${LB_CIDR}  L2_INTERFACE=${L2_INTERFACE}"
echo ">> NOTE: the app is reconciled from k8s/app/overlays/registry — set your"
echo "         registry in that overlay and push the image before Flux syncs it."

install_gateway_api_crds
install_cilium "${K8S_SERVICE_HOST}"
wait_cilium
write_cluster_vars "${K8S_SERVICE_HOST}" "${LB_CIDR}" "${L2_INTERFACE}"
flux_bootstrap "k8s/clusters/kubeadm"

echo ">> Done. Watch reconciliation: flux get kustomizations --watch"
