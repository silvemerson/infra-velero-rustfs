#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_IMAGE="velero/velero-plugin-for-aws:v1.11.0"
RUSTFS_URL="http://rustfs-lb:9000"
# URL usada pelo CLI do velero, rodando no host, para baixar logs e detalhes
# (velero backup describe --details, velero backup logs, restore describe).
# O host não resolve "rustfs-lb", só os pods; daí o endereço publicado.
RUSTFS_PUBLIC_URL="http://localhost:9000"

install_velero() {
  local context="$1"
  local bucket="$2"

  echo ">>> Instalando Velero no contexto ${context} (bucket: ${bucket})"
  velero install \
    --kubecontext "${context}" \
    --provider aws \
    --plugins "${PLUGIN_IMAGE}" \
    --bucket "${bucket}" \
    --secret-file "${SCRIPT_DIR}/credentials-velero" \
    --use-volume-snapshots=false \
    --backup-location-config "s3Url=${RUSTFS_URL},publicUrl=${RUSTFS_PUBLIC_URL},region=minio,s3ForcePathStyle=true" \
    --use-node-agent \
    --wait
}

install_velero kind-sparta-prd sparta-prd-backups
install_velero kind-sparta-dr sparta-dr-backups

echo ">>> Aplicando BackupStorageLocation somente-leitura no sparta-dr (visão do bucket do sparta-prd)"
kubectl --context kind-sparta-dr apply -f "${SCRIPT_DIR}/bsl-from-prd.yaml"

echo
echo "Aguardando BackupStorageLocations ficarem 'Available'..."
until kubectl --context kind-sparta-prd -n velero get backupstoragelocation default \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Available; do sleep 3; done
until kubectl --context kind-sparta-dr -n velero get backupstoragelocation default \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Available; do sleep 3; done
until kubectl --context kind-sparta-dr -n velero get backupstoragelocation from-prd \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Available; do sleep 3; done

echo
echo "Velero instalado nos dois clusters. Status:"
echo "--- sparta-prd ---"
kubectl --context kind-sparta-prd -n velero get backupstoragelocation
echo "--- sparta-dr ---"
kubectl --context kind-sparta-dr -n velero get backupstoragelocation
