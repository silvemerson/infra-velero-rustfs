#!/usr/bin/env bash
set -euo pipefail

BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; RESET=$'\e[0m'
step() { printf '\n%s%s▶ %s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
ok()   { printf '%s  ✔ %s%s\n' "$GREEN" "$1" "$RESET"; }

step "Limpando sparta-dr"
velero --kubecontext kind-sparta-dr restore delete demo-restore --confirm 2>/dev/null || true
kubectl --context kind-sparta-dr delete namespace demo-app --ignore-not-found

step "Limpando sparta-prd"
kubectl --context kind-sparta-prd delete namespace demo-app --ignore-not-found
velero --kubecontext kind-sparta-prd backup delete demo-backup --confirm 2>/dev/null || true

ok "ambiente pronto para rodar o smoke-test.sh de novo"
