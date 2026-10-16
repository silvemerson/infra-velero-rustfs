# Lab: Velero + RustFS

Ambiente de laboratório para a palestra **"Velero + RustFS: backup open source
para clusters Kubernetes"** (DevOps Days Juiz de Fora 2026).

Este é o repositório do lab:
<https://github.com/silvemerson/infra-velero-rustfs>. Ele contém a
infraestrutura usada para gerar os prints da apresentação e pode ser
reproduzido em qualquer máquina com Docker. O conteúdo dos slides fica em
outro repositório (`devops-days-jf-2026-velero-rustfs`); aqui fica só o lab.

Para começar:

```bash
git clone https://github.com/silvemerson/infra-velero-rustfs.git
cd infra-velero-rustfs
```

## Visão geral do cenário

- **RustFS** rodando em modo distribuído (4 nós, erasure coding) via Docker
  Compose, simulando um object storage S3 em alta disponibilidade, com um
  **HAProxy** na frente como ponto único de entrada.
- **2 clusters Kubernetes** via `kind`:
  - `sparta-prd` — onde a aplicação "de produção" roda e os backups são
    gerados.
  - `sparta-dr` — onde os backups são restaurados, simulando um cenário
    de disaster recovery (recuperação em outro cluster).
- **Velero** instalado nos dois clusters, usando o RustFS como
  `BackupStorageLocation` (via plugin AWS S3, já que o RustFS é
  S3-compatível).

```
┌─────────────────────┐        backup          ┌───────────────────────────┐
│   sparta-prd        │ ───────────────────▶   │   RustFS (HA, 4 nós)      │
│   (kind cluster)    │                        │   object storage S3       │
└─────────────────────┘                        └───────────────────────────┘
                                                          │
                                                          │ restore
                                                          ▼
                                                ┌─────────────────────┐
                                                │   sparta-dr         │
                                                │   (kind cluster)    │
                                                └─────────────────────┘
```

## Pré-requisitos

