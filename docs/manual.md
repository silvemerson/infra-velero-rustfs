# Manual: configurando e fazendo backup na mão

Este manual refaz, comando a comando, o que os scripts do lab fazem. Use-o
se você quer entender cada etapa em vez de só rodar `install-velero.sh` e
`smoke-test.sh`.

Você precisa de Docker, `kind`, `kubectl`, o CLI `velero` e o `aws` CLI. O lab
foi testado com Velero v1.15.2, plugin AWS v1.11.0 e kind v0.30.0.

O lab está em <https://github.com/silvemerson/infra-velero-rustfs>. Clone o
repositório e entre na pasta `local-docker/`; todos os caminhos deste manual
são relativos a ela.

```bash
git clone https://github.com/silvemerson/infra-velero-rustfs.git
cd infra-velero-rustfs/local-docker
```

## O cenário

A empresa fictícia Sparta tem dois clusters Kubernetes:

- `sparta-prd`: produção, onde a aplicação roda e os backups são gerados.
- `sparta-dr`: disaster recovery, onde os backups são restaurados.

Os dois gravam em um RustFS distribuído (4 nós), que fala o protocolo S3. Na
frente dos 4 nós há um HAProxy (`rustfs-lb`), que é o único endereço que os
clientes usam.

## 1. Subir o RustFS

```bash
cd rustfs
docker compose up -d
docker compose ps
```

Devem aparecer 5 containers `Up`: `rustfs-lb` e `rustfs-node0` a
`rustfs-node3`.

| O quê | Endereço |
| --- | --- |
| API S3 | `http://localhost:9000` |
| Console web | `http://localhost:9090/rustfs/console/` |
| Painel do HAProxy | `http://localhost:8404` |

Usuário e senha: `rustfsadmin` / `rustfsadmin`.

## 2. Criar os buckets

O Velero não cria bucket: ele espera que o bucket já exista. Crie um por
cluster.

```bash
export AWS_ACCESS_KEY_ID=rustfsadmin
export AWS_SECRET_ACCESS_KEY=rustfsadmin

aws --endpoint-url http://localhost:9000 s3 mb s3://sparta-prd-backups
aws --endpoint-url http://localhost:9000 s3 mb s3://sparta-dr-backups
aws --endpoint-url http://localhost:9000 s3 ls
```

O `--endpoint-url` é o que faz o `aws` CLI falar com o RustFS em vez da AWS.
Se preferir, crie os buckets pelo console web.

## 3. Criar os dois clusters

```bash
kind create cluster --config kind/cluster-prd.yaml
kind create cluster --config kind/cluster-dr.yaml
```

Cada arquivo define o nome do cluster, um control-plane, um worker e faixas
de rede de pods e serviços que não se sobrepõem entre os dois.

Os nós do kind são containers Docker em uma rede própria, e por isso não
enxergam o RustFS. Conecte cada nó à rede do RustFS:

```bash
for node in $(kind get nodes --name sparta-prd) $(kind get nodes --name sparta-dr); do
  docker network connect rustfs-ha-net "$node"
done
```

Confira os contextos criados:

```bash
kubectl config get-contexts
kubectl --context kind-sparta-prd get nodes
kubectl --context kind-sparta-dr get nodes
```

## 4. Instalar o Velero em produção

O Velero precisa das credenciais do S3 em um arquivo no formato da AWS. O
repositório já traz esse arquivo em `velero/credentials-velero`:

```ini
[default]
aws_access_key_id=rustfsadmin
aws_secret_access_key=rustfsadmin
```

Instale:

```bash
velero install \
  --kubecontext kind-sparta-prd \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket sparta-prd-backups \
  --secret-file velero/credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config "s3Url=http://rustfs-lb:9000,publicUrl=http://localhost:9000,region=minio,s3ForcePathStyle=true" \
  --use-node-agent \
  --wait
```

O que cada opção faz:

| Opção | Para que serve |
| --- | --- |
| `--provider aws` e `--plugins` | O RustFS é compatível com S3, então o plugin da AWS serve. |
| `--bucket` | Bucket onde este cluster grava os backups. |
| `--secret-file` | Vira o Secret `cloud-credentials` no namespace `velero`. |
| `--use-volume-snapshots=false` | Não há snapshot de disco de nuvem neste lab. |
| `s3Url` | Endereço do RustFS visto pelos pods do Velero. |
| `publicUrl` | Endereço do RustFS visto pelo seu terminal. Sem ele, `velero backup logs` e `describe --details` falham com `no such host`. |
| `region=minio` | O plugin exige uma região; o RustFS aceita qualquer valor. |
| `s3ForcePathStyle=true` | Usa `host/bucket` em vez de `bucket.host`, que não resolveria aqui. |
| `--use-node-agent` | Instala o agente que faz backup de volumes por arquivo. Não é usado neste manual. |

Confira que o Velero alcança o bucket:

```bash
kubectl --context kind-sparta-prd -n velero get pods
kubectl --context kind-sparta-prd -n velero get backupstoragelocation
```

A `BackupStorageLocation` chamada `default` deve estar `Available`. Se ficar
`Unavailable`, o bucket não existe ou os nós não estão na rede do RustFS.

## 5. Instalar o Velero no DR

O mesmo comando, trocando o contexto e o bucket:

```bash
velero install \
  --kubecontext kind-sparta-dr \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket sparta-dr-backups \
  --secret-file velero/credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config "s3Url=http://rustfs-lb:9000,publicUrl=http://localhost:9000,region=minio,s3ForcePathStyle=true" \
  --use-node-agent \
  --wait
```

