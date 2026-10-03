# Unecont DevOps Azure

Entrega do teste DevOps usando a aplicação original:
https://github.com/gothinkster/node-express-realworld-example-app

Repositório da entrega:
https://github.com/laguirre06/unecont-devops-azure

Apesar do título Azure, todo o ambiente roda localmente.
O README original está em docs/UPSTREAM_README.md.

## Entregas

- Dockerfile multi-stage, npm ci e API executada como usuário não-root.
- Compose com API, PostgreSQL e migrations separadas.
- Kubernetes local com kind, duas réplicas, Service, ConfigMap e Secret.
- Startup, readiness e liveness probes, requests/limits e HPA.
- GitHub Actions: validação em PR e publicação no GHCR em push na main.
- Grafana, Loki, Alloy e Prometheus com configuração e dashboard em arquivos.
- Script Bash de deploy com diagnóstico e rollback automático.

## Pré-requisitos

Ambiente utilizado: Windows, VS Code, Git Bash e Docker Desktop com backend WSL2.

Ferramentas:
- Git e Docker Compose v2.
- kubectl 1.35.x.
- kind 0.33.0, instalado em .tools/kind.exe.
- GitHub CLI para operações de PR e acompanhamento do CI.

Node e PostgreSQL não precisam ser instalados no host.

O laboratório foi validado com 2 CPUs e aproximadamente 4 GB disponíveis ao Docker.
Acompanhe o consumo com docker stats. Esse valor não é dimensionamento de produção.

## Estrutura

| Caminho | Finalidade |
|---|---|
| Dockerfile | Build, imagem de migrations e runtime |
| docker-compose.yml | API e PostgreSQL |
| docker-compose.observability.yml | Stack de observabilidade |
| k8s/kind.yaml | Cluster local |
| k8s/app/ | Configuração, banco, migrations, API e HPA |
| k8s/metrics-server/ | Metrics Server e ajuste do laboratório |
| k8s/demo/load.yaml | Job finito para demonstrar autoscaling |
| observability/ | Configurações, datasources e dashboard |
| scripts/deploy.sh | Deploy com rollback |
| .github/workflows/ci.yml | CI e publicação no GHCR |
| docs/DEMO.md | Roteiro da apresentação |

## 1. Clone e configuração local

```bash
git -c core.autocrlf=false clone \
  https://github.com/laguirre06/unecont-devops-azure.git

cd unecont-devops-azure

git config --local core.autocrlf false
git config --local core.eol lf
```

Gere credenciais apenas se .env ainda não existir:

```bash
(
  set -euo pipefail
  umask 077

  if [ -e .env ]; then
    echo ".env existente; preserve ou revise antes de prosseguir."
    exit 1
  fi

  docker run --rm node:22-bookworm-slim \
    node -e 'const c=require("node:crypto"); for (const key of ["POSTGRES_PASSWORD","JWT_SECRET","GRAFANA_PASSWORD"]) console.log(key+"="+c.randomBytes(32).toString("hex"));' \
    > .env

  git check-ignore .env
)
```

.env é ignorado pelo Git e pelo contexto de build.
.env.example contém somente referências, sem credenciais reais.

## 2. Docker Compose

```bash
docker compose --parallel 1 --progress plain build
docker compose up -d --wait --wait-timeout 120
docker compose ps -a

curl --fail http://localhost:3000/health/ready
curl --fail http://localhost:3000/api/tags
docker compose exec -T api id
```

A ordem é banco saudável, migrations concluídas e API.
O serviço migrate deve terminar com código 0.

O PostgreSQL usa volume nomeado e não publica porta no host.
A API publica somente 127.0.0.1:3000.

## 3. Kubernetes local

Instale o kind específico do projeto, no Git Bash:

```bash
mkdir -p .tools

curl --fail --location --show-error \
  --output .tools/kind.exe \
  https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-windows-amd64

./.tools/kind.exe version

./.tools/kind.exe create cluster \
  --name unecont --config k8s/kind.yaml --wait 180s --retain

kubectl --context kind-unecont -n kube-system \
  rollout status deployment/coredns --timeout=120s

kubectl --context kind-unecont -n local-path-storage \
  rollout status deployment/local-path-provisioner --timeout=120s

kubectl --context kind-unecont apply -f k8s/app/config.yaml
```

Crie o Secret sem salvar seus valores no repositório:

