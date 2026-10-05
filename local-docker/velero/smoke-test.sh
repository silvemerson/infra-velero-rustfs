#!/usr/bin/env bash
set -euo pipefail

echo ">>> Criando app de exemplo no cluster de produção (sparta-prd)"
kubectl --context kind-sparta-prd create namespace demo-app
kubectl --context kind-sparta-prd -n demo-app create deployment nginx-demo --image=nginx:alpine
kubectl --context kind-sparta-prd -n demo-app create configmap demo-config \
  --from-literal=mensagem="backup gerado antes do desastre"

echo ">>> Aguardando pod ficar pronto"
kubectl --context kind-sparta-prd -n demo-app rollout status deployment/nginx-demo --timeout=60s

echo ">>> Criando backup no cluster de produção (sparta-prd)"
velero --kubecontext kind-sparta-prd backup create demo-backup \
  --include-namespaces demo-app --wait

echo ">>> Aguardando o backup sincronizar no cluster de DR (sparta-dr)"
until velero --kubecontext kind-sparta-dr backup get 2>/dev/null | grep -q demo-backup; do
  sleep 5
done

echo ">>> Restaurando no cluster de DR (sparta-dr)"
velero --kubecontext kind-sparta-dr restore create demo-restore \
  --from-backup demo-backup --wait

echo ">>> Recursos restaurados no cluster de DR (sparta-dr):"
kubectl --context kind-sparta-dr -n demo-app get all,configmap

echo ">>> Conteúdo do configmap restaurado:"
kubectl --context kind-sparta-dr -n demo-app get configmap demo-config \
  -o jsonpath='{.data.mensagem}'
echo
