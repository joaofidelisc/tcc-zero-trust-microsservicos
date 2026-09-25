#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 -m venv --clear "$LAB_DIR/venv"
"$LAB_DIR/venv/bin/python" -m pip install --disable-pip-version-check -r "$LAB_DIR/tests/requirements.txt"

if [ ! -f "$LAB_DIR/certs/ca.crt" ]; then
    bash "$LAB_DIR/certs/generate_certs.sh"
fi
bash "$LAB_DIR/certs/generate_jwt_keys.sh"

echo "Ambiente Python criado em $LAB_DIR/venv"
echo "Para o Cenário 5, execute também: bash $LAB_DIR/scenario_5/install_tools.sh"
