#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCENARIO_DIR/common.sh"

MODE="${1:-mesh}"
STARTUP_COMPLETE=0
cleanup_startup_failure() {
    if [ "$STARTUP_COMPLETE" = "0" ]; then
        stop_port_forward
        delete_cluster
    fi
}
trap cleanup_startup_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$MODE" != "baseline" ] && [ "$MODE" != "mesh" ]; then
    echo "Uso: $0 [baseline|mesh]" >&2
    exit 2
fi

require_tools "$([ "$MODE" = "mesh" ] && printf true || printf false)"
generate_signing_key
build_images
create_cluster
install_metrics_server
if [ "$MODE" = "mesh" ]; then
    install_istio
fi
deploy_apps "$MODE"
PF_PID=""
start_port_forward "$SCENARIO_DIR/port_forward_manual.log"
printf '%s\n' "$PF_PID" >"$SCENARIO_DIR/.pf_pid"
printf '%s\n' "$MODE" >"$SCENARIO_DIR/.manual_mode"
STARTUP_COMPLETE=1

echo "Cenário 5 ($MODE) disponível em http://127.0.0.1:5005"
echo "Para encerrar: $SCENARIO_DIR/stop_manual.sh"
