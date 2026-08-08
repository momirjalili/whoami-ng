#!/usr/bin/env bash
# Load a locally-built image into every node of a containerd-based cluster
# (e.g. kubeadm on VMs) that has no shared registry. Saves the image with
# docker, scp's the tarball to each node, and imports it into containerd's
# k8s.io namespace via `ctr`.
#
# Usage:
#   k8s/scripts/load-image.sh [image[:tag]]
#
# Env overrides:
#   NODES   space-separated SSH hosts/aliases (default: controller worker-1 worker-2)

set -euo pipefail

IMAGE="${1:-whoami-ng:dev}"
NODES="${NODES:-controller worker-1 worker-2}"
TARBALL="/tmp/$(echo "$IMAGE" | tr '/:' '__').tar"

echo "==> Saving $IMAGE to $TARBALL"
docker save "$IMAGE" -o "$TARBALL"

for host in $NODES; do
  echo "==> $host: copying image"
  scp -q "$TARBALL" "$host:$TARBALL"

  echo "==> $host: importing into containerd"
  ssh "$host" "sudo ctr -n=k8s.io images import '$TARBALL' && rm -f '$TARBALL'"
done

rm -f "$TARBALL"
echo "==> Done. Loaded $IMAGE on: $NODES"
echo "    Remember: kubectl rollout restart deployment/whoami-ng"
echo "    if a pod using this tag is already running."
