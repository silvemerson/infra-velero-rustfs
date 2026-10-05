#!/usr/bin/env bash
set -euo pipefail

kubectl --context kind-sparta-prd delete namespace demo-app --ignore-not-found
kubectl --context kind-sparta-dr delete namespace demo-app --ignore-not-found
velero --kubecontext kind-sparta-prd backup delete demo-backup --confirm || true
