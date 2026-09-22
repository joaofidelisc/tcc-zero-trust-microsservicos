# Guia de Reprodução do Laboratório (Defesa do TCC)

Este documento foi criado para servir como um roteiro passo a passo caso você precise demonstrar ou explicar o funcionamento do laboratório para a banca avaliadora do seu TCC.

## 1. Visão Geral da Arquitetura

O laboratório simula uma transação de *e-commerce* onde o **Service A (Checkout)** recebe um pedido e faz uma chamada síncrona HTTP POST para o **Service B (Inventory)** para reservar o estoque.

O objetivo é medir o custo exato (em latência, CPU e memória) que a adição de camadas de segurança impõe. A evolução ocorre em 5 cenários:
1. **Cenário 1 (Baseline)**: Comunicação HTTP pura, sem nenhuma segurança interna (apenas na borda, que não é medida).
2. **Cenário 2 (JWT)**: O Service A assina um token JWT com segredo compartilhado (HS256) e o Service B valida a assinatura e as declarações esperadas.
3. **Cenário 3 (mTLS via código)**: A comunicação HTTP vira HTTPS, com ambos os serviços trocando certificados para autenticação mútua gerida manualmente pelo Python/Gunicorn.
4. **Cenário 4 (Zero Trust Manual)**: Soma o mTLS (Infra/Transporte) com o JWT (Aplicação). Representa o pior caso de *overhead* se o desenvolvedor implementar tudo no código.
5. **Cenário 5 (Service Mesh/Istio)**: Remove a segurança do código Python (que volta a ser igual ao Cenário 1) e delega toda a criptografia (mTLS) e validação (JWT) para os *Sidecars* (Envoy) gerenciados pelo Istio dentro do Kubernetes.

---

## 2. Preparação do Ambiente (Pré-requisitos)

Para executar do zero em qualquer máquina, você precisará de:
* SO Linux (recomendado Ubuntu)
* Docker e Docker Compose V2
* Python 3 (com `venv` instalado)
* Acesso à internet para baixar as dependências

Se for rodar o **Cenário 5 (Kubernetes)**, as ferramentas `kind`, `kubectl` e `istioctl` são necessárias (o lab provê um script para instalá-las localmente na pasta `scenario_5/bin`).

### 2.1. Instalando Dependências Python (Cenários 1-4)
No diretório raiz do laboratório (`tcc-zero-trust-microsservicos`), execute:
```bash
bash setup.sh
```
*Isso criará a pasta `venv` e instalará o Locust (gerador de carga), Pandas e Matplotlib.*

### 2.2. Instalando Ferramentas Kubernetes (Cenário 5)
```bash
bash scenario_5/install_tools.sh
```
*Isso fará o download das binários para `scenario_5/bin` sem poluir o seu sistema operacional global.*

---

## 3. Validando os Contratos (Smoke Test)

Antes de rodar a bateria pesada de estresse, é altamente recomendado provar para a banca que o código e a validação de segurança funcionam:
```bash
bash validate.sh
```
Esse script roda o `pytest` (testes unitários) garantindo que:
* Tokens expirados ou inválidos geram Erro HTTP 401.
* Chamadas sem certificado válido no mTLS são recusadas.
* A regra de negócio de estoque insuficiente retorna Erro HTTP 400.

---

## 4. Executando os Testes de Carga

O laboratório possui rigor experimental: ordem aleatória a cada rodada, destruição completa dos contêineres entre os testes (*clean state*) e coleta segregada de CPU/Memória.

### 4.1. Rodando Cenários 1 a 4 (Docker)
Você pode usar as variáveis de ambiente para definir o peso da carga:
```bash
USERS=200 DURATION=120s REPETITIONS=3 SPAWN_RATE=20 bash run_tests.sh
```
**O que acontece por debaixo dos panos:**
1. O script gera um identificador único de experimento (`tests/runs/experiment_YYYYMMDD_HHMMSS/`).
2. Para cada repetição (3 vezes), ele sorteia os 4 cenários.
3. Para cada cenário:
   - Sobe os contêineres (`docker compose up`).
   - Aguarda uma janela de *warmup* (10 segundos) para os servidores Python (Gunicorn) estabilizarem.
   - Ativa o Locust em *headless mode* (sem interface web).
   - Um script em background coleta `docker stats` a cada 3 segundos.
   - Derruba e deleta os contêineres.

### 4.2. Rodando o Cenário 5 (Kubernetes)
```bash
# Se quiser aproveitar a mesma pasta de experimento dos cenários anteriores:
ALLOW_EXISTING_EXPERIMENT=1 USERS=200 DURATION=120s REPETITIONS=3 SPAWN_RATE=20 bash scenario_5/run_scenario_5.sh
```
**O que acontece por debaixo dos panos:**
1. O script cria um cluster Kubernetes (`kind create cluster`).
2. Sobe as imagens locais do Service A e Service B.
3. Instala o Istio (na fase Mesh).
4. Sobe as aplicações (esperando os Pods ficarem *Ready*).
5. Abre um túnel *port-forward* temporário para injetar carga via Locust local.
6. Coleta métricas de CPU (em millicores) via `kubectl top`.
7. Destrói o cluster por completo ao fim de cada medição.

---

## 5. Visualização e Gráficos

Ao final de todas as execuções, seus resultados estarão agrupados na pasta:
`tests/runs/experiment_YYYYMMDD_HHMMSS/`

Para gerar os gráficos exigidos no TCC (Latência, Throughput e consumo isolado de CPU/Memória ao longo do tempo), basta usar o script utilitário (não se esqueça de ativar o venv antes):

```bash
source venv/bin/activate
python tests/generate_tcc_graphs.py tests/runs/experiment_O_SEU_EXPERIMENTO_AQUI/
```
Isso criará uma pasta `graficos_tcc/` dentro do diretório do experimento contendo as imagens prontas para colocar no Word/Markdown do trabalho final.

---

## Dica para a Banca

Se perguntarem sobre os gargalos:
> "O maior peso observado nos testes locais (Cenário 4) não é o volume de dados do Payload HTTP, e sim a matemática criptográfica do Handshake TLS sendo delegada à biblioteca padrão do Python concorrendo com o roteamento Web. O Istio (Cenário 5) brilha porque o Envoy foi escrito em C++ com altíssima otimização para gerir proxies, tirando o peso matemático da CPU lógica da aplicação e evitando event loop blocking no back-end."
