import datetime
import importlib.util
import os
from pathlib import Path

import jwt
import pytest
import requests

LAB_DIR = Path(__file__).resolve().parents[1]
os.environ["JWT_SECRET"] = "test-secret-with-at-least-thirty-two-bytes"


def load_module(relative_path, module_name):
    spec = importlib.util.spec_from_file_location(module_name, LAB_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse:
    def __init__(self, status_code=200, body=None):
        self.status_code = status_code
        self._body = body or {}

    def raise_for_status(self):
        if self.status_code >= 400:
            error = requests.HTTPError(f"upstream HTTP {self.status_code}")
            error.response = self
            raise error

    def json(self):
        return self._body


class FakeSession:
    def __init__(self, response):
        self.response = response
        self.last_timeout = None

    def post(self, *args, **kwargs):
        self.last_timeout = kwargs.get("timeout")
        return self.response


@pytest.mark.parametrize(
    "scenario",
    ["scenario_1", "scenario_2", "scenario_3", "scenario_4"],
)
def test_service_a_propagates_upstream_failure(scenario):
    module = load_module(f"{scenario}/service_a/app.py", f"{scenario}_service_a_failure")
    fake_session = FakeSession(FakeResponse(status_code=401, body={"error": "denied"}))
    module._http_session = fake_session

    response = module.app.test_client().post(
        "/api/v1/checkout",
        json={"item_id": "SKU-999", "quantity": 1},
    )

    assert response.status_code == 502
    assert response.get_json()["upstream_status"] == 401
    assert fake_session.last_timeout == (1.0, 3.0)


@pytest.mark.parametrize(
    "scenario",
    ["scenario_1", "scenario_2", "scenario_3", "scenario_4"],
)
def test_service_a_requires_business_success(scenario):
    module = load_module(f"{scenario}/service_a/app.py", f"{scenario}_service_a_business")
    module._http_session = FakeSession(
        FakeResponse(status_code=200, body={"status": "rejected"})
    )

    response = module.app.test_client().post(
        "/api/v1/checkout",
        json={"item_id": "SKU-999", "quantity": 1},
    )

    assert response.status_code == 502
    assert response.get_json()["error"] == "invalid_inventory_response"


@pytest.mark.parametrize("scenario", ["scenario_2", "scenario_4"])
def test_expired_jwt_is_always_rejected(scenario):
    module = load_module(f"{scenario}/service_b/app.py", f"{scenario}_service_b_expired")
    now = datetime.datetime.now(datetime.timezone.utc)
    token = jwt.encode(
        {
            "iss": "zero-trust-lab",
            "sub": "checkout_service",
            "iat": now - datetime.timedelta(minutes=2),
            "exp": now - datetime.timedelta(minutes=1),
        },
        os.environ["JWT_SECRET"],
        algorithm="HS256",
    )

    response = module.app.test_client().post(
        "/internal/reserve-stock",
        headers={"Authorization": f"Bearer {token}"},
        json={"item_id": "SKU-999", "quantity": 1},
    )

    assert response.status_code == 401
    assert response.get_json()["error"] == "invalid_token"


@pytest.mark.parametrize("scenario", ["scenario_1", "scenario_2", "scenario_3", "scenario_4"])
def test_inventory_rejects_invalid_quantity(scenario):
    module = load_module(f"{scenario}/service_b/app.py", f"{scenario}_service_b_input")
    headers = {}
    if scenario in {"scenario_2", "scenario_4"}:
        now = datetime.datetime.now(datetime.timezone.utc)
        token = jwt.encode(
            {
                "iss": "zero-trust-lab",
                "sub": "checkout_service",
                "iat": now,
                "exp": now + datetime.timedelta(minutes=1),
            },
            os.environ["JWT_SECRET"],
            algorithm="HS256",
        )
        headers["Authorization"] = f"Bearer {token}"

    response = module.app.test_client().post(
        "/internal/reserve-stock",
        headers=headers,
        json={"item_id": "SKU-999", "quantity": 0},
    )

    assert response.status_code == 400
    assert response.get_json()["error"] == "invalid_quantity"


def test_scenario_5_caches_parsed_rsa_key_and_publishes_jwks(tmp_path, monkeypatch):
    cryptography = pytest.importorskip("cryptography")
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_path = tmp_path / "jwt-private.pem"
    public_path = tmp_path / "jwt-public.pem"
    private_path.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    public_path.write_bytes(
        private_key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    )
    monkeypatch.setenv("JWT_PRIVATE_KEY_PATH", str(private_path))
    monkeypatch.setenv("JWT_PUBLIC_KEY_PATH", str(public_path))

    module = load_module(
        "scenario_5/service_a/app.py",
        "scenario_5_service_a_rs256",
    )

    assert module.get_private_key() is module.get_private_key()
    token = module.generate_internal_token()
    assert jwt.get_unverified_header(token)["alg"] == "RS256"
    assert module.get_jwks()["keys"][0]["alg"] == "RS256"
