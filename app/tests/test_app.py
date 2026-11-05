import pytest

from app import app as flask_app


@pytest.fixture()
def client():
    flask_app.config.update(TESTING=True)
    return flask_app.test_client()


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_index_shows_version(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"Version" in response.data


def test_unknown_route_returns_404(client):
    assert client.get("/does-not-exist").status_code == 404


def test_requests_are_counted_in_metrics(client):
    client.get("/health")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert b'app_requests_total{endpoint="/health",method="GET",status="200"}' in response.data
