#!/usr/bin/env bash
# Executa C5a (Kubernetes sem malha) e C5b (Kubernetes com Istio/Envoy). Para o experimento
# completo, com os seis cenários intercalados, use run_experiment.sh na raiz do laboratório.
set -Eeuo pipefail

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCENARIO_DIR/common.sh"
source "$LAB_DIR/lib/measure.sh"

REPETITIONS="${REPETITIONS:-3}"
ROUND_START="${ROUND_START:-1}"
MODES="${MODES:-baseline mesh}"
DURATION="${DURATION:-60s}"
DURATION_SECS="${DURATION%s}"
USERS="${USERS:-50}"
SPAWN_RATE="${SPAWN_RATE:-10}"
WARMUP_SECONDS="${WARMUP_SECONDS:-15}"
SKIP_ANALYSIS="${SKIP_ANALYSIS:-0}"
EXPERIMENT_ID="${EXPERIMENT_ID:-experiment_$(date +%Y%m%d_%H%M%S)}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:-$LAB_DIR/tests/runs/$EXPERIMENT_ID}"
LOCUSTFILE="$LAB_DIR/tests/locustfile.py"
PF_PID=""
METRICS_PID=""
HOST_PID=""
STAT_PID=""

cleanup() {
    for pid_var in METRICS_PID HOST_PID STAT_PID; do
        local pid="${!pid_var:-}"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        printf -v "$pid_var" '%s' ""
    done
    stop_port_forward
    delete_cluster
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_tools true
LOCUST_BIN="$(locust_binary)"
ANALYSIS_PYTHON="$(analysis_python)"
if [ -e "$EXPERIMENT_DIR" ] && [ "${ALLOW_EXISTING_EXPERIMENT:-0}" != "1" ]; then
    echo "O diretório de experimento já existe e não será sobrescrito: $EXPERIMENT_DIR" >&2
    exit 3
fi
generate_signing_key
build_images
mkdir -p "$EXPERIMENT_DIR"
[ -f "$EXPERIMENT_DIR/scenario_5_order.csv" ] || printf 'round,position,mode,started_at\n' >"$EXPERIMENT_DIR/scenario_5_order.csv"
if ! grep -q '^kind=' "$EXPERIMENT_DIR/metadata.env" 2>/dev/null; then
    {
        printf 'kind=%s\n' "$KIND_VERSION"
        printf 'kubernetes=%s\n' "$KUBECTL_VERSION"
        printf 'istio=%s\n' "$ISTIO_VERSION"
        printf 'metrics_server=%s\n' "$METRICS_SERVER_VERSION"
        printf 'kind_node_image=%s\n' "$KIND_NODE_IMAGE"
        printf 'k8s_access=%s\n' "${ACCESS_MODE:-nodeport}"
    } >>"$EXPERIMENT_DIR/metadata.env"
fi

round_end=$((ROUND_START + REPETITIONS - 1))
for round_number in $(seq "$ROUND_START" "$round_end"); do
    round_dir="$EXPERIMENT_DIR/round_$(printf '%02d' "$round_number")"
    mkdir -p "$round_dir"
    position=0
    for mode in $(printf '%s\n' $MODES | shuf); do
        position=$((position + 1))
        printf '%s,%s,%s,%s\n' "$round_number" "$position" "$mode" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/scenario_5_order.csv"
        if [ "$mode" = "mesh" ]; then
            result_name="scenario_5_mesh"
        else
            result_name="scenario_5_k8s_baseline"
        fi
        result_dir="$round_dir/$result_name"
        mkdir -p "$result_dir"
        echo "==> $(basename "$round_dir") $result_name"
        cleanup
        create_cluster
        install_metrics_server
        if [ "$mode" = "mesh" ]; then
            install_istio
        fi
        deploy_apps "$mode"
        start_port_forward "$result_dir/access.log"
        validate_checkout
        if [ "$mode" = "mesh" ]; then
            validate_mesh_rejection_without_jwt
            printf 'mesh_rejection_without_jwt=ok\n' >"$result_dir/security_check.txt"
            kubectl get pod -l app=service-a -o jsonpath='{.items[0].spec.containers[?(@.name=="istio-proxy")].resources}{.items[0].spec.initContainers[?(@.name=="istio-proxy")].resources}' >"$result_dir/sidecar_resources.json" 2>/dev/null || true
        fi
        run_warmup http://127.0.0.1:5005 "$result_dir/warmup.log"

        ramp="$(ramp_seconds)"
        sample_host "$result_dir/host.csv" &
        HOST_PID=$!
        collect_k8s_metrics "$((DURATION_SECS + ramp + 5))" "$result_dir/resources.csv" &
        METRICS_PID=$!
        (sleep "$ramp"; capture_cpu_stat_k8s start "$result_dir/cpu_stat.csv") &
        STAT_PID=$!
        run_measured_locust http://127.0.0.1:5005 "$result_dir"
        capture_cpu_stat_k8s end "$result_dir/cpu_stat.csv"
        wait "$STAT_PID" 2>/dev/null || true
        wait "$METRICS_PID" || true
        kill "$HOST_PID" 2>/dev/null || true
        wait "$HOST_PID" 2>/dev/null || true
        METRICS_PID=""; HOST_PID=""; STAT_PID=""
        stop_port_forward
        delete_cluster
    done
done

if [ "$SKIP_ANALYSIS" != "1" ]; then
    "$ANALYSIS_PYTHON" "$LAB_DIR/tests/generate_graphs.py" "$EXPERIMENT_DIR"
fi
echo "Cenário 5 concluído em $EXPERIMENT_DIR"
