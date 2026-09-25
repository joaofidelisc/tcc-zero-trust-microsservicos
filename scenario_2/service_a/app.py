"""Cenário 2: HTTP com JWT de aplicação na chamada interna."""

import datetime
import os
import threading
import time

import jwt
import requests
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from flask import Flask, jsonify, request

app = Flask(__name__)

INVENTORY_URL = os.getenv(
    "INVENTORY_URL", "http://service_b:5000/internal/reserve-stock"
)
JWT_PRIVATE_KEY_PATH = os.getenv("JWT_PRIVATE_KEY_PATH", "/keys/jwt_private.pem")
JWT_KEY_ID = "zt-lab-rs256-2026"
JWT_ISSUER = "zero-trust-lab"
JWT_SUBJECT = "checkout_service"
REQUEST_TIMEOUT = (1.0, 3.0)

_session_lock = threading.Lock()
_http_session = None
_key_lock = threading.Lock()
_private_key = None


def get_session():
    global _http_session
    if _http_session is None:
        with _session_lock:
            if _http_session is None:
                session = requests.Session()
                adapter = requests.adapters.HTTPAdapter(
                    pool_connections=20, pool_maxsize=50
                )
                session.mount("http://", adapter)
                _http_session = session
    return _http_session


def get_private_key():
    global _private_key
    if _private_key is None:
        with _key_lock:
            if _private_key is None:
                with open(JWT_PRIVATE_KEY_PATH, "rb") as key_file:
                    _private_key = load_pem_private_key(key_file.read(), password=None)
    return _private_key


def generate_internal_token():
    now = datetime.datetime.now(datetime.timezone.utc)
    return jwt.encode(
        {
            "iss": JWT_ISSUER,
            "sub": JWT_SUBJECT,
            "iat": now,
            "exp": now + datetime.timedelta(seconds=30),
        },
        get_private_key(),
        algorithm="RS256",
        headers={"kid": JWT_KEY_ID},
    )


def checkout_payload():
    data = request.get_json(silent=True) or {}
    return {
        "item_id": data.get("item_id", "SKU-999"),
        "quantity": data.get("quantity", 1),
    }


def call_inventory(payload):
    headers = {"Authorization": f"Bearer {generate_internal_token()}"}
    try:
        response = get_session().post(
            INVENTORY_URL,
            json=payload,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        inventory_data = response.json()
        if not isinstance(inventory_data, dict) or inventory_data.get("status") != "reserved":
            raise ValueError("resposta de negócio inválida do Inventory Service")
        return inventory_data, None
    except requests.Timeout:
        return None, (
            jsonify({"status": "error", "error": "inventory_timeout"}),
            504,
        )
    except requests.RequestException as exc:
        upstream_status = (
            exc.response.status_code if exc.response is not None else None
        )
        return None, (
            jsonify(
                {
                    "status": "error",
                    "error": "inventory_request_failed",
                    "upstream_status": upstream_status,
                }
            ),
            502,
        )
    except (AttributeError, TypeError, ValueError):
        return None, (
            jsonify({"status": "error", "error": "invalid_inventory_response"}),
            502,
        )


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.post("/api/v1/checkout")
def checkout():
    started_at = time.perf_counter()
    inventory_data, error_response = call_inventory(checkout_payload())
    if error_response is not None:
        return error_response

    elapsed_ms = (time.perf_counter() - started_at) * 1000
    return (
        jsonify(
            {
                "status": "success",
                "message": "Order placed (HTTP + JWT)",
                "inventory_status": inventory_data,
                "internal_latency_ms": round(elapsed_ms, 2),
            }
        ),
        200,
    )
