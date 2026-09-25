# Custo de desempenho de JWT, mTLS e Istio na comunicação entre microsserviços

Laboratório do Trabalho de Conclusão de Curso do MBA em Engenharia de Software (USP/Esalq, 2026). Ele mede o custo de desempenho de três controles de segurança na chamada entre dois microsserviços:
- autenticação por JSON Web Token (JWT);
- TLS mútuo (mTLS);
- *service mesh* Istio/Envoy.

As métricas são vazão (*throughput*), latência, CPU e memória.

A aplicação simula a finalização de um pedido em um comércio eletrônico. O serviço **Checkout** recebe a compra e chama o serviço **Inventory**, que confirma a reserva do item.

## Configurações avaliadas

| Configuração | Plataforma | Proteção da chamada Checkout → Inventory | Pasta |
|---|---|---|---|
| C1 | Docker | Nenhuma (HTTP) | `scenario_1/` |
| C2 | Docker | JWT RS256 assinado pelo Checkout e validado pelo Inventory | `scenario_2/` |
| C3 | Docker | mTLS entre as aplicações | `scenario_3/` |
| C4 | Docker | mTLS e JWT RS256 entre as aplicações | `scenario_4/` |
| C5a | Kubernetes (Kind) | Nenhuma (HTTP) | `scenario_5/` |
| C5b | Kubernetes + Istio | mTLS estrito e validação do JWT no Envoy; assinatura no Checkout | `scenario_5/` |

**Condições comuns às seis configurações:**
- **Recursos:** as aplicações têm o mesmo limite nas duas plataformas, 1 CPU e 256 MiB por contêiner.
- **Chaves:** os tokens usam o mesmo par RSA de 3.072 bits.
- **Acesso:** o gerador de carga acessa o Checkout por uma porta publicada, no Docker, ou por uma NodePort, no Kubernetes.

## Requisitos

- Linux com Docker Engine e Docker Compose v2
- Python 3, OpenSSL e curl
- Para C5a e C5b: acesso à internet na primeira execução. O script `scenario_5/install_tools.sh` baixa Kind, kubectl e istioctl nas versões fixadas em `scenario_5/versions.env`.

## Como executar

```bash
bash setup.sh                      # ambiente virtual, dependências, certificados e chaves JWT
bash scenario_5/install_tools.sh   # Kind, kubectl e istioctl (uma vez)
bash validate.sh                   # verificação dos roteiros e testes automatizados

# experimento completo usado no TCC (≈ 3,5 h; deixe a máquina ociosa)
REPETITIONS=10 DURATION=120s USERS=200 SPAWN_RATE=20 WARMUP_SECONDS=15 bash run_experiment.sh
```

**O que o `run_experiment.sh` faz em cada rodada:**
- **Ordem:** executa as seis configurações em ordem sorteada, recriando contêineres e *clusters* a cada execução.
- **Carga:** faz um aquecimento com carga e descarta a subida dos usuários.
- **Coleta:** registra, por execução, as estatísticas do Locust, a CPU e o *throttling* de cada contêiner (contadores do cgroup v2), a memória e a CPU, frequência e temperatura do computador.
- **Registro:** grava as versões, os parâmetros e o *commit* utilizados.

Os resultados ficam em `tests/runs/experiment_DATA_HORA/`.

**Execução isolada:**
- C1–C4: `bash run_tests.sh`
- C5a/C5b: `bash scenario_5/run_scenario_5.sh`

## Análise e figuras

```bash
venv/bin/python tests/generate_graphs.py tests/runs/experiment_DATA_HORA
venv/bin/python tests/generate_tcc_figures.py tests/runs/experiment_DATA_HORA pasta_de_saida
```

O primeiro comando gera, em `analysis/`:
- mediana e intervalo interquartil por configuração;
- comparações com o teste de Mann-Whitney;
- CPU por requisição e *throttling* por contêiner;
- memória e dados do computador.

O segundo gera as figuras e tabelas do TCC.

## Dados do TCC

A pasta `dados/` contém os resultados usados no trabalho:

| Pasta | Conteúdo |
|---|---|
| `dados/experimento_final_20260924/` | Experimento final: 10 rodadas × 6 configurações (60 execuções), com dados brutos por execução e análise consolidada em `analysis/`. As notas da execução estão em `NOTAS_EXECUCAO.md` |
| `dados/ensaio_preliminar_20260907/` | Ensaio preliminar (3 rodadas), feito com um desenho anterior: sem limites de recursos no Docker, JWT HS256 no Docker e acesso ao Kubernetes por `port-forward`. Citado no TCC para justificar o desenho final |

## Estrutura

```
run_experiment.sh        experimento completo (seis configurações intercaladas)
run_tests.sh             C1–C4 (Docker)
scenario_1 … scenario_4  aplicações e docker-compose de cada configuração Docker
scenario_5/              C5a e C5b: manifestos Kubernetes e Istio, configuração do Kind, roteiros
lib/measure.sh           medições comuns (aquecimento, Locust, cgroup, computador, TLS)
certs/                   geração de certificados mTLS e chaves JWT (não versionados)
tests/                   carga (locustfile), testes automatizados, análise e figuras
dados/                   resultados usados no TCC
```

Certificados, chaves privadas, o ambiente virtual e os binários baixados não são versionados e são gerados de novo pelos roteiros.
