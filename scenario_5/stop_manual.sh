#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCENARIO_DIR/common.sh"

if [ -f "$SCENARIO_DIR/.pf_pid" ]; then
    PF_PID="$(sed -n '1p' "$SCENARIO_DIR/.pf_pid")"
    stop_port_forward
    rm -f "$SCENARIO_DIR/.pf_pid"
fi
rm -f "$SCENARIO_DIR/.manual_mode"
delete_cluster
echo "Cluster $CLUSTER_NAME e port-forward do laboratório foram encerrados."
