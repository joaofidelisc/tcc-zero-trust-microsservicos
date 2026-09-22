# Explicação detalhada dos cenários experimentais

Este documento explica o funcionamento dos cenários da pasta `tcc-zero-trust-microsservicos`, usada como versão corrigida e metodologicamente mais consistente do laboratório do TCC.

A aplicação experimental simula uma operação simples de comércio eletrônico:

- `service_a`: serviço **Checkout**, responsável por receber a requisição de compra.
- `service_b`: serviço **Inventory**, responsável por reservar o item solicitado no estoque.
- `Locust`: gerador de carga externo, responsável por chamar o endpoint do Checkout durante os testes.

O fluxo funcional básico é sempre:

```text
Locust → Checkout → Inventory → Checkout → Locust
```

O que muda entre os cenários é o mecanismo aplicado à comunicação interna entre Checkout e Inventory: HTTP simples, JWT, mTLS, mTLS com JWT ou delegação desses controles ao Istio/Envoy.

## Observação sobre o `internal_latency_ms`

Em todos os cenários, o Checkout retorna um campo chamado `internal_latency_ms`.

Esse valor é medido dentro do próprio Checkout. Ele é calculado assim:

```python
started_at = time.perf_counter()
inventory_data, error_response = call_inventory(checkout_payload())
elapsed_ms = (time.perf_counter() - started_at) * 1000
```

Portanto, `internal_latency_ms` representa aproximadamente o tempo gasto pelo Checkout para:

1. montar o payload da chamada interna;
2. chamar o Inventory;
3. esperar a resposta do Inventory;
4. validar/processar a resposta recebida.

Ele não é exatamente a mesma métrica de latência coletada pelo Locust.

O Locust mede o tempo total externo:

```text
Locust → Checkout → Inventory → Checkout → Locust
```

Já `internal_latency_ms` mede a parte observada pelo Checkout:

```text
Checkout → Inventory → Checkout
```

Por isso, nos resultados do TCC, a latência principal deve ser a do Locust. O `internal_latency_ms` é útil como informação diagnóstica da aplicação.

## Cenário 1 — HTTP simples

Arquivos principais:

- `scenario_1/service_a/app.py`
- `scenario_1/service_b/app.py`
- `scenario_1/service_a/Dockerfile`
- `scenario_1/service_b/Dockerfile`
- `scenario_1/docker-compose.yml`

### Onde estão Checkout e Inventory

No Cenário 1, os dois serviços rodam em contêineres Docker separados:

```text
Contêiner service_a → Checkout
Contêiner service_b → Inventory
```

Ambos possuem Dockerfile próprio. Os dois Dockerfiles usam Python, instalam as dependências e iniciam a aplicação Flask com Gunicorn.

O `docker-compose.yml` publica apenas o Checkout na porta `5000` do host:

```yaml
service_a:
  ports:
    - "5000:5000"
```

O Inventory não é exposto diretamente para o host. Ele fica acessível apenas pela rede interna do Docker Compose, com o nome DNS `service_b`.

### Fluxo

1. O Locust envia uma requisição HTTP para:

```text
POST http://localhost:5000/api/v1/checkout
```

2. O Checkout recebe a requisição.
3. O Checkout monta o payload que será enviado ao Inventory.
4. O Checkout chama:

```text
POST http://service_b:5000/internal/reserve-stock
```

5. O Inventory valida o JSON recebido.
6. O Inventory retorna a reserva.
7. O Checkout inclui a resposta do Inventory na resposta final enviada ao Locust.

### O que o Checkout envia ao Inventory

O Checkout monta o payload com a função `checkout_payload()`:

```python
def checkout_payload():
    data = request.get_json(silent=True) or {}
    return {
        "item_id": data.get("item_id", "SKU-999"),
        "quantity": data.get("quantity", 1),
    }
```

Se o Locust não enviar valores específicos, o Checkout usa os valores padrão:

```json
{
  "item_id": "SKU-999",
  "quantity": 1
}
```

Exemplo da chamada interna:

```http
POST http://service_b:5000/internal/reserve-stock
Content-Type: application/json

{
  "item_id": "SKU-999",
  "quantity": 1
}
```

### O que o Inventory responde

Se o JSON for válido, o Inventory responde:

```json
{
  "status": "reserved",
  "item_id": "SKU-999",
  "quantity": 1,
  "security_context": "Unsecured HTTP"
}
```

O Checkout então retorna ao Locust algo como:

```json
{
  "status": "success",
  "message": "Order placed (No Security)",
  "inventory_status": {
    "status": "reserved",
    "item_id": "SKU-999",
    "quantity": 1,
    "security_context": "Unsecured HTTP"
  },
  "internal_latency_ms": 4.27
}
```

### Timeout

O Cenário 1 define:

```python
REQUEST_TIMEOUT = (1.0, 3.0)
```

Esse valor não é randomizado. No `requests`, a tupla significa:

- `1.0`: até 1 segundo para estabelecer a conexão;
- `3.0`: até 3 segundos para aguardar a resposta.

### Avaliação

O Cenário 1 faz sentido como baseline. Ele mede a comunicação funcional entre Checkout e Inventory sem autenticação adicional, sem criptografia interna e sem malha de serviços. Isso permite comparar o custo incremental dos mecanismos adicionados nos demais cenários.

## Cenário 2 — HTTP com JWT

Arquivos principais:

- `scenario_2/service_a/app.py`
- `scenario_2/service_b/app.py`
- `scenario_2/docker-compose.yml`

### Onde estão Checkout e Inventory

Assim como no Cenário 1:

```text
service_a → Checkout
service_b → Inventory
```

Os dois serviços continuam em Docker Compose. O Checkout continua exposto na porta `5000` do host, e o Inventory permanece acessível apenas na rede interna pelo nome `service_b`.

### Fluxo

1. O Locust chama o Checkout por HTTP.
2. O Checkout gera um JWT.
3. O Checkout envia o JWT no cabeçalho `Authorization`.
4. O Inventory valida o JWT antes de executar a reserva.
5. Se o token for válido, o Inventory processa a reserva.
6. A resposta volta ao Checkout.
7. O Checkout responde ao Locust.

### Como o JWT é gerado

No Checkout, a função `generate_internal_token()` cria o token:

```python
def generate_internal_token():
    now = datetime.datetime.now(datetime.timezone.utc)
    return jwt.encode(
        {
            "iss": JWT_ISSUER,
            "sub": JWT_SUBJECT,
            "iat": now,
            "exp": now + datetime.timedelta(seconds=30),
        },
        JWT_SECRET,
        algorithm="HS256",
    )
```

O token usa:

- algoritmo `HS256`;
- segredo simétrico `JWT_SECRET`;
- emissor `zero-trust-lab`;
- sujeito `checkout_service`;
- data de emissão;
- expiração de 30 segundos.

### Chave secreta, chave privada e certificado no JWT

A forma como o JWT é assinado depende do algoritmo usado. No laboratório aparecem dois modelos: HS256 e RS256.

### HS256: chave secreta compartilhada

Nos cenários C2 e C4, o JWT usa HS256.

Nesse modelo, não existe chave privada e chave pública. Existe uma chave secreta compartilhada, chamada no código de `JWT_SECRET`.

```text
Checkout usa JWT_SECRET para assinar o token
Inventory usa o mesmo JWT_SECRET para validar o token
```

Ou seja, a mesma chave serve para assinar e para validar. Por isso, ela precisa ser conhecida tanto pelo emissor quanto pelo validador.

Exemplo conceitual:

```python
JWT_SECRET = "uma-chave-secreta-grande-e-aleatoria"
```

Esse modelo é simples e adequado para laboratório, mas exige cuidado em produção, porque qualquer componente que conheça o segredo consegue tanto validar quanto emitir tokens.

### RS256: chave privada e chave pública

No cenário C5b, o JWT usa RS256.

Nesse modelo, existe um par de chaves:

```text
chave privada → usada para assinar o JWT
chave pública → usada para validar o JWT
```

A chave privada fica com quem emite o token. No laboratório, quem emite o token é o Checkout.

A chave pública pode ser disponibilizada para quem precisa validar o token. No C5b, ela é exposta em formato JWKS para que o Istio/Envoy consiga validar a assinatura.

