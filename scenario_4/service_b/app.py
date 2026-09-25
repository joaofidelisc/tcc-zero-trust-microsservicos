"""Cenário 4: Inventory Service protegido por mTLS e JWT."""

import os
import threading
from functools import wraps

import jwt
from cryptography.hazmat.primitives.serialization import load_pem_public_key
from flask import Flask, jsonify, request

app = Flask(__name__)

JWT_PUBLIC_KEY_PATH = os.getenv("JWT_PUBLIC_KEY_PATH", "/keys/jwt_public.pem")
JWT_ISSUER = "zero-trust-lab"
JWT_SUBJECT = "checkout_service"

_key_lock = threading.Lock()
_public_key = None


def get_public_key():
    global _public_key
    if _public_key is None:
        with _key_lock:
            if _public_key is None:
                with open(JWT_PUBLIC_KEY_PATH, "rb") as key_file:
                    _public_key = load_pem_public_key(key_file.read())
    return _public_key


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
                get_public_key(),
                algorithms=["RS256"],
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
                "security_context": "Internal mTLS + JWT Validated",
            }
        ),
        200,
    )
