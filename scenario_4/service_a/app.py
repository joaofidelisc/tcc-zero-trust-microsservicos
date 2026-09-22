"""Cenário 4: HTTP externo e mTLS + JWT somente na chamada interna."""

import datetime
import os
import threading
import time

import jwt
import requests
from flask import Flask, jsonify, request

app = Flask(__name__)

INVENTORY_URL = os.getenv(
    "INVENTORY_URL", "https://service_b:5000/internal/reserve-stock"
)
JWT_SECRET = os.getenv("JWT_SECRET")
JWT_ISSUER = "zero-trust-lab"
JWT_SUBJECT = "checkout_service"
REQUEST_TIMEOUT = (1.0, 3.0)

if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET deve ser definido")

_session_lock = threading.Lock()
_http_session = None


def get_session():
    global _http_session
    if _http_session is None:
        with _session_lock:
            if _http_session is None:
                session = requests.Session()
                adapter = requests.adapters.HTTPAdapter(
                    pool_connections=20, pool_maxsize=50
                )
                session.mount("https://", adapter)
                session.cert = ("/certs/service_a.crt", "/certs/service_a.key")
                session.verify = "/certs/ca.crt"
                _http_session = session
    return _http_session


def generate_internal_token():
    now = datetime.datetime.now(datetime.timezone.utc)
    return jwt.encode(
        {
            "iss": JWT_ISSUER,
            "sub": JWT_SUBJECT,
            "iat": now,
            "exp": now + datetime.timedelta(seconds=30),
        },
        JWT_SECRET,
        algorithm="HS256",
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
                "message": "Order placed (Internal mTLS + JWT)",
                "inventory_status": inventory_data,
                "internal_latency_ms": round(elapsed_ms, 2),
            }
        ),
        200,
    )
