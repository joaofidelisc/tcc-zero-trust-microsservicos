# Notas da execução

- 2026-09-24T01:52:46-03:00: rodada 1, C5b, tentativa 1 falhou sem mensagem logo após os pods ficarem prontos.
  Causa provável: o Locust sai com código 1 quando há qualquer falha de requisição (aqui, no aquecimento,
  enquanto a configuração do Envoy se propagava), e os roteiros usam "set -e".
- Correção aplicada em lib/measure.sh durante a rodada: "|| true" nas chamadas do Locust (aquecimento e
  medição). Só muda o tratamento de erro: falhas passam a ser registradas nas estatísticas em vez de
  abortar e descartar a execução. Nenhum parâmetro de carga ou de medição mudou.
- Execuções iniciadas antes da correção já carregaram a versão anterior da função. Ver failed_attempts.csv.
- 2026-09-24T01:52:55-03:00: tentativa 2 do C5b da rodada 1 também falhou (iniciada antes da correção).
  A rodada 1 ficará sem C5b até ser completada ao final com: MODES=mesh ROUND_START=1 REPETITIONS=1 (mesmos parâmetros).
- 2026-09-24T04:54:11-03:00: início da execução complementar do C5b da rodada 1 (após a rodada 10).
- 2026-09-24T04:58:55-03:00: execução complementar concluída.