Exemplo conceitual de chave privada em PEM:

```text
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC...
...
-----END PRIVATE KEY-----
```

Exemplo conceitual de chave pública em PEM:

```text
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A...
...
-----END PUBLIC KEY-----
```

No C5b, o Checkout assina o JWT com a chave privada. O Envoy/Istio valida o JWT com a chave pública. Assim, o validador não precisa conhecer a chave privada.

### Chave privada é a mesma coisa que certificado?

Não exatamente. Chave privada, chave pública e certificado são relacionados, mas não são a mesma coisa.

| Conceito | O que é | Uso no laboratório |
|---|---|---|
| Chave privada | Segredo criptográfico usado para assinar ou provar identidade | Usada no JWT RS256 do C5b e nos certificados mTLS |
| Chave pública | Parte pública correspondente à chave privada, usada para validar assinatura | Usada pelo Istio/Envoy para validar JWT RS256 |
| Certificado | Documento que contém uma chave pública e informações de identidade, assinado por uma CA | Usado no mTLS dos cenários C3 e C4 |

Para JWT RS256, o essencial é o par de chaves RSA:

```text
jwt-private.pem → assina o JWT
jwt-public.pem  → valida o JWT
```

Esses arquivos não precisam ser certificados X.509. Eles podem ser apenas chaves em formato PEM.

Já no mTLS, entram certificados X.509:

```text
service_a.crt + service_a.key
service_b.crt + service_b.key
ca.crt
```

Nesse caso, o certificado contém a chave pública e informações de identidade do serviço, e a chave privada correspondente fica protegida no próprio serviço.

Resumo:

| Uso | C2/C4 JWT HS256 | C5b JWT RS256 | C3/C4 mTLS |
|---|---|---|---|
| Usa chave privada? | Não | Sim | Sim |
| Usa chave pública? | Não | Sim | Sim, dentro do certificado |
| Usa certificado? | Não | Não necessariamente | Sim |
| Quem assina/prova identidade? | Segredo compartilhado | Chave privada | Certificado + chave privada no handshake TLS |
| Quem valida? | Mesmo segredo | Chave pública/JWKS | CA e certificados |

Portanto, quando o C5b usa RS256, ele usa uma chave privada para assinar o JWT. Essa chave privada não é, por si só, um certificado. Certificados aparecem no mTLS, não necessariamente no JWT.

### O que significam os parâmetros do JWT

O JWT é composto por declarações chamadas *claims*. No código, essas declarações são passadas no dicionário usado pela função `jwt.encode`.

```python
{
    "iss": JWT_ISSUER,
    "sub": JWT_SUBJECT,
    "iat": now,
    "exp": now + datetime.timedelta(seconds=30),
}
```

Cada campo tem uma função específica:

| Campo | Significado | Função no cenário |
|---|---|---|
| `iss` | *Issuer*, ou emissor | Indica quem emitiu o token. No laboratório, o emissor esperado é `zero-trust-lab`. |
| `sub` | *Subject*, ou sujeito | Indica em nome de quem o token foi emitido. No laboratório, representa o Checkout: `checkout_service`. |
| `iat` | *Issued at*, ou emitido em | Registra o instante em que o token foi criado. Ajuda a identificar quando o token passou a existir. |
| `exp` | *Expiration*, ou expiração | Define até quando o token é válido. Neste cenário, o token expira 30 segundos após sua criação. |

Além desses campos, a função recebe:

```python
JWT_SECRET
algorithm="HS256"
```

O `JWT_SECRET` é a chave secreta compartilhada entre Checkout e Inventory. O Checkout usa essa chave para assinar o token, e o Inventory usa a mesma chave para validar a assinatura.

O algoritmo `HS256` significa HMAC com SHA-256. Ele é um algoritmo simétrico: a mesma chave é usada para assinar e validar. Por isso, esse modelo é simples para o laboratório, mas em ambientes produtivos é comum usar algoritmos assimétricos, como RS256, nos quais uma chave privada assina o token e uma chave pública valida a assinatura.

Importante: esses campos não criptografam o conteúdo do JWT. Eles compõem um token assinado. Assim, o Inventory não descriptografa o token; ele valida a assinatura e confere se as declarações esperadas estão presentes e corretas.

### O que o Checkout envia ao Inventory

O corpo da requisição é o mesmo do Cenário 1:

```json
{
  "item_id": "SKU-999",
  "quantity": 1
}
```

Mas agora há também o cabeçalho:

```http
Authorization: Bearer <jwt>
```

Exemplo conceitual:

```http
POST http://service_b:5000/internal/reserve-stock
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJIUzI1NiIs...

{
  "item_id": "SKU-999",
  "quantity": 1
}
```

### Como o Inventory extrai e valida o JWT

No Inventory, o endpoint `/internal/reserve-stock` é protegido pelo decorador `require_jwt`. Esse decorador executa antes da função de reserva de estoque. Se o token estiver ausente ou inválido, a requisição é interrompida e o Inventory retorna erro `401`.

O primeiro passo é ler o cabeçalho `Authorization`:

```python
auth_header = request.headers.get("Authorization", "")
scheme, separator, token = auth_header.partition(" ")
```

Esse código separa o cabeçalho em três partes. Por exemplo, se a requisição tiver:

```http
Authorization: Bearer eyJhbGciOiJIUzI1NiIs...
```

então o resultado será:

```text
scheme    = "Bearer"
separator = " "
token     = "eyJhbGciOiJIUzI1NiIs..."
```

Depois, o Inventory verifica se o cabeçalho está no formato esperado:

```python
if separator == "" or scheme.lower() != "bearer" or not token:
    return jsonify({"status": "error", "error": "missing_bearer_token"}), 401
```

Isso evita aceitar requisições sem token ou com um formato diferente de `Bearer <token>`.

Em seguida, o Inventory valida o token com `jwt.decode`:

```python
payload = jwt.decode(
    token,
    JWT_SECRET,
    algorithms=["HS256"],
    issuer=JWT_ISSUER,
    options={"require": ["exp", "iat", "iss", "sub"]},
)
```

Essa chamada faz várias verificações ao mesmo tempo:

1. confere se a assinatura HS256 é válida usando `JWT_SECRET`;
2. confere se o algoritmo permitido é `HS256`;
3. confere se o emissor (`iss`) é o esperado;
4. confere se o token possui os campos obrigatórios `exp`, `iat`, `iss` e `sub`;
5. confere se o token ainda não expirou, com base no campo `exp`.

Depois disso, o código ainda verifica se o sujeito do token é o Checkout:

```python
if payload.get("sub") != JWT_SUBJECT:
    raise jwt.InvalidSubjectError("subject inválido")
```

Assim, mesmo que o token seja assinado corretamente, ele só será aceito se representar o sujeito esperado: `checkout_service`.

### Como o Inventory sabe que o token está correto?

No Cenário 2, o JWT usa assinatura simétrica com HS256. Isso significa que Checkout e Inventory compartilham a mesma chave secreta (`JWT_SECRET`).

O Checkout usa essa chave para assinar o token. A assinatura é calculada a partir do conteúdo do token e da chave secreta.

O Inventory, ao receber o token, usa a mesma chave para recalcular/verificar a assinatura. Se alguém alterar qualquer parte do token, por exemplo o `sub` ou o `exp`, a assinatura deixa de bater. Nesse caso, `jwt.decode` gera erro e o token é rejeitado.

Portanto, o Inventory sabe que o token está correto porque:

- a assinatura bate com a chave esperada;
- o algoritmo é permitido;
- o emissor é o esperado;
- o sujeito é o Checkout;
- o token não expirou;
- os campos obrigatórios estão presentes.

### Diferença entre JWT assinado e JWT criptografado

Neste laboratório, o JWT é assinado, mas não é criptografado.

Um token assinado garante integridade e autenticidade:

```text
Quem recebe consegue verificar que o token foi emitido por quem conhece a chave e que o conteúdo não foi alterado.
```

Mas a assinatura não esconde o conteúdo do token. Em um JWT comum assinado, qualquer pessoa que tenha acesso ao token consegue decodificar o cabeçalho e o payload, embora não consiga alterar o conteúdo sem invalidar a assinatura.

Já um token criptografado teria confidencialidade:

```text
Quem recebe precisaria descriptografar o token para ler seu conteúdo.
```

