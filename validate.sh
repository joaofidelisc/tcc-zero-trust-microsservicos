#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"


while IFS= read -r script_path; do
    bash -n "$script_path"
done < <(find "$LAB_DIR" -type f -name '*.sh' -not -path '*/venv/*' | sort)

python3 -m compileall -q "$LAB_DIR/scenario_1" "$LAB_DIR/scenario_2" "$LAB_DIR/scenario_3" "$LAB_DIR/scenario_4" "$LAB_DIR/scenario_5" "$LAB_DIR/tests"

for scenario_name in scenario_1 scenario_2 scenario_3 scenario_4; do
    docker compose -f "$LAB_DIR/$scenario_name/docker-compose.yml" config --quiet
done

if [ -x "$LAB_DIR/venv/bin/pytest" ]; then
    "$LAB_DIR/venv/bin/pytest" -q "$LAB_DIR/tests/test_contracts.py"
else
    echo "Pytest não instalado; execute bash setup.sh para rodar os testes de contrato."
fi

echo "Validações sintáticas e de configuração concluídas."
