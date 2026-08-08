#!/usr/bin/env bash
# Shared helpers for the Flux + Cilium bootstrap scripts.
# Sourced by bootstrap-kind.sh and bootstrap-kubeadm.sh.

set -euo pipefail

# --- Pinned, known-compatible versions ---
# Cilium 1.16 implements Gateway API v1.1.0.
CILIUM_VERSION="${CILIUM_VERSION:-1.20.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"

# --- GitHub / Flux settings (override via env) ---
GITHUB_OWNER="${GITHUB_OWNER:-momirjalili}"
GITHUB_REPO="${GITHUB_REPO:-whoami-ng}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GITHUB_APP_ID="${GITHUB_APP_ID:-}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"
GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-}"


require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }
}

install_gateway_api_crds() {
  echo ">> Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
}

# install_cilium <k8sServiceHost>
# Values here MUST match k8s/infra/controllers/cilium/helmrelease.yaml so that
# Flux adopts this release with zero drift.
install_cilium() {
  local k8s_service_host="$1"
  echo ">> Installing Cilium ${CILIUM_VERSION} (k8sServiceHost=${k8s_service_host})"
  helm repo add --force-update cilium https://helm.cilium.io >/dev/null
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${k8s_service_host}" \
    --set k8sServicePort=6443 \
    --set operator.replicas=1 \
    --set gatewayAPI.enabled=true \
    --set l2announcements.enabled=true \
    --set externalIPs.enabled=true \
    --set k8sClientRateLimit.qps=50 \
    --set k8sClientRateLimit.burst=100 \
    --set hubble.enabled=false
}

wait_cilium() {
  echo ">> Waiting for Cilium to become ready"
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
  kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
}

# write_cluster_vars <host> <lbCidr> <l2Interface>
# Creates the ConfigMap that Flux postBuild substitution reads. Created BEFORE
# `flux bootstrap` so it exists by the time the infra Kustomizations reconcile.
write_cluster_vars() {
  local host="$1" lb_cidr="$2" l2_iface="$3"
  echo ">> Writing cluster-vars ConfigMap (host=${host} lb=${lb_cidr} iface=${l2_iface})"
  kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap cluster-vars -n flux-system \
    --from-literal=CILIUM_K8S_SERVICE_HOST="${host}" \
    --from-literal=CILIUM_LB_CIDR="${lb_cidr}" \
    --from-literal=CILIUM_L2_INTERFACE="${l2_iface}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# flux_bootstrap <clusterPath>
flux_bootstrap() {
  local cluster_path="$1"
  : "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a GitHub PAT with 'repo' scope}"
  echo ">> flux bootstrap github --path=${cluster_path}"
  flux check --pre
  flux bootstrap github \
    --owner="${GITHUB_OWNER}" \
    --repository="${GITHUB_REPO}" \
    --branch="${GIT_BRANCH}" \
    --path="${cluster_path}" \
    --personal
}

install_flux_operator() {
  echo ">> Installing Flux Operator "
  helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace --force-conflicts
  kubectl -n flux-system rollout status deployment/flux-operator --timeout=120s
}

# create_flux_secret requires GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and
# GITHUB_APP_PRIVATE_KEY_PATH (a path to the app's private key PEM file, not the
# key content itself) to be set in the environment.
create_flux_secret() {
  : "${GITHUB_APP_ID:?Set GITHUB_APP_ID to the GitHub App ID}"
  : "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID to the GitHub App installation ID}"
  : "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH to the path of the GitHub App private key PEM file}"
  pwd
  flux create secret githubapp flux-system \
  --app-id="${GITHUB_APP_ID}" \
  --app-installation-id="${GITHUB_APP_INSTALLATION_ID}" \
  --app-private-key="${GITHUB_APP_PRIVATE_KEY_PATH}"
}

# apply_flux_instance <kustomizeDir>
# Applies the FluxInstance CR that tells flux-operator which Flux components
# to install and which git path to sync. This is the actual handoff to Flux:
# without it, flux-operator is installed but reconciles nothing. Must run
# after install_flux_operator (CRD) and create_flux_secret (the pullSecret
# the FluxInstance references).
apply_flux_instance() {
  local kustomize_dir="$1"
  echo ">> Applying FluxInstance (${kustomize_dir})"
  kubectl apply -k "${kustomize_dir}"
}