Esse não é o caso usado nos Cenários 2 e 4. Por isso, o correto é dizer que o Inventory valida o JWT, e não que ele descriptografa o JWT.

Resumo:

| Tipo | O que garante | O conteúdo fica escondido? | Usado neste laboratório? |
|---|---|---:|---:|
| JWT assinado | Integridade e autenticidade | Não | Sim |
| JWT criptografado | Confidencialidade | Sim | Não |

### Avaliação

O Cenário 2 faz sentido para medir o custo da autenticação na camada de aplicação. Ele mantém o transporte HTTP simples, mas adiciona validação de identidade via token. Isso isola o efeito do JWT sem misturar com custo de TLS/mTLS.

## Explicação detalhada do mTLS

O mTLS significa *mutual TLS*, ou TLS mútuo. Ele é uma variação do TLS em que os dois lados da comunicação apresentam certificados.

No TLS comum, normalmente apenas o servidor apresenta certificado. Por exemplo, quando um navegador acessa um site HTTPS, o site apresenta um certificado e o navegador valida se aquele servidor é confiável.

No mTLS, os dois lados se autenticam:

```text
Cliente → apresenta certificado ao servidor
Servidor → apresenta certificado ao cliente
```

No laboratório, isso significa:

```text
Checkout → apresenta certificado de cliente
Inventory → apresenta certificado de servidor
```

Os certificados foram emitidos por uma CA local do laboratório. A CA funciona como uma autoridade confiável. Cada serviço confia na CA e, por consequência, consegue validar certificados emitidos por ela.

### Certificados usados

Os arquivos principais são:

| Arquivo | Função |
|---|---|
| `ca.crt` | Certificado da autoridade certificadora local. Usado para validar os certificados dos serviços. |
| `service_a.crt` | Certificado apresentado pelo Checkout. |
| `service_a.key` | Chave privada do Checkout. |
| `service_b.crt` | Certificado apresentado pelo Inventory. |
| `service_b.key` | Chave privada do Inventory. |

A chave privada nunca deve ser enviada ao outro serviço. Ela fica no próprio contêiner e é usada para provar que o serviço é o dono daquele certificado.

### O que acontece durante a conexão mTLS

De forma simplificada, o fluxo é:

1. o Checkout tenta abrir uma conexão HTTPS com o Inventory;
2. o Inventory apresenta seu certificado (`service_b.crt`);
3. o Checkout valida o certificado do Inventory usando `ca.crt`;
4. o Inventory exige certificado de cliente;
5. o Checkout apresenta seu certificado (`service_a.crt`);
6. o Inventory valida o certificado do Checkout usando `ca.crt`;
7. se as validações passarem, o canal seguro é estabelecido;
8. a requisição e a resposta trafegam criptografadas dentro desse canal.

Assim, o mTLS oferece duas propriedades importantes:

- autenticação mútua entre serviços;
- criptografia do tráfego entre eles.

### Quem descriptografa no mTLS?

Nos Cenários 3 e 4, o mTLS está na aplicação/servidor Gunicorn dos próprios serviços. Portanto, o tráfego é descriptografado nos endpoints TLS dos serviços.

Em termos práticos:

```text
Checkout criptografa a requisição no canal TLS
Inventory recebe e descriptografa no endpoint TLS
Inventory processa a reserva
Inventory criptografa a resposta no mesmo canal
Checkout recebe e descriptografa a resposta
```

No Cenário 5b, isso muda. Com Istio, quem termina o mTLS são os sidecars Envoy, não o código Flask diretamente.

## Cenário 3 — mTLS na aplicação

Arquivos principais:

- `scenario_3/service_a/app.py`
- `scenario_3/service_b/app.py`
- `scenario_3/docker-compose.yml`
- `certs/ca.crt`
- `certs/service_a.crt`
- `certs/service_a.key`
- `certs/service_b.crt`
- `certs/service_b.key`

### Onde estão Checkout e Inventory

Os serviços continuam em Docker Compose:

```text
service_a → Checkout
service_b → Inventory
```

O Locust acessa o Checkout por HTTP. O mTLS é aplicado apenas na chamada interna entre Checkout e Inventory.

### Fluxo

1. Locust chama o Checkout por HTTP.
2. O Checkout monta o payload.
3. O Checkout abre uma conexão HTTPS com mTLS para o Inventory.
4. O Checkout apresenta seu certificado de cliente.
5. O Inventory apresenta seu certificado de servidor.
6. Cada lado valida o certificado do outro com a CA confiável.
7. O Checkout envia a requisição pelo canal mTLS.
8. O Inventory processa a reserva.
9. O Inventory responde pelo mesmo canal mTLS.
10. O Checkout responde ao Locust.

### Certificados envolvidos

Há dois certificados principais de serviço:

```text
service_a.crt + service_a.key → usados pelo Checkout
service_b.crt + service_b.key → usados pelo Inventory
```

E uma CA:

```text
ca.crt → usada para validar os certificados
```

### Como o Checkout usa mTLS

No Checkout:

```python
session.cert = ("/certs/service_a.crt", "/certs/service_a.key")
session.verify = "/certs/ca.crt"
```

Isso significa:

- o Checkout apresenta `service_a.crt`;
- assina a negociação com `service_a.key`;
- valida o certificado do Inventory usando `ca.crt`.

### Como o Inventory exige mTLS

O Inventory é servido por HTTPS com certificado próprio. No Docker Compose, os certificados são montados no contêiner.

O serviço B usa:

```text
/certs/service_b.crt
/certs/service_b.key
/certs/ca.crt
```

### O que o Checkout envia ao Inventory

O payload funcional continua o mesmo:

```json
{
  "item_id": "SKU-999",
  "quantity": 1
}
```

A diferença é que ele trafega dentro de um canal mTLS:

```http
POST https://service_b:5000/internal/reserve-stock
Content-Type: application/json

{
  "item_id": "SKU-999",
  "quantity": 1
}
```

### Avaliação

O Cenário 3 faz sentido para medir o custo da proteção de transporte e autenticação mútua entre serviços. Ele separa o custo do mTLS do custo do JWT. Também está bem alinhado com a descrição do TCC, pois o tráfego externo Locust → Checkout continua HTTP, enquanto a comunicação interna Checkout → Inventory usa mTLS.

## Cenário 4 — mTLS + JWT na aplicação

Arquivos principais:

- `scenario_4/service_a/app.py`
- `scenario_4/service_b/app.py`
- `scenario_4/docker-compose.yml`

### Onde estão Checkout e Inventory

Novamente:

```text
service_a → Checkout
service_b → Inventory
```

Ambos rodam em Docker. O Locust chama o Checkout por HTTP, e a chamada interna para o Inventory usa mTLS e JWT.

### Fluxo

1. Locust chama o Checkout por HTTP.
2. O Checkout monta o payload.
3. O Checkout gera um JWT HS256.
4. O Checkout abre uma conexão mTLS com o Inventory.
5. O Checkout envia o payload e o JWT pelo canal mTLS.
6. O Inventory valida o mTLS no transporte.
7. O Inventory valida o JWT na aplicação.
8. Se ambos forem válidos, o Inventory processa a reserva.
9. A resposta retorna pelo mesmo canal mTLS.
10. O Checkout responde ao Locust.

### Onde fica o JWT

O JWT é criado no Checkout:

```python
headers = {"Authorization": f"Bearer {generate_internal_token()}"}
```

E é enviado no cabeçalho HTTP:

```http
Authorization: Bearer <jwt>
```

### Onde fica o mTLS

O mTLS está na sessão HTTPS usada pelo Checkout para chamar o Inventory:

```python
session.cert = ("/certs/service_a.crt", "/certs/service_a.key")
session.verify = "/certs/ca.crt"
```

No Inventory, o serviço roda com o certificado `service_b` e exige certificado de cliente.

### Exemplo de requisição interna

```http
POST https://service_b:5000/internal/reserve-stock
Content-Type: application/json
Authorization: Bearer <jwt>

{
  "item_id": "SKU-999",
  "quantity": 1
}
```

### Ordem lógica das validações no C4

No Cenário 4, existem duas camadas de proteção. Elas não substituem uma à outra.