```bash
(
  set -euo pipefail
  umask 077
  trap 'rm -f .tools/k8s.env' EXIT

  docker run --rm --env-file .env node:22-bookworm-slim \
    node -e 'const e=process.env; console.log("POSTGRES_PASSWORD="+e.POSTGRES_PASSWORD); console.log("JWT_SECRET="+e.JWT_SECRET); console.log("DATABASE_URL=postgresql://realworld:"+e.POSTGRES_PASSWORD+"@db:5432/realworld?schema=public");' \
    > .tools/k8s.env

  kubectl --context kind-unecont -n unecont \
    create secret generic api-secrets \
    --from-env-file=.tools/k8s.env --dry-run=client -o yaml |
    kubectl --context kind-unecont apply -f -
)
```

Suba banco, migrations e API nesta ordem:

```bash
kubectl --context kind-unecont apply -f k8s/app/database.yaml

kubectl --context kind-unecont -n unecont \
  rollout status deployment/postgres --timeout=180s

./.tools/kind.exe load docker-image unecont-migrate:local --name unecont

kubectl --context kind-unecont apply -f k8s/app/migrate.yaml

kubectl --context kind-unecont -n unecont \
  wait --for=condition=complete job/api-migrate --timeout=150s

kubectl --context kind-unecont -n unecont logs job/api-migrate

kubectl --context kind-unecont apply -f k8s/app/api.yaml

kubectl --context kind-unecont -n unecont \
  rollout status deployment/api --timeout=180s
```

A API usa digest público do GHCR; migrations usam a imagem construída localmente.
Os bancos do Compose e Kubernetes são independentes.

O Job de migrations concluído não executa novamente ao reaplicar o mesmo YAML.
Para uma nova execução intencional, exclua somente o Job api-migrate e recrie-o.
Atualizações do template de um Job existente exigem recriação ou outro nome.

Acesso em terminal separado:

```bash
kubectl --context kind-unecont -n unecont \
  port-forward service/api 8080:80 --address 127.0.0.1
```

```bash
curl --fail http://localhost:8080/health/ready
curl --fail http://localhost:8080/api/tags
```

O port-forward conecta a um pod e pode encerrar após sua substituição.
Ele não demonstra balanceamento entre réplicas.

## 4. HPA

```bash
kubectl --context kind-unecont apply -k k8s/metrics-server

kubectl --context kind-unecont -n kube-system \
  rollout status deployment/metrics-server --timeout=180s

kubectl --context kind-unecont \
  wait --for=condition=Available \
  apiservice/v1beta1.metrics.k8s.io --timeout=120s

kubectl --context kind-unecont apply -f k8s/app/hpa.yaml

kubectl --context kind-unecont -n unecont top pods
kubectl --context kind-unecont -n unecont get hpa
```

O HPA usa CPU, mínimo de 2, máximo de 4 e alvo de 60%.
Com request de 100m, o alvo representa aproximadamente 60m por pod.
Metrics Server atende ao HPA; Prometheus atende à observabilidade da aplicação.

Carga por três minutos:

```bash
./.tools/kind.exe load docker-image node:22-bookworm-slim --name unecont
kubectl --context kind-unecont apply -f k8s/demo/load.yaml
kubectl --context kind-unecont -n unecont get hpa api --watch
```

Em outro terminal:

```bash
kubectl --context kind-unecont -n unecont logs job/api-load
kubectl --context kind-unecont -n unecont top pods
```

A redução tem janela de estabilização de 120 segundos.
Para repetir, exclua o Job api-load concluído antes de reaplicar o manifest.
A carga usa / e não representa benchmark das rotas de negócio ou do banco.

## 5. Observabilidade

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.observability.yml \
  up -d prometheus loki alloy grafana
```

| Interface | Endereço |
|---|---|
| API Compose | http://localhost:3000 |
| API Kubernetes, com port-forward | http://localhost:8080 |
| Grafana | http://localhost:3001/d/unecont-api |
| Prometheus | http://localhost:9090 |
| Alloy | http://localhost:12345 |
| Loki readiness | http://localhost:3100/ready |

Grafana: usuário admin e senha GRAFANA_PASSWORD do .env.

Fluxos:
- API Compose stdout → Alloy → Loki → Grafana.
- API Compose /metrics → Prometheus → Grafana.

O dashboard monitora o Compose, não os pods do kind.
Mostra scrape disponível, contador HTTP, RSS, taxa, p95 estimado e logs JSON.
Probes e scrapes não entram no contador de tráfego HTTP.
up=1 confirma sucesso do scrape, não todos os fluxos de negócio.

Gere tráfego para visualizar as curvas:

```bash
for i in {1..60}; do
  curl --fail --silent --show-error http://localhost:3000/api/tags > /dev/null
  sleep 1
