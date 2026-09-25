#!/usr/bin/env bash
# Executa os cenários Docker (C1–C4). Para o experimento completo, com os seis cenários
# intercalados em cada rodada, use run_experiment.sh, que chama este script por cenário.
set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LAB_DIR/lib/measure.sh"
RESULTS_ROOT="$LAB_DIR/tests/runs"
LOCUSTFILE="$LAB_DIR/tests/locustfile.py"
REPETITIONS="${REPETITIONS:-5}"
ROUND_START="${ROUND_START:-1}"
SCENARIOS="${SCENARIOS:-scenario_1 scenario_2 scenario_3 scenario_4}"
DURATION="${DURATION:-60s}"
DURATION_SECS="${DURATION%s}"
USERS="${USERS:-50}"
SPAWN_RATE="${SPAWN_RATE:-10}"
WARMUP_SECONDS="${WARMUP_SECONDS:-15}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-5}"
INCLUDE_SCENARIO_5="${INCLUDE_SCENARIO_5:-0}"
SKIP_ANALYSIS="${SKIP_ANALYSIS:-0}"
export CPU_LIMIT="${CPU_LIMIT:-1.0}"
export MEM_LIMIT="${MEM_LIMIT:-256m}"
EXPERIMENT_ID="${EXPERIMENT_ID:-experiment_$(date +%Y%m%d_%H%M%S)}"
EXPERIMENT_DIR="${EXPERIMENT_DIR:-$RESULTS_ROOT/$EXPERIMENT_ID}"

CURRENT_SCENARIO=""
CPU_PID=""
HOST_PID=""
STAT_PID=""