A primeira camada é o mTLS. Antes de o Inventory processar a requisição HTTP, a conexão segura precisa ser estabelecida. Nesse momento, os certificados são apresentados e validados. Se o mTLS falhar, a requisição nem chega corretamente ao endpoint `/internal/reserve-stock`.

Depois que o canal mTLS é estabelecido, a requisição HTTP trafega dentro dele. Nesse ponto, o Inventory recebe o cabeçalho `Authorization` e executa a validação do JWT, da mesma forma conceitual do Cenário 2.

Assim, a lógica é:

```text
1. mTLS valida o canal e a identidade dos serviços
2. HTTP trafega dentro do canal criptografado
3. Inventory extrai o JWT do cabeçalho Authorization
4. Inventory valida assinatura, emissor, sujeito e expiração
5. Inventory processa a reserva
6. resposta volta pelo mesmo canal mTLS
```

Portanto, no C4:

- o mTLS protege o transporte;
- o JWT identifica/autentica a chamada na camada de aplicação;
- a resposta do Inventory também volta criptografada pelo canal mTLS já estabelecido.

### Avaliação

O Cenário 4 faz sentido porque combina dois controles diferentes:

- mTLS: protege o canal e autentica os serviços.
- JWT: identifica a chamada na camada de aplicação.

Esse cenário é importante porque mostra o custo de empilhar os dois mecanismos dentro do código/configuração das aplicações.

## Cenário 5a — Kubernetes sem Istio

Arquivos principais:

- `scenario_5/k8s-app.yaml`
- `scenario_5/service_a/app.py`
- `scenario_5/service_b/app.py`
- `scenario_5/run_scenario_5.sh`
- `scenario_5/common.sh`

### Onde estão Checkout e Inventory

No Kubernetes:

```text
Pod service-a → Checkout
Pod service-b → Inventory
```

O `k8s-app.yaml` cria:

- `ServiceAccount` para `service-a`;
- `ServiceAccount` para `service-b`;
- `Deployment` do `service-a`;
- `Deployment` do `service-b`;
- `Service` do `service-a`;
- `Service` do `service-b`.

No modo baseline, o script desabilita a injeção do Istio:

```bash
kubectl label namespace default istio-injection=disabled --overwrite
```

Assim, os pods sobem sem sidecars Envoy.

### Fluxo

1. O script cria um cluster local com Kind.
2. O script carrega as imagens Docker no cluster.
3. O Kubernetes implanta Checkout e Inventory.
4. O script faz port-forward do serviço `service-a` para a porta local `5005`.
5. O Locust chama:

```text
http://127.0.0.1:5005/api/v1/checkout
```

6. O Checkout chama o Inventory usando o Service interno:

```text
http://service-b:5000/internal/reserve-stock
```

7. O Inventory responde ao Checkout.
8. O Checkout responde ao Locust.

### Segurança aplicada

No C5a, não há Istio e não há mTLS da malha. O cenário serve como baseline Kubernetes.

### Por que C5a é importante

Sem C5a, seria fácil atribuir ao Istio uma diferença que talvez venha apenas da mudança de plataforma Docker → Kubernetes.

O C5a permite comparar:

```text
Kubernetes sem Istio × Kubernetes com Istio
```

Assim, o efeito incremental da malha fica mais defensável.

### Avaliação

O C5a faz sentido e é metodologicamente importante. Ele isola o custo da plataforma Kubernetes antes de avaliar o custo adicional do Istio/Envoy.

## O que é malha de serviços, Istio e Envoy?

Uma malha de serviços, ou *service mesh*, é uma camada de infraestrutura usada para controlar a comunicação entre serviços.

Em uma aplicação de microsserviços, vários serviços chamam uns aos outros pela rede. Sem uma malha, cada aplicação precisa implementar ou configurar diretamente parte das preocupações de comunicação, como:

- autenticação entre serviços;
- criptografia do tráfego;
- autorização;
- políticas de acesso;
- observabilidade;
- métricas;
- roteamento;
- tentativas, timeouts e regras de tráfego.

A ideia da malha é deslocar parte dessas responsabilidades para uma camada comum de infraestrutura. Assim, o código da aplicação pode continuar focado na regra de negócio, enquanto a malha cuida de aspectos de comunicação e segurança.

No contexto deste laboratório, a diferença principal pode ser resumida assim:

```text
Sem malha:
Checkout chama Inventory diretamente.

Com malha:
Checkout → Envoy → Envoy → Inventory.
```

A aplicação continua existindo, mas a comunicação passa por proxies controlados pela malha.

### O que é o Istio?

Istio é uma implementação de malha de serviços. Ele fornece mecanismos para gerenciar, proteger e observar a comunicação entre serviços.

No Cenário 5b, o Istio é usado para aplicar controles como:

- mTLS entre serviços;
- identidade das cargas de trabalho;
- validação de JWT;
- políticas de autorização;
- configuração centralizada do tráfego.

Uma forma simples de entender é:

```text
Istio = plano de controle da malha
```

Ele distribui configurações, certificados e políticas para os componentes que ficam no caminho das requisições.

### O que é o Envoy?

Envoy é o proxy usado pelo Istio no caminho de dados.

No Kubernetes, ele é normalmente injetado como sidecar dentro do mesmo pod da aplicação. No laboratório, quando o Istio está ativo, a estrutura fica assim:

```text
Pod Checkout
  ├── aplicação Checkout
  └── sidecar Envoy

Pod Inventory
  ├── aplicação Inventory
  └── sidecar Envoy
```

O Envoy é quem efetivamente intercepta e processa o tráfego.

Enquanto o Istio define e distribui regras, o Envoy executa essas regras no caminho da requisição.

Uma analogia útil é:

```text
Istio = cérebro/controle
Envoy = executor no caminho da requisição
```

No Cenário 5b:

1. o Checkout envia a requisição;
2. o Envoy do pod Checkout intercepta a saída;
3. o Envoy do Checkout estabelece mTLS com o Envoy do pod Inventory;
4. o Envoy do Inventory valida políticas e JWT conforme configuração recebida do Istio;
5. se a requisição for permitida, ela chega ao Inventory;
6. a resposta volta pelo caminho inverso.

### Por que usar Istio/Envoy no experimento?

O objetivo do C5b é comparar uma implementação em que os controles ficam na infraestrutura com os cenários em que os controles ficam no código/configuração direta das aplicações.

Nos cenários C2, C3 e C4, JWT e mTLS aparecem diretamente no código ou na configuração dos serviços Flask/Gunicorn.

No C5b, parte dessas responsabilidades é delegada para Istio/Envoy:

- o mTLS é estabelecido entre sidecars Envoy;
- a identidade da carga de trabalho vem do Kubernetes/Istio;
- a validação do JWT é aplicada pela infraestrutura antes de chegar ao Inventory;
- o Inventory não precisa implementar diretamente a validação JWT no código Flask.

Isso permite discutir o compromisso arquitetural do *service mesh*: ele melhora a separação de responsabilidades, mas adiciona componentes, consumo de recursos e complexidade operacional.

## Cenário 5b — Kubernetes com Istio/Envoy

Arquivos principais:

- `scenario_5/service_a/app.py`
- `scenario_5/service_b/app.py`
- `scenario_5/k8s-app.yaml`
- `scenario_5/k8s-istio.yaml`
- `scenario_5/run_scenario_5.sh`
- `scenario_5/common.sh`

### Onde estão Checkout e Inventory

No Kubernetes com Istio:

```text
Pod service-a:
  - contêiner service-a → Checkout
  - sidecar Envoy

Pod service-b:
  - contêiner service-b → Inventory
  - sidecar Envoy
```

O Checkout e o Inventory continuam sendo os mesmos serviços de aplicação, mas agora cada pod recebe um sidecar Envoy injetado pelo Istio.

### Fluxo

1. O script cria o cluster Kind.
2. O script instala o Istio.
3. A injeção automática de sidecar é habilitada no namespace.
4. O script implanta Checkout e Inventory.
5. O Checkout gera um JWT RS256.
6. O Checkout chama o Inventory por HTTP local/rede de serviço:

```text
http://service-b:5000/internal/reserve-stock
```

