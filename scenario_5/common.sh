#!/usr/bin/env bash

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCENARIO_DIR/.." && pwd)"
BIN_DIR="$SCENARIO_DIR/bin"
RUNTIME_DIR="$SCENARIO_DIR/runtime-secrets"
source "$SCENARIO_DIR/versions.env"

CLUSTER_NAME="${CLUSTER_NAME:-zt-lab-corrected}"
SERVICE_A_IMAGE="zero-trust-lab-service-a:corrected-v2"
SERVICE_B_IMAGE="zero-trust-lab-service-b:corrected-v2"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml"
export PATH="$BIN_DIR:$PATH"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Comando obrigatório ausente: $1" >&2
        return 1
    fi
}

require_tools() {
    local needs_istio="${1:-false}"
    for command_name in docker kind kubectl curl openssl awk sed; do
        require_command "$command_name"
    done
    if [ "$needs_istio" = "true" ]; then
        require_command istioctl
        if ! istioctl version --remote=false 2>/dev/null | grep -q "$ISTIO_VERSION"; then
            echo "A versão fixada do Istio é $ISTIO_VERSION. Execute ./install_tools.sh." >&2
            return 1
        fi
    fi
}

locust_binary() {
    if [ -x "$LAB_DIR/venv/bin/locust" ]; then
        printf '%s\n' "$LAB_DIR/venv/bin/locust"
    elif command -v locust >/dev/null 2>&1; then
        command -v locust
    else
        echo "Locust ausente. Execute ./setup.sh na raiz de tcc-zero-trust-microsservicos." >&2
        return 1
    fi
}

analysis_python() {
    if [ -x "$LAB_DIR/venv/bin/python" ]; then
        printf '%s\n' "$LAB_DIR/venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        command -v python3
    else
        echo "Python 3 ausente. Execute ./setup.sh na raiz de tcc-zero-trust-microsservicos." >&2
        return 1
    fi
}

build_images() {
    docker build -t "$SERVICE_A_IMAGE" "$SCENARIO_DIR/service_a"
    docker build -t "$SERVICE_B_IMAGE" "$SCENARIO_DIR/service_b"
}

generate_signing_key() {
    # Mesmo par RSA de 3.072 bits usado em C2 e C4 (certs/generate_jwt_keys.sh).
    bash "$LAB_DIR/certs/generate_jwt_keys.sh"
    mkdir -p "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"
    cp "$LAB_DIR/certs/jwt_private.pem" "$RUNTIME_DIR/jwt-private.pem"
    cp "$LAB_DIR/certs/jwt_public.pem" "$RUNTIME_DIR/jwt-public.pem"
    chmod 600 "$RUNTIME_DIR/jwt-private.pem"
    chmod 644 "$RUNTIME_DIR/jwt-public.pem"
}

cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

delete_cluster() {
    if cluster_exists; then
        kind delete cluster --name "$CLUSTER_NAME"
    fi
}

create_cluster() {
    if cluster_exists; then
        echo "O cluster $CLUSTER_NAME já existe. Encerre-o antes de continuar." >&2
        return 1
    fi
    kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$SCENARIO_DIR/kind-config.yaml" --wait 180s
    kind load docker-image "$SERVICE_A_IMAGE" "$SERVICE_B_IMAGE" --name "$CLUSTER_NAME"
}

install_metrics_server() {
    kubectl apply -f "$METRICS_SERVER_URL"
    kubectl patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
    for attempt in $(seq 1 30); do
        if kubectl top nodes >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "Metrics Server iniciou, mas ainda não publicou métricas." >&2
    return 1
}

install_istio() {
    istioctl install --set profile=default -y
    kubectl label namespace default istio-injection=enabled --overwrite
}

create_jwt_secret() {
    kubectl create secret generic jwt-signing-key --from-file=jwt-private.pem="$RUNTIME_DIR/jwt-private.pem" --from-file=jwt-public.pem="$RUNTIME_DIR/jwt-public.pem" --dry-run=client -o yaml | kubectl apply -f -
}