- Docker
- [`kind`](https://kind.sigs.k8s.io/)
- `kubectl`
- [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli)
- `aws` CLI (só para inspecionar buckets manualmente, opcional)

## Estrutura

```
local-docker/
├── rustfs/
│   ├── docker-compose.yml       # cluster RustFS HA (4 nós) + balanceador
│   └── haproxy.cfg              # config do HAProxy na frente dos 4 nós
├── kind/
│   ├── cluster-prd.yaml         # config do cluster sparta-prd
│   ├── cluster-dr.yaml          # config do cluster sparta-dr
│   ├── create-clusters.sh       # cria os 2 clusters e conecta à rede do RustFS
│   └── delete-clusters.sh       # destrói os 2 clusters
└── velero/
    ├── credentials-velero       # credenciais S3 usadas pelo Velero
    ├── bsl-from-prd.yaml        # BackupStorageLocation extra no sparta-dr,
    │                            # apontando (read-only) pro bucket do sparta-prd
    ├── install-velero.sh        # instala o Velero nos dois clusters
    ├── uninstall-velero.sh      # remove o Velero dos dois clusters
    ├── smoke-test.sh            # fluxo completo de demo: deploy → backup → restore
    └── cleanup-demo.sh          # limpa os recursos criados pelo smoke-test
```

## Passo a passo

Os passos abaixo usam os scripts do lab. Para fazer tudo na mão, comando a
comando e com a explicação de cada opção, veja o
[manual](docs/manual.md).

### 1. Subir o RustFS (HA)

```bash
cd local-docker/rustfs
docker compose up -d
docker compose ps -a   # os 4 nós devem ficar "Up"
```

Endpoints (credenciais padrão: `rustfsadmin` / `rustfsadmin`):

| O quê                          | URL                                      |
| ------------------------------ | ---------------------------------------- |
| API S3 (via balanceador)       | `http://localhost:9000`                  |
| Console web (via balanceador)  | `http://localhost:9090/rustfs/console/`  |
| Estatísticas do HAProxy        | `http://localhost:8404`                  |
| API S3 direto em cada nó       | `http://localhost:9010` … `9013`         |

Na frente dos 4 nós há um **HAProxy** (`rustfs-lb`), fazendo o papel do load
balancer/VIP de um ambiente real. Ele checa o `/health` de cada nó a cada 2s
e tira do balanceamento quem cair — por isso qualquer nó pode ser derrubado,
inclusive o `node0`, sem quebrar os clientes. De dentro dos clusters kind, o
endpoint S3 usado pelo Velero é `http://rustfs-lb:9000`.

Abrir `http://localhost:9000` no navegador devolve `403` — é a API S3, não o
console. As portas `9010`–`9013` existem só para depuração (falar com um nó
específico, sem passar pelo balanceador).

**Notas sobre o compose** (documentadas também como comentários no arquivo):

- `user: "0:0"` — os volumes nomeados do Docker nascem `root:root`, e o
  usuário padrão da imagem (`rustfs`, uid 10001) não tem permissão de
  escrita neles. Rodar como root contorna isso — aceitável só neste lab.
- `RUSTFS_UNSAFE_BYPASS_DISK_CHECK=true` — em produção, o RustFS exige que
  cada "disco" do erasure coding esteja em um dispositivo físico distinto.
  Como todos os volumes aqui compartilham o mesmo storage do Docker num
  único host, essa checagem é desabilitada. **Não usar fora de lab/CI.**
- `RUSTFS_RPC_SECRET` — necessário para autenticação entre os nós quando se
  usam credenciais default em modo distribuído.

Criação de buckets (feito manualmente na primeira vez; o `install-velero.sh`
não cria buckets, então rode isso antes):

```bash
export AWS_ACCESS_KEY_ID=rustfsadmin
export AWS_SECRET_ACCESS_KEY=rustfsadmin
aws --endpoint-url http://localhost:9000 s3 mb s3://sparta-prd-backups
aws --endpoint-url http://localhost:9000 s3 mb s3://sparta-dr-backups
```

### 2. Subir os dois clusters kind

```bash
cd local-docker/kind
./create-clusters.sh
```

O script cria `sparta-prd` e `sparta-dr` e conecta os containers de
cada nó à rede Docker do RustFS (`rustfs-ha-net`), para que os pods
consigam resolver `rustfs-lb` e alcançar o object storage.

Contextos kubectl gerados: `kind-sparta-prd` e `kind-sparta-dr`.

Para destruir depois:

```bash
./delete-clusters.sh
```

### 3. Instalar o Velero nos dois clusters

```bash
cd local-docker/velero
./install-velero.sh
```

Isso:

- Instala o Velero no `sparta-prd`, com `BackupStorageLocation` padrão
  apontando para o bucket `sparta-prd-backups`.
- Instala o Velero no `sparta-dr`, com `BackupStorageLocation` padrão
  apontando para `sparta-dr-backups`.
- Aplica no `sparta-dr` uma **segunda** `BackupStorageLocation`
  (`from-prd`, somente leitura) apontando para o bucket
  `sparta-prd-backups` — é isso que permite ao cluster de destino
  enxergar e restaurar backups feitos no cluster de origem, simulando o
  cenário real de disaster recovery cross-cluster.

As `BackupStorageLocation` usam dois endereços para o mesmo RustFS:

- `s3Url=http://rustfs-lb:9000` — usado pelos pods do Velero, dentro dos
  clusters.
- `publicUrl=http://localhost:9000` — usado pelo CLI `velero` rodando no host
  para baixar logs e detalhes (`velero backup describe --details`,
  `velero backup logs`, `velero restore describe`). O host não resolve
  `rustfs-lb`; sem o `publicUrl` esses comandos falham com `no such host`.

Para desinstalar:

```bash
./uninstall-velero.sh
```

### 4. Rodar o fluxo de demo (backup → restore cross-cluster)

```bash
cd local-docker/velero
./smoke-test.sh
```

O script roda em 5 etapas, cada uma mostrando o comando real antes de
executá-lo e parando no final, esperando Enter, para dar tempo de explicar o
que aconteceu (pensado pra apresentar ao vivo, não só pra validar o lab):

1. Cria um namespace `demo-app` no `sparta-prd` com um Deployment
   (`nginx-demo`) e um ConfigMap, e espera o pod ficar pronto.
2. Faz um backup desse namespace com o Velero (`--wait`).
3. Espera o backup sincronizar no `sparta-dr` (via `from-prd`) e mostra a
   tabela do `velero backup get` assim que ele aparece.
4. Restaura o backup no `sparta-dr` (`--wait`).
5. Mostra os recursos restaurados e o conteúdo do ConfigMap — prova de que
   os dados vieram do backup, não foram recriados do zero.

Para rodar sem pausas (por exemplo, só para validar o ambiente antes do
evento, sem apresentar):

```bash
PAUSE=0 ./smoke-test.sh
```

Esse é o roteiro de comandos recomendado para tirar os prints principais da
palestra (estado do `velero backup describe`, `velero restore describe`,
recursos no cluster de destino, console do RustFS mostrando o objeto do
backup).

Para limpar os recursos de demo sem derrubar o ambiente (apaga namespace,
backup **e** o restore nos dois clusters, para o script poder ser rodado de
novo do zero):

```bash
./cleanup-demo.sh
```

## Demonstrando HA do RustFS (failover)

Para mostrar que o backup sobrevive à queda de um nó do RustFS:

```bash
cd local-docker/rustfs
docker compose stop node0      # derruba um dos 4 nós (qualquer um serve)
# ... faça um backup/restore ou liste o bucket normalmente, mostrando que
#     continua funcionando ...
docker compose start node0     # sobe o nó de volta
```

Deixe `http://localhost:8404` aberto durante a demo: a página do HAProxy
mostra o nó ficando vermelho (`DOWN`) e voltando a verde (`UP`).

O que esperar, com 4 nós de 4 discos cada (16 discos):

| Nós fora | Leitura | Escrita | Dados |
| -------- | ------- | ------- | ----- |
| 1        | ok      | ok      | intactos |
| 2        | `503`   | `503`   | intactos — voltam a ficar acessíveis quando os nós sobem |

Ou seja: o cluster tolera a queda de **um** nó sem interrupção. Com dois nós
fora ele perde o quórum e fica indisponível, mas não perde dados.

**Limite do lab:** os 16 "discos" são volumes Docker no mesmo disco físico
do host. Isso demonstra a lógica de erasure coding, quórum e failover, mas
não protege contra a falha do host ou do disco — para isso, cada nó precisa
estar em uma máquina (ou VM) com discos próprios.

## Roteiro de prints

Sequência sugerida, na ordem em que a história é contada na palestra. Rode o
`smoke-test.sh` antes, para o backup e o restore já existirem.

| # | O que mostra | Comando / URL |
| - | ------------ | ------------- |
| 1 | Os 4 nós do RustFS e o balanceador no ar | `docker compose ps` (em `local-docker/rustfs`) |
| 2 | Balanceador com os 4 nós `UP` | `http://localhost:8404` |
| 3 | Os dois clusters | `kind get clusters` e `kubectl config get-contexts` |
| 4 | Nós de cada cluster | `kubectl --context kind-sparta-prd get nodes` (idem `kind-sparta-dr`) |
| 5 | Velero ligado ao RustFS em produção | `kubectl --context kind-sparta-prd -n velero get backupstoragelocation` |
| 6 | DR enxergando o bucket de produção (`from-prd`) | `kubectl --context kind-sparta-dr -n velero get backupstoragelocation` |
| 7 | Aplicação rodando em produção | `kubectl --context kind-sparta-prd -n demo-app get all,configmap` |
| 8 | Backup concluído | `velero --kubecontext kind-sparta-prd backup describe demo-backup --details` |
| 9 | Objetos do backup no RustFS | console em `http://localhost:9090/rustfs/console/`, bucket `sparta-prd-backups` |
| 10 | Backup visível no cluster de DR | `velero --kubecontext kind-sparta-dr backup get` |
| 11 | Restore concluído | `velero --kubecontext kind-sparta-dr restore describe demo-restore` |
| 12 | Aplicação restaurada no DR | `kubectl --context kind-sparta-dr -n demo-app get all,configmap` |
| 13 | Nó do RustFS fora, balanceador marcando `DOWN` | `docker compose stop node0` e `http://localhost:8404` |
| 14 | Backup funcionando com um nó fora | `velero --kubecontext kind-sparta-prd backup create demo-backup-ha --include-namespaces demo-app --wait` |

Depois do print 14, suba o nó de volta (`docker compose start node0`) e, se
quiser deixar o ambiente limpo, apague o backup extra:

```bash
velero --kubecontext kind-sparta-prd backup delete demo-backup-ha --confirm
```

## Encerrando tudo

```bash
cd local-docker/kind && ./delete-clusters.sh
cd ../rustfs && docker compose down -v
```