7. O tráfego é interceptado pelos sidecars Envoy.
8. O mTLS ocorre entre os Envoys.
9. O Envoy do lado do Inventory valida políticas de autenticação/autorização.
10. Se as políticas forem satisfeitas, a requisição chega ao código do Inventory.
11. O Inventory processa a reserva.
12. A resposta retorna pelo caminho inverso.

### JWT no C5b

Assim como C2 e C4, o C5b também usa JWT. A diferença é que C2 e C4 usam HS256 validado pela aplicação, enquanto a versão corrigida do C5b usa RS256 validado pela infraestrutura Istio/Envoy.

| Cenário | Usa JWT? | Algoritmo | Quem gera o token? | Quem valida o token? | Chave usada |
|---|---:|---|---|---|---|
| C2 | Sim | HS256 | Checkout | Inventory, no código Flask | Mesmo segredo compartilhado (`JWT_SECRET`) |
| C4 | Sim | HS256 | Checkout | Inventory, no código Flask, depois do canal mTLS ser estabelecido | Mesmo segredo compartilhado (`JWT_SECRET`) |
| C5b | Sim | RS256 | Checkout | Envoy/Istio, antes de liberar a requisição para o Inventory | Chave privada assina; chave pública/JWKS valida |

A diferença principal não é a existência do JWT, pois C4 e C5b usam JWT. A diferença principal é onde e como ele é validado.

No C4, o próprio Inventory executa a validação no código Python. O token chega ao Inventory dentro do canal mTLS, e o decorador `require_jwt` valida assinatura, emissor, sujeito e expiração.

No C5b, o Inventory não implementa validação JWT no Flask. O token é validado pelo Envoy configurado pelo Istio, usando a chave pública exposta em JWKS. Se o token não for aceito, a requisição pode ser bloqueada antes de chegar à aplicação Inventory.

O Checkout gera o token usando uma chave privada:

```python
jwt.encode(
    {
        "iss": JWT_ISSUER,
        "sub": JWT_SUBJECT,
        "iat": now,
        "exp": now + datetime.timedelta(seconds=30),
    },
    get_private_key(),
    algorithm="RS256",
    headers={"kid": JWT_KEY_ID},
)
```

O Checkout também expõe a chave pública em formato JWKS:

```text
/.well-known/jwks.json
```

O Istio usa esse JWKS para validar o token:

```yaml
jwksUri: http://service-a.default.svc.cluster.local:5000/.well-known/jwks.json
```

### mTLS no C5b

O mTLS não é implementado no código Flask. Ele é aplicado pelo Istio/Envoy.

O manifesto `k8s-istio.yaml` define:

```yaml
kind: PeerAuthentication
mtls:
  mode: STRICT
```

Isso exige mTLS para o tráfego destinado ao serviço selecionado.

### Autorização no C5b

O `AuthorizationPolicy` restringe o acesso ao Inventory exigindo:

1. identidade de workload do `service-a`;
2. principal derivado do JWT emitido pelo Checkout.

No manifesto:

```yaml
principals:
  - cluster.local/ns/default/sa/service-a
requestPrincipals:
  - zero-trust-lab/checkout_service
```

Isso significa que não basta enviar qualquer requisição para o Inventory. A chamada precisa vir da identidade esperada e carregar um JWT aceito.

### Como o JWT é validado no C5b

No C5b, o Checkout gera um JWT assinado com RS256. Diferentemente do HS256, o RS256 é assimétrico:

```text
chave privada → assina o token
chave pública → valida o token
```

O Checkout guarda a chave privada e a usa para assinar o token. Ele também disponibiliza a chave pública no endpoint JWKS:

```text
/.well-known/jwks.json
```

O Istio consulta esse JWKS para saber qual chave pública deve usar na validação. Assim, o Envoy consegue verificar se o token foi realmente assinado pela chave privada correspondente, sem precisar conhecer a chave privada.

A validação do JWT ocorre na infraestrutura, antes de a requisição chegar ao código do Inventory. Se o token estiver ausente, expirado, malformado, com emissor incorreto ou assinatura inválida, o Envoy pode bloquear a chamada.

### Como o mTLS funciona no C5b

No C5b, o mTLS não é estabelecido diretamente entre os processos Flask. Ele é estabelecido entre os sidecars Envoy injetados pelo Istio.

O fluxo conceitual é:

```text
Checkout Flask → Envoy do pod Checkout → mTLS → Envoy do pod Inventory → Inventory Flask
```

Isso significa que:

- a aplicação Checkout faz uma chamada HTTP local/normal para o destino configurado;
- o sidecar Envoy do Checkout intercepta a saída;
- o Envoy estabelece mTLS com o Envoy do Inventory;
- o Envoy do Inventory valida políticas e encaminha a requisição ao Inventory Flask;
- a resposta retorna pelo caminho inverso.

Portanto, no C5b, quem termina o mTLS são os sidecars Envoy. O código Flask do Inventory não precisa carregar certificados nem implementar validação TLS diretamente.

### O Inventory valida JWT diretamente?

Não. No C5b, a aplicação Inventory é simples. Ela não contém lógica de JWT.

Quem valida JWT e mTLS é a infraestrutura Istio/Envoy antes de a requisição chegar ao Flask.

Isso representa a delegação dos controles de segurança para a infraestrutura.

### Avaliação

O C5b faz sentido como cenário de service mesh. Ele demonstra bem a diferença entre:

- implementar segurança dentro da aplicação;
- delegar autenticação de workload, mTLS e política para a malha.

Essa versão corrigida é mais adequada do que usar HS256 embutido diretamente em um manifesto, porque RS256 + JWKS é mais compatível com o modo usual de validação JWT em malhas e gateways.

## Explicação das figuras dos cenários

As figuras dos cenários têm o objetivo de mostrar visualmente onde cada controle de comunicação está localizado. Elas não substituem o código, mas ajudam a entender o fluxo de requisição e resposta entre Locust, Checkout e Inventory.

Em todas as figuras, o fluxo funcional é o mesmo:

```text
Locust → Checkout → Inventory → Checkout → Locust
```

O que muda é o mecanismo de segurança aplicado entre Checkout e Inventory.

### Figura 1 — C1: comunicação HTTP simples em Docker

A Figura 1 representa o cenário de referência.

Ela mostra o Locust enviando uma requisição HTTP para o Checkout, que está no contêiner `service_a`. O Checkout então chama o Inventory, no contêiner `service_b`, usando HTTP simples pela rede interna do Docker Compose.

O ponto mais importante da figura é que não há controles adicionais na comunicação interna:

- não há JWT;
- não há mTLS;
- não há Istio;
- não há Envoy.

A resposta do Inventory volta para o Checkout, e o Checkout retorna a resposta final ao Locust.

Essa figura deve ser lida como o baseline funcional usado para comparar os demais cenários.

### Figura 2 — C2: comunicação HTTP com JWT em Docker

A Figura 2 mostra o acréscimo do JWT na comunicação interna.

O Checkout continua recebendo a requisição do Locust por HTTP. Antes de chamar o Inventory, ele gera e assina um JWT com HS256. Esse token é enviado no cabeçalho:

```http
Authorization: Bearer <jwt>
```

O Inventory recebe a requisição, extrai o token do cabeçalho `Authorization` e valida:

- assinatura;
- emissor;
- sujeito;
- expiração;
- campos obrigatórios.

O ponto mais importante da figura é que o JWT protege a chamada na camada de aplicação, mas o transporte continua HTTP.

Também é importante observar que o JWT é assinado, não criptografado. O Inventory valida a assinatura e as declarações, mas não descriptografa o token.

### Figura 3 — C3: comunicação com mTLS na aplicação em Docker

A Figura 3 mostra a comunicação interna protegida por mTLS.

Nesse cenário, o Locust ainda chama o Checkout por HTTP. A diferença está na chamada entre Checkout e Inventory. O Checkout usa um certificado de cliente e o Inventory usa um certificado de servidor. Ambos confiam na CA local do laboratório.

A figura destaca três elementos importantes:

- certificado e chave do Checkout;
- certificado e chave do Inventory;
- CA confiável usada para validar os certificados.

O mTLS autentica os dois lados e estabelece um canal criptografado. Assim, a requisição do Checkout para o Inventory e a resposta do Inventory para o Checkout trafegam pelo mesmo canal protegido.

O ponto central da figura é mostrar que o controle está no transporte, não no token de aplicação.

