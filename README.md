# Laboratório corrigido — TCC Zero Trust

Esta pasta é uma versão independente e corrigida do laboratório. A pasta original
lab não é usada nem modificada por estes scripts.

## O que foi corrigido

| Problema anterior | Correção nesta pasta |
|---|---|
| Falhas do Service B podiam virar HTTP 200 no Service A | Todas as chamadas usam timeout, raise_for_status e validação do status de negócio; falhas retornam 502 ou 504 |
| O Locust contava apenas o status HTTP | A resposta agora só é sucesso quando checkout é success e o estoque está reserved |
| O cache JWT podia aceitar token expirado e crescer indefinidamente | O cache foi removido; assinatura, expiração, emissor, assunto e claims obrigatórias são verificados em todas as chamadas |
| O custo do mTLS incluía também TLS entre Locust e Service A | O tráfego externo é HTTP nos quatro cenários Docker; somente A → B usa mTLS nos Cenários 3 e 4 |
| Locust reutilizava a identidade do Service A | O Locust não usa certificado; somente o Service A possui a chave cliente mTLS |
| Ambos os containers recebiam todas as chaves privadas | Cada serviço monta apenas sua própria chave e a CA |
| Cenário 5 usava a ServiceAccount default | Service A e Service B possuem contas distintas e a política exige o principal mTLS do Service A |
| JWT simétrico era exposto como JWKS no Istio | Cenário 5 usa RS256; a chave privada fica em Secret somente no Service A e o Envoy obtém apenas a chave pública |
| Docker era comparado diretamente com Kubernetes + Istio | Cenário 5 mede Kubernetes sem mesh e Kubernetes + Istio em clusters novos, com ordem aleatória |
| Uma única rodada em ordem fixa | Cenários 1–4 usam cinco repetições por padrão e ordem aleatória em cada rodada |
| Resultados anteriores eram apagados | Cada execução cria tests/runs/experiment_DATA_HORA |
| Sleeps eram usados como readiness | Compose usa healthchecks; Kubernetes usa readiness probes e rollout status |
| Cleanup podia deixar processos ou matar kubectl alheio | Traps encerram apenas os PIDs e o cluster zt-lab-corrected deste laboratório |
| Dependências e imagens eram flutuantes | Python e dependências são fixados; Kind, Kubernetes, Istio e Metrics Server têm versões declaradas |
| Gráficos tinham data e arquivo histórico hardcoded | O analisador recebe qualquer diretório de experimento e calcula média, desvio e distribuição das repetições |

## Preparação

Na raiz desta pasta:

    cd "/home/cardozo/Desktop/TCC USP/ProjetodePesquisa/tcc-zero-trust-microsservicos"
    bash setup.sh
    bash validate.sh

O setup cria um venv próprio, instala Locust, pytest, pandas e matplotlib, e gera
os certificados dos Cenários 3 e 4. Ele não reutiliza o venv nem os certificados
da pasta original.

## Execução oficial dos Cenários 1–4

Com os valores padrão são feitas cinco repetições de 60 segundos. A ordem dos
quatro cenários é sorteada novamente em cada repetição.

    bash run_tests.sh

Execução curta para conferir o funcionamento:

    REPETITIONS=1 DURATION=15s USERS=10 SPAWN_RATE=5 WARMUP_SECONDS=2 bash run_tests.sh

Parâmetros aceitos:

- REPETITIONS: quantidade de rodadas; padrão 5.
- DURATION: duração Locust no formato 60s.
- USERS: usuários simultâneos; padrão 50.
- SPAWN_RATE: usuários iniciados por segundo; padrão 10.
- WARMUP_SECONDS: aquecimento antes da medição; padrão 10.
- COOLDOWN_SECONDS: intervalo entre cenários; padrão 5.
- EXPERIMENT_ID: nome opcional do diretório da rodada.
- INCLUDE_SCENARIO_5=1: executa também a comparação Kubernetes × Istio.

