#!/usr/bin/env bash
# Experimento completo: em cada rodada, os seis cenários (C1–C4 em Docker, C5a e C5b em
# Kubernetes) são executados em ordem aleatória, com os mesmos limites de recursos.
#
# Uso: REPETITIONS=10 DURATION=120s USERS=200 SPAWN_RATE=20 WARMUP_SECONDS=15 bash run_experiment.sh
set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
REPETITIONS="${REPETITIONS:-10}"
DURATION="${DURATION:-120s}"
USERS="${USERS:-200}"
SPAWN_RATE="${SPAWN_RATE:-20}"
WARMUP_SECONDS="${WARMUP_SECONDS:-15}"
export CPU_LIMIT="${CPU_LIMIT:-1.0}"
export MEM_LIMIT="${MEM_LIMIT:-256m}"
EXPERIMENT_ID="${EXPERIMENT_ID:-experiment_$(date +%Y%m%d_%H%M%S)}"
EXPERIMENT_DIR="$LAB_DIR/tests/runs/$EXPERIMENT_ID"
source "$LAB_DIR/scenario_5/versions.env"

if [ -e "$EXPERIMENT_DIR" ]; then
    echo "O diretório de experimento já existe e não será sobrescrito: $EXPERIMENT_DIR" >&2
    exit 3
fi
if [ "$CPU_LIMIT" != "1.0" ] || [ "$MEM_LIMIT" != "256m" ]; then
    echo "Aviso: os manifestos Kubernetes usam 1 CPU e 256 MiB; CPU_LIMIT/MEM_LIMIT só alteram o Docker." >&2
fi
mkdir -p "$EXPERIMENT_DIR"

git_commit="$(git -C "$LAB_DIR" rev-parse HEAD 2>/dev/null || printf unavailable)"
git_dirty="$(git -C "$LAB_DIR" status --porcelain 2>/dev/null | grep -qv '^??' && printf yes || printf no)"
{
    printf 'experiment_id=%s\n' "$EXPERIMENT_ID"
    printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'design=six configurations interleaved and randomized in each round\n'
    printf 'repetitions=%s\n' "$REPETITIONS"
    printf 'duration=%s\n' "$DURATION"
    printf 'users=%s\n' "$USERS"
    printf 'spawn_rate=%s\n' "$SPAWN_RATE"
    printf 'warmup_seconds=%s\n' "$WARMUP_SECONDS"
    printf 'warmup=load with same users, discarded; ramp-up excluded with --reset-stats\n'
    printf 'cpu_limit=%s\n' "$CPU_LIMIT"
    printf 'mem_limit=%s\n' "$MEM_LIMIT"
    printf 'jwt=RS256 3072-bit (C2, C4, C5b); C5a without token\n'
    printf 'git_commit=%s\n' "$git_commit"
    printf 'git_uncommitted_changes=%s\n' "$git_dirty"
    printf 'cpu_model=%s\n' "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
    printf 'logical_cpus=%s\n' "$(nproc)"
    printf 'memory_bytes=%s\n' "$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)"
    printf 'os=%s\n' "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'docker=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
    printf 'compose=%s\n' "$(docker compose version --short)"
    printf 'locust=%s\n' "$("$LAB_DIR/venv/bin/locust" --version 2>/dev/null | awk '{print $2}')"
    printf 'kind=%s\n' "$KIND_VERSION"
    printf 'kubernetes=%s\n' "$KUBECTL_VERSION"
    printf 'istio=%s\n' "$ISTIO_VERSION"
    printf 'metrics_server=%s\n' "$METRICS_SERVER_VERSION"
    printf 'kind_node_image=%s\n' "$KIND_NODE_IMAGE"
    printf 'k8s_access=%s\n' "${ACCESS_MODE:-nodeport}"
} >"$EXPERIMENT_DIR/metadata.env"
git -C "$LAB_DIR" diff >"$EXPERIMENT_DIR/code.diff" 2>/dev/null || true
printf 'round,position,configuration,started_at\n' >"$EXPERIMENT_DIR/experiment_order.csv"
printf 'round,configuration,attempt,failed_at\n' >"$EXPERIMENT_DIR/failed_attempts.csv"

common_env=(
    ALLOW_EXISTING_EXPERIMENT=1 SKIP_ANALYSIS=1 REPETITIONS=1
    EXPERIMENT_ID="$EXPERIMENT_ID" EXPERIMENT_DIR="$EXPERIMENT_DIR"
    DURATION="$DURATION" USERS="$USERS" SPAWN_RATE="$SPAWN_RATE" WARMUP_SECONDS="$WARMUP_SECONDS"
)

for round_number in $(seq 1 "$REPETITIONS"); do
    mapfile -t order < <(printf '%s\n' scenario_1 scenario_2 scenario_3 scenario_4 k8s_baseline k8s_mesh | shuf)
    position=0
    for configuration in "${order[@]}"; do
        position=$((position + 1))
        printf '%s,%s,%s,%s\n' "$round_number" "$position" "$configuration" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/experiment_order.csv"
        case "$configuration" in
            scenario_*)   result_name="$configuration"; command=(bash "$LAB_DIR/run_tests.sh"); selector=(SCENARIOS="$configuration") ;;
            k8s_baseline) result_name="scenario_5_k8s_baseline"; command=(bash "$LAB_DIR/scenario_5/run_scenario_5.sh"); selector=(MODES=baseline) ;;
            k8s_mesh)     result_name="scenario_5_mesh"; command=(bash "$LAB_DIR/scenario_5/run_scenario_5.sh"); selector=(MODES=mesh) ;;
        esac
        result_dir="$EXPERIMENT_DIR/round_$(printf '%02d' "$round_number")/$result_name"
        # Uma falha transitória (ex.: rede do cluster ainda não pronta) não deve abortar o
        # experimento: a execução é descartada, registrada e repetida uma vez.
        for attempt in 1 2; do
            if env "${common_env[@]}" ROUND_START="$round_number" "${selector[@]}" "${command[@]}"; then
                break
            fi
            printf '%s,%s,%s,%s\n' "$round_number" "$configuration" "$attempt" "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/failed_attempts.csv"
            rm -rf "$result_dir"
            if [ "$attempt" = "2" ]; then
                echo "Falha repetida em $configuration (rodada $round_number); seguindo para a próxima configuração." >&2
            fi
        done
    done
done

printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$EXPERIMENT_DIR/metadata.env"
"$LAB_DIR/venv/bin/python" "$LAB_DIR/tests/generate_graphs.py" "$EXPERIMENT_DIR"
echo "Experimento concluído: $EXPERIMENT_DIR"
