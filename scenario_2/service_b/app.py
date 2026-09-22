"""Cenário 2: Inventory Service protegido por JWT HS256."""

import os
from functools import wraps

import jwt
from flask import Flask, jsonify, request

app = Flask(__name__)

JWT_SECRET = os.getenv("JWT_SECRET")
JWT_ISSUER = "zero-trust-lab"
JWT_SUBJECT = "checkout_service"

if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET deve ser definido")


def require_jwt(function):
    @wraps(function)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        scheme, separator, token = auth_header.partition(" ")
        if separator == "" or scheme.lower() != "bearer" or not token:
            return jsonify({"status": "error", "error": "missing_bearer_token"}), 401

        try:
            payload = jwt.decode(
                token,
                JWT_SECRET,
                algorithms=["HS256"],
                issuer=JWT_ISSUER,
                options={"require": ["exp", "iat", "iss", "sub"]},
            )
            if payload.get("sub") != JWT_SUBJECT:
                raise jwt.InvalidSubjectError("subject inválido")
        except jwt.PyJWTError:
            return jsonify({"status": "error", "error": "invalid_token"}), 401
        return function(*args, **kwargs)

    return decorated


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.post("/internal/reserve-stock")
@require_jwt
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
                "security_context": "HTTP + JWT Validated",
            }
        ),
        200,
    )