## Execução manual de um cenário Docker

O exemplo abaixo usa o Cenário 4. Troque scenario_4 por scenario_1, scenario_2
ou scenario_3 quando necessário.

    cd "/home/cardozo/Desktop/TCC USP/ProjetodePesquisa/tcc-zero-trust-microsservicos"
    export JWT_SECRET="$(openssl rand -hex 32)"
    docker compose -f scenario_4/docker-compose.yml up -d --build --wait
    curl --fail-with-body -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5000/api/v1/checkout
    ./venv/bin/locust -f tests/locustfile.py --headless -u 50 -r 10 -t 60s -H http://127.0.0.1:5000 --csv=/tmp/scenario_4_manual
    docker compose -f scenario_4/docker-compose.yml down --remove-orphans

O JWT_SECRET só é necessário nos Cenários 2 e 4. O endpoint externo continua
HTTP também nos Cenários 3 e 4, pois o mTLS medido é exclusivamente interno.

## Cenário 5

As ferramentas são instaladas localmente, com versão fixa e verificação de
checksum:

    bash scenario_5/install_tools.sh

Rodada controlada completa. Por padrão são três pares de medições, sorteando
baseline ou mesh primeiro e criando um cluster novo para cada medição:

    bash scenario_5/run_scenario_5.sh

Teste curto:

    REPETITIONS=1 DURATION=15s USERS=10 SPAWN_RATE=5 bash scenario_5/run_scenario_5.sh

Modo manual Kubernetes sem mesh:

    bash scenario_5/start_manual.sh baseline
    curl --fail-with-body -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5005/api/v1/checkout
    bash scenario_5/stop_manual.sh

Modo manual Kubernetes + Istio:

    bash scenario_5/start_manual.sh mesh
    curl --fail-with-body -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5005/api/v1/checkout
    bash scenario_5/stop_manual.sh

No modo mesh, o Service B aceita somente requisições que tenham simultaneamente:

- mTLS originado da ServiceAccount service-a;
- JWT RS256 emitido por zero-trust-lab;
- assunto checkout_service.

## Organização dos resultados

Cada execução produz uma estrutura semelhante a:

    tests/runs/experiment_20260813_180000/
      metadata.env
      scenario_order.csv
      round_01/
        scenario_1/
          results_stats.csv
          results_stats_history.csv
          results_failures.csv
          resources.csv
      analysis/
        runs.csv
        summary_by_scenario.csv
        resource_summary_by_run.csv
        performance_distributions.png

Para refazer a análise:

    ./venv/bin/python tests/generate_graphs.py tests/runs/experiment_20260813_180000

Não compare diretamente os novos números com os CSVs antigos como se a
metodologia fosse idêntica. O isolamento do mTLS, a validação de negócio, o
aquecimento e as repetições mudaram deliberadamente o protocolo.

Os diretórios cujo nome começa com smoke são apenas evidências de funcionamento
com duração reduzida. Não use esses números como resultados científicos do TCC.

## Validações locais

    bash validate.sh

Esse comando verifica a sintaxe de todos os scripts Bash e Python, valida os
quatro arquivos Compose e, quando o venv existe, executa os testes de contrato.

Os testes de contrato comprovam que:

- erro interno não aparece como sucesso externo;
- resposta de negócio inválida é rejeitada;
- token expirado nunca é aceito;
- entradas inválidas são rejeitadas.

## Versões do Cenário 5

As versões estão em scenario_5/versions.env. Esta revisão usa Istio 1.30.3,
Kind 0.31.0, Kubernetes 1.35.0 e Metrics Server 0.8.1. O node image do Kind é
fixado também por digest.

Referências oficiais:

- https://istio.io/latest/docs/releases/supported-releases/
- https://github.com/kubernetes-sigs/kind/releases
- https://kubernetes.io/releases/
- https://github.com/kubernetes-sigs/metrics-server/releases
