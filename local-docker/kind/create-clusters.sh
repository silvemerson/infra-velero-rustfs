#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUSTFS_NETWORK="rustfs-ha-net"

kind create cluster --config "${SCRIPT_DIR}/cluster-prd.yaml"
kind create cluster --config "${SCRIPT_DIR}/cluster-dr.yaml"

echo "Connecting kind nodes to ${RUSTFS_NETWORK} so pods can reach the RustFS cluster..."
for node in $(kind get nodes --name sparta-prd) $(kind get nodes --name sparta-dr); do
  docker network connect "${RUSTFS_NETWORK}" "${node}" 2>/dev/null || true
done

echo
echo "Clusters ready. Contexts available:"
kubectl config get-contexts | grep -E "sparta-prd|sparta-dr" || true
echo
echo "Use: kubectl --context kind-sparta-prd ..."
echo "     kubectl --context kind-sparta-dr ..."
