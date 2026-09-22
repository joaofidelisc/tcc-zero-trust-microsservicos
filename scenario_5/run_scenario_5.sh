#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCENARIO_DIR/common.sh"

REPETITIONS="${REPETITIONS:-3}"
DURATION="${DURATION:-60s}"
DURATION_SECS="${DURATION%s}"
USERS="${USERS:-50}"
SPAWN_RATE="${SPAWN_RATE:-10}"
WARMUP_SECONDS="${WARMUP_SECONDS:-10}"
EXPERIMENT_ID="${EXPERIMENT_ID:-experiment_$(date +%Y%m%d_%H%M%S)}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:-$LAB_DIR/tests/runs/$EXPERIMENT_ID}"
LOCUSTFILE="$LAB_DIR/tests/locustfile.py"
PF_PID=""
METRICS_PID=""

cleanup() {
    if [ -n "${METRICS_PID:-}" ] && kill -0 "$METRICS_PID" 2>/dev/null; then
        kill "$METRICS_PID" 2>/dev/null || true
        wait "$METRICS_PID" 2>/dev/null || true
    fi
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
printf 'round,position,mode,started_at\n' >"$EXPERIMENT_DIR/scenario_5_order.csv"

for round_number in $(seq 1 "$REPETITIONS"); do
    round_dir="$EXPERIMENT_DIR/round_$(printf '%02d' "$round_number")"
    mkdir -p "$round_dir"
    position=0
    for mode in $(printf 'baseline\nmesh\n' | shuf); do
        position=$((position + 1))
        printf '%s,%s,%s,%s\n' "$round_number" "$position" "$mode" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/scenario_5_order.csv"
        cleanup
        create_cluster
        install_metrics_server
        if [ "$mode" = "mesh" ]; then
            install_istio
        fi
        deploy_apps "$mode"
        start_port_forward "$round_dir/port_forward_$mode.log"
        validate_checkout
        if [ "$mode" = "mesh" ]; then
            validate_mesh_rejection_without_jwt
            result_name="scenario_5_mesh"
        else
            result_name="scenario_5_k8s_baseline"
        fi
        result_dir="$round_dir/$result_name"
        mkdir -p "$result_dir"
        sleep "$WARMUP_SECONDS"
        collect_k8s_metrics "$((DURATION_SECS + 5))" "$result_dir/resources.csv" &
        METRICS_PID=$!
        "$LOCUST_BIN" -f "$LOCUSTFILE" --headless -u "$USERS" -r "$SPAWN_RATE" -t "$DURATION" -H http://127.0.0.1:5005 --csv="$result_dir/results" --csv-full-history
        wait "$METRICS_PID" || true
        METRICS_PID=""
        stop_port_forward
        delete_cluster
    done
done

"$ANALYSIS_PYTHON" "$LAB_DIR/tests/generate_graphs.py" "$EXPERIMENT_DIR"
echo "Cenário 5 concluído em $EXPERIMENT_DIR"
