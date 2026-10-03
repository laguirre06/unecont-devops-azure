# Roteiro da entrevista — 40 minutos

## Preparação

- Docker Desktop iniciado.
- Compose e observabilidade rodando.
- Cluster kind-unecont com duas réplicas prontas.
- HPA com CPU numérica.
- Port-forward na porta 8080 em terminal dedicado.
- Grafana aberto com dashboard e tráfego recente.
- Repositório, PR e execução verde do Actions abertos.
- Não executar o Job de carga durante a demo de rollback.
- Deixar imagens já disponíveis para evitar tempo gasto com downloads.

## 0–5 min: visão geral

Aplicação original Express/Prisma com PostgreSQL.
Ambiente local, sem necessidade de recursos pagos em Azure.

Explicar:
- Separação entre build, runtime e migrations.
- Saúde da aplicação e recursos no Kubernetes.
- CI publica; script faz deploy no cluster local.
- Observabilidade coleta a API do Compose.
- Tudo está versionado, exceto credenciais e dados locais.

## 5–12 min: Docker

Mostrar Dockerfile e Compose.

```bash
docker compose ps -a
docker compose exec -T api id
curl --fail http://localhost:3000/api/tags
```

Decisões:
- npm ci e lockfile.
- Usuário não-root.
- Banco saudável antes de migrations.
- Migrations concluídas antes da API.
- Portas publicadas somente em localhost.

## 12–20 min: Kubernetes e HPA

```bash
kubectl --context kind-unecont -n unecont get pods,svc,pvc,job
kubectl --context kind-unecont -n unecont top pods
kubectl --context kind-unecont -n unecont get hpa
```

Mostrar probes, requests/limits e rolling update no manifest.
Explicar readiness dependente do banco e liveness independente.

Iniciar a carga no começo desta seção:

```bash
kubectl --context kind-unecont -n unecont \
  delete job api-load --ignore-not-found

kubectl --context kind-unecont apply -f k8s/demo/load.yaml
kubectl --context kind-unecont -n unecont get hpa api --watch
```

Mostrar 2 → 4; deixar a redução ocorrer enquanto apresenta o pipeline.
Se a demo ficar lenta, usar os eventos já obtidos como evidência adicional.

## 20–27 min: CI/CD

Mostrar PR com check verde e execução da main com publicação.

Explicar:
- PR valida e não publica.
- main valida e publica imagens por commit.
- GITHUB_TOKEN com permissão mínima por job.
- Imagem de migrations separada.
- Sem expor o computador ao runner.
- Manifest fixado em digest.

```bash
kubectl --context kind-unecont -n unecont get deployment api \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## 27–33 min: observabilidade

Abrir http://localhost:3001/d/unecont-api.

Mostrar:
- UP representa scrape bem-sucedido.
- Contador HTTP e taxa.
- RSS do processo.
- p95 estimado pelo histograma.
- Logs JSON com request ID, status e duração.

Explicar:
- Alloy coleta; Loki armazena/consulta logs.
- Prometheus coleta métricas.
- Grafana apresenta os dois.
- Templates de rota evitam cardinalidade com IDs.
- Não registrar tokens, bodies ou query strings.

## 33–37 min: automação

Garantir fim da carga e retorno a duas réplicas.

Aplicar referência válida:
```bash
bash scripts/deploy.sh \
  ghcr.io/laguirre06/unecont-devops-azure:sha-dcf6958ed95bb28adc34c64ef5de4cefccf66eb9 90
```

Se já estiver nessa referência, usar o digest validado para provocar troca de referência.

Aplicar tag inexistente:
```bash
bash scripts/deploy.sh \
  ghcr.io/laguirre06/unecont-devops-azure:demo-tag-inexistente-20261003 60
echo "ExitCode=$?"
```

Mostrar:
- Pods anteriores disponíveis.
- ErrImagePull e timeout.
- Diagnóstico e rollback.
- Código 1 mesmo com recuperação.
- Limitação: não reverte banco.

## 37–40 min: produção e perguntas

Priorizar:
- HA entre nós e zonas.
- Banco gerenciado e restauração de backups.
- Gestão externa de segredos e identidade.
- TLS, RBAC e políticas de rede.
- SLOs, alertas e retenção.
- Promoção de imagens por digest.
- Migrations retrocompatíveis.
- Remover exceções locais de cgroup/TLS/socket.

Apresentar pendências com transparência:
- Lint original e um teste TODO.
- Um nó local e um banco sem HA.
- CI não provisiona Kubernetes.
- Dashboard monitora Compose.
- Pinning completo de dependências/imagens como evolução.
