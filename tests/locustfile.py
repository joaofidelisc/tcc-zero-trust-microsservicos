"""Carga externa idêntica para todos os cenários."""

from locust import HttpUser, between, task


class APITester(HttpUser):
    wait_time = between(0.1, 0.5)

    @task
    def checkout(self):
        payload = {"item_id": "SKU-999", "quantity": 1}
        with self.client.post(
            "/api/v1/checkout",
            json=payload,
            name="/api/v1/checkout",
            timeout=5,
            catch_response=True,
        ) as response:
            if response.status_code != 200:
                response.failure(f"HTTP {response.status_code}: {response.text[:200]}")
                return

            try:
                body = response.json()
            except ValueError:
                response.failure("resposta não é JSON")
                return

            inventory = body.get("inventory_status")
            if body.get("status") != "success":
                response.failure(f"checkout sem sucesso: {body}")
            elif not isinstance(inventory, dict) or inventory.get("status") != "reserved":
                response.failure(f"estoque não reservado: {body}")
            else:
                response.success()