cleanup() {
    for pid_var in CPU_PID HOST_PID STAT_PID; do
        local pid="${!pid_var:-}"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        printf -v "$pid_var" '%s' ""
    done
    if [ -n "${CURRENT_SCENARIO:-}" ] && [ -d "$LAB_DIR/$CURRENT_SCENARIO" ]; then
        docker compose -f "$LAB_DIR/$CURRENT_SCENARIO/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in docker curl openssl shuf awk; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Comando obrigatório ausente: $command_name" >&2
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 ('docker compose') é obrigatório." >&2
    exit 1
fi

if [ -x "$LAB_DIR/venv/bin/locust" ]; then
    LOCUST_BIN="$LAB_DIR/venv/bin/locust"
    ANALYSIS_PYTHON="$LAB_DIR/venv/bin/python"
elif command -v locust >/dev/null 2>&1; then
    LOCUST_BIN="$(command -v locust)"
    ANALYSIS_PYTHON="${ANALYSIS_PYTHON:-$(command -v python3)}"
else
    echo "Locust ausente. Execute: bash setup.sh" >&2
    exit 1
fi

if ! [[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || ! [[ "$DURATION_SECS" =~ ^[1-9][0-9]*$ ]]; then
    echo "REPETITIONS deve ser inteiro positivo e DURATION deve usar o formato 60s." >&2
    exit 2
fi

if [ ! -f "$LAB_DIR/certs/ca.crt" ] || [ ! -f "$LAB_DIR/certs/service_a.key" ] || [ ! -f "$LAB_DIR/certs/service_b.key" ]; then
    bash "$LAB_DIR/certs/generate_certs.sh"
fi
bash "$LAB_DIR/certs/generate_jwt_keys.sh" >/dev/null

if [ -e "$EXPERIMENT_DIR" ] && [ "${ALLOW_EXISTING_EXPERIMENT:-0}" != "1" ]; then
    echo "O diretório de experimento já existe e não será sobrescrito: $EXPERIMENT_DIR" >&2
    exit 3
fi
mkdir -p "$EXPERIMENT_DIR"
[ -f "$EXPERIMENT_DIR/scenario_order.csv" ] || printf 'round,position,scenario,started_at\n' >"$EXPERIMENT_DIR/scenario_order.csv"
if [ ! -f "$EXPERIMENT_DIR/metadata.env" ]; then
    {
        printf 'experiment_id=%s\n' "$EXPERIMENT_ID"
        printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'repetitions=%s\n' "$REPETITIONS"
        printf 'duration=%s\n' "$DURATION"
        printf 'users=%s\n' "$USERS"
        printf 'spawn_rate=%s\n' "$SPAWN_RATE"
        printf 'warmup_seconds=%s\n' "$WARMUP_SECONDS"
        printf 'cpu_limit=%s\n' "$CPU_LIMIT"
        printf 'mem_limit=%s\n' "$MEM_LIMIT"
        printf 'kernel=%s\n' "$(uname -srmo)"
        printf 'docker=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
        printf 'compose=%s\n' "$(docker compose version --short)"
        printf 'memory_bytes=%s\n' "$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)"
    } >"$EXPERIMENT_DIR/metadata.env"
fi

collect_docker_metrics() {
    local compose_file="$1"
    local duration="$2"
    local output_file="$3"
    printf 'timestamp,container,cpu_percent,memory_usage,memory_limit,memory_percent\n' >"$output_file"
    local end_time=$((SECONDS + duration))
    while [ "$SECONDS" -lt "$end_time" ]; do
        mapfile -t container_ids < <(docker compose -f "$compose_file" ps -q)
        if [ "${#container_ids[@]}" -gt 0 ]; then
            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' "${container_ids[@]}" 2>/dev/null | while IFS='|' read -r name cpu memory_block memory_percent; do
                memory_usage="$(printf '%s' "$memory_block" | awk -F' / ' '{print $1}' | tr -d ' ')"
                memory_limit="$(printf '%s' "$memory_block" | awk -F' / ' '{print $2}' | tr -d ' ')"
                printf '%s,%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$name" "$cpu" "$memory_usage" "$memory_limit" "$memory_percent" >>"$output_file"
            done
        fi
        sleep 3
    done
}

validate_checkout() {
    for attempt in $(seq 1 30); do
        if curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5000/api/v1/checkout 2>/dev/null | python3 -c 'import json,sys; body=json.load(sys.stdin); assert body.get("status")=="success"; assert body.get("inventory_status",{}).get("status")=="reserved"' 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "O Checkout não concluiu uma compra válida em 127.0.0.1:5000." >&2
    return 1
}

run_scenario() {
    local scenario_name="$1"
    local round_dir="$2"
    local result_dir="$round_dir/$scenario_name"
    local compose_file="$LAB_DIR/$scenario_name/docker-compose.yml"
    local ramp
    ramp="$(ramp_seconds)"
    mkdir -p "$result_dir"
    CURRENT_SCENARIO="$scenario_name"
    echo "==> $(basename "$round_dir") $scenario_name"
    docker compose -f "$compose_file" up -d --build --wait --wait-timeout 180
    validate_checkout
    if [ "$scenario_name" = "scenario_3" ] || [ "$scenario_name" = "scenario_4" ]; then
        record_tls_docker "$compose_file" "$result_dir/tls.txt"
    fi
    run_warmup http://127.0.0.1:5000 "$result_dir/warmup.log"

    sample_host "$result_dir/host.csv" &
    HOST_PID=$!
    collect_docker_metrics "$compose_file" "$((DURATION_SECS + ramp + 5))" "$result_dir/resources.csv" &
    CPU_PID=$!
    # O início da janela de CPU coincide com o fim da subida dos usuários (--reset-stats).
    (sleep "$ramp"; capture_cpu_stat_docker "$compose_file" start "$result_dir/cpu_stat.csv") &
    STAT_PID=$!
    run_measured_locust http://127.0.0.1:5000 "$result_dir"
    capture_cpu_stat_docker "$compose_file" end "$result_dir/cpu_stat.csv"
    wait "$STAT_PID" 2>/dev/null || true
    wait "$CPU_PID" || true
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
    CPU_PID=""; HOST_PID=""; STAT_PID=""
    docker compose -f "$compose_file" down --remove-orphans
    CURRENT_SCENARIO=""
    sleep "$COOLDOWN_SECONDS"
}

round_end=$((ROUND_START + REPETITIONS - 1))
for round_number in $(seq "$ROUND_START" "$round_end"); do
    round_dir="$EXPERIMENT_DIR/round_$(printf '%02d' "$round_number")"
    mkdir -p "$round_dir"
    mapfile -t scenario_order < <(printf '%s\n' $SCENARIOS | shuf)
    position=0
    for scenario_name in "${scenario_order[@]}"; do
        position=$((position + 1))
        printf '%s,%s,%s,%s\n' "$round_number" "$position" "$scenario_name" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/scenario_order.csv"
        run_scenario "$scenario_name" "$round_dir"
    done
done

if [ "$INCLUDE_SCENARIO_5" = "1" ]; then
    ALLOW_EXISTING_EXPERIMENT=1 SKIP_ANALYSIS=1 EXPERIMENT_ID="$EXPERIMENT_ID" EXPERIMENT_DIR="$EXPERIMENT_DIR" REPETITIONS="$REPETITIONS" ROUND_START="$ROUND_START" DURATION="$DURATION" USERS="$USERS" SPAWN_RATE="$SPAWN_RATE" WARMUP_SECONDS="$WARMUP_SECONDS" bash "$LAB_DIR/scenario_5/run_scenario_5.sh"
fi

if [ "$SKIP_ANALYSIS" != "1" ]; then
    "$ANALYSIS_PYTHON" "$LAB_DIR/tests/generate_graphs.py" "$EXPERIMENT_DIR"
fi
echo "Execução concluída sem sobrescrever rodadas anteriores: $EXPERIMENT_DIR"