### Figura 4 — C4: comunicação com mTLS e JWT na aplicação em Docker

A Figura 4 combina os mecanismos das Figuras 2 e 3.

O Checkout gera um JWT HS256, abre um canal mTLS com o Inventory e envia o token dentro desse canal criptografado.

A leitura correta da figura é em duas camadas:

1. primeiro, o mTLS estabelece um canal seguro entre Checkout e Inventory;
2. depois, dentro desse canal, o Inventory valida o JWT recebido no cabeçalho `Authorization`.

Portanto, o C4 possui:

- autenticação e criptografia de transporte com mTLS;
- autenticação de aplicação com JWT.

A resposta do Inventory retorna ao Checkout pelo mesmo canal mTLS.

Essa figura é importante porque mostra que mTLS e JWT não fazem a mesma coisa. O mTLS protege a conexão entre serviços; o JWT identifica e valida a chamada na camada de aplicação.

### Figura 5 — C5a: comunicação entre pods no Kubernetes sem Istio

A Figura 5 mostra a execução da aplicação no Kubernetes local sem Istio.

Nesse cenário, Checkout e Inventory não estão mais em contêineres Docker Compose isolados diretamente, mas em pods do Kubernetes:

```text
Pod service-a → Checkout
Pod service-b → Inventory
```

O Locust acessa o Checkout por meio de port-forward ou exposição controlada para o teste. O Checkout chama o Inventory usando o Service interno do Kubernetes.

O ponto mais importante da figura é que não há sidecar Envoy nem mTLS da malha.

Essa figura existe para mostrar o baseline Kubernetes. Ela permite separar o efeito de mudar de Docker para Kubernetes do efeito de adicionar Istio.

Sem essa figura, seria fácil interpretar incorretamente toda diferença de desempenho como custo do Istio.

### Figura 6 — C5b: comunicação no Kubernetes com Istio/Envoy

A Figura 6 mostra o cenário com malha de serviços.

Nesse caso, cada pod possui a aplicação e um sidecar Envoy:

```text
Pod Checkout
  ├── aplicação Checkout
  └── sidecar Envoy

Pod Inventory
  ├── aplicação Inventory
  └── sidecar Envoy
```

O Checkout gera um JWT RS256. A chamada para o Inventory passa pelos sidecars Envoy. O mTLS ocorre entre os Envoys, e as políticas do Istio controlam se a requisição pode chegar ao Inventory.

O ponto mais importante da figura é que, nesse cenário, os controles não estão todos no código Flask:

- o mTLS é tratado pelos sidecars Envoy;
- a validação do JWT é aplicada pela infraestrutura Istio/Envoy;
- o Inventory não precisa implementar diretamente a validação JWT no código.

A resposta retorna pelo caminho inverso, passando novamente pelos Envoys.

Essa figura representa a delegação de responsabilidades de segurança para a infraestrutura da malha.

### Figura 7 — CPU e memória do C1 em Docker

A Figura 7 apresenta o comportamento de CPU e memória das aplicações no cenário C1, que é o baseline HTTP em Docker.

Ela deve ser usada como referência visual para os demais cenários Docker. Como C1 não possui JWT, mTLS ou Istio, o consumo observado está associado principalmente ao processamento funcional da aplicação, à comunicação HTTP simples e ao funcionamento dos contêineres.

O ponto mais importante é observar como Checkout e Inventory se comportam quando não há controles adicionais de segurança. Isso ajuda a avaliar se os cenários seguintes aumentam de forma perceptível o consumo ou alteram o padrão das curvas.

### Figura 8 — CPU e memória do C2 em Docker

A Figura 8 mostra o cenário C2, no qual há validação JWT na aplicação.

A leitura recomendada é comparar essa figura com a Figura 7. Como C2 adiciona JWT, mas mantém HTTP simples, diferenças entre C1 e C2 podem sugerir o custo operacional da geração e validação do token.

No experimento, os resultados de desempenho de C1 e C2 ficaram próximos. Assim, a figura ajuda a sustentar a interpretação de que o JWT isolado não produziu degradação relevante nas condições avaliadas.

É importante lembrar que isso vale para este laboratório, com tokens curtos, validação local e HS256. Não significa que todo uso de JWT terá sempre baixo custo.

### Figura 9 — CPU e memória do C3 em Docker

A Figura 9 apresenta o cenário C3, com mTLS na comunicação interna entre Checkout e Inventory.

Ela deve ser interpretada em conjunto com a Figura 7, pois C3 acrescenta proteção de transporte em relação ao baseline. O mTLS envolve negociação TLS, certificados e criptografia do canal entre os serviços.

A figura ajuda a observar se esse mecanismo altera o consumo de CPU ou memória das aplicações. Como o mTLS está nos próprios serviços, o custo aparece associado aos contêineres de Checkout e Inventory, e não a sidecars externos.

### Figura 10 — CPU e memória do C4 em Docker

A Figura 10 mostra o cenário C4, que combina mTLS e JWT na aplicação.

Ela deve ser comparada principalmente com as Figuras 8 e 9:

- em relação à Figura 8, C4 adiciona mTLS;
- em relação à Figura 9, C4 adiciona JWT.

A figura representa o cenário Docker mais completo em termos de controles implementados na aplicação. O objetivo é observar se empilhar mTLS e JWT muda o padrão de consumo em relação aos cenários isolados.

No texto do TCC, a interpretação mais segura é dizer que C4 manteve desempenho próximo aos demais cenários Docker sob a carga avaliada, sem afirmar equivalência estatística ampla.

### Figura 11 — CPU e memória do C5a em Kubernetes sem Istio

A Figura 11 apresenta o cenário C5a, isto é, Kubernetes local sem malha de serviços.

Essa figura é muito importante porque serve como controle da plataforma Kubernetes. Ela mostra o comportamento da aplicação quando executada em pods, mas sem sidecars Envoy e sem políticas do Istio.

A comparação mais importante não é apenas C1 contra C5a, porque isso mistura mudança de plataforma e mudança de ambiente de execução. A utilidade principal da Figura 11 é permitir a comparação com a Figura 12.

Ela mostra que parte relevante da diferença de desempenho em relação ao Docker já aparece no Kubernetes sem Istio. Por isso, a perda observada em C5b não deve ser atribuída integralmente à malha.

### Figura 12 — CPU e memória do C5b em Kubernetes com Istio/Envoy

A Figura 12 apresenta o cenário C5b, com Kubernetes, Istio e sidecars Envoy.

Ela mostra as aplicações Python e os sidecars. Essa separação é importante porque, no C5b, parte do trabalho de segurança e comunicação não ocorre dentro do código Flask, mas nos proxies Envoy.

A comparação recomendada é entre Figura 11 e Figura 12:

```text
Figura 11 → Kubernetes sem Istio
Figura 12 → Kubernetes com Istio/Envoy
```

Essa comparação ajuda a observar o efeito incremental da malha. No TCC, os resultados indicaram pequena redução de vazão e aumento moderado de latência em C5b em relação a C5a. A figura complementa essa interpretação mostrando que a malha adiciona componentes e consumo próprio, sem eliminar a limitação de desempenho já observada no Kubernetes sem Istio.

Também é importante tomar cuidado com médias simples de CPU no C5b, porque a inclusão de sidecars altera o conjunto de contêineres. Uma média menor por contêiner não significa necessariamente menor custo total do cenário.

### Por que o `service_a`/Checkout consome mais CPU e memória em várias figuras?

Nas Figuras 8, 9, 10 e 11, é esperado que o `service_a`, isto é, o Checkout, apresente consumo de CPU e memória maior que o `service_b`/Inventory em vários momentos.

Isso acontece porque os dois serviços não executam exatamente o mesmo papel no fluxo.

O Checkout é o ponto de entrada da aplicação. Ele recebe todas as requisições do Locust e, para cada requisição externa, inicia uma chamada interna para o Inventory. Assim, ele atua ao mesmo tempo como:

- servidor HTTP para o Locust;
- cliente HTTP/HTTPS do Inventory;
- agregador da resposta final;
- componente responsável por medir `internal_latency_ms`;
- em alguns cenários, emissor de JWT;
- em alguns cenários, cliente mTLS.

O Inventory, por outro lado, executa uma função mais simples: recebe a chamada interna, valida o que for necessário e retorna a reserva do item. Ele não chama outro serviço depois disso.