deploy_apps() {
    local mode="$1"
    if [ "$mode" = "baseline" ]; then
        kubectl label namespace default istio-injection=disabled --overwrite
    fi
    local sign_jwt="false"
    if [ "$mode" = "mesh" ]; then
        sign_jwt="true"
    fi
    create_jwt_secret
    sed "s/__SIGN_JWT__/$sign_jwt/" "$SCENARIO_DIR/k8s-app.yaml" | kubectl apply -f -
    kubectl rollout status deployment/service-a --timeout=180s
    kubectl rollout status deployment/service-b --timeout=180s
    if [ "$mode" = "mesh" ]; then
        kubectl apply -f "$SCENARIO_DIR/k8s-istio.yaml"
        kubectl wait --for=condition=Ready pod -l app=service-a --timeout=180s
        kubectl wait --for=condition=Ready pod -l app=service-b --timeout=180s
    fi
}

start_port_forward() {
    # Mantido o nome por compatibilidade. Por padrão o acesso usa a NodePort mapeada
    # pelo Kind (ACCESS_MODE=nodeport); ACCESS_MODE=portforward reproduz o desenho antigo.
    local log_file="$1"
    if [ "${ACCESS_MODE:-nodeport}" = "portforward" ]; then
        kubectl port-forward service/service-a 5005:5000 >"$log_file" 2>&1 &
        PF_PID=$!
    else
        printf 'acesso via NodePort 30500 mapeada em 127.0.0.1:5005\n' >"$log_file"
    fi
    for attempt in $(seq 1 60); do
        if curl -fsS --max-time 2 http://127.0.0.1:5005/health >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "O Checkout não respondeu em 127.0.0.1:5005; consulte $log_file." >&2
    return 1
}

stop_port_forward() {
    if [ -n "${PF_PID:-}" ] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
    PF_PID=""
}

collect_k8s_metrics() {
    local duration="$1"
    local output_file="$2"
    printf 'timestamp,pod,container,cpu_millicores,mem_mib\n' >"$output_file"
    local end_time=$((SECONDS + duration))
    while [ "$SECONDS" -lt "$end_time" ]; do
        while read -r pod container cpu_raw memory_raw; do
            [ -n "$pod" ] || continue
            case "$cpu_raw" in
                *m) cpu_value="${cpu_raw%m}" ;;
                *n) cpu_value="$(awk -v value="${cpu_raw%n}" 'BEGIN {printf "%.3f", value/1000000}')" ;;
                *) cpu_value="$(awk -v value="$cpu_raw" 'BEGIN {printf "%.3f", value*1000}')" ;;
            esac
            case "$memory_raw" in
                *Ki) memory_value="$(awk -v value="${memory_raw%Ki}" 'BEGIN {printf "%.3f", value/1024}')" ;;
                *Mi) memory_value="${memory_raw%Mi}" ;;
                *Gi) memory_value="$(awk -v value="${memory_raw%Gi}" 'BEGIN {printf "%.3f", value*1024}')" ;;
                *) memory_value="$memory_raw" ;;
            esac
            printf '%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$pod" "$container" "$cpu_value" "$memory_value" >>"$output_file"
        done < <(kubectl top pods --containers --no-headers 2>/dev/null || true)
        sleep 3
    done
}

validate_checkout() {
    # Logo após a criação do cluster, o DNS interno e as regras de rede do service-b podem
    # ainda não estar ativos; tenta por até ~60 s antes de considerar falha.
    kubectl rollout status deployment/coredns -n kube-system --timeout=120s >/dev/null
    for attempt in $(seq 1 30); do
        if curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5005/api/v1/checkout 2>/dev/null | python3 -c 'import json,sys; body=json.load(sys.stdin); assert body.get("status")=="success"; assert body.get("inventory_status",{}).get("status")=="reserved"' 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "O Checkout não concluiu uma compra válida em 127.0.0.1:5005." >&2
    return 1
}

validate_mesh_rejection_without_jwt() {
    status="$(kubectl exec deploy/service-a -c service-a -- python -c "import urllib.error,urllib.request; req=urllib.request.Request('http://service-b:5000/internal/reserve-stock', data=b'{\"item_id\":\"SKU-999\",\"quantity\":1}', headers={'Content-Type':'application/json'}, method='POST'); exec(\"try:\\n urllib.request.urlopen(req, timeout=3)\\n print(200)\\nexcept urllib.error.HTTPError as error:\\n print(error.code)\")")"
    if [ "$status" != "401" ] && [ "$status" != "403" ]; then
        echo "A chamada sem JWT deveria falhar com 401/403, mas retornou $status." >&2
        return 1
    fi
}
