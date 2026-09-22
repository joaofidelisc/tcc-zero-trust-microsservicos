"""Cenário 1: Inventory Service sem autenticação."""

from flask import Flask, jsonify, request

app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.post("/internal/reserve-stock")
def reserve_stock():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"status": "error", "error": "invalid_json"}), 400

    item_id = data.get("item_id")
    quantity = data.get("quantity")
    if not isinstance(item_id, str) or not item_id.strip():
        return jsonify({"status": "error", "error": "invalid_item_id"}), 400
    if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity <= 0:
        return jsonify({"status": "error", "error": "invalid_quantity"}), 400

    return (
        jsonify(
            {
                "status": "reserved",
                "item_id": item_id,
                "quantity": quantity,
                "security_context": "Unsecured HTTP",
            }
        ),
        200,
    )