## 6. Fazer o DR enxergar os backups de produção

Até aqui cada cluster só vê o próprio bucket. Para restaurar no DR um backup
feito em produção, o DR precisa de uma segunda `BackupStorageLocation`,
apontando para o bucket de produção em modo somente leitura:

```bash
kubectl --context kind-sparta-dr apply -f velero/bsl-from-prd.yaml
kubectl --context kind-sparta-dr -n velero get backupstoragelocation
```

Devem aparecer `default` e `from-prd`, as duas `Available`.

O `accessMode: ReadOnly` do arquivo garante que o DR nunca apaga nem altera
um backup de produção.

## 7. Subir uma aplicação em produção

```bash
kubectl --context kind-sparta-prd create namespace demo-app
kubectl --context kind-sparta-prd -n demo-app create deployment nginx-demo --image=nginx:alpine
kubectl --context kind-sparta-prd -n demo-app create configmap demo-config \
  --from-literal=mensagem="backup gerado antes do desastre"

kubectl --context kind-sparta-prd -n demo-app rollout status deployment/nginx-demo
kubectl --context kind-sparta-prd -n demo-app get all,configmap
```

## 8. Fazer o backup

```bash
velero --kubecontext kind-sparta-prd backup create demo-backup \
  --include-namespaces demo-app --wait
```

Veja o resultado:

```bash
velero --kubecontext kind-sparta-prd backup get
velero --kubecontext kind-sparta-prd backup describe demo-backup --details
velero --kubecontext kind-sparta-prd backup logs demo-backup
```

O `describe --details` lista cada recurso que entrou no backup.

Veja os arquivos no RustFS:

```bash
aws --endpoint-url http://localhost:9000 s3 ls s3://sparta-prd-backups/backups/demo-backup/
```

Ou abra o console web e navegue até o bucket `sparta-prd-backups`.

## 9. Restaurar no DR

O Velero do DR sincroniza a lista de backups do bucket a cada minuto. Espere
o `demo-backup` aparecer:

```bash
velero --kubecontext kind-sparta-dr backup get
```

Ele aparece com `STORAGE LOCATION` igual a `from-prd`. Restaure:

```bash
velero --kubecontext kind-sparta-dr restore create demo-restore \
  --from-backup demo-backup --wait
```

Confira:

```bash
velero --kubecontext kind-sparta-dr restore describe demo-restore
kubectl --context kind-sparta-dr -n demo-app get all,configmap
kubectl --context kind-sparta-dr -n demo-app get configmap demo-config \
  -o jsonpath='{.data.mensagem}'
```

A mensagem `backup gerado antes do desastre` prova que o ConfigMap veio do
backup.

O restore termina `Completed` com 1 warning sobre o ConfigMap
`kube-root-ca.crt`. Isso é esperado: cada cluster tem a própria autoridade
certificadora, então o Velero mantém o ConfigMap do DR e avisa que ele difere
do que estava no backup.

## 10. Agendar backups

Um backup manual serve para a demo; em produção o normal é agendar. Este
exemplo roda todo dia às 3h e guarda cada backup por 7 dias:

```bash
velero --kubecontext kind-sparta-prd schedule create demo-diario \
  --schedule "0 3 * * *" \
  --include-namespaces demo-app \
  --ttl 168h

velero --kubecontext kind-sparta-prd schedule get
```

Para não esperar até as 3h, dispare um backup a partir do agendamento:

```bash
velero --kubecontext kind-sparta-prd backup create --from-schedule demo-diario --wait
```

## 11. Testar a queda de um nó do RustFS

Abra `http://localhost:8404` e derrube um nó:

```bash
cd rustfs
docker compose stop node0
```

O painel do HAProxy marca o `node0` como `DOWN` em poucos segundos. Faça um
backup com o nó fora:

```bash
velero --kubecontext kind-sparta-prd backup create demo-backup-ha \
  --include-namespaces demo-app --wait
```

O backup termina `Completed`. Suba o nó de volta:

```bash
docker compose start node0
```

Com 4 nós, o RustFS tolera a queda de um. Com dois nós fora ele responde
`503` para leitura e escrita, mas os dados continuam lá e voltam a ficar
acessíveis quando os nós sobem.

## 12. Limpar

Apagar só o que este manual criou, mantendo o ambiente:

```bash
velero --kubecontext kind-sparta-prd schedule delete demo-diario --confirm
velero --kubecontext kind-sparta-prd backup delete --all --confirm
kubectl --context kind-sparta-prd delete namespace demo-app
kubectl --context kind-sparta-dr delete namespace demo-app
```

Apagar tudo:

```bash
kind delete cluster --name sparta-prd
kind delete cluster --name sparta-dr
cd rustfs && docker compose down -v
```

O `-v` remove os volumes, ou seja, todos os buckets e backups.

## Problemas comuns

| Sintoma | Causa provável |
| --- | --- |
| `BackupStorageLocation` fica `Unavailable` | O bucket não foi criado, ou os nós do kind não foram conectados à rede `rustfs-ha-net`. |
| `velero backup logs` ou `describe --details` falha com `no such host` | Falta o `publicUrl` na `BackupStorageLocation`. |
| O backup não aparece no `sparta-dr` | A sincronização leva até um minuto. Confira também se a `from-prd` está `Available`. |
| Abrir `http://localhost:9000` no navegador devolve `403` | Esse é o endereço da API S3. O console fica em `http://localhost:9090/rustfs/console/`. |
| Backup falha com dois nós do RustFS parados | O cluster perdeu o quórum. Suba pelo menos três dos quatro nós. |