done
```

## 6. CI/CD

Em pull_request para main:
- Build dentro do Docker.
- Lint estrito de main.ts, observability.ts e setup.ts.
- Testes unitários.
- Sintaxe Bash, JSON do dashboard e configuração Compose.
- Smoke test da API e banco pelo Compose.

Em push na main:
- Repete validações.
- Publica API e imagem de migrations no GHCR com tag sha-COMMIT.
- Usa GITHUB_TOKEN; packages: write existe apenas no job de publicação.
- PR não publica imagens.

O runner não faz deploy no computador local.
O deploy no kind é executado pelo script.

Pacotes precisam estar públicos para pull sem credenciais.
O manifest da API está fixado em um digest validado; uma nova publicação não o atualiza automaticamente.

## 7. Script de deploy

```bash
bash scripts/deploy.sh \
  ghcr.io/laguirre06/unecont-devops-azure:sha-dcf6958ed95bb28adc34c64ef5de4cefccf66eb9 \
  90
```

Falha controlada:

```bash
bash scripts/deploy.sh \
  ghcr.io/laguirre06/unecont-devops-azure:demo-tag-inexistente-20261003 \
  60

echo "ExitCode=$?"
```

| Código | Significado |
|---|---|
| 0 | Deploy concluído ou imagem já aplicada e saudável |
| 1 | Deploy falhou; consulte logs para confirmar a recuperação |
| 2 | Argumentos ou precondições inválidos |
| 3 | Rollback falhou ou foi abortado |
| 130 / 143 | Interrupção; script tenta rollback |

O script exige baseline saudável e captura a revisão anterior.
Em falha, coleta diagnóstico e restaura o template anterior.
O teste validado retornou 1 após rollback bem-sucedido.

Execute um deploy por vez. O controle de concorrência é básico.
Rollback não reverte migrations nem dados.

## Evidências obtidas

- 26 testes passaram; 1 teste original permanece TODO.
- Compose e Kubernetes retornaram HTTP 200.
- Banco parado: liveness 200 e readiness 503; recuperação para 200.
- SIGTERM concluído com código 0.
- HPA escalou de 2 para 4 e retornou para 2.
- Gerador contabilizou 225427 requisições bem-sucedidas e zero falhas.
- CI passou em PR e main; imagens públicas foram executadas no kind.
- Dashboard apresentou métricas e logs reais.
- Tag inexistente gerou ErrImagePull, seguido de rollback para a revisão saudável.
- Dois pods anteriores permaneceram disponíveis durante o rollout inválido.

## Limitações e evolução para produção

- Um único nó kind e um único computador: sem alta disponibilidade contra falha do host.
- PostgreSQL local com uma réplica: sem HA e sem processo de backup configurado.
- PVC sobrevive à troca do pod, mas os dados são perdidos ao excluir o cluster.
- failCgroupV1: false é compatibilidade local; migrar o host para cgroup v2.
- Metrics Server usa kubelet-insecure-tls somente no laboratório.
- Alloy acessa o socket Docker como root; :ro não restringe os poderes da API Docker.
- Serviços de observabilidade são locais, sem TLS e sem autenticação em Loki/Prometheus.
- Credenciais locais no .env; em produção usar gestão externa, RBAC e proteção dos dados.
- Lint completo tem 33 erros originais; o CI cobre estritamente os arquivos de instrumentação/setup.
- Prometheus retém 2 dias/512 MiB; Loki ainda não tem política de expurgo configurada.
- Tags de versão de imagens e major tag do checkout ainda podem variar; evolução: pinning por digest/SHA.
- Smoke do CI cobre Compose; validação Kubernetes/HPA/rollback foi feita no laboratório.

Para produção: cluster gerenciado, distribuição entre nós/zonas, banco gerenciado,
backup com restauração testada, gestão externa de segredos, políticas de rede,
SLOs/alertas, retenção, promoção por digest e migrations compatíveis com rollback.

## Limpeza

Parar observabilidade:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml \
  stop prometheus loki alloy grafana
```

Remover containers do projeto preservando volumes:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml down
```

Excluir o cluster APAGA os dados do PostgreSQL no kind:

```bash
./.tools/kind.exe delete cluster --name unecont
```

Adicionar --volumes ao compose down APAGA os volumes do Compose.
Não use docker system prune como procedimento de limpeza deste projeto.