De forma simplificada:

```text
Checkout:
Locust → recebe requisição
Checkout → monta payload
Checkout → gera JWT, quando aplicável
Checkout → abre/chama conexão interna
Checkout → espera Inventory
Checkout → monta resposta final

Inventory:
Inventory → recebe chamada interna
Inventory → valida entrada/JWT, quando aplicável
Inventory → retorna reserva
```

Por isso, o Checkout tende a ter mais trabalho por requisição.

### Explicação por cenário

Na Figura 8, o C2 adiciona JWT. O Checkout gera e assina o token antes de chamar o Inventory. O Inventory valida o token, mas o Checkout continua acumulando o papel de receber a carga externa e iniciar a chamada interna.

Na Figura 9, o C3 adiciona mTLS. O Checkout atua como cliente mTLS na chamada para o Inventory, usando certificado, chave privada e validação da CA. Esse trabalho ocorre além de receber a requisição externa.

Na Figura 10, o C4 combina mTLS e JWT. O Checkout gera o JWT e também inicia a conexão mTLS. Por isso, faz sentido que ele tenha carga maior do que o Inventory, que recebe, valida e responde.

Na Figura 11, o C5a executa a aplicação no Kubernetes sem Istio. O Checkout continua sendo o ponto de entrada acessado pelo Locust e o responsável por chamar o Inventory dentro do cluster. Além disso, o caminho de entrada via Kubernetes/port-forward e a chamada interna pelo Service do cluster mantêm o Checkout como componente central do fluxo.

### Por que a memória também pode ser maior?

A memória do Checkout também pode ser maior porque ele carrega mais bibliotecas e mantém mais estruturas em execução, como:

- cliente HTTP `requests`;
- sessão HTTP reutilizável;
- adaptador de conexões;
- bibliotecas de JWT nos cenários com token;
- configuração de certificados nos cenários com mTLS;
- workers e threads do Gunicorn processando a entrada externa.

Além disso, pequenas diferenças de memória entre serviços Flask/Gunicorn podem ocorrer por importações, bibliotecas carregadas e comportamento dos workers durante a carga.

### Como explicar isso no TCC

Uma explicação resumida e segura seria:

> O maior consumo do Checkout em vários cenários é coerente com seu papel no fluxo experimental. O serviço A é o ponto de entrada da carga, recebe as requisições do Locust, prepara a chamada ao Inventory, aplica controles como emissão de JWT ou configuração mTLS quando necessário e consolida a resposta final. O Inventory executa uma operação mais restrita, recebendo a chamada interna, validando os controles aplicáveis e retornando a reserva. Assim, as curvas de CPU e memória refletem não apenas os mecanismos de segurança, mas também a diferença de responsabilidade entre os serviços.

Essa interpretação é mais defensável do que afirmar que todo aumento de CPU ou memória foi causado apenas por JWT, mTLS ou Kubernetes. O desenho da aplicação também influencia o consumo observado.

### Como usar as figuras na explicação do TCC

Uma forma resumida de apresentar as figuras é:

> As figuras mostram a evolução dos controles de comunicação. O C1 representa a comunicação HTTP simples. O C2 adiciona autenticação por JWT na aplicação. O C3 adiciona mTLS no transporte. O C4 combina mTLS e JWT na aplicação. O C5a mostra a mesma aplicação em Kubernetes sem malha, servindo como controle da plataforma. O C5b adiciona Istio/Envoy, deslocando mTLS e validação de políticas para a infraestrutura.

Essa leitura ajuda a justificar por que as comparações devem ser feitas em pares coerentes:

- C1 × C2: efeito do JWT em Docker;
- C1 × C3: efeito do mTLS em Docker;
- C3 × C4: efeito adicional do JWT sobre mTLS;
- C5a × C5b: efeito incremental do Istio/Envoy sobre Kubernetes.

## Por que existem Dockerfile e Docker Compose?

Nos cenários Docker, aparecem dois tipos de arquivo que têm responsabilidades diferentes:

- `Dockerfile`;
- `docker-compose.yml`.

Eles não fazem a mesma coisa.

### Papel do Dockerfile

O Dockerfile serve para construir a imagem de um serviço específico.

Ele responde à pergunta:

```text
Como empacotar e executar esta aplicação?
```

Por exemplo, o Dockerfile do Checkout define:

```dockerfile
FROM python:3.11.9-slim-bookworm
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install -r requirements.txt
COPY app.py .
CMD ["gunicorn", "...", "app:app"]
```

Isso significa que o Dockerfile define:

- a imagem base do Python;
- o diretório de trabalho;
- as dependências instaladas;
- os arquivos da aplicação copiados para a imagem;
- o comando usado para iniciar o serviço.

No laboratório, cada serviço tem seu próprio Dockerfile:

```text
scenario_X/service_a/Dockerfile → imagem do Checkout
scenario_X/service_b/Dockerfile → imagem do Inventory
```

Essa separação faz sentido porque Checkout e Inventory são serviços diferentes. Mesmo quando os Dockerfiles são parecidos, cada um constrói a imagem de uma aplicação própria.

### Papel do Docker Compose

O Docker Compose serve para subir o cenário experimental completo.

Ele responde à pergunta:

```text
Como os serviços rodam juntos?
```

O `docker-compose.yml` define:

- quais serviços fazem parte do cenário;
- como construir o Checkout;
- como construir o Inventory;
- qual porta será publicada no host;
- quais serviços ficam apenas na rede interna;
- quais variáveis de ambiente serão passadas;
- quais certificados serão montados;
- qual serviço depende do outro;
- quais healthchecks serão usados;
- qual rede Docker conecta os contêineres.

Exemplo conceitual:

```yaml
services:
  service_a:
    build: ./service_a
    ports:
      - "5000:5000"
    environment:
      INVENTORY_URL: http://service_b:5000/internal/reserve-stock
    depends_on:
      service_b:
        condition: service_healthy

  service_b:
    build: ./service_b
    networks: [internal]
```

Nesse exemplo, o Compose:

1. constrói a imagem do Checkout;
2. constrói a imagem do Inventory;
3. cria a rede interna;
4. sobe o Inventory;
5. espera o Inventory ficar saudável;
6. sobe o Checkout;
7. publica apenas o Checkout em `localhost:5000`;
8. permite que o Checkout acesse o Inventory pelo nome `service_b`.

### Por que isso não fica tudo no Dockerfile?

Algumas partes poderiam até ser colocadas no Dockerfile, mas isso misturaria responsabilidades.

O Dockerfile do Checkout não deve saber como subir o Inventory. Ele deve apenas construir a imagem do Checkout.

Da mesma forma, o Dockerfile do Inventory não deve saber qual porta do host será usada pelo Checkout, nem qual será a ordem de inicialização dos serviços.

A separação correta é:

```text
Dockerfile
  → constrói uma imagem de um serviço

docker-compose.yml
  → sobe vários serviços e conecta eles
```

No laboratório:

```text
service_a/Dockerfile
  → imagem do Checkout

service_b/Dockerfile
  → imagem do Inventory

docker-compose.yml
  → cenário completo: Checkout + Inventory + rede + portas + variáveis + certificados
```

### Exposição de portas

Nos cenários Docker, normalmente apenas o Checkout é publicado no host:

```yaml
service_a:
  ports:
    - "5000:5000"
```

Isso permite que o Locust chame:

```text
http://localhost:5000/api/v1/checkout
```

O Inventory não é publicado diretamente no host. Ele fica acessível apenas dentro da rede interna do Docker Compose, pelo nome:

```text
http://service_b:5000/internal/reserve-stock
```

Essa decisão faz sentido para o experimento, porque o Inventory representa um serviço interno. O ponto de entrada externo é o Checkout.

## Locust e geração de carga

Arquivo principal:

- `tests/locustfile.py`

O Locust chama sempre o endpoint externo do Checkout:

```text
POST /api/v1/checkout
```

Payload usado:

```json
{
  "item_id": "SKU-999",
  "quantity": 1
}
```

O Locust valida se:

1. a resposta HTTP foi `200`;
2. o JSON retornado possui `status: success`;
3. o campo `inventory_status.status` é `reserved`.

