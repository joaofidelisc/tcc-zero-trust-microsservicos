"""Cenário 5: Checkout Service em Kubernetes com identidade Istio."""

import base64
import datetime
import os
import threading
import time

import jwt
import requests
from cryptography.hazmat.primitives.serialization import (
    load_pem_private_key,
    load_pem_public_key,
)
from flask import Flask, jsonify, request

app = Flask(__name__)

INVENTORY_URL = os.getenv(
    "INVENTORY_URL", "http://service-b:5000/internal/reserve-stock"
)
JWT_PRIVATE_KEY_PATH = os.getenv(
    "JWT_PRIVATE_KEY_PATH", "/var/run/secrets/zt-jwt/jwt-private.pem"
)
JWT_PUBLIC_KEY_PATH = os.getenv(
    "JWT_PUBLIC_KEY_PATH", "/var/run/secrets/zt-jwt/jwt-public.pem"
)
JWT_ISSUER = "zero-trust-lab"
JWT_SUBJECT = "checkout_service"
JWT_KEY_ID = "zt-lab-rs256-2026"
# C5a (Kubernetes sem malha) roda com SIGN_JWT=false: nenhuma proteção na chamada interna,
# como o C1. Em C5b o Checkout assina o token e o Envoy do Inventory o valida.
SIGN_JWT = os.getenv("SIGN_JWT", "true").lower() == "true"
REQUEST_TIMEOUT = (1.0, 3.0)

_session_lock = threading.Lock()
_key_lock = threading.Lock()
_http_session = None
_private_key = None
_jwks = None


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
                    _private_key = load_pem_private_key(
                        key_file.read(),
                        password=None,
                    )
    return _private_key


def base64url_uint(value):
    byte_length = max(1, (value.bit_length() + 7) // 8)
    encoded = base64.urlsafe_b64encode(value.to_bytes(byte_length, "big"))
    return encoded.rstrip(b"=").decode("ascii")


def get_jwks():
    global _jwks
    if _jwks is None:
        with _key_lock:
            if _jwks is None:
                with open(JWT_PUBLIC_KEY_PATH, "rb") as key_file:
                    public_key = load_pem_public_key(key_file.read())
                numbers = public_key.public_numbers()
                _jwks = {
                    "keys": [
                        {
                            "kty": "RSA",
                            "use": "sig",
                            "alg": "RS256",
                            "kid": JWT_KEY_ID,
                            "n": base64url_uint(numbers.n),
                            "e": base64url_uint(numbers.e),
                        }
                    ]
                }
    return _jwks


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


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.get("/.well-known/jwks.json")
def jwks():
    return jsonify(get_jwks()), 200


@app.post("/api/v1/checkout")
def checkout():
    started_at = time.perf_counter()
    data = request.get_json(silent=True) or {}
    payload = {
        "item_id": data.get("item_id", "SKU-999"),
        "quantity": data.get("quantity", 1),
    }
    headers = {"Authorization": f"Bearer {generate_internal_token()}"} if SIGN_JWT else None

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
    except requests.Timeout:
        return jsonify({"status": "error", "error": "inventory_timeout"}), 504
    except requests.RequestException as exc:
        upstream_status = (
            exc.response.status_code if exc.response is not None else None
        )
        return (
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
        return jsonify({"status": "error", "error": "invalid_inventory_response"}), 502

    elapsed_ms = (time.perf_counter() - started_at) * 1000
    return (
        jsonify(
            {
                "status": "success",
                "message": "Order placed (Kubernetes workload identity)",
                "inventory_status": inventory_data,
                "internal_latency_ms": round(elapsed_ms, 2),
            }
        ),
        200,
    )
