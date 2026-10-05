#!/usr/bin/env bash
set -euo pipefail

kubectl --context kind-sparta-prd delete namespace velero --ignore-not-found
kubectl --context kind-sparta-dr delete namespace velero --ignore-not-found
kubectl --context kind-sparta-prd delete crd -l component=velero --ignore-not-found
kubectl --context kind-sparta-dr delete crd -l component=velero --ignore-not-found
