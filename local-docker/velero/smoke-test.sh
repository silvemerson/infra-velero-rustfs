#!/usr/bin/env bash
set -euo pipefail

BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; DIM=$'\e[2m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
PAUSE=${PAUSE:-1}

step()  { printf '\n%s%s▶ %s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
ok()    { printf '%s  ✔ %s%s\n' "$GREEN" "$1" "$RESET"; }
info()  { printf '%s  %s%s\n' "$DIM" "$1" "$RESET"; }
pause() { [ "$PAUSE" = "1" ] && { printf '%s  ↵ Enter para continuar...%s' "$DIM" "$RESET"; read -r; } || true; }
cmd()   { printf '%s  $ %s%s\n' "$YELLOW" "$1" "$RESET"; }
run()   { cmd "$*"; "$@"; }

step "1/5 · Criando a aplicação em produção (sparta-prd)"
run kubectl --context kind-sparta-prd create namespace demo-app
run kubectl --context kind-sparta-prd -n demo-app create deployment nginx-demo --image=nginx:alpine
run kubectl --context kind-sparta-prd -n demo-app create configmap demo-config \
  --from-literal=mensagem="backup gerado antes do desastre"
run kubectl --context kind-sparta-prd -n demo-app rollout status deployment/nginx-demo --timeout=60s
ok "demo-app rodando em produção"
pause

step "2/5 · Fazendo backup com o Velero"
run velero --kubecontext kind-sparta-prd backup create demo-backup \
  --include-namespaces demo-app --wait
ok "backup demo-backup completo, salvo no RustFS"
pause

step "3/5 · Esperando o backup aparecer no cluster de DR"
until velero --kubecontext kind-sparta-dr backup get 2>/dev/null | grep -q demo-backup; do
  info "ainda sincronizando via BSL from-prd..."
  sleep 5
done
run velero --kubecontext kind-sparta-dr backup get
ok "backup visível em sparta-dr"
pause

step "4/5 · Restaurando no cluster de DR (sparta-dr)"
run velero --kubecontext kind-sparta-dr restore create demo-restore \
  --from-backup demo-backup --wait
ok "restore completo"
pause

step "5/5 · Conferindo o resultado em sparta-dr"
run kubectl --context kind-sparta-dr -n demo-app get all,configmap
cmd "kubectl --context kind-sparta-dr -n demo-app get configmap demo-config -o jsonpath='{.data.mensagem}'"
MSG=$(kubectl --context kind-sparta-dr -n demo-app get configmap demo-config -o jsonpath='{.data.mensagem}')
printf '  %s\n' "$MSG"
ok "ConfigMap restaurado com a mensagem original"
