# Pendências para conclusão do TCC

Este documento consolida os pontos da análise do TCC que ainda precisam ser verificados ou executados. Ele não substitui a revisão final com a orientadora e deve ser usado como lista de conferência.

## Itens já encaminhados

- Problema de pesquisa explicitado na introdução.
- Objetivo geral ajustado para dialogar diretamente com o problema.
- Introdução contextualizada com estado da arte e referências de computação.
- Título atualizado para “Zero Trust” em microsserviços: estudo experimental sobre segurança e desempenho em APIs RESTful.
- Referência a revisão sistemática removida, conforme a orientação recebida para o trabalho.
- Citações de JWT, TLS, Zero Trust, microsserviços, métricas de segurança e service mesh incluídas.
- Figuras dos seis cenários incluídas e legendas padronizadas.
- Explicações das Figuras 1 a 12 incluídas no texto.
- Considerações sobre aquecimento, JWT, mTLS, CA local, Istio, Envoy e service mesh incluídas.
- Agradecimentos ampliados, incluindo a homenagem ao avô.
- Apêndice A criado e formatado conforme o manual da ESALQ.
- Procedimentos de reprodução documentados e código corrigido separado do original.
- Repositório público criado com README, scripts, guia de reprodução e `.gitignore` para artefatos sensíveis.

## Pendências prioritárias

### 1. Validar a versão final com a orientadora

- Confirmar se o título atualizado foi aceito formalmente.
- Confirmar se a formulação do problema de pesquisa está adequada ao escopo do curso.
- Confirmar se a quantidade e a seleção das referências são suficientes.
- Confirmar se a interpretação dos resultados não está sendo apresentada como prova de segurança ou causalidade quando o experimento mediu principalmente desempenho.

### 2. Revisar a seção de Introdução

- Conferir se a introdução permanece dentro do limite de duas páginas indicado no manual.
- Verificar se o último parágrafo contém claramente o objetivo do trabalho.
- Conferir se todas as citações usadas na introdução aparecem nas referências e vice-versa.
- Evitar afirmações gerais sobre Docker, Kubernetes, Istio ou segurança que não estejam apoiadas por referência.

### 3. Revisar resultados e interpretação

- Conferir se os valores das tabelas, gráficos, resumo e considerações finais são idênticos.
- Recalcular, se necessário, as diferenças percentuais de C5a para C5b a partir dos dados consolidados.
- Explicitar que as três rodadas permitem análise descritiva, mas não sustentam testes de hipótese ou generalização estatística ampla.
- Conferir a interpretação do consumo de CPU e memória do Checkout, Inventory e sidecars, evitando afirmar “throttling” sem contadores específicos.
- Separar, quando possível, o consumo das aplicações, sidecars, plano de controle do cluster e gerador de carga.
- Verificar se percentis são apresentados como médias dos percentis por rodada, e não como percentis globais de todas as requisições.

### 4. Melhorar a reprodutibilidade

- Executar `bash validate.sh` em uma máquina limpa ou ambiente isolado e registrar o resultado.
- Executar ao menos uma rodada de C1–C4 e uma rodada de C5 para confirmar que os comandos documentados continuam funcionando.
- Registrar no repositório as versões efetivamente usadas, preferencialmente com saída de `python --version`, `docker compose version`, `kind version`, `kubectl version` e `istioctl version`.
- Confirmar que nenhum certificado, chave privada, segredo JWT, resultado bruto ou binário baixado está versionado.
- Se os testes forem refeitos, preservar os metadados, a ordem dos cenários e os arquivos brutos junto aos resultados analisados.

### 5. Revisar figuras e tabelas

- Conferir se o gerador de carga está desenhado fora do contêiner ou cluster quando essa for a arquitetura real da execução.
- Conferir se cada figura identifica claramente Checkout, Inventory, retorno da resposta, JWT, certificados, CA e proxies Envoy quando aplicável.
- Verificar legibilidade das figuras na exportação PDF, especialmente setas, rótulos e textos pequenos.
- Conferir se títulos de tabelas aparecem antes das tabelas e se fontes aparecem após elas.
- Confirmar a numeração contínua das figuras no texto principal e a numeração própria caso sejam adicionadas figuras ao apêndice.

### 6. Revisão normativa e textual final

- Fazer uma leitura integral procurando erros de digitação, concordância, acentuação e repetição.
- Conferir o uso consistente de termos em inglês, aspas e siglas.
- Verificar se o texto está predominantemente na terceira pessoa e no pretérito perfeito, conforme o manual.
- Conferir margens, fonte Arial 11, espaçamento 1,5, recuo de primeira linha, alinhamento justificado e títulos sem numeração indevida.
- Conferir referências em ordem alfabética, espaçamento simples entre entradas e ausência de negrito indevido.
- Confirmar que o documento final não ultrapassa 30 páginas, incluindo o Apêndice A.

### 7. Considerações finais

- Responder explicitamente se o objetivo foi atingido.
- Responder explicitamente se a pergunta de pesquisa foi respondida pelos experimentos.
- Diferenciar o que foi observado nos dados do que permanece como hipótese ou limitação.
- Registrar que os resultados caracterizam o ambiente experimental avaliado e não representam uma medida universal de Docker, Kubernetes, Istio ou dos mecanismos de autenticação.
- Relacionar os próximos passos às limitações efetivamente identificadas.

## Ordem recomendada de execução

1. Validar o título, problema e objetivo com a orientadora.
2. Executar os testes de reprodução e registrar versões do ambiente.
3. Conferir tabelas, gráficos, cálculos e coerência entre resultados e discussão.
4. Revisar a discussão de segurança e as limitações.
5. Fazer a revisão normativa e linguística final.
6. Exportar o PDF, verificar visualmente todas as páginas e confirmar o limite de 30 páginas.
7. Criar um commit final no repositório somente após remover artefatos sensíveis e resultados que não devam ser públicos.

