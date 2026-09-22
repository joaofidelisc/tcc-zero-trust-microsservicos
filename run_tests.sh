#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_ROOT="$LAB_DIR/tests/runs"
LOCUSTFILE="$LAB_DIR/tests/locustfile.py"
REPETITIONS="${REPETITIONS:-5}"
DURATION="${DURATION:-60s}"
DURATION_SECS="${DURATION%s}"
USERS="${USERS:-50}"
SPAWN_RATE="${SPAWN_RATE:-10}"
WARMUP_SECONDS="${WARMUP_SECONDS:-10}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-5}"
INCLUDE_SCENARIO_5="${INCLUDE_SCENARIO_5:-0}"
EXPERIMENT_ID="${EXPERIMENT_ID:-experiment_$(date +%Y%m%d_%H%M%S)}"
EXPERIMENT_DIR="$RESULTS_ROOT/$EXPERIMENT_ID"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
export JWT_SECRET

CURRENT_SCENARIO=""
CPU_PID=""

cleanup() {
    if [ -n "${CPU_PID:-}" ] && kill -0 "$CPU_PID" 2>/dev/null; then
        kill "$CPU_PID" 2>/dev/null || true
        wait "$CPU_PID" 2>/dev/null || true
    fi
    CPU_PID=""
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

if [ -e "$EXPERIMENT_DIR" ]; then
    echo "O diretório de experimento já existe e não será sobrescrito: $EXPERIMENT_DIR" >&2
    exit 3
fi
mkdir -p "$EXPERIMENT_DIR"
printf 'round,position,scenario,started_at\n' >"$EXPERIMENT_DIR/scenario_order.csv"
{
    printf 'experiment_id=%s\n' "$EXPERIMENT_ID"
    printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'repetitions=%s\n' "$REPETITIONS"
    printf 'duration=%s\n' "$DURATION"
    printf 'users=%s\n' "$USERS"
    printf 'spawn_rate=%s\n' "$SPAWN_RATE"
    printf 'warmup_seconds=%s\n' "$WARMUP_SECONDS"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'docker=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
    printf 'compose=%s\n' "$(docker compose version --short)"
    printf 'memory_bytes=%s\n' "$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)"
} >"$EXPERIMENT_DIR/metadata.env"

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
    curl -fsS --max-time 5 -H 'Content-Type: application/json' -d '{"item_id":"SKU-999","quantity":1}' http://127.0.0.1:5000/api/v1/checkout | python3 -c 'import json,sys; body=json.load(sys.stdin); assert body.get("status")=="success"; assert body.get("inventory_status",{}).get("status")=="reserved"'
}

run_scenario() {
    local scenario_name="$1"
    local round_dir="$2"
    local result_dir="$round_dir/$scenario_name"
    local compose_file="$LAB_DIR/$scenario_name/docker-compose.yml"
    mkdir -p "$result_dir"
    CURRENT_SCENARIO="$scenario_name"
    docker compose -f "$compose_file" up -d --build --wait --wait-timeout 180
    validate_checkout
    sleep "$WARMUP_SECONDS"
    collect_docker_metrics "$compose_file" "$((DURATION_SECS + 5))" "$result_dir/resources.csv" &
    CPU_PID=$!
    "$LOCUST_BIN" -f "$LOCUSTFILE" --headless -u "$USERS" -r "$SPAWN_RATE" -t "$DURATION" -H http://127.0.0.1:5000 --csv="$result_dir/results" --csv-full-history
    wait "$CPU_PID" || true
    CPU_PID=""
    docker compose -f "$compose_file" down --remove-orphans
    CURRENT_SCENARIO=""
    sleep "$COOLDOWN_SECONDS"
}

for round_number in $(seq 1 "$REPETITIONS"); do
    round_dir="$EXPERIMENT_DIR/round_$(printf '%02d' "$round_number")"
    mkdir -p "$round_dir"
    mapfile -t scenario_order < <(printf 'scenario_1\nscenario_2\nscenario_3\nscenario_4\n' | shuf)
    position=0
    for scenario_name in "${scenario_order[@]}"; do
        position=$((position + 1))
        printf '%s,%s,%s,%s\n' "$round_number" "$position" "$scenario_name" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/scenario_order.csv"
        run_scenario "$scenario_name" "$round_dir"
    done
done

if [ "$INCLUDE_SCENARIO_5" = "1" ]; then
    ALLOW_EXISTING_EXPERIMENT=1 EXPERIMENT_ID="$EXPERIMENT_ID" EXPERIMENT_DIR="$EXPERIMENT_DIR" REPETITIONS="$REPETITIONS" DURATION="$DURATION" USERS="$USERS" SPAWN_RATE="$SPAWN_RATE" WARMUP_SECONDS="$WARMUP_SECONDS" bash "$LAB_DIR/scenario_5/run_scenario_5.sh"
fi

"$ANALYSIS_PYTHON" "$LAB_DIR/tests/generate_graphs.py" "$EXPERIMENT_DIR"
echo "Experimento concluído sem sobrescrever rodadas anteriores: $EXPERIMENT_DIR"