Isso é importante porque evita contar como sucesso uma resposta HTTP que não tenha produzido a reserva esperada.

## Os resultados, tabelas e dados fazem sentido?

Sim, os resultados fazem sentido dentro do desenho experimental adotado, desde que sejam interpretados como resultados de laboratório e não como uma regra universal sobre Docker, Kubernetes, Istio, JWT ou mTLS.

Os arquivos principais dos resultados finais são:

- `runs.csv`: contém uma linha por rodada e por cenário;
- `summary_by_scenario.csv`: consolida médias e desvios-padrão das três rodadas;
- `resource_summary_by_run.csv`: resume consumo de CPU por rodada e cenário.

### Como explicar as tabelas de forma resumida

A lógica das tabelas é a seguinte:

1. `runs.csv` mostra o que aconteceu em cada execução individual.
2. `summary_by_scenario.csv` calcula médias e desvios-padrão a partir dessas execuções.
3. `resource_summary_by_run.csv` ajuda a interpretar consumo de recursos, mas deve ser lido com cuidado porque Docker e Kubernetes usam unidades diferentes.

Assim, a Tabela 3 do TCC resume o desempenho observado em três rodadas por cenário, usando vazão, latência média, P50 e P95.

### O padrão dos resultados é coerente?

O padrão geral é coerente. Nos cenários Docker C1 a C4, a vazão média ficou muito próxima:

```text
C1: 507,36 req/s
C2: 506,11 req/s
C3: 507,58 req/s
C4: 515,30 req/s
```

Isso indica que, nas condições do experimento, adicionar JWT, mTLS ou mTLS+JWT na aplicação não produziu queda relevante de vazão média em relação ao baseline HTTP.

Também faz sentido observar que as latências médias de C1 a C4 ficaram próximas, com variação entre rodadas. Como houve apenas três rodadas, pequenas diferenças entre C1, C2, C3 e C4 não devem ser apresentadas como prova estatística de superioridade de um cenário sobre outro. A interpretação mais segura é dizer que os cenários Docker apresentaram desempenho semelhante sob a carga avaliada.

### Por que Kubernetes ficou pior que Docker?

Os cenários Kubernetes tiveram vazão menor e latência maior:

```text
C5a — Kubernetes sem Istio: 187,53 req/s e 723,62 ms
C5b — Kubernetes com Istio: 181,52 req/s e 756,94 ms
```

Isso também é coerente, porque C5a e C5b mudam a plataforma de execução. Eles não são apenas “Docker com mais segurança”; eles passam a usar Kubernetes local com Kind, pods, services, rede do cluster, métricas e, no C5b, sidecars Envoy.

Por isso, a principal conclusão não deve ser que “Istio causou toda a perda em relação ao Docker”. O controle C5a mostra que grande parte da diferença já aparece no Kubernetes sem Istio.

A comparação mais justa para medir o efeito incremental da malha é:

```text
C5a — Kubernetes sem Istio
versus
C5b — Kubernetes com Istio
```

Nessa comparação, o C5b teve:

- queda de vazão de aproximadamente 3,21%;
- aumento de latência média de aproximadamente 4,60%.

Essa diferença é compatível com a inclusão da malha, dos sidecars e das políticas, mas ainda deve ser interpretada dentro das limitações do laboratório.

### O fato de não ter falhas faz sentido?

Sim. Todas as execuções registraram zero falhas. Isso sugere que, durante a carga aplicada, os serviços responderam corretamente do ponto de vista operacional.

Mas isso não significa que o sistema foi validado contra todos os tipos de falha ou ataque. A ausência de falhas no Locust quer dizer apenas que, nas requisições executadas, o endpoint respondeu com sucesso conforme o critério do teste.

Ela não comprova, por exemplo:

- resistência a tokens adulterados;
- rejeição de certificados inválidos;
- comportamento com serviço indisponível;
- consistência transacional real de estoque;
- segurança completa no sentido amplo de Zero Trust.

### Como explicar CPU e memória com cuidado

Os dados de CPU também fazem sentido, mas exigem cuidado porque as unidades são diferentes.

Nos cenários Docker, a CPU aparece em percentual. Nos cenários Kubernetes, aparece em millicores. Portanto, não é ideal comparar diretamente uma média de CPU Docker com uma média Kubernetes sem explicar a diferença de unidade e de composição dos contêineres.

Além disso, no Kubernetes com Istio, existem mais contêineres envolvidos, porque cada pod pode ter a aplicação e o sidecar Envoy. Então uma média simples por contêiner pode não representar o custo total do cenário.

Por isso, a explicação mais segura é:

```text
Os dados de CPU e memória ajudam a caracterizar o comportamento observado, mas não devem ser usados isoladamente como medida definitiva de custo total.
```

### Resumo interpretativo recomendado

Uma forma curta e defensável de explicar os resultados seria:

> Os resultados indicam que, nas configurações Docker avaliadas, os mecanismos JWT, mTLS e mTLS+JWT mantiveram vazão e latência próximas ao cenário HTTP sem proteção adicional. A maior diferença de desempenho apareceu na transição para Kubernetes, observada já no cenário C5a, antes da inclusão do Istio. Assim, o efeito da malha deve ser interpretado pela comparação entre C5a e C5b, na qual o Istio/Envoy acrescentou pequena redução de vazão e aumento moderado de latência. Como o estudo foi executado em um único host local e com três rodadas por cenário, os resultados devem ser tratados como evidência experimental descritiva, não como conclusão universal ou estatisticamente generalizável.

### O que as tabelas sustentam

As tabelas sustentam bem as seguintes conclusões:

- C1 a C4 tiveram desempenho semelhante no ambiente Docker.
- JWT isolado não mostrou custo relevante no experimento.
- mTLS na aplicação também não reduziu a vazão média de forma evidente nas condições medidas.
- A mudança para Kubernetes teve impacto muito maior que a inclusão isolada do Istio.
- C5b apresentou custo incremental em relação a C5a, mas não explica sozinho a diferença entre Docker e Kubernetes.
- A ausência de falhas mostra estabilidade operacional durante a carga, mas não comprova segurança completa.

### O que as tabelas não sustentam

As tabelas não devem ser usadas para afirmar que:

- JWT sempre tem custo desprezível em qualquer sistema;
- mTLS nunca impacta desempenho;
- Docker é sempre mais rápido que Kubernetes;
- Istio sempre terá apenas esse custo percentual;
- o sistema implementa Zero Trust completo;
- os resultados têm significância estatística ampla.

Essas afirmações exigiriam mais ambientes, mais rodadas, testes negativos, variação de carga e análise estatística mais ampla.

## O código faz sentido?

Sim, considerando a pasta `tcc-zero-trust-microsservicos`, o código faz sentido para o objetivo do TCC.

Os pontos positivos são:

- separa claramente Checkout e Inventory;
- mantém o mesmo fluxo funcional em todos os cenários;
- isola o efeito do JWT no C2;
- isola o efeito do mTLS no C3;
- combina mTLS e JWT no C4;
- separa Kubernetes sem Istio de Kubernetes com Istio;
- usa RS256 + JWKS no cenário Istio;
- valida resposta funcional no Locust;
- inclui timeouts para evitar travamentos;
- registra `internal_latency_ms` como métrica diagnóstica.

Alguns cuidados metodológicos:

- `internal_latency_ms` não substitui a latência medida pelo Locust.
- O C2 e C4 usam HS256, adequado para laboratório, mas menos representativo que RS256/OIDC em produção.
- O C5b depende da correta injeção dos sidecars Envoy e da aplicação dos manifests do Istio.
- Os resultados representam este laboratório específico, não desempenho universal de Docker, Kubernetes ou Istio.

## Resumo final

| Cenário | Plataforma | Comunicação interna | Controle principal |
|---|---|---|---|
| C1 | Docker | HTTP | Sem segurança adicional |
| C2 | Docker | HTTP + JWT | Token assinado na aplicação |
| C3 | Docker | HTTPS com mTLS | Certificados nos serviços |
| C4 | Docker | HTTPS com mTLS + JWT | Canal seguro + token |
| C5a | Kubernetes | HTTP entre pods | Baseline Kubernetes |
| C5b | Kubernetes + Istio | mTLS entre sidecars + JWT | Segurança delegada ao Istio/Envoy |

