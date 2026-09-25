#!/usr/bin/env bash
# Funções de medição compartilhadas pelos cenários Docker (run_tests.sh) e Kubernetes
# (scenario_5/run_scenario_5.sh). Requer que o chamador defina LOCUST_BIN, LOCUSTFILE,
# USERS, SPAWN_RATE, DURATION_SECS e WARMUP_SECONDS.

# Segundos até todos os usuários virtuais estarem ativos (ex.: 200 / 20 = 10 s).
ramp_seconds() {
    printf '%s\n' "$(( (USERS + SPAWN_RATE - 1) / SPAWN_RATE ))"
}

# Amostra o host a cada 2 s: CPU ocupada (%), carga, frequência média (MHz) e
# temperatura máxima (°C). Roda em segundo plano até ser encerrada.
sample_host() {
    local output_file="$1"
    printf 'timestamp,cpu_busy_percent,load1,cpu_mhz_mean,temp_max_c\n' >"$output_file"
    local prev_total prev_idle
    read -r prev_total prev_idle < <(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print t, idle}' /proc/stat)
    while true; do
        sleep 2
        local total idle
        read -r total idle < <(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print t, idle}' /proc/stat)
        local busy
        busy="$(awk -v t="$((total - prev_total))" -v i="$((idle - prev_idle))" 'BEGIN { if (t > 0) printf "%.1f", 100 * (t - i) / t; else print "" }')"
        prev_total="$total"; prev_idle="$idle"
        local load1 mhz temp
        load1="$(cut -d' ' -f1 /proc/loadavg)"
        mhz="$(awk '/^cpu MHz/{s+=$4; n++} END { if (n) printf "%.0f", s/n }' /proc/cpuinfo)"
        temp="$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1 | awk '{ if ($1 != "") printf "%.1f", $1/1000 }')"
        printf '%s,%s,%s,%s,%s\n' "$(date --iso-8601=seconds)" "$busy" "$load1" "$mhz" "$temp" >>"$output_file"
    done
}

# Aquecimento com carga real (mesmos usuários e tarefa), descartado da análise.
# O Locust sai com código 1 quando alguma requisição falha; falhas são dados (ficam nas
# estatísticas) e não devem abortar a execução nem descartá-la.
run_warmup() {
    local host_url="$1"
    local log_file="$2"
    "$LOCUST_BIN" -f "$LOCUSTFILE" --headless -u "$USERS" -r "$SPAWN_RATE" \
        -t "${WARMUP_SECONDS}s" -H "$host_url" --only-summary >"$log_file" 2>&1 || true
}

# Execução medida. --reset-stats descarta a subida dos usuários: a janela estatística
# começa quando todos os usuários estão ativos e dura DURATION_SECS.
run_measured_locust() {
    local host_url="$1"
    local result_dir="$2"
    local total_seconds=$((DURATION_SECS + $(ramp_seconds)))
    "$LOCUST_BIN" -f "$LOCUSTFILE" --headless -u "$USERS" -r "$SPAWN_RATE" \
        -t "${total_seconds}s" -H "$host_url" --reset-stats \
        --csv="$result_dir/results" --csv-full-history >"$result_dir/locust.log" 2>&1 || true
    tail -n 3 "$result_dir/locust.log" | sed 's/^/    /'
}

# Contadores do cgroup v2 de cada contêiner Docker do compose (CPU total e throttling).
capture_cpu_stat_docker() {
    local compose_file="$1"
    local phase="$2"
    local output_file="$3"
    [ -f "$output_file" ] || printf 'timestamp,phase,container,key,value\n' >"$output_file"
    local now
    now="$(date --iso-8601=seconds)"
    local container_id name
    for container_id in $(docker compose -f "$compose_file" ps -q); do
        name="$(docker inspect --format '{{.Name}}' "$container_id" | sed 's#^/##')"
        docker exec "$container_id" cat /sys/fs/cgroup/cpu.stat 2>/dev/null | while read -r key value; do
            printf '%s,%s,%s,%s,%s\n' "$now" "$phase" "$name" "$key" "$value" >>"$output_file"
        done || true
    done
}

# Mesmo registro para os contêineres dos pods Kubernetes (aplicações e sidecars).
capture_cpu_stat_k8s() {
    local phase="$1"
    local output_file="$2"
    [ -f "$output_file" ] || printf 'timestamp,phase,container,key,value\n' >"$output_file"
    local now
    now="$(date --iso-8601=seconds)"
    local pod container
    while read -r pod; do
        [ -n "$pod" ] || continue
        # O Istio 1.30 injeta o Envoy como "native sidecar" (initContainers com restartPolicy
        # Always); contêineres de init já encerrados simplesmente não respondem ao exec.
        for container in $(kubectl get pod "$pod" -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}'); do
            kubectl exec "$pod" -c "$container" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null | while read -r key value; do
                printf '%s,%s,%s/%s,%s,%s\n' "$now" "$phase" "$pod" "$container" "$key" "$value" >>"$output_file"
            done || true
        done
    done < <(kubectl get pods -l 'app in (service-a,service-b)' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}

# Registra a versão de TLS e a suíte negociadas entre Checkout e Inventory (C3 e C4).
record_tls_docker() {
    local compose_file="$1"
    local output_file="$2"
    docker compose -f "$compose_file" exec -T service_a python -c '
import socket, ssl
ctx = ssl.create_default_context(cafile="/certs/ca.crt")
ctx.load_cert_chain("/certs/service_a.crt", "/certs/service_a.key")
with ctx.wrap_socket(socket.create_connection(("service_b", 5000), timeout=5), server_hostname="service_b") as s:
    print(f"tls_version={s.version()}\ncipher={s.cipher()[0]}\nkey_bits={s.cipher()[2]}")
' >"$output_file" 2>&1 || true
}
